#include "fio.h"
#include "http.h"
#include "websockets.h"
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

typedef struct { const char *ptr; size_t len; } jl_slice;

static jl_slice slice_of(FIOBJ o) {
  jl_slice s = {NULL, 0};
  if (!o || FIOBJ_IS_NULL(o))
    return s;
  fio_str_info_s i = fiobj_obj2cstr(o);
  s.ptr = i.data;
  s.len = i.len;
  return s;
}
void shim_path(http_s *h, jl_slice *path, jl_slice *query) {
  *path = slice_of(h->path);
  *query = slice_of(h->query);
}

int shim_respond(http_s *h, const char *ctype, size_t ctlen, const char *body, size_t len) {
  http_set_header2(h, (fio_str_info_s){.data = "content-type", .len = 12},
                   (fio_str_info_s){.data = (char *)ctype, .len = ctlen});
  return http_send_body(h, (void *)body, len);
}

/* ---- WebSocket ---- */
static void (*jl_ws_msg)(ws_s *, const char *, size_t, int);
static void (*jl_ws_open)(ws_s *);
static void (*jl_ws_close)(intptr_t, void *);
void shim_ws_cbs(void *m, void *o, void *c) {
  jl_ws_msg = m;
  jl_ws_open = o;
  jl_ws_close = c;
}
static void ws_msg_tr(ws_s *ws, fio_str_info_s m, uint8_t t) {
  jl_ws_msg(ws, m.data, m.len, t);
}
int shim_upgrade2ws(http_s *h, void *udata) {
  return http_upgrade2ws(h, .on_message = ws_msg_tr, .on_open = jl_ws_open,
                         .on_close = jl_ws_close, .udata = udata);
}
int shim_ws_write(ws_s *ws, const char *d, size_t l, int t) {
  return websocket_write(ws, (fio_str_info_s){.data = (char *)d, .len = l}, t);
}
uintptr_t shim_ws_subscribe(ws_s *ws, const char *c, size_t l) {
  return websocket_subscribe(ws, .channel = {.data = (char *)c, .len = l});
}

/* ---- reactor wake pipe, for work queued from other threads ---- */
static int wake_fd[2] = {-1, -1};
static atomic_int wake_pending;
static void wake_on_data(intptr_t uuid, fio_protocol_s *pr) {
  char buf[256];
  while (read(wake_fd[0], buf, sizeof(buf)) > 0)
    ;
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
static void shim_wake(void) {
  if (wake_fd[1] >= 0 && atomic_exchange(&wake_pending, 1) == 0) {
    char c = 1;
    (void)!write(wake_fd[1], &c, 1);
  }
}
void shim_publish(const char *c, size_t cl, const char *m, size_t ml) {
  fio_publish(.channel = {.data = (char *)c, .len = cl},
              .message = {.data = (char *)m, .len = ml});
  shim_wake();
}
size_t shim_capa(void) { return fio_capa(); }

#ifdef WS_PATCHED
/* Applies settings from the environment: WS_DEFLATE=level, WS_UTF8=0|1,
 * WS_SLOW_LIMIT=bytes, WS_SLOW_POLICY=ignore|close|newest|oldest */
#include <stdlib.h>
void shim_configure(void) {
  const char *e;
  if ((e = getenv("WS_DEFLATE")))
    websocket_deflate_set(1, atoi(e), 128);
  if ((e = getenv("WS_UTF8")))
    websocket_validate_utf8_set(atoi(e));
  if ((e = getenv("WS_SLOW_LIMIT"))) {
    const char *p = getenv("WS_SLOW_POLICY");
    int policy = WEBSOCKET_SLOW_CLOSE;
    if (p && !strcmp(p, "ignore")) policy = WEBSOCKET_SLOW_IGNORE;
    if (p && !strcmp(p, "newest")) policy = WEBSOCKET_SLOW_DROP_NEWEST;
    if (p && !strcmp(p, "oldest")) policy = WEBSOCKET_SLOW_DROP_OLDEST;
    websocket_slow_subscriber_set((size_t)atol(e), policy, NULL);
  }
}
const char *shim_stats(void) {
  static char buf[256];
  size_t d, c, ev;
  websocket_slow_subscriber_stats(&d, &c, &ev);
  snprintf(buf, sizeof(buf), "{\"capa\":%zu,\"slow_dropped\":%zu,\"slow_closed\":%zu,\"slow_events\":%zu}",
           (size_t)fio_capa(), d, c, ev);
  return buf;
}
void shim_ws_close(ws_s *ws, int code) { websocket_close2(ws, (uint16_t)code); }
#else
void shim_configure(void) {}
const char *shim_stats(void) {
  static char buf[256];
  snprintf(buf, sizeof(buf), "{\"capa\":%zu}", (size_t)fio_capa());
  return buf;
}
void shim_ws_close(ws_s *ws, int code) { websocket_close(ws); (void)code; }
#endif
