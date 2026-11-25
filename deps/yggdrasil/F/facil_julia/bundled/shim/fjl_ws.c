#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "fjl_ws.h"

#include <websockets.h>

#include <errno.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* ---- per-connection state: the facil.io WebSocket's udata ---- */

typedef struct fjl_sub_s {
  struct fjl_sub_s *next;
  uintptr_t id;
  size_t len;
  char name[];
} fjl_sub_s;

typedef struct {
  void *jl;
  fjl_sub_s *subs; /* touched only under the connection's task lock */
  size_t max_msg;
  unsigned flags;
  int opened;
} fjl_ws_s;

static fjl_ws_callbacks_s cbs;

void fjl_ws_init(const fjl_ws_callbacks_s *cb) { cbs = *cb; }

/* The connection whose callback is running on this thread, so calls made
 * from inside it skip the lock and the deferral. */
static __thread intptr_t cur_uuid = -1;
static __thread ws_s *cur_ws;

#define ENTER(ws_)                                                             \
  const intptr_t prev_uuid = cur_uuid;                                         \
  ws_s *const prev_ws = cur_ws;                                                \
  cur_uuid = websocket_uuid(ws_);                                              \
  cur_ws = (ws_)
#define LEAVE()                                                                \
  cur_uuid = prev_uuid;                                                        \
  cur_ws = prev_ws

static void tr_open(ws_s *ws) {
  fjl_ws_s *c = websocket_udata_get(ws);
  c->opened = 1;
  websocket_max_msg_size_set(ws, c->max_msg);
  if (c->flags & FJL_WS_NO_UTF8)
    websocket_utf8_check_set(ws, 0);
  ENTER(ws);
  cbs.on_open(c->jl, websocket_uuid(ws));
  LEAVE();
}

static void tr_message(ws_s *ws, fio_str_info_s msg, uint8_t is_text) {
  fjl_ws_s *c = websocket_udata_get(ws);
  ENTER(ws);
  cbs.on_message(c->jl, websocket_uuid(ws), msg.data, msg.len, is_text);
  LEAVE();
}

static void tr_ready(ws_s *ws) {
  fjl_ws_s *c = websocket_udata_get(ws);
  ENTER(ws);
  cbs.on_ready(c->jl, websocket_uuid(ws));
  LEAVE();
}

static void tr_shutdown(ws_s *ws) {
  fjl_ws_s *c = websocket_udata_get(ws);
  ENTER(ws);
  cbs.on_shutdown(c->jl, websocket_uuid(ws));
  LEAVE();
}

static void tr_close(intptr_t uuid, void *udata) {
  fjl_ws_s *c = udata;
  if (!c)
    return;
  if (cur_uuid == uuid && uuid > 0) {
    cur_uuid = -1;
    cur_ws = NULL;
  }
  cbs.on_close(c->jl, uuid, c->opened);
  while (c->subs) {
    fjl_sub_s *s = c->subs;
    c->subs = s->next;
    free(s);
  }
  free(c);
}

/* ---- permessage-deflate: zlib-ng compresses, libdeflate decompresses ---- */

typedef struct {
  const uint8_t *next_in;
  uint32_t avail_in;
  size_t total_in;
  uint8_t *next_out;
  uint32_t avail_out;
  size_t total_out;
  const char *msg;
  void *state;
  void *zalloc, *zfree, *opaque;
  int data_type;
  uint32_t adler;
  unsigned long reserved;
} zng_stream_s; /* zlib-ng's zng_stream */

static int (*zng_init2)(zng_stream_s *, int, int, int, int, int);
static int (*zng_deflate)(zng_stream_s *, int);
static int (*zng_reset)(zng_stream_s *);
static int (*zng_end)(zng_stream_s *);
static void *(*ld_alloc_d)(void);
static int (*ld_decompress)(void *d, const void *in, size_t len, void *out,
                            size_t cap, size_t *got);
static __thread zng_stream_s *zc;
static __thread int zc_level;
static __thread void *ld_d;

/* Raw DEFLATE ending in a sync flush, with its 00 00 ff ff removed. */
static size_t zng_compress_fn(const void *in, size_t len, void *out,
                              size_t cap, int level) {
  if (zc && zc_level != level) {
    zng_end(zc);
    free(zc);
    zc = NULL;
  }
  if (!zc) {
    zc = calloc(1, sizeof(*zc));
    if (!zc)
      return 0;
    if (zng_init2(zc, level, 8, -15, 8, 0) != 0) {
      free(zc);
      zc = NULL;
      return 0;
    }
    zc_level = level;
  }
  zc->next_in = in;
  zc->avail_in = (uint32_t)len;
  zc->next_out = out;
  zc->avail_out = (uint32_t)cap;
  const int r = zng_deflate(zc, 2 /* Z_SYNC_FLUSH */);
  const size_t n = cap - zc->avail_out;
  const int ok = r == 0 && !zc->avail_in && zc->avail_out && n >= 4;
  zng_reset(zc);
  return ok ? n - 4 : 0;
}

static int ld_decompress_fn(const void *in, size_t len, void *out, size_t cap,
                            size_t *got) {
  if (!ld_d && !(ld_d = ld_alloc_d()))
    return 2;
  const int r = ld_decompress(ld_d, in, len, out, cap, got);
  return r == 0 ? 0 : r == 3 ? 1 : 2; /* LIBDEFLATE_INSUFFICIENT_SPACE = 3 */
}

void fjl_ws_codec(void *init2, void *deflate, void *reset, void *end,
                  void *alloc_d, void *decompress) {
  if (!(init2 && deflate && reset && end && alloc_d && decompress)) {
    websocket_deflate_codec_set(NULL, NULL);
    return;
  }
  zng_init2 = (int (*)(zng_stream_s *, int, int, int, int, int))init2;
  zng_deflate = (int (*)(zng_stream_s *, int))deflate;
  zng_reset = (int (*)(zng_stream_s *))reset;
  zng_end = (int (*)(zng_stream_s *))end;
  ld_alloc_d = (void *(*)(void))alloc_d;
  ld_decompress = (int (*)(void *, const void *, size_t, void *, size_t,
                           size_t *))decompress;
  websocket_deflate_codec_set(zng_compress_fn, ld_decompress_fn);
}

/* ---- upgrade ---- */

static int deflate_level = 1;
static size_t deflate_min = 128;
static atomic_int deflate_on;

void fjl_ws_deflate_config(int level, size_t min_size) {
  deflate_level = level;
  deflate_min = min_size;
  if (atomic_load(&deflate_on))
    websocket_deflate_set(1, level, min_size);
}

int fjl_ws_upgrade(http_s *h, void *jl, unsigned flags, size_t max_msg,
                   const char *subprotocol, size_t sp_len) {
  fjl_ws_s *c = calloc(1, sizeof(*c));
  if (!c)
    return -1;
  c->jl = jl;
  c->max_msg = max_msg;
  c->flags = flags;
  if (flags & FJL_WS_DEFLATE) {
    if (!atomic_exchange(&deflate_on, 1))
      websocket_deflate_set(1, deflate_level, deflate_min);
  } else if (atomic_load(&deflate_on) && h->headers) {
    /* deflate is offered process-wide; this route declines it */
    static uintptr_t ext = 0;
    if (!ext)
      ext = fiobj_hash_string("sec-websocket-extensions", 24);
    fiobj_hash_delete2(h->headers, ext);
  }
  if (subprotocol && sp_len)
    http_set_header2(
        h, (fio_str_info_s){.data = "sec-websocket-protocol", .len = 22},
        (fio_str_info_s){.data = (char *)subprotocol, .len = sp_len});
  return http_upgrade2ws(h, .on_open = tr_open, .on_message = tr_message,
                         .on_ready = (flags & FJL_WS_READY) ? tr_ready : NULL,
                         .on_shutdown =
                             (flags & FJL_WS_SHUTDOWN) ? tr_shutdown : NULL,
                         .on_close = tr_close, .udata = c);
}

/* ---- calls from any thread ---- */

/* Locks the connection's protocol for writing. The lock is held only for
 * short writes, never across a callback, so spinning on it is safe. */
static ws_s *lock_write(intptr_t uuid) {
  for (unsigned i = 0;; ++i) {
    fio_protocol_s *pr = fio_protocol_try_lock(uuid, FIO_PR_LOCK_WRITE);
    if (pr) {
      if (!fio_is_valid(uuid)) {
        fio_protocol_unlock(pr, FIO_PR_LOCK_WRITE);
        return NULL;
      }
      return (ws_s *)pr;
    }
    if (errno == EBADF)
      return NULL;
    if (i & 63)
      continue;
    sched_yield();
  }
}

int fjl_ws_send(intptr_t uuid, const char *data, size_t len, int is_text) {
  fio_str_info_s m = {.data = (char *)data, .len = len};
  if (uuid == cur_uuid)
    return websocket_write(cur_ws, m, (uint8_t)is_text) ? -1 : 0;
  ws_s *ws = lock_write(uuid);
  if (!ws)
    return -1;
  const int r = websocket_write(ws, m, (uint8_t)is_text);
  fio_protocol_unlock((fio_protocol_s *)ws, FIO_PR_LOCK_WRITE);
  return r ? -1 : 0;
}

size_t fjl_ws_pending(intptr_t uuid) { return fio_pending_bytes(uuid); }

/* Work that needs the connection's task lock: done in place from inside one
 * of its callbacks, otherwise deferred to the reactor. */
typedef struct {
  int op;
  int arg;
  size_t len;
  char data[];
} ws_op_s;

enum { OP_CLOSE, OP_SUB, OP_UNSUB, OP_PAUSE };

static int sub_add(ws_s *ws, const char *ch, size_t len, int mode) {
  fjl_ws_s *c = websocket_udata_get(ws);
  for (fjl_sub_s *s = c->subs; s; s = s->next)
    if (s->len == len && !memcmp(s->name, ch, len))
      return 0;
  fjl_sub_s *s = malloc(sizeof(*s) + len);
  if (!s)
    return -1;
  memcpy(s->name, ch, len);
  s->len = len;
  s->id = websocket_subscribe(ws, .channel = {.data = s->name, .len = len},
                              .force_text = mode == 1,
                              .force_binary = mode == 2);
  if (!s->id) {
    free(s);
    return -1;
  }
  s->next = c->subs;
  c->subs = s;
  return 0;
}

static int sub_remove(ws_s *ws, const char *ch, size_t len) {
  fjl_ws_s *c = websocket_udata_get(ws);
  for (fjl_sub_s **p = &c->subs; *p; p = &(*p)->next) {
    fjl_sub_s *s = *p;
    if (s->len == len && !memcmp(s->name, ch, len)) {
      *p = s->next;
      websocket_unsubscribe(ws, s->id);
      free(s);
      return 0;
    }
  }
  return -1;
}

static int op_run(ws_s *ws, int op, int arg, const char *data, size_t len) {
  switch (op) {
  case OP_CLOSE:
    websocket_close3(ws, (uint16_t)arg, data, len);
    return 0;
  case OP_SUB:
    return sub_add(ws, data, len, arg);
  case OP_UNSUB:
    return sub_remove(ws, data, len);
  case OP_PAUSE:
    websocket_read_pause(ws, arg);
    return 0;
  }
  return -1;
}

static void op_task(intptr_t uuid, fio_protocol_s *pr, void *udata) {
  ws_op_s *o = udata;
  ENTER((ws_s *)pr);
  op_run((ws_s *)pr, o->op, o->arg, o->data, o->len);
  LEAVE();
  free(o);
  (void)uuid;
}

static void op_fallback(intptr_t uuid, void *udata) {
  free(udata);
  (void)uuid;
}

static int op_submit(intptr_t uuid, int op, int arg, const char *data,
                     size_t len) {
  if (uuid == cur_uuid)
    return op_run(cur_ws, op, arg, data, len);
  if (!fio_is_valid(uuid))
    return -1;
  ws_op_s *o = malloc(sizeof(*o) + len);
  if (!o)
    return -1;
  o->op = op;
  o->arg = arg;
  o->len = len;
  if (len)
    memcpy(o->data, data, len);
  fio_defer_io_task(uuid, .type = FIO_PR_LOCK_TASK, .task = op_task,
                    .udata = o, .fallback = op_fallback);
  if (!fjl_on_reactor())
    fjl_wake();
  return 0;
}

int fjl_ws_close(intptr_t uuid, int code, const char *reason, size_t len) {
  return op_submit(uuid, OP_CLOSE, code, reason, len);
}
int fjl_ws_subscribe(intptr_t uuid, const char *ch, size_t len, int mode) {
  return op_submit(uuid, OP_SUB, mode, ch, len);
}
int fjl_ws_unsubscribe(intptr_t uuid, const char *ch, size_t len) {
  return op_submit(uuid, OP_UNSUB, 0, ch, len);
}
int fjl_ws_read_pause(intptr_t uuid, int pause) {
  return op_submit(uuid, OP_PAUSE, pause, NULL, 0);
}

/* ---- process-local pub/sub ---- */

static void (*ps_message_cb)(void *, const char *, size_t, const char *,
                             size_t);
static void (*ps_unsub_cb)(void *);

void fjl_ps_init(void (*on_message)(void *, const char *, size_t,
                                    const char *, size_t),
                 void (*on_unsubscribe)(void *)) {
  ps_message_cb = on_message;
  ps_unsub_cb = on_unsubscribe;
}

static void ps_message(fio_msg_s *m) {
  ps_message_cb(m->udata1, m->channel.data, m->channel.len, m->msg.data,
                m->msg.len);
}

static void ps_unsubscribe(void *u1, void *u2) {
  ps_unsub_cb(u1);
  (void)u2;
}

void *fjl_ps_subscribe(const char *ch, size_t len, void *jl) {
  return fio_subscribe(.channel = {.data = (char *)ch, .len = len},
                       .on_message = ps_message,
                       .on_unsubscribe = ps_unsubscribe, .udata1 = jl);
}

void fjl_ps_unsubscribe(void *sub) {
  fio_unsubscribe(sub);
  if (!fjl_on_reactor())
    fjl_wake();
}

int fjl_ps_publish(const char *ch, size_t ch_len, const char *msg,
                   size_t len) {
  fio_publish(.engine = FIO_PUBSUB_PROCESS,
              .channel = {.data = (char *)ch, .len = ch_len},
              .message = {.data = (char *)msg, .len = len});
  if (!fjl_on_reactor())
    fjl_wake();
  return 0;
}
