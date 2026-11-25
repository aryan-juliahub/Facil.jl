#include "fio.h"
#include "http.h"
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
intptr_t shim_body_len(http_s *h) { return h->body ? fiobj_data_len(h->body) : -1; }
const char *shim_body_read(http_s *h, intptr_t want, size_t *len) {
  fio_str_info_s s = fiobj_data_read(h->body, want);
  *len = s.len;
  return s.data;
}

int http_send_body_nocopy(http_s *r, void *data, uintptr_t length,
                          void (*dealloc)(void *), int vectored);

/* mode: 0 copy, 3 no-copy as two packets, 4 no-copy as one writev. */
int shim_respond(http_s *h, int mode, const char *ctype, size_t ctlen,
                 const char *body, size_t len, void (*dealloc)(void *)) {
  http_set_header2(h, (fio_str_info_s){.data = "content-type", .len = 12},
                   (fio_str_info_s){.data = (char *)ctype, .len = ctlen});
  if (mode == 0 || !len)
    return http_send_body(h, (void *)body, len);
  return http_send_body_nocopy(h, (void *)body, len, dealloc, mode == 4);
}
size_t shim_capa(void) { return fio_capa(); }
