#include "fio.h"
#include "http.h"
#include "websockets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
void shim_publish(const char *c, size_t cl, const char *m, size_t ml) {
  fio_publish(.channel = {.data = (char *)c, .len = cl},
              .message = {.data = (char *)m, .len = ml});
}

typedef struct {
  size_t len;
  int is_text;
  char data[];
} pend_s;
static volatile long sent_ok, sent_dropped;
static void send_task(intptr_t uuid, fio_protocol_s *pr, void *ud) {
  pend_s *p = ud;
  websocket_write((ws_s *)pr, (fio_str_info_s){.data = p->data, .len = p->len},
                  p->is_text);
  __sync_fetch_and_add(&sent_ok, 1);
  free(p);
  (void)uuid;
}
static void send_fb(intptr_t uuid, void *ud) {
  free(ud);
  __sync_fetch_and_add(&sent_dropped, 1);
  (void)uuid;
}
void shim_ws_send_uuid(intptr_t uuid, const char *d, size_t l, int t) {
  pend_s *p = malloc(sizeof(*p) + l);
  p->len = l;
  p->is_text = t;
  memcpy(p->data, d, l);
  fio_defer_io_task(uuid, .type = FIO_PR_LOCK_TASK, .task = send_task,
                    .udata = p, .fallback = send_fb);
}
long shim_sent_ok(void) { return sent_ok; }
long shim_sent_dropped(void) { return sent_dropped; }

int shim_upgrade2sse(http_s *h, void *on_open, void *on_close, void *udata) {
  return http_upgrade2sse(h, .on_open = on_open, .on_close = on_close,
                          .udata = udata);
}
int shim_sse_write(http_sse_s *sse, const char *d, size_t l) {
  return http_sse_write(sse, .data = {.data = (char *)d, .len = l});
}

ssize_t shim_write_copy(intptr_t uuid, const char *d, size_t l) {
  void *c = fio_malloc(l);
  memcpy(c, d, l);
  return fio_write2(uuid, .data.buffer = c, .length = l,
                    .after.dealloc = fio_free);
}

static const char *obj_str(FIOBJ o, size_t *len) {
  if (!o) {
    *len = 0;
    return NULL;
  }
  fio_str_info_s s = fiobj_obj2cstr(o);
  *len = s.len;
  return s.data;
}
const char *shim_method(http_s *h, size_t *len) { return obj_str(h->method, len); }
const char *shim_path(http_s *h, size_t *len) { return obj_str(h->path, len); }
const char *shim_query(http_s *h, size_t *len) { return obj_str(h->query, len); }
const char *shim_header(http_s *h, const char *name, size_t nlen, size_t *len) {
  return obj_str(fiobj_hash_get2(h->headers, fiobj_hash_string(name, nlen)), len);
}
size_t shim_header_count(http_s *h) { return fiobj_hash_count(h->headers); }
intptr_t shim_body_len(http_s *h) { return h->body ? fiobj_data_len(h->body) : -1; }
const char *shim_body_read(http_s *h, intptr_t want, size_t *len) {
  fio_str_info_s s = fiobj_data_read(h->body, want);
  *len = s.len;
  return s.data;
}
void shim_set_status(http_s *h, size_t st) { h->status = st; }
int shim_set_header(http_s *h, const char *n, size_t nl, const char *v, size_t vl) {
  return http_set_header2(h, (fio_str_info_s){.data = (char *)n, .len = nl},
                          (fio_str_info_s){.data = (char *)v, .len = vl});
}
void shim_sizes(void) {
  fprintf(stderr,
          "sizeof: fio_str_info_s=%zu websocket_settings_s=%zu http_sse_s=%zu "
          "http_sse_write_args=%zu fio_publish_args_s=%zu websocket_subscribe_s=%zu "
          "fio_write_args_s=%zu http_settings_s=%zu\n",
          sizeof(fio_str_info_s), sizeof(websocket_settings_s), sizeof(http_sse_s),
          sizeof(struct http_sse_write_args), sizeof(fio_publish_args_s),
          sizeof(struct websocket_subscribe_s), sizeof(fio_write_args_s),
          sizeof(struct http_settings_s));
}
