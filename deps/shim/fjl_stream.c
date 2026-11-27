#include "fjl_stream.h"

#include <http1.h>
#include <http_internal.h>

#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* ---- streamed responses ---- */

static int is_http11(http_s *h) {
  fio_str_info_s v = fiobj_obj2cstr(h->version);
  return v.len == 8 && !memcmp(v.data, "HTTP/1.1", 8);
}

static int is_head(http_s *h) {
  fio_str_info_s m = fiobj_obj2cstr(h->method);
  return m.len == 4 && !strncasecmp(m.data, "head", 4);
}

/* Streamed heads skip http_finish, which adds `date` to other responses. */
static void date_if_missing(http_s *h) {
  static uint64_t date_hash = 0;
  if (!date_hash)
    date_hash = fiobj_hash_string("date", 4);
  if (fiobj_hash_get2(h->private_data.out_headers, date_hash))
    return;
  FIOBJ d = fiobj_str_buf(32);
  fiobj_str_resize(d, http_time2str(fiobj_obj2cstr(d).data,
                                    fio_last_tick().tv_sec));
  http_set_header(h, HTTP_HEADER_DATE, d);
}

intptr_t fjl_stream_begin(http_s *h, int status, int *info) {
  *info = 0;
  if (!h || HTTP_INVALID_HANDLE(h))
    return -1;
  int flags = 0;
  if (http_settings(h)->tls)
    flags |= FJL_STREAM_TLS;
  if (is_head(h))
    flags |= FJL_STREAM_HEAD;
  h->status = (uintptr_t)status;
  date_if_missing(h);
  if (is_http11(h)) {
    flags |= FJL_STREAM_CHUNKED;
    http_set_header2(
        h, (fio_str_info_s){.data = (char *)"transfer-encoding", .len = 17},
        (fio_str_info_s){.data = (char *)"chunked", .len = 7});
  } else {
    /* Without chunked framing the end of the body is the end of the
     * connection. */
    http_set_header(h, HTTP_HEADER_CONNECTION, fiobj_dup(HTTP_HVALUE_CLOSE));
  }
  intptr_t uuid = http1_stream_begin(h, FIO_WRITE_LAZY);
  *info = flags;
  return uuid;
}

int fjl_stream_link(intptr_t uuid, void *udata, void (*on_gone)(void *)) {
  fio_uuid_link(uuid, udata, on_gone);
  return 0;
}

static inline uint8_t hex_line(char *out, size_t l) {
  char tmp[16];
  int n = 0, k = 0;
  do {
    tmp[n++] = "0123456789abcdef"[l & 15];
    l >>= 4;
  } while (l);
  while (n)
    out[k++] = tmp[--n];
  out[k++] = '\r';
  out[k++] = '\n';
  return (uint8_t)k;
}

static void wake_if(int scheduled, int flags) {
  if (scheduled && (flags & FJL_W_WAKE))
    fjl_wake();
}

ssize_t fjl_stream_write(intptr_t uuid, const char *data, size_t len,
                         void (*dealloc)(void *), int flags) {
  char pre[20];
  int sched = 0;
  const int chunked = flags & FJL_W_CHUNKED;
  const int last = flags & FJL_W_LAST;
  fio_write_framed_args_s a = {
      .buffer = data,
      .length = len,
      .dealloc = dealloc,
      .mode = (uint8_t)(flags & FJL_W_MODE),
      .copy = !!(flags & FJL_W_COPY),
  };
  if (chunked && len) {
    a.pre = pre;
    a.pre_len = hex_line(pre, len);
    a.post = "\r\n0\r\n\r\n";
    a.post_len = last ? 7 : 2;
  } else if (chunked && last) {
    a.pre = "0\r\n\r\n";
    a.pre_len = 5;
  }
  ssize_t r = fio_write_framed(uuid, a, &sched);
  wake_if(sched, flags);
  return r;
}

void fjl_stream_end(intptr_t uuid, void *udata, int chunked, int how) {
  if (udata)
    fio_uuid_unlink(uuid, udata);
  (void)chunked;
  if (how == 0) {
    http1_stream_end_now(uuid);
  } else {
    http1_stream_end(uuid);
    if (how == 2)
      fjl_wake();
  }
}

static void flush_task(void *uuid, void *ignr) {
  fio_flush_or_schedule((intptr_t)uuid);
  (void)ignr;
}

void fjl_stream_flush(intptr_t uuid, int on_caller) {
  if (on_caller) {
    if (fio_flush_or_schedule(uuid))
      fjl_wake();
  } else {
    fio_defer(flush_task, (void *)uuid, NULL);
    fjl_wake();
  }
}

/* ---- SSE ---- */

typedef struct {
  http_sse_s **out;
  void *udata;
  void (*on_close)(void *);
} sse_ctx;

static void sse_open(http_sse_s *sse) {
  sse_ctx *c = sse->udata;
  if (c->out) {
    *c->out = http_sse_dup(sse);
    c->out = NULL;
  }
}

static void sse_close(http_sse_s *sse) {
  sse_ctx *c = sse->udata;
  if (!c)
    return;
  if (c->on_close)
    c->on_close(c->udata);
  free(c);
}

/* facil.io's SSE protocol has no reader, so a paused-then-upgraded
 * connection would never notice the client leaving. This one drains (and
 * ignores) input; reading EOF closes the connection. */
static void sse_on_data(intptr_t uuid, fio_protocol_s *pr) {
  char buf[512];
  while (fio_read(uuid, buf, sizeof(buf)) > 0)
    ;
  (void)pr;
}

static void sse_watch_input(intptr_t uuid) {
  fio_protocol_s *pr = fio_protocol_try_lock(uuid, FIO_PR_LOCK_WRITE);
  if (!pr)
    return;
  pr->on_data = sse_on_data;
  fio_protocol_unlock(pr, FIO_PR_LOCK_WRITE);
  fio_force_event(uuid, FIO_EVENT_ON_DATA);
}

http_sse_s *fjl_sse_upgrade(http_s *h, void *udata, void (*on_close)(void *),
                            intptr_t *uuid, int *tls) {
  *uuid = -1;
  *tls = 0;
  if (!h || HTTP_INVALID_HANDLE(h))
    return NULL;
  sse_ctx *c = calloc(1, sizeof(*c));
  if (!c)
    return NULL;
  http_sse_s *dup = NULL;
  c->out = &dup;
  c->udata = udata;
  c->on_close = on_close;
  *tls = http_settings(h)->tls != NULL;
  date_if_missing(h);
  /* on_open runs inside the call; c may be freed (by on_close) before it
   * returns, so only the local is read afterwards. */
  if (http_upgrade2sse(h, .on_open = sse_open, .on_close = sse_close,
                       .udata = c) || !dup)
    return NULL;
  *uuid = http_sse2uuid(dup);
  if (*uuid != -1)
    sse_watch_input(*uuid);
  return dup;
}

int fjl_sse_close(http_sse_s *sse) {
  if (!sse)
    return -1;
  int r = http_sse_close(sse);
  if (!fjl_on_reactor())
    fjl_wake();
  return r;
}

void fjl_sse_free(http_sse_s *sse) {
  if (sse)
    http_sse_free(sse);
}

/* ---- static files ---- */

void fjl_mime_register(const char *ext, size_t elen, const char *type,
                       size_t tlen) {
  http_mimetype_register((char *)ext, elen, FIOBJ_INVALID);
  http_mimetype_register((char *)ext, elen, fiobj_str_new(type, tlen));
}

size_t fjl_mime_find(const char *ext, size_t elen, char *buf, size_t cap) {
  FIOBJ m = http_mimetype_find((char *)ext, elen);
  if (!m)
    return 0;
  fio_str_info_s s = fiobj_obj2cstr(m);
  size_t n = s.len < cap ? s.len : cap;
  memcpy(buf, s.data, n);
  fiobj_free(m);
  return n;
}

int fjl_sendfile(http_s *h, int status, const char *path, size_t len) {
  if (!h || HTTP_INVALID_HANDLE(h) || !len)
    return -1;
  h->status = (uintptr_t)status;
  return http_sendfile2(h, path, len, NULL, 0);
}
