#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "fjl.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define FJL_STACK (8u << 20)

extern volatile fio_lock_i fio_signal_set_flag;

const char *fjl_version(void) { return FJL_VERSION; }
const char *fjl_build_id(void) { return FJL_BUILD_ID; }
int fjl_abi(void) { return FJL_ABI; }

static _Thread_local int on_reactor;
static atomic_ulong n_wakes, n_drains, n_ran, n_cancelled, n_pool, n_starts;

int fjl_on_reactor(void) { return on_reactor; }

/* ---- threads: every facil.io thread gets an 8 MB stack and is marked ---- */

typedef struct {
  void *(*fn)(void *);
  void *arg;
} fjl_boot_s;

static void *fjl_boot(void *p) {
  fjl_boot_s b = *(fjl_boot_s *)p;
  free(p);
  on_reactor = 1;
  return b.fn(b.arg);
}

static int fjl_spawn(pthread_t *t, void *(*fn)(void *), void *arg) {
  fjl_boot_s *b = malloc(sizeof(*b));
  if (!b)
    return -1;
  b->fn = fn;
  b->arg = arg;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, FJL_STACK);
  int r = pthread_create(t, &attr, fjl_boot, b);
  pthread_attr_destroy(&attr);
  if (r)
    free(b);
  return r;
}

void *fio_thread_new(void *(*thread_func)(void *), void *arg) {
  pthread_t *thread = malloc(sizeof(*thread));
  if (!thread)
    return NULL;
  if (fjl_spawn(thread, thread_func, arg)) {
    free(thread);
    return NULL;
  }
  atomic_fetch_add(&n_pool, 1);
  return thread;
}

void fio_thread_free(void *p_thr) {
  if (*((pthread_t *)p_thr))
    pthread_detach(*((pthread_t *)p_thr));
  free(p_thr);
}

int fio_thread_join(void *p_thr) {
  if (!p_thr || !(*((pthread_t *)p_thr)))
    return -1;
  pthread_join(*((pthread_t *)p_thr), NULL);
  free(p_thr);
  return 0;
}

size_t fjl_thread_stack_size(void) {
#if defined(__APPLE__)
  return pthread_get_stacksize_np(pthread_self());
#else
  pthread_attr_t a;
  size_t s = 0;
  if (pthread_getattr_np(pthread_self(), &a) == 0) {
    pthread_attr_getstacksize(&a, &s);
    pthread_attr_destroy(&a);
  }
  return s;
#endif
}

/* ---- cross-thread task queue, drained by the reactor on each wake ---- */

typedef struct fjl_node {
  struct fjl_node *next;
  fjl_task_fn run, cancel;
  void *a, *b, *c;
} fjl_node;

static _Atomic(fjl_node *) q_head;
static atomic_int accepting;
static atomic_int posters;

static fjl_node *q_take(void) {
  fjl_node *n = atomic_exchange(&q_head, NULL), *prev = NULL;
  while (n) {
    fjl_node *next = n->next;
    n->next = prev;
    prev = n;
    n = next;
  }
  return prev;
}

static void q_run(int cancel) {
  fjl_node *n = q_take();
  while (n) {
    fjl_node *next = n->next;
    if (!cancel) {
      n->run(n->a, n->b, n->c);
      atomic_fetch_add_explicit(&n_ran, 1, memory_order_relaxed);
    } else {
      if (n->cancel)
        n->cancel(n->a, n->b, n->c);
      atomic_fetch_add_explicit(&n_cancelled, 1, memory_order_relaxed);
    }
    free(n);
    n = next;
  }
}

/* ---- wake pipe ---- */

static int wake_fd[2] = {-1, -1};
static atomic_int wake_pending;

/* The pending flag is cleared only after the pipe is drained, and the queue is
 * taken only after that: a poster that skipped its write pushed its task before
 * the flag cleared, so this drain sees it. */
static void wake_on_data(intptr_t uuid, fio_protocol_s *pr) {
  char buf[256];
  while (read(wake_fd[0], buf, sizeof(buf)) > 0)
    ;
  atomic_store(&wake_pending, 0);
  atomic_fetch_add_explicit(&n_drains, 1, memory_order_relaxed);
  q_run(0);
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

void fjl_wake(void) {
  if (wake_fd[1] < 0)
    return;
  if (atomic_exchange(&wake_pending, 1) == 0) {
    char c = 1;
    (void)!write(wake_fd[1], &c, 1);
    atomic_fetch_add_explicit(&n_wakes, 1, memory_order_relaxed);
  }
}

int fjl_post(fjl_task_fn run, fjl_task_fn cancel, void *a, void *b, void *c) {
  atomic_fetch_add(&posters, 1);
  if (!atomic_load(&accepting)) {
    atomic_fetch_sub(&posters, 1);
    return -1;
  }
  fjl_node *n = malloc(sizeof(*n));
  if (!n) {
    atomic_fetch_sub(&posters, 1);
    return -1;
  }
  *n = (fjl_node){.run = run, .cancel = cancel, .a = a, .b = b, .c = c};
  n->next = atomic_load(&q_head);
  while (!atomic_compare_exchange_weak(&q_head, &n->next, n))
    ;
  fjl_wake();
  atomic_fetch_sub(&posters, 1);
  return 0;
}

/* ---- resume queue ---- */

static void resume_run(void *h, void *task, void *fallback) {
  http_resume((http_pause_handle_s *)h, (void (*)(http_s *))task,
              (void (*)(void *))fallback);
}
static void resume_cancel(void *h, void *task, void *fallback) {
  if (fallback)
    ((void (*)(void *))fallback)(http_paused_udata_get(h));
  (void)task;
}

int fjl_resume(http_pause_handle_s *handle, void (*task)(http_s *),
               void (*fallback)(void *)) {
  return fjl_post(resume_run, resume_cancel, handle, (void *)task,
                  (void *)fallback);
}

/* ---- reactor lifecycle ---- */

static pthread_mutex_t life_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t ready_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready_cv = PTHREAD_COND_INITIALIZER;
static pthread_t reactor;
static atomic_int running, stopping;
static int ready, nthreads, wake_attach_fd = -1;

static void on_start(void *ignr) {
  fio_attach_fd(wake_attach_fd, &wake_protocol);
  pthread_mutex_lock(&ready_mu);
  ready = 1;
  pthread_cond_broadcast(&ready_cv);
  pthread_mutex_unlock(&ready_mu);
  (void)ignr;
}

static void *reactor_main(void *arg) {
  fio_start(.threads = (int16_t)(intptr_t)arg, .workers = 1);
  pthread_mutex_lock(&ready_mu);
  ready = 2;
  pthread_cond_broadcast(&ready_cv);
  pthread_mutex_unlock(&ready_mu);
  return NULL;
}

/* The pipe lives for the whole process so fjl_wake never writes to a stale
 * descriptor; each start attaches a duplicate of the read end, which facil.io
 * closes when it stops. */
static int open_pipe(void) {
  if (wake_fd[0] < 0) {
    int fds[2];
    if (pipe(fds))
      return -1;
    fio_set_non_block(fds[0]);
    fio_set_non_block(fds[1]);
    wake_fd[0] = fds[0];
    wake_fd[1] = fds[1];
  }
  wake_attach_fd = dup(wake_fd[0]);
  return wake_attach_fd < 0 ? -1 : 0;
}

int fjl_start(int threads) {
  pthread_mutex_lock(&life_mu);
  if (atomic_load(&running)) {
    pthread_mutex_unlock(&life_mu);
    return -1;
  }
  fio_signal_set_flag = 1;
  signal(SIGPIPE, SIG_IGN);
  if (threads < 1)
    threads = 1;
  if (open_pipe()) {
    pthread_mutex_unlock(&life_mu);
    return -2;
  }
  atomic_store(&wake_pending, 0);
  pthread_mutex_lock(&ready_mu);
  ready = 0;
  pthread_mutex_unlock(&ready_mu);
  fio_state_callback_add(FIO_CALL_ON_START, on_start, NULL);
  if (fjl_spawn(&reactor, reactor_main, (void *)(intptr_t)threads)) {
    fio_state_callback_remove(FIO_CALL_ON_START, on_start, NULL);
    close(wake_attach_fd);
    pthread_mutex_unlock(&life_mu);
    return -2;
  }
  pthread_mutex_lock(&ready_mu);
  while (!ready)
    pthread_cond_wait(&ready_cv, &ready_mu);
  int failed = ready == 2;
  pthread_mutex_unlock(&ready_mu);
  if (failed) {
    pthread_join(reactor, NULL);
    pthread_mutex_unlock(&life_mu);
    return -2;
  }
  running = 1;
  nthreads = threads;
  atomic_store(&accepting, 1);
  atomic_fetch_add(&n_starts, 1);
  pthread_mutex_unlock(&life_mu);
  return 0;
}

void fjl_call_complete(fjl_call_s *call, intptr_t result, int err) {
  call->result = result;
  call->err = err;
  void (*notify)(void *) = call->notify;
  void *arg = call->notify_arg;
  atomic_store(&call->done, 1);
  if (notify)
    notify(arg);
}

static int stop_begin(void) {
  if (!atomic_load(&running) || atomic_load(&stopping))
    return -1;
  atomic_store(&stopping, 1);
  atomic_store(&accepting, 0);
  while (atomic_load(&posters))
    sched_yield();
  fio_stop();
  atomic_store(&wake_pending, 0);
  fjl_wake();
  return 0;
}

static void stop_finish(void) {
  pthread_join(reactor, NULL);
  nthreads = 0;
  q_run(1);
  atomic_store(&running, 0);
  atomic_store(&stopping, 0);
}

int fjl_stop(void) {
  pthread_mutex_lock(&life_mu);
  int r = stop_begin();
  pthread_mutex_unlock(&life_mu);
  if (r == 0)
    stop_finish();
  return r;
}

static void *stopper_main(void *call) {
  stop_finish();
  fjl_call_complete(call, 0, 0);
  return NULL;
}

int fjl_stop_async(fjl_call_s *call) {
  pthread_mutex_lock(&life_mu);
  int r = stop_begin();
  pthread_mutex_unlock(&life_mu);
  if (r)
    return r;
  pthread_t t;
  if (fjl_spawn(&t, stopper_main, call)) {
    stop_finish();
    fjl_call_complete(call, 0, 0);
    return 0;
  }
  pthread_detach(t);
  return 0;
}

int fjl_is_running(void) {
  return atomic_load(&running) && !atomic_load(&stopping) && fio_is_running();
}
int fjl_reactor_threads(void) { return nthreads; }

/* ---- listeners ---- */

static intptr_t listen_now(const char *address, const char *port,
                           const fjl_listen_s *o) {
  if (!o || !o->on_request) {
    errno = EINVAL;
    return -1;
  }
  http_settings_s s = {
      .on_request = o->on_request,
      .on_upgrade = o->on_upgrade,
      .on_finish = o->on_finish,
      .udata = o->udata,
      .public_folder = o->public_folder,
      .public_folder_length = o->public_folder ? strlen(o->public_folder) : 0,
      .max_header_size = o->max_header_size,
      .max_body_size = o->max_body_size,
      .max_clients = o->max_clients,
      .tls = o->tls,
      .ws_max_msg_size = o->ws_max_msg_size,
      .timeout = o->timeout,
      .ws_timeout = o->ws_timeout,
      .log = o->log,
  };
  return (http_listen)(port, address, s);
}

typedef struct {
  const char *address, *port;
  const fjl_listen_s *o;
} listen_args;

static void listen_task(void *args, void *call, void *ignr) {
  listen_args *a = args;
  errno = 0;
  intptr_t r = listen_now(a->address, a->port, a->o);
  int err = r < 0 ? errno : 0;
  free(a);
  fjl_call_complete(call, r, err);
  (void)ignr;
}
static void listen_cancel(void *args, void *call, void *ignr) {
  free(args);
  fjl_call_complete(call, -1, ECANCELED);
  (void)ignr;
}

int fjl_listen_async(const char *address, const char *port,
                     const fjl_listen_s *opts, fjl_call_s *call) {
  atomic_store(&call->done, 0);
  if (on_reactor || !fio_is_running()) {
    errno = 0;
    intptr_t r = listen_now(address, port, opts);
    fjl_call_complete(call, r, r < 0 ? errno : 0);
    return 0;
  }
  listen_args *a = malloc(sizeof(*a));
  if (!a)
    return -1;
  *a = (listen_args){.address = address, .port = port, .o = opts};
  if (fjl_post(listen_task, listen_cancel, a, call, NULL)) {
    free(a);
    return -1;
  }
  return 0;
}

typedef struct {
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int signalled;
} waiter;

static void waiter_notify(void *p) {
  waiter *w = p;
  pthread_mutex_lock(&w->mu);
  w->signalled = 1;
  pthread_cond_broadcast(&w->cv);
  pthread_mutex_unlock(&w->mu);
}

intptr_t fjl_listen(const char *address, const char *port,
                    const fjl_listen_s *opts) {
  waiter w = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0};
  fjl_call_s call = {.notify = waiter_notify, .notify_arg = &w};
  if (fjl_listen_async(address, port, opts, &call)) {
    errno = ECANCELED;
    return -1;
  }
  pthread_mutex_lock(&w.mu);
  while (!w.signalled)
    pthread_cond_wait(&w.cv, &w.mu);
  pthread_mutex_unlock(&w.mu);
  if (call.result < 0)
    errno = call.err;
  return call.result;
}

static void close_task(void *uuid, void *b, void *c) {
  fio_close((intptr_t)uuid);
  (void)b;
  (void)c;
}

int fjl_listen_close(intptr_t listener) {
  if (listener < 0)
    return -1;
  if (on_reactor) {
    fio_close(listener);
    return 0;
  }
  return fjl_post(close_task, NULL, (void *)listener, NULL, NULL);
}

void *fjl_settings_udata(http_settings_s *settings) {
  return settings ? settings->udata : NULL;
}
void *fjl_server_udata(http_s *h) {
  http_settings_s *s = http_settings(h);
  return s ? s->udata : NULL;
}
size_t fjl_sizeof_listen_s(void) { return sizeof(fjl_listen_s); }

/* ---- diagnostics ---- */

void fjl_stats(uint64_t *out) {
  out[0] = atomic_load(&n_wakes);
  out[1] = atomic_load(&n_drains);
  out[2] = atomic_load(&n_ran);
  out[3] = atomic_load(&n_cancelled);
  out[4] = atomic_load(&n_pool);
  out[5] = atomic_load(&n_starts);
}

int fjl_log_level(int level) {
  int old = FIO_LOG_LEVEL;
  FIO_LOG_LEVEL = level;
  return old;
}

int fjl_sig_disposition(int sig) {
  struct sigaction sa;
  if (sigaction(sig, NULL, &sa))
    return -1;
  if (sa.sa_handler == SIG_DFL)
    return 0;
  if (sa.sa_handler == SIG_IGN)
    return 1;
  return 2;
}
