#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "fjl_async.h"

#include <http_internal.h>

#include <stdatomic.h>
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
