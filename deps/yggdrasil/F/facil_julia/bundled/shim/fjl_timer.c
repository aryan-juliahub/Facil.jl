#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "fjl_timer.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/event.h>
#elif defined(__linux__)
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/prctl.h>
#include <sys/timerfd.h>
#else
#error "fjl_timer: unsupported platform"
#endif

#define FJL_TIMER_BATCH 512
#define FJL_TIMER_STACK (1u << 20)

typedef struct {
  uint64_t due;
  void *token;
} item_s;

static item_s *heap;
static size_t len, cap;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t armed = UINT64_MAX; /* due time the thread is waiting for */
static void (*fire_cb)(void *const *, int);
static atomic_int started;
static atomic_ulong n_wakeups, n_fired;

uint64_t fjl_timer_now(void) {
#if defined(__APPLE__)
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
#endif
}

/* ---- binary min-heap on `due`; callers hold `mu` ---- */

static int heap_push(item_s it) {
  if (len == cap) {
    size_t ncap = cap ? cap * 2 : 1024;
    item_s *n = realloc(heap, ncap * sizeof(*n));
    if (!n)
      return -1;
    heap = n;
    cap = ncap;
  }
  size_t i = len++;
  while (i && heap[(i - 1) / 2].due > it.due) {
    heap[i] = heap[(i - 1) / 2];
    i = (i - 1) / 2;
  }
  heap[i] = it;
  return 0;
}

static void sift_down(size_t i) {
  item_s it = heap[i];
  for (;;) {
    size_t c = 2 * i + 1;
    if (c >= len)
      break;
    if (c + 1 < len && heap[c + 1].due < heap[c].due)
      c++;
    if (heap[c].due >= it.due)
      break;
    heap[i] = heap[c];
    i = c;
  }
  heap[i] = it;
}

static void sift_up(size_t i) {
  item_s it = heap[i];
  while (i && heap[(i - 1) / 2].due > it.due) {
    heap[i] = heap[(i - 1) / 2];
    i = (i - 1) / 2;
  }
  heap[i] = it;
}

static item_s heap_pop(void) {
  item_s top = heap[0];
  heap[0] = heap[--len];
  if (len)
    sift_down(0);
  return top;
}

static void heap_remove(size_t i) {
  heap[i] = heap[--len];
  if (i < len) {
    sift_down(i);
    sift_up(i);
  }
}

/* ---- platform wait: sleep until `due` (UINT64_MAX: forever) or a kick ---- */

#if defined(__APPLE__)
static int kq = -1;

static int wait_init(void) {
  kq = kqueue();
  if (kq < 0)
    return -1;
  struct kevent ch;
  EV_SET(&ch, 0, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
  return kevent(kq, &ch, 1, NULL, 0, NULL) < 0 ? -1 : 0;
}

static void wait_until(uint64_t due, uint64_t now) {
  struct kevent ch, ev;
  if (due == UINT64_MAX) {
    kevent(kq, NULL, 0, &ev, 1, NULL);
    return;
  }
  EV_SET(&ch, 1, EVFILT_TIMER, EV_ADD | EV_ONESHOT, NOTE_NSECONDS | NOTE_CRITICAL,
         (int64_t)(due - now), NULL);
  kevent(kq, &ch, 1, &ev, 1, NULL);
}

static void kick(void) {
  struct kevent ch;
  EV_SET(&ch, 0, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
  kevent(kq, &ch, 1, NULL, 0, NULL);
}

static void thread_setup(void) {}

#else /* __linux__ */
static int tfd = -1, efd = -1;

static int wait_init(void) {
  tfd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
  efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  return tfd < 0 || efd < 0 ? -1 : 0;
}

static void wait_until(uint64_t due, uint64_t now) {
  struct itimerspec its = {{0, 0}, {0, 0}};
  if (due != UINT64_MAX) {
    its.it_value.tv_sec = (time_t)(due / 1000000000u);
    its.it_value.tv_nsec = (long)(due % 1000000000u);
    if (!its.it_value.tv_sec && !its.it_value.tv_nsec)
      its.it_value.tv_nsec = 1;
  }
  timerfd_settime(tfd, TFD_TIMER_ABSTIME, &its, NULL);
  struct pollfd p[2] = {{.fd = tfd, .events = POLLIN}, {.fd = efd, .events = POLLIN}};
  while (poll(p, 2, -1) < 0 && errno == EINTR)
    ;
  uint64_t junk;
  (void)!read(tfd, &junk, sizeof(junk));
  (void)!read(efd, &junk, sizeof(junk));
  (void)now;
}

static void kick(void) {
  uint64_t one = 1;
  (void)!write(efd, &one, sizeof(one));
}

/* The default 50 us timer slack would be most of the error budget. */
static void thread_setup(void) { prctl(PR_SET_TIMERSLACK, 1UL, 0, 0, 0); }
#endif

/* ---- the timer thread ---- */

static void *timer_main(void *arg) {
  void *batch[FJL_TIMER_BATCH];
  (void)arg;
  thread_setup();
  for (;;) {
    int n = 0;
    pthread_mutex_lock(&mu);
    uint64_t now = fjl_timer_now();
    while (len && heap[0].due <= now && n < FJL_TIMER_BATCH)
      batch[n++] = heap_pop().token;
    uint64_t next = len ? heap[0].due : UINT64_MAX;
    armed = n ? 0 : next;
    pthread_mutex_unlock(&mu);
    if (n) {
      atomic_fetch_add_explicit(&n_fired, (unsigned long)n, memory_order_relaxed);
      fire_cb(batch, n);
      continue;
    }
    atomic_fetch_add_explicit(&n_wakeups, 1, memory_order_relaxed);
    wait_until(next, now);
  }
  return NULL;
}

int fjl_timer_init(void (*fire)(void *const *, int)) {
  static pthread_mutex_t init_mu = PTHREAD_MUTEX_INITIALIZER;
  if (atomic_load(&started))
    return 0;
  pthread_mutex_lock(&init_mu);
  int r = 0;
  if (!atomic_load(&started)) {
    fire_cb = fire;
    r = wait_init();
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, FJL_TIMER_STACK);
    if (!r)
      r = pthread_create(&t, &attr, timer_main, NULL) ? -1 : 0;
    pthread_attr_destroy(&attr);
    if (!r) {
      pthread_detach(t);
      atomic_store(&started, 1);
    }
  }
  pthread_mutex_unlock(&init_mu);
  return r;
}

int fjl_timer_at(uint64_t due, void *token) {
  if (!atomic_load(&started))
    return -1;
  pthread_mutex_lock(&mu);
  int r = heap_push((item_s){due, token});
  int earlier = !r && due < armed;
  if (earlier)
    armed = due;
  pthread_mutex_unlock(&mu);
  if (earlier)
    kick();
  return r;
}

int fjl_timer_after(uint64_t delay, void *token) {
  return fjl_timer_at(fjl_timer_now() + delay, token);
}

int fjl_timer_cancel(void *token) {
  int found = 0;
  pthread_mutex_lock(&mu);
  for (size_t i = 0; i < len; i++) {
    if (heap[i].token == token) {
      heap_remove(i);
      found = 1;
      break;
    }
  }
  pthread_mutex_unlock(&mu);
  return found;
}

void fjl_timer_sleep(uint64_t ns) {
#if defined(__APPLE__)
  static _Thread_local int tkq = -1;
  if (tkq < 0)
    tkq = kqueue();
  if (tkq >= 0) {
    struct kevent ch, ev;
    EV_SET(&ch, 1, EVFILT_TIMER, EV_ADD | EV_ONESHOT,
           NOTE_NSECONDS | NOTE_CRITICAL, (int64_t)ns, NULL);
    if (kevent(tkq, &ch, 1, &ev, 1, NULL) >= 0)
      return;
  }
  struct timespec t = {(time_t)(ns / 1000000000u), (long)(ns % 1000000000u)};
  while (nanosleep(&t, &t) < 0 && errno == EINTR)
    ;
#else
  uint64_t due = fjl_timer_now() + ns;
  struct timespec t = {(time_t)(due / 1000000000u), (long)(due % 1000000000u)};
  while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &t, NULL) == EINTR)
    ;
#endif
}

void fjl_timer_stats(uint64_t *out) {
  pthread_mutex_lock(&mu);
  out[0] = len;
  pthread_mutex_unlock(&mu);
  out[1] = atomic_load(&n_wakeups);
  out[2] = atomic_load(&n_fired);
}
