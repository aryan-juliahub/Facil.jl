#ifndef FJL_HTTP_H
#define FJL_HTTP_H

#include "fjl.h"

/* One HTTP server: its facil.io settings plus a reference count held by the
 * listener and by every connection it accepted. The settings live until the
 * count reaches zero, so a connection never outlives them. */
typedef struct fjl_server_s fjl_server_s;

/* Standard header names, in HttpTypes' order (ids 1..n). Call once. */
int fjl_http_init(const char *const *names, const uint8_t *lens, int n);

/* `opts` is copied; `on_finish(settings)` runs once the listener and every
 * connection are gone, then `on_release(udata)` runs a grace period later,
 * after which the server is freed. */
fjl_server_s *fjl_http_server_new(const fjl_listen_s *opts,
                                  void (*on_release)(void *udata));
/* Only for a server whose listen failed. */
void fjl_http_server_free(fjl_server_s *srv);
/* Opens the listener on the reactor; call->result is its uuid or -1. */
int fjl_http_listen_async(fjl_server_s *srv, const char *address,
                          const char *port, fjl_call_s *call);
/* Closes the listener and every connection (pending output is flushed).
 * WebSockets get their on_shutdown callback and a 1001 close first. */
int fjl_http_close(fjl_server_s *srv);
http_settings_s *fjl_http_settings(fjl_server_s *srv);
/* Call before listening. A connection over `max_pending` unsent bytes whose
 * queue stops shrinking for about 3 s is dropped; 0 disables the cap. */
void fjl_http_server_limits(fjl_server_s *srv, size_t max_pending);
/* Graceful close: stops accepting, makes every later reply close its
 * connection, closes connections idle for `idle_secs` and shuts WebSockets
 * down (on_shutdown, 1001). fjl_http_close ends whatever is left. */
int fjl_http_drain(fjl_server_s *srv, int idle_secs);
size_t fjl_http_connections(fjl_server_s *srv);
/* A free TCP port on `address` (0 when none could be found). */
int fjl_http_free_port(const char *address);

typedef struct {
  const char *ptr;
  int64_t len;
} fjl_slice_s;

typedef struct {
  int32_t code; /* standard header id, 0 for a custom name */
  int32_t pad;
  fjl_slice_s name, value;
} fjl_hdr_s;

typedef struct {
  fjl_slice_s method, path, query, body; /* query.len < 0: no '?' */
  int32_t version;                       /* 1..5 as HttpTypes' Versions, 0 unknown */
  int32_t nheaders;
  fjl_hdr_s *headers;
} fjl_req_s;

/* The request as views into facil.io's buffers, valid until the response is
 * sent. Thread-local storage, so each reactor thread has its own. */
const fjl_req_s *fjl_req_read(http_s *h);

/* `id` is the standard header id of `name`, or 0. */
int fjl_resp_header(http_s *h, int32_t id, const char *name, size_t nlen,
                    const char *value, size_t vlen);
/* Sends status, headers and body. A non-empty body goes out without a copy and
 * `dealloc(body)` runs exactly once when facil.io is done with it. A body
 * given with a 1xx, 204 or 304 status is released unsent. */
int fjl_resp_send(http_s *h, int status, const char *body, size_t len,
                  void (*dealloc)(void *));
int fjl_resp_error(http_s *h, int status);

/* The client of the connection a request arrived on. `cert` is the PEM
 * certificate a TLS client presented (a malloc block released with
 * fjl_free), or NULL; it is only looked up when `want_cert` is set. */
typedef struct {
  uint8_t ip[48];
  int32_t ip_len;
  int32_t port;
  int32_t tls;
  int32_t pad;
  char *cert;
  int64_t cert_len;
} fjl_peer_s;

/* Fills `out` for `h` (reactor only, while `h` is valid). 0, or -1 when the
 * connection is unknown. */
int fjl_req_peer(http_s *h, fjl_peer_s *out, int want_cert);
void fjl_free(void *p);

/* Offline requests for the precompile workload; they never reach a socket. */
http_s *fjl_http_fake_request(void);
void fjl_http_fake_free(http_s *h);

#endif
