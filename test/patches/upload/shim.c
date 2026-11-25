#include "http.h"
#include "http_internal.h"
#include <string.h>
#include "fio.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <unistd.h>


typedef struct { const char *ptr; size_t len; } jl_slice;
typedef struct {
  int32_t method_code;
  int32_t nheaders;
  jl_slice method, path, query, version, body;
} jl_req;
typedef struct { int32_t name_code; int32_t pad; jl_slice name, value; } jl_hdr;

static const char *const METHODS[] = {"GET", "HEAD", "POST", "PUT", "DELETE",
                                      "PATCH", "OPTIONS", "CONNECT", "TRACE"};
#define N_METHODS ((int)(sizeof(METHODS) / sizeof(METHODS[0])))

static const char *const HNAMES[] = {
    "host", "user-agent", "accept", "accept-encoding", "accept-language",
    "connection", "content-type", "content-length", "cookie", "referer",
    "origin", "cache-control", "authorization", "if-none-match",
    "if-modified-since", "upgrade-insecure-requests", "sec-fetch-site",
    "sec-fetch-mode", "sec-fetch-dest", "sec-fetch-user", "pragma", "range",
    "transfer-encoding", "expect", "x-forwarded-for", "x-forwarded-proto",
    "x-requested-with", "upgrade", "te", "dnt"};
#define N_HNAMES ((int)(sizeof(HNAMES) / sizeof(HNAMES[0])))
static uint8_t HNAME_LEN[N_HNAMES];
static int tables_ready = 0;

static void init_tables(void) {
  for (int i = 0; i < N_HNAMES; i++)
    HNAME_LEN[i] = (uint8_t)strlen(HNAMES[i]);
  tables_ready = 1;
}

int jlshim_method_count(void) { return N_METHODS; }
const char *jlshim_method_name(int code) { return METHODS[code - 1]; }
int jlshim_header_count(void) { return N_HNAMES; }
const char *jlshim_header_name(int code) { return HNAMES[code - 1]; }

static inline int method_code(const char *p, size_t len) {
  for (int i = 0; i < N_METHODS; i++)
    if (!strncmp(METHODS[i], p, len) && METHODS[i][len] == 0)
      return i + 1;
  return 0;
}

static inline int header_code(const char *p, size_t len) {
  for (int i = 0; i < N_HNAMES; i++)
    if (HNAME_LEN[i] == len && p[0] == HNAMES[i][0] && !memcmp(HNAMES[i], p, len))
      return i + 1;
  return 0;
}

static inline jl_slice slice_of(FIOBJ o) {
  jl_slice s = {NULL, 0};
  if (!o || FIOBJ_IS_NULL(o))
    return s;
  fio_str_info_s i = fiobj_obj2cstr(o);
  s.ptr = i.data;
  s.len = i.len;
  return s;
}

int jlshim_req_head(http_s *h, jl_req *out) {
  out->method = slice_of(h->method);
  out->method_code = method_code(out->method.ptr, out->method.len);
  out->path = slice_of(h->path);
  out->query = slice_of(h->query);
  out->version = slice_of(h->version);
  out->nheaders = 0;
  out->body.ptr = NULL;
  out->body.len = 0;
  return 0;
}

typedef struct { jl_hdr *out; int cap; int n; } hdr_ctx;

static inline void push_hdr(hdr_ctx *c, jl_slice name, int code, FIOBJ v) {
  if (c->n < c->cap) {
    jl_hdr *d = c->out + c->n;
    d->name_code = code;
    d->name = name;
    d->value = slice_of(v);
  }
  c->n++;
}

static int each_header(FIOBJ value, void *arg) {
  hdr_ctx *c = arg;
  jl_slice name = slice_of(fiobj_hash_key_in_loop());
  int code = header_code(name.ptr, name.len);
  if (FIOBJ_TYPE_IS(value, FIOBJ_T_ARRAY)) {
    size_t cnt = fiobj_ary_count(value);
    for (size_t i = 0; i < cnt; i++)
      push_hdr(c, name, code, fiobj_ary_index(value, (int64_t)i));
  } else {
    push_hdr(c, name, code, value);
  }
  return 0;
}

jl_slice jlshim_req_body(http_s *h) {
  jl_slice s = {NULL, 0};
  if (h->body && !FIOBJ_IS_NULL(h->body)) {
    intptr_t len = fiobj_data_len(h->body);
    if (len > 0) {
      fio_str_info_s b = fiobj_data_pread(h->body, 0, (uintptr_t)len);
      s.ptr = b.data;
      s.len = b.len;
    }
  }
  return s;
}

/* Returns the real header count; if it exceeds cap the caller retries. */
int jlshim_req_full(http_s *h, jl_req *out, jl_hdr *hdrs, int cap) {
  if (!tables_ready)
    init_tables();
  jlshim_req_head(h, out);
  hdr_ctx c = {hdrs, cap, 0};
  if (h->headers)
    fiobj_each1(h->headers, 0, each_header, &c);
  out->nheaders = c.n;
  out->body = jlshim_req_body(h);
  return c.n;
}

/* First value of one header, looked up by lowercased name. 1 if found. */
int jlshim_req_header(http_s *h, const char *name, size_t len, jl_slice *out) {
  FIOBJ v = fiobj_hash_get2(h->headers, fiobj_hash_string(name, len));
  if (!v)
    return 0;
  if (FIOBJ_TYPE_IS(v, FIOBJ_T_ARRAY))
    v = fiobj_ary_index(v, 0);
  *out = slice_of(v);
  return 1;
}

int jlshim_respond(http_s *h, int status, const jl_slice *names,
                   const jl_slice *values, int n, const char *body,
                   size_t len) {
  h->status = (uintptr_t)status;
  for (int i = 0; i < n; i++)
    http_set_header2(h,
                     (fio_str_info_s){.data = (char *)names[i].ptr, .len = names[i].len},
                     (fio_str_info_s){.data = (char *)values[i].ptr, .len = values[i].len});
  return http_send_body(h, (void *)body, len);
}


static int wake_fd[2] = {-1, -1};
static atomic_int wake_pending;
static atomic_ulong n_wakes, n_drains;

static void wake_on_data(intptr_t uuid, fio_protocol_s *pr) {
  char buf[256];
  while (read(wake_fd[0], buf, sizeof(buf)) > 0)
    ;
  /* Reset only after the drain: a waker that skipped its write queued its
   * task before this point, and the queue is emptied before the next poll. */
  atomic_store(&wake_pending, 0);
  atomic_fetch_add(&n_drains, 1);
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

void shim_resume(http_pause_handle_s *handle, void (*task)(http_s *),
                 void (*fallback)(void *)) {
  http_resume(handle, task, fallback);
  shim_wake();
}

unsigned long shim_wakes(void) { return atomic_load(&n_wakes); }
unsigned long shim_drains(void) { return atomic_load(&n_drains); }
size_t shim_udata_offset(void) { return offsetof(http_s, udata); }

static void *reactor_main(void *arg) {
  fio_start(.threads = (int16_t)(intptr_t)arg, .workers = 1);
  return NULL;
}
int shim_start_pthread(int threads) {
  pthread_t t;
  return pthread_create(&t, NULL, reactor_main, (void *)(intptr_t)threads);
}

