#ifndef FJL_BODY_H
#define FJL_BODY_H

#include "fjl.h"
#include <http1_body.h>

/* Request bodies (http1_body.h). Configures the global body planner once;
 * every HTTP server in the process then delivers bodies through it. */
int fjl_body_configure(void (*on_headers)(http_s *h, int64_t content_length,
                                          http1_body_plan_s *plan),
                       int (*on_data)(http_s *h, void *udata,
                                      const uint8_t *data, size_t len),
                       void (*on_abort)(void *udata, int32_t mode),
                       size_t mem_limit, size_t read_chunk);
/* Any thread: resumes reading a body whose on_data returned 1. */
void fjl_body_resume(intptr_t uuid);
/* Answers with `status` and closes the connection after the reply. */
int fjl_body_reject(http_s *h, int status);

/* The settings' udata when the request's server calls `on_request`, else NULL. */
void *fjl_body_server(http_s *h, void (*on_request)(http_s *));

/* Struct sizes, checked against the Julia mirrors at load. */
size_t fjl_sizeof_body_plan(void);
size_t fjl_sizeof_body_info(void);

#endif
