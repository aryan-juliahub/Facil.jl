/* Descriptor reuse under churn (patch 14; patches 03/04 on kqueue).
 * One process runs a raw facil.io echo server on several reactor threads and
 * client threads against it. Churn clients open and drop connections as fast
 * as they can (reset, server close, half close), so closed descriptor numbers
 * are handed straight to new connections while poll events for the old ones
 * may still be in flight. Keeper clients hold connections that must stay up
 * until they say goodbye; any keeper the server closes early, or that stops
 * answering, is a failure, and so is a refused connect (the listener closed).
 * Mode `fin` churns with orderly closes only (no resets), which keeps every
 * close on the server's EOF and `fio_close` paths.
 * usage: fdreuse <port> <reactor threads> <seconds> [mixed|fin]; last line
 * PASS or FAIL. */
#include <fio.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define KEEPERS 16
#define CHURNERS 8
#define CHURN_CAP 16000
#define ROUND_TRIPS 20

typedef struct {
  fio_protocol_s pr;
  int keeper, quitting;
} conn_s;

static int port, fin_only;
static volatile int stop_clients;
static size_t srv_opened, srv_closed, early_close;
static size_t keepers_done, keeper_fail, churn_done, churn_count, connect_err,
    refused;

static double now_s(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

static void on_data(intptr_t uuid, fio_protocol_s *pr) {
  conn_s *c = (conn_s *)pr;
  char buf[256];
  ssize_t n;
  while ((n = fio_read(uuid, buf, sizeof(buf))) > 0) {
    for (ssize_t i = 0; i < n; ++i) {
      switch (buf[i]) {
      case 'K':
        c->keeper = 1;
        fio_write(uuid, "k", 1);
        break;
      case 'Q':
        c->quitting = 1;
        fio_write(uuid, "q", 1);
        break;
      case 'X':
        fio_close(uuid);
        return;
      default:
        fio_write(uuid, buf + i, 1);
      }
    }
  }
}

static void on_close(intptr_t uuid, fio_protocol_s *pr) {
  conn_s *c = (conn_s *)pr;
  if (c->keeper && !c->quitting) {
    fio_atomic_add(&early_close, 1);
    fprintf(stderr, "keeper %p closed by the server before it quit\n",
            (void *)uuid);
  }
  fio_atomic_add(&srv_closed, 1);
  free(c);
}

static uint8_t on_shutdown(intptr_t uuid, fio_protocol_s *pr) {
  (void)uuid;
  ((conn_s *)pr)->quitting = 1;
  return 0;
}

static void on_open(intptr_t uuid, void *udata) {
  (void)udata;
  conn_s *c = calloc(1, sizeof(*c));
  c->pr = (fio_protocol_s){.on_data = on_data,
                           .on_close = on_close,
                           .on_shutdown = on_shutdown};
  fio_atomic_add(&srv_opened, 1);
  fio_attach(uuid, &c->pr);
  fio_timeout_set(uuid, 60);
}

static int dial(void) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0)
    return -1;
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  struct timeval tv = {.tv_sec = 5};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  /* source ports taken in turn from a wide range, so back-to-back runs do not
   * run out of ephemeral ports held in TIME_WAIT */
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  static size_t next_port;
  if (!next_port)
    next_port = (size_t)getpid() * 7919;
  for (int tries = 0; tries < 64; ++tries) {
    struct sockaddr_in b = {.sin_family = AF_INET};
    b.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    b.sin_port = htons(10000 + (fio_atomic_add(&next_port, 1) % 38000));
    if (!bind(fd, (struct sockaddr *)&b, sizeof(b)))
      break;
  }
  if (connect(fd, (struct sockaddr *)&a, sizeof(a))) {
    if (errno == ECONNREFUSED)
      fio_atomic_add(&refused, 1);
    close(fd);
    return -1;
  }
  return fd;
}

static void reset_close(int fd) {
  struct linger l = {.l_onoff = 1, .l_linger = 0};
  setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, sizeof(l));
  close(fd);
}

/* sends one byte and expects `want` back; 0 on success */
static int ask(int fd, char out, char want) {
  char in;
  if (send(fd, &out, 1, 0) != 1)
    return -1;
  return (recv(fd, &in, 1, 0) == 1 && in == want) ? 0 : -1;
}

static void *keeper(void *arg) {
  (void)arg;
  while (!stop_clients) {
    int fd = dial();
    if (fd < 0) {
      fio_atomic_add(&connect_err, 1);
      usleep(1000);
      continue;
    }
    int ok = !ask(fd, 'K', 'k');
    for (int i = 0; ok && i < ROUND_TRIPS; ++i) {
      ok = !ask(fd, 'p', 'p');
      if (i == ROUND_TRIPS / 2)
        usleep(200);
    }
    ok = ok && !ask(fd, 'Q', 'q');
    if (!ok) {
      fio_atomic_add(&keeper_fail, 1);
      fprintf(stderr, "keeper connection lost (%s)\n", strerror(errno));
    } else {
      fio_atomic_add(&keepers_done, 1);
    }
    reset_close(fd);
  }
  return NULL;
}

static void *churner(void *arg) {
  (void)arg;
  char in;
  while (!stop_clients) {
    size_t k = fio_atomic_add(&churn_count, 1);
    if (k > CHURN_CAP)
      break;
    int fd = dial();
    if (fd < 0) {
      fio_atomic_add(&connect_err, 1);
      continue;
    }
    switch (fin_only ? 2 + (k & 1) : (k & 3)) {
    case 0: /* reset before sending anything */
      break;
    case 1: /* data, then reset while the server may be reading */
      send(fd, "cc", 2, 0);
      break;
    case 2: /* the server closes */
      send(fd, "X", 1, 0);
      while (recv(fd, &in, 1, 0) > 0)
        ;
      break;
    case 3: /* echo, then an orderly close */
      send(fd, "c", 1, 0);
      recv(fd, &in, 1, 0);
      shutdown(fd, SHUT_WR);
      close(fd);
      fio_atomic_add(&churn_done, 1);
      continue;
    }
    reset_close(fd);
    fio_atomic_add(&churn_done, 1);
  }
  return NULL;
}

static double seconds;

static void *controller(void *arg) {
  (void)arg;
  pthread_t k[KEEPERS], c[CHURNERS];
  for (int i = 0; i < 300 && !fio_is_running(); ++i)
    usleep(10000);
  usleep(100000);
  for (int i = 0; i < KEEPERS; ++i)
    pthread_create(k + i, NULL, keeper, NULL);
  for (int i = 0; i < CHURNERS; ++i)
    pthread_create(c + i, NULL, churner, NULL);
  double end = now_s() + seconds;
  while (now_s() < end && churn_count <= CHURN_CAP)
    usleep(10000);
  stop_clients = 1;
  for (int i = 0; i < KEEPERS; ++i)
    pthread_join(k[i], NULL);
  for (int i = 0; i < CHURNERS; ++i)
    pthread_join(c[i], NULL);
  usleep(200000);
  fio_stop();
  return NULL;
}

int main(int argc, char **argv) {
  if (argc != 4 && argc != 5) {
    fprintf(stderr, "usage: %s <port> <threads> <seconds> [mixed|fin]\n",
            argv[0]);
    return 2;
  }
  fin_only = argc == 5 && !strcmp(argv[4], "fin");
  port = atoi(argv[1]);
  int threads = atoi(argv[2]);
  seconds = atof(argv[3]);
  if (fio_listen(.port = argv[1], .address = "127.0.0.1",
                 .on_open = on_open) == -1) {
    perror("listen");
    return 1;
  }
  alarm((unsigned)seconds + 60); /* a wedged reactor fails instead of hanging */
  pthread_t ctl;
  pthread_create(&ctl, NULL, controller, NULL);
  fio_start(.threads = threads, .workers = 1);
  pthread_join(ctl, NULL);
  int ok = !early_close && !keeper_fail && !refused && keepers_done > 0 &&
           churn_done > 0;
  printf("engine %s threads %d%s: %zu keepers, %zu churn connections, %zu "
         "opened, %zu closed, %zu connect errors (%zu refused), %zu early "
         "closes, %zu lost keepers\n%s\n",
         fio_engine(), threads, fin_only ? " (orderly closes)" : "",
         keepers_done, churn_done, srv_opened, srv_closed, connect_err, refused,
         early_close, keeper_fail, ok ? "PASS" : "FAIL");
  return !ok;
}
