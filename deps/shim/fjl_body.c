#include "fjl_body.h"

#include <http_internal.h>

int fjl_body_configure(void (*on_headers)(http_s *, int64_t,
                                          http1_body_plan_s *),
                       int (*on_data)(http_s *, void *, const uint8_t *,
                                      size_t),
                       void (*on_abort)(void *, int32_t), size_t mem_limit,
                       size_t read_chunk) {
  http1_body_configure((http1_body_config_s){.on_headers = on_headers,
                                             .on_data = on_data,
                                             .on_abort = on_abort,
                                             .mem_limit = mem_limit,
                                             .read_chunk = read_chunk});
  return 0;
}

void fjl_body_resume(intptr_t uuid) {
  http1_body_resume(uuid);
  fjl_wake();
}

int fjl_body_reject(http_s *h, int status) {
  if (!h || HTTP_INVALID_HANDLE(h))
    return -1;
  http_set_header(h, HTTP_HEADER_CONNECTION, fiobj_dup(HTTP_HVALUE_CLOSE));
  return http_send_error(h, (size_t)status);
}

void *fjl_body_server(http_s *h, void (*on_request)(http_s *)) {
  http_settings_s *st = http_settings(h);
  return (st && st->on_request == on_request) ? st->udata : NULL;
}

size_t fjl_sizeof_body_plan(void) { return sizeof(http1_body_plan_s); }
size_t fjl_sizeof_body_info(void) { return sizeof(http1_body_info_s); }
