#ifndef FJL_H
#define FJL_H

#include <fio.h>
#include <http.h>
#include <stddef.h>
#include <stdint.h>

#define FJL_VERSION "0.1.0"
#define FJL_ABI 3

#ifndef FJL_BUILD_ID
#define FJL_BUILD_ID "unknown"
#endif

/* Library identity. Julia refuses to load a library whose ABI differs. */
const char *fjl_version(void);
const char *fjl_build_id(void);
int fjl_abi(void);

/* Completion record for calls that finish on another thread. `done` becomes 1
 * after `result` and `err` are set; `notify(notify_arg)` then runs, if set.
 * Julia passes uv_async_send and an AsyncCondition handle and waits for that
 * notification, never on `done` alone, so the handle outlives the call. */
typedef struct {
  intptr_t result;
  int err;
  _Atomic int done;
  void (*notify)(void *arg);
  void *notify_arg;
} fjl_call_s;
void fjl_call_complete(fjl_call_s *call, intptr_t result, int err);

/* Reactor lifecycle. fjl_start returns once the reactor is accepting work:
 * 0 ok, -1 already running, -2 thread or pipe creation failed. fjl_stop
 * blocks until the reactor threads exit; fjl_stop_async completes `call`
 * instead. Both return 0, or -1 when not running. */
int fjl_start(int threads);
int fjl_stop(void);
int fjl_stop_async(fjl_call_s *call);
int fjl_is_running(void);
int fjl_on_reactor(void);
int fjl_reactor_threads(void);

/* Runs on a reactor thread soon after being posted from any thread. When the
 * reactor stops first, `cancel` (if not NULL) runs instead, on the stopping
 * thread. Returns 0, or -1 when the reactor is not running (nothing runs). */
typedef void (*fjl_task_fn)(void *a, void *b, void *c);
int fjl_post(fjl_task_fn run, fjl_task_fn cancel, void *a, void *b, void *c);
void fjl_wake(void);

/* Hands a paused request back to the reactor, which calls http_resume. */
int fjl_resume(http_pause_handle_s *handle, void (*task)(http_s *),
               void (*fallback)(void *));

/* Server listeners. Fields left zero take facil.io's defaults. */
typedef struct {
  void (*on_request)(http_s *h);
  void (*on_upgrade)(http_s *h, char *protocol, size_t len);
  void (*on_finish)(http_settings_s *settings);
  void *udata;
  const char *public_folder;
  size_t max_header_size;
  size_t max_body_size;
  intptr_t max_clients;
  void *tls;
  size_t ws_max_msg_size;
  uint8_t timeout;
  uint8_t ws_timeout;
  uint8_t log;
  uint8_t public_folder_flags; /* HTTP_PUBLIC_* */
  /* cache-control for public_folder files; NULL keeps facil.io's default */
  const char *cache_control;
} fjl_listen_s;

/* Opens a listener on the reactor; call->result is its uuid, or -1 with
 * call->err set. Arguments must stay valid until the call is done. Returns -1
 * if the request could not be queued. fjl_listen is the blocking form, for
 * threads that never run Julia code. */
int fjl_listen_async(const char *address, const char *port,
                     const fjl_listen_s *opts, fjl_call_s *call);
intptr_t fjl_listen(const char *address, const char *port,
                    const fjl_listen_s *opts);
/* Closes a listener; its on_finish runs on the reactor. 0 ok, -1 failed. */
int fjl_listen_close(intptr_t listener);
void *fjl_settings_udata(http_settings_s *settings);
void *fjl_server_udata(http_s *h);
size_t fjl_sizeof_listen_s(void);

/* Diagnostics: out[0..5] = wakes written, drains, tasks run, tasks cancelled,
 * pool threads created, starts. */
void fjl_stats(uint64_t *out);
/* facil.io's log level (FIO_LOG_LEVEL_*); returns the previous one. */
int fjl_log_level(int level);
/* 0 SIG_DFL, 1 SIG_IGN, 2 handler installed. */
int fjl_sig_disposition(int sig);
size_t fjl_thread_stack_size(void);

#endif
