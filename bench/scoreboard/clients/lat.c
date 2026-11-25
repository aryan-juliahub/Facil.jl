// lat: single-thread kqueue HTTP/1.1 keep-alive load client, nanosecond timing.
//   lat -P port -f reqfile [-c conns] [-d secs] [-w warmup secs] [-r req/s] [-p pipeline] [-s settle secs]
//   lat -P port -u /path [-B body bytes [-k chunk bytes]] ...   builds the request itself:
//       GET without -B, else POST with Content-Length, or chunked with -k; the body is all 'x'.
// Connections open one by one (a refused connect is retried), so a small accept queue is fine.
// -s N: nothing is sent until N seconds after start, so several instances begin together.
// -r 0 (default) is closed loop; -r N is open loop at N req/s, latency counted from the
// scheduled send time. svc_* = from the actual send, late_* = how late the client sent.
// Responses must carry Content-Length (any size). Prints one JSON line.
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/event.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define RBUF 65536
typedef struct {
  int fd, inflight, idle, in_body;
  size_t woff, rlen, skip;
  uint64_t t0, t_sent;
  char rbuf[RBUF];
} conn;

static int kq, port = 3500, nconn = 100, pipeline = 1;
static double dur = 10, warm = 3, rate = 0, settle = 0;
static char *req;
static size_t reqlen;
static conn *conns, **idle;
static int nidle;
static float *lat, *svc, *late;
static size_t nlat, caplat;
static uint64_t t_start, t_warm, t_end;
static uint64_t done, done_all, non2xx, conn_errors, connect_fail, late_errors, connect_retries, bad_framing;
static uint64_t bytes_in;

static uint64_t ns(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }

static void die(const char *m) { perror(m); exit(2); }

static int open_conn(conn *c) {
  struct sockaddr_in a = {0};
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
  c->fd = socket(AF_INET, SOCK_STREAM, 0);
  if (c->fd < 0) die("socket");
  int one = 1;
  setsockopt(c->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  setsockopt(c->fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  if (connect(c->fd, (void *)&a, sizeof(a))) {
    close(c->fd);
    c->fd = -1;
    connect_fail++;
    return -1;
  }
  fcntl(c->fd, F_SETFL, fcntl(c->fd, F_GETFL) | O_NONBLOCK);
  struct kevent ev;
  EV_SET(&ev, c->fd, EVFILT_READ, EV_ADD, 0, 0, c);
  kevent(kq, &ev, 1, NULL, 0, NULL);
  c->inflight = 0;
  c->woff = c->rlen = c->skip = 0;
  c->in_body = 0;
  return 0;
}

static void flush_conn(conn *c) {
  while (c->woff < reqlen) {
    ssize_t n = write(c->fd, req + c->woff, reqlen - c->woff);
    if (n < 0) {
      if (errno == EAGAIN) {
        struct kevent ev;
        EV_SET(&ev, c->fd, EVFILT_WRITE, EV_ADD | EV_ONESHOT, 0, 0, c);
        kevent(kq, &ev, 1, NULL, 0, NULL);
      }
      return;
    }
    c->woff += n;
  }
}

static void send_req(conn *c, uint64_t t0) {
  c->t0 = t0;
  c->t_sent = ns();
  c->woff = 0;
  c->inflight = pipeline;
  c->idle = 0;
  flush_conn(c);
}

static void released(conn *c) {
  if (rate > 0) {
    c->idle = 1;
    idle[nidle++] = c;
  } else {
    send_req(c, ns());
  }
}

static void reset_conn(conn *c) {
  conn_errors++;
  if (t_warm && ns() >= t_warm)
    late_errors++;
  close(c->fd);
  for (int tries = 0; tries < 500; tries++) {
    if (open_conn(c) == 0) {
      released(c);
      return;
    }
    usleep(1000);
  }
}

static void record(conn *c) {
  uint64_t now = ns();
  done_all += pipeline;
  if (now >= t_warm && now <= t_end) {
    done += pipeline;
    if (nlat == caplat) {
      caplat *= 2;
      lat = realloc(lat, caplat * sizeof(float));
      svc = realloc(svc, caplat * sizeof(float));
      late = realloc(late, caplat * sizeof(float));
    }
    svc[nlat] = (float)((now - c->t_sent) / 1e3);
    late[nlat] = (float)((c->t_sent - c->t0) / 1e3);
    lat[nlat++] = (float)((now - c->t0) / 1e3);
  }
}

/* 1 = a response head was consumed and its body is now in c->skip; 0 = need more; -1 = bad framing */
static int take_head(conn *c) {
  char *end = memmem(c->rbuf, c->rlen, "\r\n\r\n", 4);
  if (!end)
    return c->rlen == RBUF ? -1 : 0;
  size_t head = (size_t)(end - c->rbuf) + 4, clen = 0;
  int have_len = 0;
  for (char *p = c->rbuf; p < end;) {
    char *nl = memchr(p, '\n', (size_t)(end - p) + 2);
    if (!strncasecmp(p, "content-length:", 15)) {
      clen = strtoul(p + 15, NULL, 10);
      have_len = 1;
    }
    p = nl + 1;
  }
  int status2 = c->rlen >= 12 && c->rbuf[9] == '2';
  if (!have_len && !(c->rbuf[9] == '1' || (c->rbuf[9] == '2' && c->rbuf[10] == '0' && c->rbuf[11] == '4')))
    return -1;
  if (!status2)
    non2xx++;
  c->rlen -= head;
  if (c->rlen)
    memmove(c->rbuf, c->rbuf + head, c->rlen);
  c->skip = clen;
  return 1;
}

/* consume body bytes still owed; 1 = response complete */
static int drain_body(conn *c) {
  size_t k = c->skip < c->rlen ? c->skip : c->rlen;
  c->skip -= k;
  c->rlen -= k;
  if (c->rlen)
    memmove(c->rbuf, c->rbuf + k, c->rlen);
  return c->skip == 0;
}

static void on_read(conn *c) {
  for (;;) {
    ssize_t n;
    if (c->skip > 0 && c->rlen == 0) {
      static char sink[262144];
      size_t want = c->skip < sizeof(sink) ? c->skip : sizeof(sink);
      n = read(c->fd, sink, want);
      if (n < 0 && errno == EAGAIN)
        return;
      if (n <= 0) {
        reset_conn(c);
        return;
      }
      bytes_in += n;
      c->skip -= n;
      if (c->skip)
        continue;
    } else {
      n = read(c->fd, c->rbuf + c->rlen, RBUF - c->rlen);
      if (n < 0 && errno == EAGAIN)
        return;
      if (n <= 0) {
        reset_conn(c);
        return;
      }
      bytes_in += n;
      c->rlen += n;
    }
    for (;;) {
      if (!c->inflight)
        break;
      if (!c->in_body) {
        int h = take_head(c);
        if (h < 0) {
          bad_framing++;
          reset_conn(c);
          return;
        }
        if (h == 0)
          break;
        c->in_body = 1;
      }
      if (c->skip > 0 && !drain_body(c))
        break;
      c->in_body = 0;
      if (--c->inflight)
        continue;
      record(c);
      released(c);
      if (rate > 0)
        return;
    }
    if (c->skip == 0 && (size_t)n < RBUF / 2)
      return;
  }
}

static int cmp(const void *a, const void *b) {
  float x = *(float *)a, y = *(float *)b;
  return x < y ? -1 : x > y;
}
static double pctof(float *v, double p) {
  if (!nlat)
    return 0;
  size_t i = (size_t)(p * nlat);
  return v[i >= nlat ? nlat - 1 : i] / 1e3;
}
static double pct(double p) { return pctof(lat, p); }

static void build_request(const char *url, long body, long chunk) {
  size_t cap = (body > 0 ? (size_t)body + (chunk ? ((size_t)body / chunk + 2) * 20 : 0) : 0) + 512, n = 0;
  req = malloc(cap);
  if (body < 0)
    n = snprintf(req, cap, "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", url);
  else if (!chunk)
    n = snprintf(req, cap, "POST %s HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/octet-stream\r\nContent-Length: %ld\r\n\r\n", url, body);
  else
    n = snprintf(req, cap, "POST %s HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n", url);
  for (long i = 0; i < body;) {
    long piece = chunk && body - i > chunk ? chunk : body - i;
    if (chunk)
      n += snprintf(req + n, cap - n, "%lx\r\n", piece);
    memset(req + n, 'x', (size_t)piece);
    n += piece;
    i += piece;
    if (chunk) { req[n++] = '\r'; req[n++] = '\n'; }
  }
  if (chunk && body >= 0) { memcpy(req + n, "0\r\n\r\n", 5); n += 5; }
  reqlen = n;
}

int main(int argc, char **argv) {
  const char *file = NULL, *url = NULL;
  long body = -1, chunk = 0;
  int o;
  while ((o = getopt(argc, argv, "P:f:c:d:w:r:p:s:u:B:k:")) != -1) {
    if (o == 'P') port = atoi(optarg);
    else if (o == 'f') file = optarg;
    else if (o == 'c') nconn = atoi(optarg);
    else if (o == 'd') dur = atof(optarg);
    else if (o == 'w') warm = atof(optarg);
    else if (o == 'r') rate = atof(optarg);
    else if (o == 'p') pipeline = atoi(optarg);
    else if (o == 's') settle = atof(optarg);
    else if (o == 'u') url = optarg;
    else if (o == 'B') body = atol(optarg);
    else if (o == 'k') chunk = atol(optarg);
  }
  if (url) {
    build_request(url, body, chunk);
    char *one = req;
    size_t onelen = reqlen;
    req = malloc(onelen * pipeline);
    for (int i = 0; i < pipeline; i++)
      memcpy(req + i * onelen, one, onelen);
    reqlen = onelen * pipeline;
  } else {
    if (!file) { fprintf(stderr, "need -f reqfile or -u path\n"); return 2; }
    FILE *f = fopen(file, "rb");
    if (!f) die("reqfile");
    fseek(f, 0, SEEK_END);
    size_t one = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    reqlen = one * pipeline;
    req = malloc(reqlen);
    if (fread(req, 1, one, f) != one) die("read reqfile");
    for (int i = 1; i < pipeline; i++)
      memcpy(req + i * one, req, one);
    fclose(f);
  }

  uint64_t t_proc = ns();
  kq = kqueue();
  conns = calloc(nconn, sizeof(conn));
  idle = calloc(nconn, sizeof(conn *));
  caplat = 1 << 20;
  lat = malloc(caplat * sizeof(float));
  svc = malloc(caplat * sizeof(float));
  late = malloc(caplat * sizeof(float));
  for (int i = 0; i < nconn; i++) {
    int tries = 0;
    while (open_conn(&conns[i])) {
      if (++tries > 2000) die("connect");
      connect_retries++;
      usleep(2000);
    }
    if (settle > 0)
      usleep(300);
  }
  connect_fail = 0;
  while (settle > 0 && ns() < t_proc + (uint64_t)(settle * 1e9))
    usleep(1000);

  t_start = ns();
  t_warm = t_start + (uint64_t)(warm * 1e9);
  t_end = t_warm + (uint64_t)(dur * 1e9);
  uint64_t sent = 0, max_backlog = 0;
  for (int i = 0; i < nconn; i++)
    released(&conns[i]);

  struct kevent evs[256];
  struct timespec zero = {0, 0}, tick = {0, 50 * 1000 * 1000};
  for (;;) {
    uint64_t now = ns();
    if (now >= t_end)
      break;
    if (rate > 0) {
      uint64_t due = (uint64_t)((now - t_start) * rate / 1e9);
      while (sent < due && nidle) {
        conn *c = idle[--nidle];
        send_req(c, t_start + (uint64_t)(sent * 1e9 / rate));
        sent++;
      }
      if (now >= t_warm && due - sent > max_backlog)
        max_backlog = due - sent;
    }
    int n = kevent(kq, NULL, 0, evs, 256, rate > 0 ? &zero : &tick);
    for (int i = 0; i < n; i++) {
      conn *c = evs[i].udata;
      if (evs[i].filter == EVFILT_WRITE)
        flush_conn(c);
      else
        on_read(c);
    }
  }
  uint64_t stuck = 0, now = ns();
  for (int i = 0; i < nconn; i++)
    if (conns[i].fd >= 0 && !conns[i].idle && conns[i].inflight && now - conns[i].t0 > 2000000000ull)
      stuck++;
  qsort(lat, nlat, sizeof(float), cmp);
  qsort(svc, nlat, sizeof(float), cmp);
  qsort(late, nlat, sizeof(float), cmp);
  double sum = 0;
  for (size_t i = 0; i < nlat; i++)
    sum += lat[i];
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  double cpu = ru.ru_utime.tv_sec + ru.ru_stime.tv_sec + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6;
  printf("{\"rps\":%.1f,\"n\":%llu,\"n_all\":%llu,\"client_cpu\":%.3f,\"wall\":%.3f,\"bytes_in\":%llu,"
         "\"mean\":%.4f,\"p50\":%.4f,\"p90\":%.4f,\"p99\":%.4f,\"p999\":%.4f,\"max\":%.4f,"
         "\"svc_p50\":%.4f,\"svc_p99\":%.4f,\"svc_p999\":%.4f,\"svc_max\":%.4f,\"late_p99\":%.4f,\"late_p999\":%.4f,\"late_max\":%.4f,"
         "\"non2xx\":%llu,\"conn_errors\":%llu,\"connect_fail\":%llu,\"stuck\":%llu,\"max_backlog\":%llu,\"late_errors\":%llu,"
         "\"connect_retries\":%llu,\"bad_framing\":%llu}\n",
         done / dur, (unsigned long long)done, (unsigned long long)done_all, cpu, (now - t_proc) / 1e9,
         (unsigned long long)bytes_in, nlat ? sum / nlat / 1e3 : 0, pct(0.50), pct(0.90), pct(0.99), pct(0.999),
         nlat ? lat[nlat - 1] / 1e3 : 0,
         pctof(svc, 0.50), pctof(svc, 0.99), pctof(svc, 0.999), pctof(svc, 1.0), pctof(late, 0.99), pctof(late, 0.999), pctof(late, 1.0),
         (unsigned long long)non2xx, (unsigned long long)conn_errors, (unsigned long long)connect_fail,
         (unsigned long long)stuck, (unsigned long long)max_backlog, (unsigned long long)late_errors,
         (unsigned long long)connect_retries, (unsigned long long)bad_framing);
  return 0;
}
