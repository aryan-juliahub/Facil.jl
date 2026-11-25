#include "fio.h"
#include "http.h"
#include "http_internal.h"
#include <string.h>

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
intptr_t shim_uuid(http_s *h) { return http2protocol(h)->uuid; }
int shim_set_header(http_s *h, const char *n, size_t nl, const char *v, size_t vl) {
  return http_set_header2(h, (fio_str_info_s){.data = (char *)n, .len = nl},
                          (fio_str_info_s){.data = (char *)v, .len = vl});
}

static const char FLOOD_HEAD[] = "HTTP/1.1 200 OK\r\nconnection:close\r\n\r\n";
static char FLOOD_BLOCK[65536];
/* A handler that streams n 64 KiB writes without looking at the queue. */
void shim_flood(http_s *h, int n) {
  intptr_t uuid = http_hijack(h, NULL);
  fio_write2(uuid, .data.buffer = FLOOD_HEAD, .length = sizeof(FLOOD_HEAD) - 1,
             .after.dealloc = FIO_DEALLOC_NOOP);
  for (int i = 0; i < n; i++)
    fio_write2(uuid, .data.buffer = FLOOD_BLOCK, .length = sizeof(FLOOD_BLOCK),
               .after.dealloc = FIO_DEALLOC_NOOP);
  fio_close(uuid);
}
