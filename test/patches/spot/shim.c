#include "http.h"
#include "http_internal.h"
#include <string.h>

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

/* Offline request for the micro-benchmark: never touches a socket. */
static void fake_hdr(http_s *h, const char *n, const char *v) {
  FIOBJ name = fiobj_str_new(n, strlen(n));
  set_header_add(h->headers, name, fiobj_str_new(v, strlen(v)));
  fiobj_free(name);
}

http_s *jlshim_fake_request(int shape) {
  http_s *h = calloc(1, sizeof(*h));
  h->method = fiobj_str_new("GET", 3);
  h->path = fiobj_str_new("/json", 5);
  h->version = fiobj_str_new("HTTP/1.1", 8);
  h->headers = fiobj_hash_new();
  fake_hdr(h, "host", "127.0.0.1:3203");
  fake_hdr(h, "connection", "keep-alive");
  if (shape) {
    fake_hdr(h, "user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36");
    fake_hdr(h, "accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8");
    fake_hdr(h, "accept-encoding", "gzip, deflate, br, zstd");
    fake_hdr(h, "accept-language", "en-US,en;q=0.9");
    fake_hdr(h, "cache-control", "no-cache");
    fake_hdr(h, "cookie", "sid=0123456789abcdef0123456789abcdef; theme=dark; _ga=GA1.1.123456789.1700000000");
    fake_hdr(h, "referer", "http://127.0.0.1:3203/index.html");
    fake_hdr(h, "sec-fetch-site", "same-origin");
    fake_hdr(h, "sec-fetch-mode", "cors");
    fake_hdr(h, "x-request-id", "7f3c2b1a-9d8e-4f6a-b5c4-3e2d1f0a9b8c");
  }
  return h;
}

void jlshim_fake_free(http_s *h) {
  fiobj_free(h->method);
  fiobj_free(h->path);
  fiobj_free(h->version);
  fiobj_free(h->headers);
  free(h);
}
