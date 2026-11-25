#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "fjl_http.h"

#include <http1.h>
#include <http_internal.h>
#include <fio_tls.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* ---- servers: settings kept alive by the listener and every connection ---- */

typedef struct fjl_conn_s {
  struct fjl_conn_s *prev, *next;
  fjl_server_s *srv;
  intptr_t uuid;
  size_t last_pending;
  int stalls;
} fjl_conn_s;

struct fjl_server_s {
  http_settings_s settings;
  void (*on_finish)(http_settings_s *);
  void (*on_release)(void *);
  atomic_long refs;
  pthread_mutex_t mu;
  fjl_conn_s conns; /* list head */
  size_t nconns;
  intptr_t listener;
  size_t max_pending; /* output cap per connection, 0 for none */
  int sweep_again;
};

#define FJL_RELEASE_GRACE_MS 2000
/* Outlasts the TLS handshake timeout: a pending handshake still names the server. */
#define FJL_TLS_RELEASE_GRACE_MS 12000
#define FJL_SWEEP_MS 1000
static void sweep_task(void *p);
static void sweep_finish(void *p);

static void on_upgrade_fallback(http_s *h, char *p, size_t n) {
  http_send_error(h, 400);
  (void)p;
  (void)n;
}

fjl_server_s *fjl_http_server_new(const fjl_listen_s *o,
                                  void (*on_release)(void *)) {
  if (!o || !o->on_request)
    return NULL;
  fjl_server_s *s = calloc(1, sizeof(*s));
  if (!s)
    return NULL;
  http_settings_s *st = &s->settings;
  st->on_request = o->on_request;
  st->on_upgrade = o->on_upgrade ? o->on_upgrade : on_upgrade_fallback;
  st->udata = o->udata;
  st->max_header_size = o->max_header_size ? o->max_header_size : 32 * 1024;
  st->max_body_size = o->max_body_size ? o->max_body_size : HTTP_DEFAULT_BODY_LIMIT;
  st->max_clients = o->max_clients;
  st->tls = o->tls;
  st->ws_max_msg_size = o->ws_max_msg_size ? o->ws_max_msg_size : 262144;
  st->timeout = o->timeout ? o->timeout : 40;
  st->ws_timeout = o->ws_timeout ? o->ws_timeout : 40;
  st->log = o->log;
  if (o->public_folder) {
    st->public_folder_length = strlen(o->public_folder);
    st->public_folder = strdup(o->public_folder);
  }
  s->on_finish = o->on_finish;
  s->on_release = on_release;
  atomic_store(&s->refs, 1);
  pthread_mutex_init(&s->mu, NULL);
  s->conns.next = s->conns.prev = &s->conns;
  s->listener = -1;
  return s;
}

void fjl_http_server_free(fjl_server_s *s) {
  if (!s)
    return;
  pthread_mutex_destroy(&s->mu);
  if (s->settings.tls)
    fio_tls_destroy(s->settings.tls);
  free((void *)s->settings.public_folder);
  free(s);
}

http_settings_s *fjl_http_settings(fjl_server_s *s) { return &s->settings; }

size_t fjl_http_connections(fjl_server_s *s) {
  pthread_mutex_lock(&s->mu);
  size_t n = s->nconns;
  pthread_mutex_unlock(&s->mu);
  return n;
}

static void release_noop(void *s) { (void)s; }
static void draining_set(fjl_server_s *s, int on);
static void release_now(void *p) {
  fjl_server_s *s = p;
  draining_set(s, 0);
  if (s->on_release)
    s->on_release(s->settings.udata);
  fjl_http_server_free(s);
}

/* Deferred tasks of a closed connection may still read the settings, so the
 * memory is freed a grace period after the last reference is dropped. */
static void server_unref(fjl_server_s *s) {
  if (atomic_fetch_sub(&s->refs, 1) != 1)
    return;
  if (s->on_finish)
    s->on_finish(&s->settings);
  if (fio_is_running())
    fio_run_every(s->settings.tls ? FJL_TLS_RELEASE_GRACE_MS
                                  : FJL_RELEASE_GRACE_MS,
                  1, release_noop, s, release_now);
  else
    release_now(s);
}

static void conn_closed(void *p) {
  fjl_conn_s *c = p;
  fjl_server_s *s = c->srv;
  pthread_mutex_lock(&s->mu);
  c->prev->next = c->next;
  c->next->prev = c->prev;
  s->nconns--;
  pthread_mutex_unlock(&s->mu);
  free(c);
  server_unref(s);
}

static uint8_t at_capacity;

static void conn_open(intptr_t uuid, void *udata) {
  fjl_server_s *s = udata;
  http_settings_s *st = &s->settings;
  fio_timeout_set(uuid, st->timeout);
  intptr_t capa = st->max_clients;
  if (capa <= 0 || (size_t)(capa + HTTP_BUSY_UNLESS_HAS_FDS) > fio_capa()) {
    capa = (intptr_t)fio_capa() - HTTP_BUSY_UNLESS_HAS_FDS;
    if (capa <= 0)
      capa = (intptr_t)fio_capa();
  }
  if (fio_uuid2fd(uuid) >= capa) {
    if (!at_capacity)
      FIO_LOG_WARNING("HTTP server at capacity");
    at_capacity = 1;
    http_send_error2(503, uuid, st);
    fio_close(uuid);
    return;
  }
  at_capacity = 0;
  fjl_conn_s *c = malloc(sizeof(*c));
  if (!c) {
    fio_close(uuid);
    return;
  }
  c->srv = s;
  c->uuid = uuid;
  atomic_fetch_add(&s->refs, 1);
  pthread_mutex_lock(&s->mu);
  c->next = s->conns.next;
  c->prev = &s->conns;
  s->conns.next->prev = c;
  s->conns.next = c;
  s->nconns++;
  pthread_mutex_unlock(&s->mu);
  fio_uuid_link(uuid, c, conn_closed);
  if (!http1_new(uuid, st, NULL, 0))
    fio_close(uuid);
}

/* Runs once a handshake picked HTTP/1.1, or with uuid -1 when it failed. */
static void tls_open(intptr_t uuid, void *udata, void *ignr) {
  fjl_server_s *s = udata;
  if (uuid < 0)
    return;
  if (s->listener < 0) {
    fio_close(uuid);
    return;
  }
  conn_open(uuid, udata);
  (void)ignr;
}

/* A failed fio_listen also lands here, with uuid -1; that server was never
 * referenced by a listener and is freed by its creator. */
static void listener_finish(intptr_t uuid, void *udata) {
  if (uuid >= 0) {
    ((fjl_server_s *)udata)->listener = -1;
    server_unref(udata);
  }
}

static intptr_t listen_now(fjl_server_s *s, const char *address,
                           const char *port) {
  if (s->settings.tls)
    fio_tls_alpn_add(s->settings.tls, "http/1.1", tls_open, NULL, NULL);
  intptr_t r = fio_listen(.port = port, .address = address,
                          .tls = s->settings.tls, .on_open = conn_open,
                          .on_finish = listener_finish, .udata = s);
  if (r >= 0) {
    s->listener = r;
    if (s->max_pending) {
      atomic_fetch_add(&s->refs, 1);
      s->sweep_again = 0;
      fio_run_every(FJL_SWEEP_MS, 1, sweep_task, s, sweep_finish);
    }
  }
  return r;
}

typedef struct {
  fjl_server_s *srv;
  const char *address, *port;
} listen_args;

static void listen_task(void *args, void *call, void *ignr) {
  listen_args *a = args;
  errno = 0;
  intptr_t r = listen_now(a->srv, a->address, a->port);
  int err = r < 0 ? (errno ? errno : EADDRINUSE) : 0;
  free(a);
  fjl_call_complete(call, r, err);
  (void)ignr;
}

static void listen_cancel(void *args, void *call, void *ignr) {
  free(args);
  fjl_call_complete(call, -1, ECANCELED);
  (void)ignr;
}

int fjl_http_listen_async(fjl_server_s *srv, const char *address,
                          const char *port, fjl_call_s *call) {
  atomic_store(&call->done, 0);
  listen_args *a = malloc(sizeof(*a));
  if (!a)
    return -1;
  *a = (listen_args){.srv = srv, .address = address, .port = port};
  if (fjl_on_reactor() || !fio_is_running()) {
    listen_task(a, call, NULL);
    return 0;
  }
  if (fjl_post(listen_task, listen_cancel, a, call, NULL)) {
    free(a);
    return -1;
  }
  return 0;
}

static void close_task(void *p, void *b, void *c) {
  fjl_server_s *s = p;
  if (s->listener >= 0) {
    fio_close(s->listener);
    s->listener = -1;
  }
  pthread_mutex_lock(&s->mu);
  size_t n = s->nconns, i = 0;
  intptr_t *uuids = n ? malloc(n * sizeof(*uuids)) : NULL;
  for (fjl_conn_s *x = s->conns.next; uuids && x != &s->conns; x = x->next)
    uuids[i++] = x->uuid;
  pthread_mutex_unlock(&s->mu);
  for (size_t j = 0; j < i; j++)
    fio_close(uuids[j]);
  free(uuids);
  (void)b;
  (void)c;
}

int fjl_http_close(fjl_server_s *srv) {
  if (!srv)
    return -1;
  if (fjl_on_reactor()) {
    close_task(srv, NULL, NULL);
    return 0;
  }
  return fjl_post(close_task, NULL, srv, NULL, NULL);
}

/* ---- limits: output cap and graceful drain ---- */

#define FJL_STALL_SWEEPS 3

/* A connection over the output cap whose queue has not shrunk for
 * FJL_STALL_SWEEPS sweeps in a row is dropped. */
static void sweep_task(void *p) {
  fjl_server_s *s = p;
  s->sweep_again = s->listener >= 0 && fio_is_running();
  if (!s->sweep_again)
    return;
  pthread_mutex_lock(&s->mu);
  size_t n = s->nconns, i = 0;
  intptr_t *drop = n ? malloc(n * sizeof(*drop)) : NULL;
  for (fjl_conn_s *x = s->conns.next; drop && x != &s->conns; x = x->next) {
    size_t pending = fio_pending_bytes(x->uuid);
    if (pending > s->max_pending && pending >= x->last_pending) {
      if (++x->stalls >= FJL_STALL_SWEEPS)
        drop[i++] = x->uuid;
    } else {
      x->stalls = 0;
    }
    x->last_pending = pending;
  }
  pthread_mutex_unlock(&s->mu);
  for (size_t j = 0; j < i; j++) {
    FIO_LOG_DEBUG("HTTP: dropping a client that stopped reading");
    fio_force_close(drop[j]);
  }
  free(drop);
}

static void sweep_finish(void *p) {
  fjl_server_s *s = p;
  if (s->sweep_again) {
    s->sweep_again = 0;
    fio_run_every(FJL_SWEEP_MS, 1, sweep_task, s, sweep_finish);
  } else {
    server_unref(s);
  }
}

void fjl_http_server_limits(fjl_server_s *s, size_t max_pending) {
  s->max_pending = max_pending;
}

/* Servers being drained: their responses ask the client to close. */
#define FJL_MAX_DRAINING 64
static fjl_server_s *draining[FJL_MAX_DRAINING];
static atomic_int ndraining;
static pthread_mutex_t draining_mu = PTHREAD_MUTEX_INITIALIZER;

static int is_draining(http_settings_s *st) {
  if (!atomic_load(&ndraining))
    return 0;
  int found = 0;
  pthread_mutex_lock(&draining_mu);
  for (int i = 0; i < FJL_MAX_DRAINING && !found; i++)
    found = draining[i] && &draining[i]->settings == st;
  pthread_mutex_unlock(&draining_mu);
  return found;
}

static void draining_set(fjl_server_s *s, int on) {
  pthread_mutex_lock(&draining_mu);
  for (int i = 0; i < FJL_MAX_DRAINING; i++) {
    if (on && !draining[i]) {
      draining[i] = s;
      atomic_fetch_add(&ndraining, 1);
      break;
    }
    if (!on && draining[i] == s) {
      draining[i] = NULL;
      atomic_fetch_sub(&ndraining, 1);
      break;
    }
  }
  pthread_mutex_unlock(&draining_mu);
}

static void drain_task(void *p, void *secs, void *c) {
  fjl_server_s *s = p;
  if (s->listener >= 0) {
    fio_close(s->listener);
    s->listener = -1;
  }
  pthread_mutex_lock(&s->mu);
  for (fjl_conn_s *x = s->conns.next; x != &s->conns; x = x->next)
    fio_timeout_set(x->uuid, (uint8_t)(uintptr_t)secs);
  pthread_mutex_unlock(&s->mu);
  (void)c;
}

int fjl_http_drain(fjl_server_s *srv, int idle_secs) {
  if (!srv)
    return -1;
  if (idle_secs < 1)
    idle_secs = 1;
  draining_set(srv, 1);
  void *secs = (void *)(uintptr_t)(idle_secs > 255 ? 255 : idle_secs);
  if (fjl_on_reactor()) {
    drain_task(srv, secs, NULL);
    return 0;
  }
  return fjl_post(drain_task, NULL, srv, secs, NULL);
}

int fjl_http_free_port(const char *address) {
  struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM,
                           .ai_flags = AI_PASSIVE},
                  *res = NULL;
  if (getaddrinfo(address, "0", &hints, &res) || !res)
    return 0;
  int port = 0;
  int fd = socket(res->ai_family, SOCK_STREAM, 0);
  if (fd >= 0) {
    struct sockaddr_storage ss;
    socklen_t len = sizeof(ss);
    if (!bind(fd, res->ai_addr, res->ai_addrlen) &&
        !getsockname(fd, (struct sockaddr *)&ss, &len)) {
      if (ss.ss_family == AF_INET)
        port = ntohs(((struct sockaddr_in *)&ss)->sin_port);
      else if (ss.ss_family == AF_INET6)
        port = ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
    }
    close(fd);
  }
  freeaddrinfo(res);
  return port;
}

/* ---- request read ---- */

#define FJL_MAX_STD_LEN 64
static const char **std_names;
static uint8_t *std_lens;
static int std_n;
/* by_len[l] lists the ids of names of length l, zero-terminated */
static int16_t *by_len[FJL_MAX_STD_LEN + 1];
/* Response header names as facil.io strings with their hash cached. */
static FIOBJ *std_objs;

int fjl_http_init(const char *const *names, const uint8_t *lens, int n) {
  if (std_names)
    return 0;
  const char **nm = malloc(sizeof(*nm) * n);
  uint8_t *ln = malloc(n);
  if (!nm || !ln)
    return -1;
  int count[FJL_MAX_STD_LEN + 1] = {0};
  for (int i = 0; i < n; i++) {
    nm[i] = strndup(names[i], lens[i]);
    ln[i] = lens[i];
    if (lens[i] <= FJL_MAX_STD_LEN)
      count[lens[i]]++;
  }
  for (int l = 0; l <= FJL_MAX_STD_LEN; l++) {
    by_len[l] = calloc(count[l] + 1, sizeof(int16_t));
    int k = 0;
    for (int i = 0; i < n; i++)
      if (ln[i] == l)
        by_len[l][k++] = (int16_t)(i + 1);
  }
  std_objs = calloc(n + 1, sizeof(FIOBJ));
  if (std_objs)
    for (int i = 0; i < n; i++) {
      std_objs[i + 1] = fiobj_str_new(nm[i], ln[i]);
      fiobj_obj2hash(std_objs[i + 1]);
    }
  std_lens = ln;
  std_n = n;
  std_names = nm;
  return 0;
}

static inline int32_t std_index(const char *p, size_t len) {
  if (len > FJL_MAX_STD_LEN || !std_names)
    return 0;
  for (int16_t *id = by_len[len]; *id; id++) {
    const char *s = std_names[*id - 1];
    if (s[0] == p[0] && !memcmp(s, p, len))
      return *id;
  }
  return 0;
}

static inline fjl_slice_s slice_of(FIOBJ o) {
  fjl_slice_s s = {NULL, 0};
  if (!o || FIOBJ_IS_NULL(o))
    return s;
  fio_str_info_s i = fiobj_obj2cstr(o);
  s.ptr = i.data;
  s.len = (int64_t)i.len;
  return s;
}

static inline int32_t version_code(fjl_slice_s v) {
  if (v.len == 8 && !memcmp(v.ptr, "HTTP/1.", 7)) {
    if (v.ptr[7] == '1')
      return 3;
    if (v.ptr[7] == '0')
      return 2;
  }
  if (v.len == 8 && !memcmp(v.ptr, "HTTP/0.9", 8))
    return 1;
  return 0;
}

typedef struct {
  fjl_req_s req;
  int cap;
} req_buf;

static _Thread_local req_buf rb;

static inline void push_hdr(fjl_slice_s name, int32_t code, FIOBJ v) {
  if (rb.req.nheaders >= rb.cap) {
    int cap = rb.cap ? rb.cap * 2 : 64;
    fjl_hdr_s *n = realloc(rb.req.headers, sizeof(*n) * cap);
    if (!n)
      return;
    rb.req.headers = n;
    rb.cap = cap;
  }
  fjl_hdr_s *d = rb.req.headers + rb.req.nheaders++;
  d->code = code;
  d->pad = 0;
  d->name = name;
  d->value = slice_of(v);
}

static int each_header(FIOBJ value, void *arg) {
  fjl_slice_s name = slice_of(fiobj_hash_key_in_loop());
  int32_t code = std_index(name.ptr, (size_t)name.len);
  if (FIOBJ_TYPE_IS(value, FIOBJ_T_ARRAY)) {
    size_t cnt = fiobj_ary_count(value);
    for (size_t i = 0; i < cnt; i++)
      push_hdr(name, code, fiobj_ary_index(value, (int64_t)i));
  } else {
    push_hdr(name, code, value);
  }
  (void)arg;
  return 0;
}

const fjl_req_s *fjl_req_read(http_s *h) {
  fjl_req_s *r = &rb.req;
  r->method = slice_of(h->method);
  r->path = slice_of(h->path);
  if (!r->path.len) {
    r->path.ptr = "/";
    r->path.len = 1;
  }
  if (h->query && !FIOBJ_IS_NULL(h->query)) {
    r->query = slice_of(h->query);
  } else {
    r->query.ptr = NULL;
    r->query.len = -1;
  }
  r->version = version_code(slice_of(h->version));
  r->nheaders = 0;
  if (h->headers)
    fiobj_each1(h->headers, 0, each_header, NULL);
  r->body.ptr = NULL;
  r->body.len = 0;
  if (h->body && !FIOBJ_IS_NULL(h->body)) {
    fio_str_info_s b = fiobj_obj2cstr(h->body);
    r->body.ptr = b.data;
    r->body.len = b.data ? (int64_t)b.len : 0;
  }
  return r;
}

/* ---- response write ---- */

/* Offline requests carry this marker; their responses go nowhere. */
static char fake_marker;
#define IS_FAKE(h) ((h)->udata == &fake_marker)

int fjl_resp_header(http_s *h, int32_t id, const char *name, size_t nlen,
                    const char *value, size_t vlen) {
  if (IS_FAKE(h))
    return 0;
  if (id > 0 && id <= std_n && std_objs && std_objs[id])
    return http_set_header(h, std_objs[id], fiobj_str_new(value, vlen));
  return http_set_header2(h, (fio_str_info_s){.data = (char *)name, .len = nlen},
                          (fio_str_info_s){.data = vlen ? (char *)value : NULL,
                                           .len = vlen});
}

int fjl_resp_send(http_s *h, int status, const char *body, size_t len,
                  void (*dealloc)(void *)) {
  if (IS_FAKE(h)) {
    if (len && dealloc)
      dealloc((void *)body);
    return 0;
  }
  if (!HTTP_INVALID_HANDLE(h)) {
    h->status = (uintptr_t)status;
    if (is_draining(http_settings(h)))
      http_set_header(h, HTTP_HEADER_CONNECTION, fiobj_dup(HTTP_HVALUE_CLOSE));
  }
  if (!len) {
    http_finish(h);
    return 0;
  }
  return http_send_body_nocopy(h, (void *)body, len, dealloc, 1);
}

int fjl_resp_error(http_s *h, int status) {
  return IS_FAKE(h) ? 0 : http_send_error(h, status);
}

/* ---- offline requests ---- */

static void fake_hdr(http_s *h, const char *n, const char *v) {
  FIOBJ name = fiobj_str_new(n, strlen(n));
  FIOBJ val = fiobj_str_new(v, strlen(v));
  FIOBJ old = fiobj_hash_get(h->headers, name);
  if (!old) {
    fiobj_hash_set(h->headers, name, val);
  } else {
    if (!FIOBJ_TYPE_IS(old, FIOBJ_T_ARRAY)) {
      FIOBJ a = fiobj_ary_new2(2);
      fiobj_ary_push(a, fiobj_dup(old));
      fiobj_hash_replace(h->headers, name, a);
      old = a;
    }
    fiobj_ary_push(old, val);
  }
  fiobj_free(name);
}

http_s *fjl_http_fake_request(void) {
  http_s *h = calloc(1, sizeof(*h));
  if (!h)
    return NULL;
  h->method = fiobj_str_new("POST", 4);
  h->path = fiobj_str_new("/precompile", 11);
  h->query = fiobj_str_new("a=1&b=2", 7);
  h->version = fiobj_str_new("HTTP/1.1", 8);
  h->headers = fiobj_hash_new();
  fake_hdr(h, "host", "127.0.0.1:8080");
  fake_hdr(h, "accept", "*/*");
  fake_hdr(h, "content-type", "application/json");
  fake_hdr(h, "x-custom", "one");
  fake_hdr(h, "x-custom", "two");
  h->body = fiobj_data_newstr();
  fiobj_data_write(h->body, "{\"a\":1}", 7);
  h->udata = &fake_marker;
  return h;
}

void fjl_http_fake_free(http_s *h) {
  if (!h)
    return;
  fiobj_free(h->method);
  fiobj_free(h->path);
  fiobj_free(h->query);
  fiobj_free(h->version);
  fiobj_free(h->headers);
  fiobj_free(h->body);
  fiobj_free(h->private_data.out_headers);
  free(h);
}
