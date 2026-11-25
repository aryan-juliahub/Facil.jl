/* Edge-case TLS client for the safety checks.
 *
 *   tls_probe coalesce <port> <n>      the handshake's last flight and n pipelined GET /json
 *                                      requests leave in ONE socket write; expects n responses
 *   tls_probe bigrec <port> <bytes>    POST /upload whose head and body share one TLS record
 *                                      and one socket write; prints the server's reply
 *   tls_probe abort <port> <n> <size>  n times: GET /s/<size>, read 32 KB, reset the connection
 *   tls_probe stall <port> <seconds>   connects, sends nothing; reports when the server closes
 */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static int port;

static double now(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return tv.tv_sec + tv.tv_usec / 1e6;
}

static int tcp_connect(int timeout_s) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
  inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  struct timeval tv = {timeout_s, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  if (connect(fd, (struct sockaddr *)&a, sizeof(a))) {
    perror("connect");
    exit(1);
  }
  return fd;
}

static void reset_close(int fd) {
  struct linger l = {1, 0};
  setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, sizeof(l));
  close(fd);
}

static void write_all(int fd, const char *p, long n) {
  while (n > 0) {
    ssize_t w = write(fd, p, n);
    if (w <= 0) {
      perror("write");
      exit(1);
    }
    p += w;
    n -= w;
  }
}

/* Handshakes over memory BIOs. The client's last flight stays in the write BIO
 * so the caller can append application records before anything is sent. */
static SSL *handshake_hold_last_flight(SSL_CTX *ctx, int fd) {
  SSL *ssl = SSL_new(ctx);
  BIO *rb = BIO_new(BIO_s_mem()), *wb = BIO_new(BIO_s_mem());
  SSL_set_bio(ssl, rb, wb);
  SSL_set_connect_state(ssl);
  char buf[16384];
  for (;;) {
    int r = SSL_do_handshake(ssl);
    if (r == 1)
      return ssl;
    if (SSL_get_error(ssl, r) != SSL_ERROR_WANT_READ) {
      ERR_print_errors_fp(stderr);
      exit(1);
    }
    char *out;
    long n = BIO_get_mem_data(wb, &out);
    write_all(fd, out, n);
    (void)BIO_reset(wb);
    ssize_t got = read(fd, buf, sizeof(buf));
    if (got <= 0) {
      fprintf(stderr, "server closed during handshake\n");
      exit(1);
    }
    BIO_write(rb, buf, (int)got);
  }
}

/* Sends everything queued in the write BIO with one write, then collects
 * plaintext until `want(text, len)` is satisfied or the server goes quiet. */
static long flush_and_collect(SSL *ssl, int fd, char *text, long cap, int (*want)(const char *, long, long), long arg) {
  BIO *rb = SSL_get_rbio(ssl), *wb = SSL_get_wbio(ssl);
  char *out;
  long n = BIO_get_mem_data(wb, &out);
  ssize_t w = write(fd, out, n);
  if (w != n) {
    fprintf(stderr, "short write %zd of %ld\n", w, n);
    exit(1);
  }
  fprintf(stderr, "sent %ld bytes in one write\n", n);
  (void)BIO_reset(wb);
  long len = 0;
  char buf[16384];
  while (!want(text, len, arg)) {
    ssize_t got = read(fd, buf, sizeof(buf));
    if (got <= 0)
      break;
    BIO_write(rb, buf, (int)got);
    for (;;) {
      int r = SSL_read(ssl, text + len, (int)(cap - len - 1));
      if (r <= 0)
        break;
      len += r;
      text[len] = 0;
    }
  }
  return len;
}

static int count_of(const char *text, const char *needle) {
  int c = 0;
  for (const char *p = text; (p = strstr(p, needle)); p += strlen(needle))
    ++c;
  return c;
}
static int want_responses(const char *text, long len, long n) {
  return len > 0 && count_of(text, "\"login_count\":42}") >= n;
}
static int want_sha(const char *text, long len, long ignr) {
  (void)ignr;
  return len > 0 && strstr(text, "sha256=") && text[len - 1] == '\n';
}

int main(int argc, char **argv) {
  if (argc < 4)
    return 2;
  port = atoi(argv[2]);
  SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
  SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
  static char text[1 << 20];
  if (!strcmp(argv[1], "coalesce")) {
    int n = atoi(argv[3]);
    int fd = tcp_connect(3);
    SSL *ssl = handshake_hold_last_flight(ctx, fd);
    char req[256];
    int rl = snprintf(req, sizeof(req), "GET /json HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n", port);
    for (int i = 0; i < n; ++i)
      SSL_write(ssl, req, rl);
    double t0 = now();
    flush_and_collect(ssl, fd, text, sizeof(text), want_responses, n);
    int got = count_of(text, "\"login_count\":42}");
    printf("coalesce: %d of %d responses in %.0f ms %s\n", got, n, (now() - t0) * 1e3, got == n ? "OK" : "FAIL");
    reset_close(fd);
    return got != n;
  }
  if (!strcmp(argv[1], "bigrec")) {
    int bytes = atoi(argv[3]);
    int fd = tcp_connect(3);
    SSL *ssl = handshake_hold_last_flight(ctx, fd);
    /* the flight is sent alone here: this check is about one record, not the handshake */
    BIO *wb = SSL_get_wbio(ssl);
    char *out;
    long n = BIO_get_mem_data(wb, &out);
    write_all(fd, out, n);
    (void)BIO_reset(wb);
    usleep(100000);
    static char req[20000];
    if (bytes > 16000)
      return 2;
    int rl = snprintf(req, sizeof(req), "POST /upload HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Length: %d\r\n\r\n", port, bytes);
    for (int i = 0; i < bytes; ++i)
      req[rl + i] = (char)((i * 7 + (i >> 10)) & 0xff);
    SSL_write(ssl, req, rl + bytes);
    double t0 = now();
    long len = flush_and_collect(ssl, fd, text, sizeof(text), want_sha, 0);
    const char *body = len > 0 ? strstr(text, "\r\n\r\n") : NULL;
    printf("bigrec: %.0f ms %s", (now() - t0) * 1e3, body ? body + 4 : "NO REPLY\n");
    reset_close(fd);
    return body == NULL;
  }
  if (!strcmp(argv[1], "abort")) {
    if (argc < 5)
      return 2;
    int n = atoi(argv[3]), ok = 0;
    char req[256], buf[32768];
    int rl = snprintf(req, sizeof(req), "GET /s/%s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n", argv[4], port);
    for (int i = 0; i < n; ++i) {
      int fd = tcp_connect(3);
      SSL *ssl = SSL_new(ctx);
      SSL_set_fd(ssl, fd);
      if (SSL_connect(ssl) == 1 && SSL_write(ssl, req, rl) == rl && SSL_read(ssl, buf, sizeof(buf)) > 0)
        ++ok;
      SSL_free(ssl);
      reset_close(fd);
    }
    printf("abort: %d of %d connections got a first chunk before the reset\n", ok, n);
    return ok != n;
  }
  if (!strcmp(argv[1], "stall")) {
    int fd = tcp_connect(atoi(argv[3]));
    double t0 = now();
    char b;
    ssize_t r = read(fd, &b, 1);
    printf("stall: read returned %zd after %.1f s (%s)\n", r, now() - t0, r == 0 ? "server closed" : r < 0 ? "still open at the limit" : "data");
    close(fd);
    return 0;
  }
  return 2;
}
