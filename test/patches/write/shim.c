#include "fio.h"
#include "http.h"
#include "http_internal.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct { const char *ptr; size_t len; } jl_slice;

static inline jl_slice slice_of(FIOBJ o) {
  jl_slice s = {NULL, 0};
  if (!o || FIOBJ_IS_NULL(o))
    return s;
  fio_str_info_s i = fiobj_obj2cstr(o);
  s.ptr = i.data;
  s.len = i.len;
  return s;
}

void shim_req(http_s *h, jl_slice *path, jl_slice *query) {
  *path = slice_of(h->path);
  *query = slice_of(h->query);
}

static void set_headers(http_s *h, int status, const jl_slice *names,
                        const jl_slice *values, int n) {
  h->status = (uintptr_t)status;
  for (int i = 0; i < n; i++)
    http_set_header2(h,
                     (fio_str_info_s){.data = (char *)names[i].ptr, .len = names[i].len},
                     (fio_str_info_s){.data = (char *)values[i].ptr, .len = values[i].len});
}

int shim_respond(http_s *h, int status, const jl_slice *names,
                 const jl_slice *values, int n, const char *body, size_t len) {
  set_headers(h, status, names, values, n);
  return http_send_body(h, (void *)body, len);
}

int http_send_body_nocopy(http_s *r, void *data, uintptr_t length,
                          void (*dealloc)(void *), int gather);
int shim_respond_nocopy(http_s *h, int status, const jl_slice *names,
                        const jl_slice *values, int n, const char *body,
                        size_t len, void (*dealloc)(void *), int gather) {
  set_headers(h, status, names, values, n);
  return http_send_body_nocopy(h, (void *)body, len, dealloc, gather);
}

void shim_gather_set(int on) { fio_gather_writes = on; }

/* ---- waking the reactor from another thread ---- */

static int wake_fd[2] = {-1, -1};
static atomic_int wake_pending;
static atomic_ulong n_wakes;

static void wake_on_data(intptr_t uuid, fio_protocol_s *pr) {
  char buf[256];
  while (read(wake_fd[0], buf, sizeof(buf)) > 0)
    ;
  /* Cleared only after the drain, so a waker that skipped its write has
   * its task picked up before the next poll. */
  atomic_store(&wake_pending, 0);
  (void)uuid;
  (void)pr;
}
static void wake_ping(intptr_t uuid, fio_protocol_s *pr) {
  fio_touch(uuid);
  (void)pr;
}
static void wake_on_close(intptr_t uuid, fio_protocol_s *pr) {
  (void)uuid;
  (void)pr;
}
static fio_protocol_s wake_protocol = {
    .on_data = wake_on_data, .ping = wake_ping, .on_close = wake_on_close};
static void wake_attach(void *ignr) {
  fio_attach_fd(wake_fd[0], &wake_protocol);
  (void)ignr;
}
int shim_wake_init(void) {
  if (pipe(wake_fd))
    return -1;
  fio_set_non_block(wake_fd[0]);
  fio_set_non_block(wake_fd[1]);
  fio_state_callback_add(FIO_CALL_ON_START, wake_attach, NULL);
  return 0;
}
void shim_wake(void) {
  if (wake_fd[1] < 0)
    return;
  if (atomic_exchange(&wake_pending, 1) == 0) {
    char c = 1;
    (void)!write(wake_fd[1], &c, 1);
    atomic_fetch_add(&n_wakes, 1);
  }
}
unsigned long shim_wakes(void) { return atomic_load(&n_wakes); }

/* ---- streaming, new write path ---- */

intptr_t http1_stream_begin(http_s *h, int mode);
void http1_stream_end(intptr_t uuid);
void http1_stream_end_now(intptr_t uuid);

enum { SHIM_LAST = 4, SHIM_COPY = 8, SHIM_WAKE = 16 };

static void set_stream_headers(http_s *h) {
  http_set_header2(h, (fio_str_info_s){.data = (char *)"content-type", .len = 12},
                   (fio_str_info_s){.data = (char *)"text/plain", .len = 10});
  http_set_header2(h, (fio_str_info_s){.data = (char *)"transfer-encoding", .len = 17},
                   (fio_str_info_s){.data = (char *)"chunked", .len = 7});
}

/* Sends a chunked head and holds the parser. `link` is handed to `on_gone`
 * if the connection closes before `shim_stream_end`. */
intptr_t shim_stream_begin(http_s *h, int mode, void *link,
                           void (*on_gone)(void *)) {
  set_stream_headers(h);
  intptr_t uuid = http1_stream_begin(h, mode);
  if (uuid != -1 && on_gone)
    fio_uuid_link(uuid, link, on_gone);
  return uuid;
}

static inline int hex_line(char *out, size_t l) {
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
  return k;
}

/* One chunk as a single packet: size line, the caller's bytes, CRLF. Returns
 * the connection's pending bytes or -1 (dealloc has then been called). */
ssize_t shim_stream_write(intptr_t uuid, const char *d, size_t l,
                          void (*dealloc)(void *), int flags) {
  char pre[20];
  int sched = 0;
  ssize_t r = fio_write_framed(
      uuid,
      (fio_write_framed_args_s){.buffer = d,
                                .length = l,
                                .dealloc = dealloc,
                                .pre = pre,
                                .pre_len = (uint8_t)hex_line(pre, l),
                                .post = "\r\n0\r\n\r\n",
                                .post_len = (flags & SHIM_LAST) ? 7 : 2,
                                .mode = flags & 3,
                                .copy = !!(flags & SHIM_COPY)},
      &sched);
  if (sched && (flags & SHIM_WAKE))
    shim_wake();
  return r;
}

ssize_t shim_stream_last(intptr_t uuid, int flags) {
  int sched = 0;
  ssize_t r = fio_write_framed(
      uuid,
      (fio_write_framed_args_s){.pre = "0\r\n\r\n", .pre_len = 5, .mode = flags & 3},
      &sched);
  if (sched && (flags & SHIM_WAKE))
    shim_wake();
  return r;
}

void shim_flush(intptr_t uuid, int wake) {
  if (fio_flush_or_schedule(uuid) && wake)
    shim_wake();
}

/* how: 0 inside the request callback, 1 elsewhere on the reactor, 2 from
 * another thread. */
void shim_stream_end(intptr_t uuid, void *link, int how) {
  if (link)
    fio_uuid_unlink(uuid, link);
  if (how == 0) {
    http1_stream_end_now(uuid);
  } else {
    http1_stream_end(uuid);
    if (how == 2)
      shim_wake();
  }
}

/* ---- streaming, baseline (copying) path as in v8_stream ---- */

static int will_close(http_s *h) {
  static uint64_t ch;
  if (!ch)
    ch = fiobj_hash_string("connection", 10);
  fio_str_info_s s;
  FIOBJ t = fiobj_hash_get2(h->private_data.out_headers, ch);
  if (t) {
    s = fiobj_obj2cstr(t);
    return s.data[0] == 'c' || s.data[0] == 'C';
  }
  t = fiobj_hash_get2(h->headers, ch);
  if (t) {
    s = fiobj_obj2cstr(t);
    return !(!s.data || !s.len || s.data[0] == 'k' || s.data[0] == 'K');
  }
  s = fiobj_obj2cstr(h->version);
  return !(s.len > 7 && s.data && s.data[5] == '1' && s.data[6] == '.' &&
           s.data[7] == '1');
}
static const char HIJACK_HEAD[] =
    "HTTP/1.1 200 OK\r\ncontent-type:text/plain\r\nconnection:close\r\n"
    "transfer-encoding:chunked\r\n\r\n";
intptr_t shim_stream_hijack(http_s *h) {
  intptr_t uuid = http_hijack(h, NULL);
  fio_write2(uuid, .data.buffer = HIJACK_HEAD, .length = sizeof(HIJACK_HEAD) - 1,
             .after.dealloc = FIO_DEALLOC_NOOP);
  return uuid;
}
intptr_t shim_stream_stock(http_s *h, int *closing) {
  if ((*closing = will_close(h)))
    return shim_stream_hijack(h);
  intptr_t uuid = http2protocol(h)->uuid;
  set_stream_headers(h);
  ((http_vtable_s *)h->private_data.vtbl)->http_finish(h);
  return uuid;
}
intptr_t shim_stream_begin_old(http_s *h) {
  set_stream_headers(h);
  return http1_stream_begin(h, FIO_WRITE_EAGER);
}
ssize_t shim_write_chunk(intptr_t uuid, const char *d, size_t l) {
  char *c = fio_malloc(l + 24);
  int n = snprintf(c, 20, "%zx\r\n", l);
  memcpy(c + n, d, l);
  c[n + l] = '\r';
  c[n + l + 1] = '\n';
  return fio_write2(uuid, .data.buffer = c, .length = n + l + 2,
                    .after.dealloc = fio_free);
}
ssize_t shim_write_copy(intptr_t uuid, const char *d, size_t l) {
  void *c = fio_malloc(l);
  memcpy(c, d, l);
  return fio_write2(uuid, .data.buffer = c, .length = l, .after.dealloc = fio_free);
}
ssize_t shim_write_last(intptr_t uuid) {
  return fio_write2(uuid, .data.buffer = "0\r\n\r\n", .length = 5,
                    .after.dealloc = FIO_DEALLOC_NOOP);
}
