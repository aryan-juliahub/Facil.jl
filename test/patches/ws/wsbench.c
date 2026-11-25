// WebSocket load client (kqueue, plain TCP). Prints one JSON line.
//   wsbench echo <port> <path> <conns> <threads> <size> <text|bin> <warm_s> <dur_s>
//   wsbench sub  <port> <path> <conns> <threads> <expect_per_conn> <timeout_s> <readyfile> [stalled]
//     `stalled` connections (spread evenly) subscribe and then never read.
//   WSB_PAYLOAD_FILE=<file>: echo mode sends the first <size> bytes of the file as the message.
//   WSB_DEFLATE_FRAME=<file>: echo mode offers permessage-deflate and sends the file's bytes as
//     one compressed message; replies are counted, not compared (wire bytes are reported).
//   wsbench idle <port> <path> <conns> <threads> <readyfile>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define FINE 10000 /* 1 us buckets below 10 ms, 100 us buckets up to 100 s */
#define NB (FINE + 999901)

typedef struct {
  int fd, dead;
  uint8_t *buf;
  size_t len, cap;
  size_t msg_off;   /* payload bytes of the current message already checked */
  uint64_t t_send;
  uint64_t next_seq; /* sub: next expected sequence number */
} conn_t;

typedef struct {
  pthread_t th;
  int kq, n;
  conn_t *c;
  uint64_t msgs, errors, bytes, done, wire;
  int active;
  uint64_t first_ns, last_ns;
  uint64_t *hist;
  uint64_t max_ns;
} thr_t;

enum { ECHO, SUB, IDLE } mode;
static int port, nconn, nthr;
static const char *path;
static size_t msg_size;
static int is_text;
static uint8_t *msg, *frame;
static size_t frame_len;
static uint64_t t_warm_end, t_end, expect_per;
static atomic_int stop_flag;
static int n_stalled, deflate_mode;

static inline uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }

static void hist_add(thr_t *t, uint64_t ns) {
  uint64_t us = ns / 1000;
  size_t i = us < FINE ? us : FINE + (us - FINE) / 100;
  if (i >= NB) i = NB - 1;
  t->hist[i]++;
  if (ns > t->max_ns) t->max_ns = ns;
}

static void write_all(thr_t *t, conn_t *c, const uint8_t *p, size_t n) {
  while (n) {
    ssize_t w = write(c->fd, p, n);
    if (w > 0) { p += w; n -= (size_t)w; continue; }
    if (w < 0 && (errno == EAGAIN || errno == EINTR)) {
      struct pollfd pf = {c->fd, POLLOUT, 0};
      poll(&pf, 1, 1000);
      continue;
    }
    c->dead = 1; t->errors++;
    return;
  }
}

static size_t make_frame(uint8_t *out, int opcode, const uint8_t *payload, size_t n) {
  static const uint8_t mask[4] = {0x37, 0xfa, 0x21, 0x3d};
  size_t h = 0;
  out[h++] = 0x80 | opcode;
  if (n < 126) out[h++] = 0x80 | n;
  else if (n < 65536) { out[h++] = 0x80 | 126; out[h++] = n >> 8; out[h++] = n & 255; }
  else { out[h++] = 0x80 | 127; for (int i = 7; i >= 0; i--) out[h++] = (uint8_t)((uint64_t)n >> (8 * i)); }
  memcpy(out + h, mask, 4); h += 4;
  for (size_t i = 0; i < n; i++) out[h + i] = payload[i] ^ mask[i & 3];
  return h + n;
}

static void send_msg(thr_t *t, conn_t *c) {
  c->t_send = now_ns();
  write_all(t, c, frame, frame_len);
}

static inline uint64_t digits(const uint8_t *p, int n) {
  uint64_t v = 0;
  for (int i = 0; i < n; i++) v = v * 10 + (p[i] - '0');
  return v;
}

static void on_message_done(thr_t *t, conn_t *c, uint64_t now, int measuring) {
  if (measuring) { t->msgs++; hist_add(t, now - c->t_send); }
  c->msg_off = 0;
  if (!atomic_load_explicit(&stop_flag, memory_order_relaxed)) send_msg(t, c);
}

/* Consumes every complete frame in c->buf. */
static void parse(thr_t *t, conn_t *c, uint64_t now, int measuring) {
  size_t off = 0;
  while (!c->dead) {
    size_t avail = c->len - off;
    if (avail < 2) break;
    uint8_t *p = c->buf + off;
    int fin = p[0] & 0x80, op = p[0] & 0x0f;
    uint64_t plen = p[1] & 0x7f;
    size_t h = 2;
    if (p[1] & 0x80) { t->errors++; c->dead = 1; break; }
    if (plen == 126) { if (avail < 4) break; plen = ((uint64_t)p[2] << 8) | p[3]; h = 4; }
    else if (plen == 127) { if (avail < 10) break; plen = 0; for (int i = 0; i < 8; i++) plen = (plen << 8) | p[2 + i]; h = 10; }
    size_t total = h + plen;
    if (avail < total) {
      if (total > c->cap) {
        size_t ncap = total + 4096;
        uint8_t *nb = malloc(ncap);
        memcpy(nb, p, avail);
        free(c->buf); c->buf = nb; c->cap = ncap; c->len = avail; off = 0;
      }
      break;
    }
    uint8_t *pl = p + h;
    if (op == 9) {
      uint8_t pong[160];
      size_t n = make_frame(pong, 10, pl, plen > 125 ? 125 : plen);
      write_all(t, c, pong, n);
    } else if (op == 8) {
      t->errors++; c->dead = 1;
    } else if (op <= 2) {
      t->bytes += plen;
      t->wire += total;
      if (mode == ECHO && deflate_mode) {
        if (!(p[0] & 0x40)) t->errors++;
        if (fin) on_message_done(t, c, now, measuring);
      } else if (mode == ECHO) {
        if (c->msg_off + plen > msg_size || memcmp(pl, msg + c->msg_off, plen)) { t->errors++; c->msg_off = 0; }
        else c->msg_off += plen;
        if (fin) {
          if (c->msg_off != msg_size) t->errors++;
          on_message_done(t, c, now, measuring);
        }
      } else if (mode == SUB) {
        if (!fin || plen < 32) t->errors++;
        else {
          uint64_t seq = digits(pl, 10), ts = digits(pl + 11, 20);
          if (seq != c->next_seq) t->errors++;
          c->next_seq = seq + 1;
          if (!t->first_ns) t->first_ns = now;
          t->last_ns = now;
          t->msgs++;
          hist_add(t, now > ts ? now - ts : 0);
          if (c->next_seq == expect_per) t->done++;
        }
      }
    }
    off += total;
  }
  if (off) { memmove(c->buf, c->buf + off, c->len - off); c->len -= off; }
}

static void *run(void *arg) {
  thr_t *t = arg;
  struct kevent ev[256];
  int measuring = mode != ECHO;
  if (mode == ECHO)
    for (int i = 0; i < t->n; i++) send_msg(t, &t->c[i]);
  for (;;) {
    struct timespec ts = {0, 50 * 1000000};
    int n = kevent(t->kq, NULL, 0, ev, 256, &ts);
    uint64_t now = now_ns();
    if (mode == ECHO) {
      if (!measuring && now >= t_warm_end) { measuring = 1; t->msgs = 0; t->bytes = 0; t->wire = 0; t->first_ns = now; }
      if (now >= t_end) { t->last_ns = now; break; }
    } else if (mode == SUB) {
      if (t->done == (uint64_t)t->active || now >= t_end) break;
    }
    if (atomic_load(&stop_flag)) break;
    for (int i = 0; i < n; i++) {
      conn_t *c = ev[i].udata;
      if (c->dead) continue;
      if (!c->buf) { c->cap = 4096; c->buf = malloc(c->cap); }
      ssize_t r = read(c->fd, c->buf + c->len, c->cap - c->len);
      if (r > 0) {
        c->len += (size_t)r;
        parse(t, c, mode == ECHO ? now_ns() : now, measuring);
      } else if (r == 0 || (errno != EAGAIN && errno != EINTR)) {
        c->dead = 1; t->errors++;
        close(c->fd);
      }
    }
  }
  return NULL;
}

static int n_reported;
static int fail(int fd, const char *what) {
  if (n_reported++ < 3) fprintf(stderr, "wsbench: %s failed: %s\n", what, strerror(errno));
  if (fd >= 0) close(fd);
  return -1;
}
static int ws_connect(conn_t *c) {
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  if (fd < 0) return fail(-1, "socket");
  if (connect(fd, (struct sockaddr *)&a, sizeof(a))) return fail(fd, "connect");
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  /* Close by reset: a normal close would park the port in TIME_WAIT for 30 s. */
  struct linger lg = {1, 0};
  setsockopt(fd, SOL_SOCKET, SO_LINGER, &lg, sizeof(lg));
  char req[512], res[2048];
  int n = snprintf(req, sizeof(req),
                   "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n%s\r\n", path, port,
                   deflate_mode ? "Sec-WebSocket-Extensions: permessage-deflate; client_no_context_takeover; server_no_context_takeover\r\n" : "");
  if (write(fd, req, n) != n) return fail(fd, "write");
  size_t got = 0;
  char *end = NULL;
  while (got < sizeof(res) - 1) {
    ssize_t r = read(fd, res + got, sizeof(res) - 1 - got);
    if (r <= 0) return fail(fd, r ? "read" : "read (eof)");
    got += (size_t)r; res[got] = 0;
    if ((end = strstr(res, "\r\n\r\n"))) break;
  }
  if (!end || strncmp(res, "HTTP/1.1 101", 12)) { errno = EPROTO; return fail(fd, "upgrade"); }
  if (deflate_mode && !strcasestr(res, "permessage-deflate")) { errno = EPROTO; return fail(fd, "permessage-deflate negotiation"); }
  size_t extra = got - (size_t)(end + 4 - res);
  c->fd = fd;
  if (extra) { c->cap = 4096; c->buf = malloc(c->cap); memcpy(c->buf, end + 4, extra); c->len = extra; }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  return 0;
}

static void on_term(int s) { (void)s; atomic_store(&stop_flag, 1); }

int main(int argc, char **argv) {
  if (argc < 7) { fprintf(stderr, "bad args\n"); return 2; }
  mode = !strcmp(argv[1], "echo") ? ECHO : !strcmp(argv[1], "sub") ? SUB : IDLE;
  port = atoi(argv[2]); path = argv[3]; nconn = atoi(argv[4]); nthr = atoi(argv[5]);
  if (nthr > nconn) nthr = nconn;
  double warm = 0, dur = 0;
  const char *ready = NULL;
  if (mode == ECHO) {
    msg_size = (size_t)atol(argv[6]); is_text = !strcmp(argv[7], "text"); warm = atof(argv[8]); dur = atof(argv[9]);
    msg = malloc(msg_size); frame = malloc(msg_size + 16);
    for (size_t i = 0; i < msg_size; i++) msg[i] = is_text ? (uint8_t)('a' + i % 26) : (uint8_t)(i * 31 + (i >> 8));
    const char *pf = getenv("WSB_PAYLOAD_FILE");
    if (pf) {
      FILE *f = fopen(pf, "rb");
      if (!f || fread(msg, 1, msg_size, f) != msg_size) { fprintf(stderr, "%s: need %zu bytes\n", pf, msg_size); return 2; }
      fclose(f);
    }
    frame_len = make_frame(frame, is_text ? 1 : 2, msg, msg_size);
    const char *df = getenv("WSB_DEFLATE_FRAME");
    if (df) {
      FILE *f = fopen(df, "rb");
      if (!f) { perror(df); return 2; }
      uint8_t *z = malloc(msg_size + 1024);
      size_t zn = fread(z, 1, msg_size + 1024, f);
      fclose(f);
      frame = malloc(zn + 16);
      frame_len = make_frame(frame, is_text ? 1 : 2, z, zn);
      frame[0] |= 0x40;
      deflate_mode = 1;
    }
  } else if (mode == SUB) {
    expect_per = strtoull(argv[6], NULL, 10); dur = atof(argv[7]); ready = argv[8];
    if (argc > 9) n_stalled = atoi(argv[9]);
  } else ready = argv[6];
  struct rlimit rl; getrlimit(RLIMIT_NOFILE, &rl);
  if (rl.rlim_cur < (rlim_t)nconn + 64) { rl.rlim_cur = nconn + 64; setrlimit(RLIMIT_NOFILE, &rl); }
  signal(SIGPIPE, SIG_IGN); signal(SIGTERM, on_term); signal(SIGINT, on_term);

  thr_t *T = calloc(nthr, sizeof(thr_t));
  conn_t *C = calloc(nconn, sizeof(conn_t));
  int connect_errors = 0;
  for (int i = 0; i < nthr; i++) { T[i].kq = kqueue(); T[i].hist = calloc(NB, 8); T[i].c = C + (size_t)i * nconn / nthr; T[i].n = (int)((size_t)(i + 1) * nconn / nthr - (size_t)i * nconn / nthr); }
  for (int i = 0; i < nthr; i++)
    for (int j = 0; j < T[i].n; j++) {
      conn_t *c = &T[i].c[j];
      if (ws_connect(c)) { connect_errors++; c->dead = 1; c->fd = -1; continue; }
      const long gi = c - C;
      if (n_stalled && gi * n_stalled / nconn != (gi + 1) * n_stalled / nconn) continue;
      T[i].active++;
      struct kevent e; EV_SET(&e, c->fd, EVFILT_READ, EV_ADD, 0, 0, c);
      kevent(T[i].kq, &e, 1, NULL, 0, NULL);
    }
  uint64_t t0 = now_ns();
  t_warm_end = t0 + (uint64_t)(warm * 1e9);
  t_end = mode == IDLE ? UINT64_MAX : t_warm_end + (uint64_t)(dur * 1e9);
  if (ready) { FILE *f = fopen(ready, "w"); fprintf(f, "%d %d\n", nconn - connect_errors, connect_errors); fclose(f); }
  for (int i = 0; i < nthr; i++) pthread_create(&T[i].th, NULL, run, &T[i]);
  for (int i = 0; i < nthr; i++) pthread_join(T[i].th, NULL);

  uint64_t msgs = 0, errors = 0, bytes = 0, wire = 0, maxns = 0, first = UINT64_MAX, last = 0;
  int active = 0;
  uint64_t *H = calloc(NB, 8);
  for (int i = 0; i < nthr; i++) {
    msgs += T[i].msgs; errors += T[i].errors; bytes += T[i].bytes; wire += T[i].wire; active += T[i].active;
    if (T[i].max_ns > maxns) maxns = T[i].max_ns;
    if (T[i].first_ns && T[i].first_ns < first) first = T[i].first_ns;
    if (T[i].last_ns > last) last = T[i].last_ns;
    for (size_t k = 0; k < NB; k++) H[k] += T[i].hist[k];
  }
  uint64_t tot = 0, acc = 0; double p50 = 0, p99 = 0; int g50 = 0, g99 = 0;
  for (size_t k = 0; k < NB; k++) tot += H[k];
  for (size_t k = 0; k < NB && tot; k++) {
    acc += H[k];
    double us = k < FINE ? (double)k : FINE + (double)(k - FINE) * 100;
    if (!g50 && acc * 2 >= tot) { p50 = us; g50 = 1; }
    if (!g99 && acc * 100 >= tot * 99) { p99 = us; g99 = 1; }
  }
  double secs = (last > first) ? (double)(last - first) / 1e9 : 0;
  const char *mname = mode == ECHO ? "echo" : mode == SUB ? "sub" : "idle";
  printf("{\"mode\":\"%s\",\"conns\":%d,\"connect_errors\":%d,\"msgs\":%llu,\"secs\":%.3f,\"rate\":%.0f,"
         "\"bytes\":%llu,\"p50_us\":%.0f,\"p99_us\":%.0f,\"max_us\":%.0f,\"errors\":%llu",
         mname, nconn, connect_errors, (unsigned long long)msgs, secs, secs > 0 ? msgs / secs : 0,
         (unsigned long long)bytes, p50, p99, maxns / 1e3, (unsigned long long)errors);
  printf(",\"wire_bytes\":%llu", (unsigned long long)wire);
  if (mode == SUB) printf(",\"stalled\":%d,\"expected\":%llu", n_stalled, (unsigned long long)(expect_per * (uint64_t)active));
  printf("}\n");
  return 0;
}
