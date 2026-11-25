#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "fjl_async.h"

#include <http_internal.h>

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/time.h>
#include <time.h>
#include <stdlib.h>

struct fjl_async_s {
  struct fjl_async_s *prev, *next;
  http_pause_handle_s *handle;
  intptr_t uuid;
  uint64_t id;
  atomic_int refs;
  int shard;
};

#define FJL_SHARDS 16

typedef struct {
  fio_lock_i lock;
  fjl_async_s head;
} shard_s;

static shard_s shards[FJL_SHARDS];
static atomic_int shards_ready;
static atomic_size_t inflight;
static atomic_int touching;
static size_t touch_ms = 1000;
static void (*resume_cb)(http_s *, uint64_t);
static void (*drop_cb)(uint64_t);

void fjl_async_init(void (*on_resume)(http_s *, uint64_t),
                    void (*on_drop)(uint64_t)) {
  resume_cb = on_resume;
  drop_cb = on_drop;
  if (atomic_load(&shards_ready))
    return;
  for (int i = 0; i < FJL_SHARDS; i++) {
    shards[i].lock = FIO_LOCK_INIT;
    shards[i].head.next = shards[i].head.prev = &shards[i].head;
  }
  atomic_store(&shards_ready, 1);
}

size_t fjl_async_inflight(void) { return atomic_load(&inflight); }
void fjl_async_touch_interval(size_t ms) { touch_ms = ms ? ms : 1000; }

static void link_in(fjl_async_s *a) {
  shard_s *s = shards + a->shard;
  fio_lock(&s->lock);
  a->next = s->head.next;
  a->prev = &s->head;
  s->head.next->prev = a;
  s->head.next = a;
  fio_unlock(&s->lock);
  atomic_fetch_add_explicit(&inflight, 1, memory_order_relaxed);
}

static void unlink_out(fjl_async_s *a) {
  shard_s *s = shards + a->shard;
  fio_lock(&s->lock);
  a->prev->next = a->next;
  a->next->prev = a->prev;
  fio_unlock(&s->lock);
  atomic_fetch_sub_explicit(&inflight, 1, memory_order_relaxed);
}

/* Paused connections are not read, so facil.io would time them out. */
static void touch_all(void *ignr) {
  for (int i = 0; i < FJL_SHARDS; i++) {
    shard_s *s = shards + i;
    fio_lock(&s->lock);
    for (fjl_async_s *a = s->head.next; a != &s->head; a = a->next)
      fio_touch(a->uuid);
    fio_unlock(&s->lock);
  }
  (void)ignr;
}
static void touch_stopped(void *ignr) {
  atomic_store(&touching, 0);
  (void)ignr;
}

static void resumed(http_s *h) {
  fjl_async_s *a = h->udata;
  h->udata = NULL;
  uint64_t id = a->id;
  unlink_out(a);
  free(a);
  resume_cb(h, id);
}

static void dropped(void *udata) {
  fjl_async_s *a = udata;
  uint64_t id = a->id;
  unlink_out(a);
  free(a);
  drop_cb(id);
}

static int release(fjl_async_s *a) {
  if (atomic_fetch_sub(&a->refs, 1) != 1)
    return 0;
  if (fjl_on_reactor()) {
    http_resume(a->handle, resumed, dropped);
    return 0;
  }
  if (fjl_resume(a->handle, resumed, dropped) == 0)
    return 0;
  dropped(a);
  return -1;
}

static void paused(http_pause_handle_s *handle) {
  fjl_async_s *a = http_paused_udata_get(handle);
  a->handle = handle;
  release(a);
}

fjl_async_s *fjl_async_pause(http_s *h, uint64_t id) {
  if (!resume_cb || HTTP_INVALID_HANDLE(h) || !h->private_data.flag)
    return NULL;
  fjl_async_s *a = malloc(sizeof(*a));
  if (!a)
    return NULL;
  a->uuid = ((http_fio_protocol_s *)h->private_data.flag)->uuid;
  a->id = id;
  a->handle = NULL;
  a->shard = (int)(fio_uuid2fd(a->uuid) % FJL_SHARDS);
  atomic_store(&a->refs, 2);
  link_in(a);
  if (!atomic_exchange(&touching, 1))
    fio_run_every(touch_ms, 0, touch_all, NULL, touch_stopped);
  h->udata = a;
  http_pause(h, paused);
  return a;
}

int fjl_async_done(fjl_async_s *a) { return a ? release(a) : -1; }

/* Worker hand-off. avail = idle - queued: offers reserve an idle worker by
 * taking from avail, then publish the job in queued. While the offer rate is
 * high, idle workers spin before sleeping, and an offer seen by a spinner
 * needs no wake-up syscall. */
static pthread_mutex_t work_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t work_cv = PTHREAD_COND_INITIALIZER;
static int work_sleeping; /* guarded by work_mu */
static atomic_int work_idle, work_avail, work_queued, work_spinning;
static atomic_uint_fast64_t offer_last_ns, offer_gap_ns = 1000000;

#define SPIN_NS 50000
#define HOT_GAP_NS 20000

static uint64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static inline void cpu_relax(void) {
#if defined(__aarch64__)
  __asm__ __volatile__("yield");
#elif defined(__x86_64__) || defined(__i386__)
  __asm__ __volatile__("pause");
#endif
}

static int take_if_positive(atomic_int *v) {
  int n = atomic_load_explicit(v, memory_order_relaxed);
  while (n > 0)
    if (atomic_compare_exchange_weak(v, &n, n - 1))
      return 1;
  return 0;
}

int fjl_work_offer(void) {
  uint64_t t = now_ns();
  uint64_t last = atomic_exchange_explicit(&offer_last_ns, t, memory_order_relaxed);
  uint64_t gap = atomic_load_explicit(&offer_gap_ns, memory_order_relaxed);
  uint64_t d = t > last ? t - last : 0;
  atomic_store_explicit(&offer_gap_ns, gap - gap / 8 + d / 8, memory_order_relaxed);
  if (!take_if_positive(&work_avail))
    return 0;
  atomic_fetch_add(&work_queued, 1);
  if (atomic_load(&work_spinning))
    return 1;
  pthread_mutex_lock(&work_mu);
  int wake = work_sleeping > 0;
  pthread_mutex_unlock(&work_mu);
  if (wake)
    pthread_cond_signal(&work_cv);
  return 1;
}

int fjl_work_idle(void) { return atomic_load(&work_avail); }

static int spin_for_job(void) {
  if (atomic_load_explicit(&offer_gap_ns, memory_order_relaxed) > HOT_GAP_NS)
    return 0;
  atomic_fetch_add(&work_spinning, 1);
  uint64_t t0 = now_ns();
  int got = 0;
  for (unsigned i = 1;; i++) {
    if (take_if_positive(&work_queued)) {
      got = 1;
      break;
    }
    cpu_relax();
    if (!(i & 63) && now_ns() - t0 > SPIN_NS)
      break;
  }
  atomic_fetch_sub(&work_spinning, 1);
  if (!got)
    got = take_if_positive(&work_queued);
  /* an offer may have skipped the wake-up because this worker was spinning */
  if (atomic_load(&work_queued) && !atomic_load(&work_spinning)) {
    pthread_mutex_lock(&work_mu);
    int wake = work_sleeping > 0;
    pthread_mutex_unlock(&work_mu);
    if (wake)
      pthread_cond_broadcast(&work_cv);
  }
  return got;
}

int fjl_work_wait(int max_idle, int timeout_ms) {
  if (take_if_positive(&work_queued)) {
    atomic_fetch_add(&work_avail, 1);
    return 1;
  }
  int n = atomic_load(&work_idle);
  do {
    if (n >= max_idle)
      return -1;
  } while (!atomic_compare_exchange_weak(&work_idle, &n, n + 1));
  atomic_fetch_add(&work_avail, 1);

  int got = spin_for_job();
  if (!got) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct timespec until;
    until.tv_sec = tv.tv_sec + timeout_ms / 1000;
    until.tv_nsec = tv.tv_usec * 1000L + (timeout_ms % 1000) * 1000000L;
    if (until.tv_nsec >= 1000000000L) {
      until.tv_sec++;
      until.tv_nsec -= 1000000000L;
    }
    pthread_mutex_lock(&work_mu);
    work_sleeping++;
    int r = 0;
    for (;;) {
      if ((got = take_if_positive(&work_queued)))
        break;
      if (r == ETIMEDOUT && take_if_positive(&work_avail))
        break;
      r = pthread_cond_timedwait(&work_cv, &work_mu, &until);
    }
    work_sleeping--;
    pthread_mutex_unlock(&work_mu);
  }
  atomic_fetch_sub(&work_idle, 1);
  return got;
}
