/* TLS load generator that costs far less CPU than the server under test.
 *
 *   tlsload ka <port> <path> <conns> <threads> <warm_s> <dur_s>
 *       keep-alive GETs. After two fully decrypted responses per connection the
 *       client stops decrypting: it walks the TLS record headers on the wire
 *       and counts plaintext bytes (record length - 17 under TLS 1.3 AEAD) to
 *       find the end of each response.
 *   tlsload hs <port> <threads> <warm_s> <dur_s> [resume] [tls12] [fin] [max=<connections>]
 *       one connection per request (`Connection: close`), read to the server's
 *       close and then reset, so no TIME_WAIT entries pile up on the client.
 *       `fin` closes normally instead: right for a server that closes first.
 *       `max=` ends the run early: this machine has ~16k client ports, and a
 *       port met again while its last connection lingers stalls for seconds.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static int port;
static const char *path = "/json";
static atomic_ulong n_ok, n_err, n_reused, n_bytes, n_all, n_slow;
static atomic_int measuring, stopping;
static SSL_CTX *ctx;
static int resume_mode;
static int fin_mode;
static unsigned long max_all;

static double now(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return tv.tv_sec + tv.tv_usec / 1e6;
}

static int tcp_connect(void) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
  inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  struct timeval tv = {5, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  if (connect(fd, (struct sockaddr *)&a, sizeof(a))) {
    close(fd);
    return -1;
  }
  return fd;
}

static void reset_close(int fd) {
  struct linger l = {1, 0};
  setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, sizeof(l));
  close(fd);
}

/* ---------------------------------------------------------------- keep-alive */

typedef struct {
  int fd;
  SSL *ssl;
  size_t expect; /* plaintext bytes per response */
  size_t got;    /* plaintext bytes of the current response so far */
  size_t rec_left;
  unsigned char hdr[5];
  int hdr_len;
} conn_s;

static char request[512];
static int request_len;

/* Reads one response with real decryption; returns its plaintext size. */
static long read_response_plain(SSL *ssl) {
  static __thread char buf[1 << 16];
  size_t total = 0, head = 0;
  long clen = -1;
  char hb[4096];
  size_t hl = 0;
  for (;;) {
    int r = SSL_read(ssl, buf, sizeof(buf));
    if (r <= 0)
      return -1;
    if (!head) {
      size_t take = (size_t)r < sizeof(hb) - 1 - hl ? (size_t)r : sizeof(hb) - 1 - hl;
      memcpy(hb + hl, buf, take);
      hl += take;
      hb[hl] = 0;
      char *e = strstr(hb, "\r\n\r\n");
      if (e) {
        head = (e - hb) + 4;
        char *c = strcasestr(hb, "content-length:");
        if (!c)
          return -1;
        clen = atol(c + 15);
      }
    }
    total += r;
    if (head && total >= head + (size_t)clen)
      return (long)total;
  }
}

static int conn_open(conn_s *c) {
  c->fd = tcp_connect();
  if (c->fd < 0)
    return -1;
  c->ssl = SSL_new(ctx);
  SSL_set_fd(c->ssl, c->fd);
  if (SSL_connect(c->ssl) != 1)
    return -1;
  long a = 0;
  for (int i = 0; i < 2; ++i) {
    if (SSL_write(c->ssl, request, request_len) != request_len)
      return -1;
    a = read_response_plain(c->ssl);
    if (a <= 0)
      return -1;
  }
  if (SSL_pending(c->ssl) || SSL_has_pending(c->ssl))
    return -1;
  c->expect = (size_t)a;
  c->got = 0;
  c->rec_left = 0;
  c->hdr_len = 0;
  fcntl(c->fd, F_SETFL, fcntl(c->fd, F_GETFL) | O_NONBLOCK);
  return 0;
}

typedef struct {
  conn_s *conns;
  int count;
} ka_thread_s;

static void *ka_thread(void *arg) {
  ka_thread_s *t = arg;
  int kq = kqueue();
  static __thread unsigned char buf[1 << 18];
  for (int i = 0; i < t->count; ++i) {
    struct kevent ev;
    EV_SET(&ev, t->conns[i].fd, EVFILT_READ, EV_ADD, 0, 0, &t->conns[i]);
    kevent(kq, &ev, 1, NULL, 0, NULL);
    if (SSL_write(t->conns[i].ssl, request, request_len) != request_len)
      atomic_fetch_add(&n_err, 1);
  }
  struct kevent evs[64];
  struct timespec to = {0, 100000000};
  while (!stopping) {
    int n = kevent(kq, NULL, 0, evs, 64, &to);
    for (int e = 0; e < n; ++e) {
      conn_s *c = evs[e].udata;
      for (;;) {
        ssize_t r = read(c->fd, buf, sizeof(buf));
        if (r <= 0) {
          if (r == 0 || (errno != EAGAIN && errno != EINTR)) {
            atomic_fetch_add(&n_err, 1);
            struct kevent ev;
            EV_SET(&ev, c->fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
            kevent(kq, &ev, 1, NULL, 0, NULL);
          }
          break;
        }
        if (measuring)
          atomic_fetch_add(&n_bytes, r);
        ssize_t p = 0;
        while (p < r) {
          if (c->rec_left) {
            size_t take = c->rec_left < (size_t)(r - p) ? c->rec_left : (size_t)(r - p);
            c->rec_left -= take;
            p += take;
            continue;
          }
          c->hdr[c->hdr_len++] = buf[p++];
          if (c->hdr_len < 5)
            continue;
          c->hdr_len = 0;
          size_t len = ((size_t)c->hdr[3] << 8) | c->hdr[4];
          c->rec_left = len;
          if (c->hdr[0] == 23 && len >= 17)
            c->got += len - 17;
          if (c->got >= c->expect) {
            if (c->got > c->expect)
              atomic_fetch_add(&n_err, 1);
            c->got = 0;
            atomic_fetch_add(&n_all, 1);
            if (measuring)
              atomic_fetch_add(&n_ok, 1);
            if (SSL_write(c->ssl, request, request_len) != request_len)
              atomic_fetch_add(&n_err, 1);
          }
        }
        if ((size_t)r < sizeof(buf))
          break;
      }
    }
  }
  return NULL;
}

/* ---------------------------------------------------------------- handshakes */

/* A thread keeps its latest ticket in serialized form and resumes every
 * connection from a fresh copy, as Node's client does with a session buffer:
 * OpenSSL retires a TLS 1.3 session object after one resumption. */
typedef struct {
  unsigned char *der;
  int len;
} ticket_s;

static int sess_index;
static int new_session_cb(SSL *ssl, SSL_SESSION *s) {
  ticket_s *t = SSL_get_ex_data(ssl, sess_index);
  if (t) {
    OPENSSL_free(t->der);
    t->der = NULL;
    t->len = i2d_SSL_SESSION(s, &t->der);
  }
  return 0;
}

static void *hs_thread(void *arg) {
  ticket_s ticket = {NULL, 0};
  (void)arg;
  while (!stopping) {
    double t0 = now();
    int fd = tcp_connect();
    if (now() - t0 > 0.1)
      atomic_fetch_add(&n_slow, 1);
    if (fd < 0) {
      if (measuring)
        atomic_fetch_add(&n_err, 1);
      usleep(1000);
      continue;
    }
    SSL *ssl = SSL_new(ctx);
    SSL_set_fd(ssl, fd);
    SSL_set_ex_data(ssl, sess_index, resume_mode ? &ticket : NULL);
    if (resume_mode && ticket.len > 0) {
      const unsigned char *p = ticket.der;
      SSL_SESSION *sess = d2i_SSL_SESSION(NULL, &p, ticket.len);
      if (sess) {
        SSL_set_session(ssl, sess);
        SSL_SESSION_free(sess);
      }
    }
    /* Reads to the server's close before resetting. Resetting right after
     * the body instead made runs against every server stall for seconds. */
    int ok = SSL_connect(ssl) == 1 && SSL_write(ssl, request, request_len) == request_len;
    size_t total = 0;
    char buf[4096];
    while (ok) {
      int r = SSL_read(ssl, buf, sizeof(buf));
      if (r <= 0)
        break;
      total += r;
    }
    ok = ok && total > 150;
    atomic_fetch_add(&n_all, 1);
    if (measuring) {
      atomic_fetch_add(ok ? &n_ok : &n_err, 1);
      if (ok && SSL_session_reused(ssl))
        atomic_fetch_add(&n_reused, 1);
    }
    SSL_free(ssl);
    if (fin_mode)
      close(fd);
    else
      reset_close(fd);
  }
  OPENSSL_free(ticket.der);
  return NULL;
}

int main(int argc, char **argv) {
  if (argc < 6)
    return 2;
  int ka = !strcmp(argv[1], "ka");
  port = atoi(argv[2]);
  ctx = SSL_CTX_new(TLS_client_method());
  SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
  int threads, conns = 0;
  double warm, dur;
  if (ka) {
    if (argc < 8)
      return 2;
    path = argv[3];
    conns = atoi(argv[4]);
    threads = atoi(argv[5]);
    warm = atof(argv[6]);
    dur = atof(argv[7]);
    SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION);
    request_len = snprintf(request, sizeof(request), "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n", path, port);
  } else {
    threads = atoi(argv[3]);
    warm = atof(argv[4]);
    dur = atof(argv[5]);
    for (int i = 6; i < argc; ++i) {
      if (!strcmp(argv[i], "resume"))
        resume_mode = 1;
      if (!strncmp(argv[i], "max=", 4))
        max_all = strtoul(argv[i] + 4, NULL, 10);
      if (!strcmp(argv[i], "fin"))
        fin_mode = 1;
      if (!strcmp(argv[i], "tls12"))
        SSL_CTX_set_max_proto_version(ctx, TLS1_2_VERSION);
    }
    sess_index = SSL_get_ex_new_index(0, NULL, NULL, NULL, NULL);
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_CLIENT | SSL_SESS_CACHE_NO_INTERNAL);
    SSL_CTX_sess_set_new_cb(ctx, new_session_cb);
    request_len = snprintf(request, sizeof(request), "GET /json HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n", port);
  }
  pthread_t *th = calloc(threads, sizeof(*th));
  ka_thread_s *kt = calloc(threads, sizeof(*kt));
  conn_s *all = calloc(conns ? conns : 1, sizeof(*all));
  size_t expect = 0;
  if (ka) {
    for (int i = 0; i < conns; ++i) {
      if (conn_open(&all[i])) {
        fprintf(stderr, "connection %d failed to open\n", i);
        ERR_print_errors_fp(stderr);
        return 1;
      }
      expect = all[i].expect;
    }
    int per = conns / threads, at = 0;
    for (int i = 0; i < threads; ++i) {
      kt[i].conns = all + at;
      kt[i].count = (i == threads - 1) ? conns - at : per;
      at += kt[i].count;
      pthread_create(&th[i], NULL, ka_thread, &kt[i]);
    }
  } else {
    for (int i = 0; i < threads; ++i)
      pthread_create(&th[i], NULL, hs_thread, NULL);
  }
  usleep((useconds_t)(warm * 1e6));
  measuring = 1;
  double t0 = now();
  while (now() - t0 < dur && (!max_all || n_all < max_all))
    usleep(5000);
  measuring = 0;
  double secs = now() - t0;
  unsigned long ok = n_ok, err = n_err, reused = n_reused, bytes = n_bytes;
  stopping = 1;
  for (int i = 0; i < threads; ++i)
    pthread_join(th[i], NULL);
  unsigned long total = n_all + (ka ? 2UL * conns : 0);
  if (ka)
    for (int i = 0; i < conns; ++i)
      reset_close(all[i].fd);
  printf("{\"mode\":\"%s\",\"count\":%lu,\"rate\":%.0f,\"errors\":%lu,\"reused\":%lu,\"secs\":%.3f,\"wire_bytes_per_req\":%.0f,\"plain_bytes_per_resp\":%zu,\"all\":%lu,\"slow_connects\":%lu}\n",
         argv[1], ok, ok / secs, err, reused, secs, ok ? (double)bytes / ok : 0, expect, total, (unsigned long)n_slow);
  return 0;
}
