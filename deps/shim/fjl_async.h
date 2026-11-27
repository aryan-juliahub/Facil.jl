#ifndef FJL_ASYNC_H
#define FJL_ASYNC_H

#include "fjl.h"

/* A request whose handler runs on a Julia task. The connection is paused
 * until both the pause has taken effect and fjl_async_done was called; the
 * reactor then resumes it and calls on_resume(h, id) with a live `h`. If the
 * connection closed meanwhile, on_drop(id) runs instead. Exactly one of the
 * two runs per paused request. */
typedef struct fjl_async_s fjl_async_s;

void fjl_async_init(void (*on_resume)(http_s *h, uint64_t id),
                    void (*on_drop)(uint64_t id),
                    void (*on_gone)(uint64_t id));
/* Call on the reactor thread, inside on_request. NULL if `h` cannot pause. */
fjl_async_s *fjl_async_pause(http_s *h, uint64_t id);
/* Any thread. Returns 0, or -1 when the reactor stopped (on_drop already ran). */
int fjl_async_done(fjl_async_s *a);
/* Client watch of a paused request. Once watched, a reactor timer checks the
 * connection every FJL_WATCH_MS. A reset or a closed connection counts as
 * gone. A FIN alone may be a half-close from a client still waiting for the
 * reply: with `probe` set (an HTTP/1.1 request), one `100 Continue` interim
 * response is sent, which a client that closed answers with a reset; without
 * it a FIN is not counted. `notify` makes on_gone(id) run once, on the
 * reactor, when the client is found gone. Call from any thread before
 * fjl_async_done. Returns FJL_CLIENT_*. */
#define FJL_WATCH_MS 200
enum { FJL_CLIENT_OPEN = 0, FJL_CLIENT_GONE = 2 };
int fjl_async_watch(fjl_async_s *a, int notify, int probe);
/* FJL_CLIENT_* of a request; any thread, before fjl_async_done. */
int fjl_async_client(fjl_async_s *a);

/* Paused requests not yet resumed or dropped. */
size_t fjl_async_inflight(void);
/* Milliseconds between touches of paused connections, so the idle timeout
 * never closes them (default 1000). */
void fjl_async_touch_interval(size_t ms);

/* Idle Julia worker tasks wait here, blocked in C rather than in the Julia
 * scheduler. fjl_work_offer hands one job to an idle worker (1), or returns 0
 * when every worker is busy. fjl_work_wait returns 1 for a job, 0 on timeout,
 * -1 when `max_idle` workers already wait (the caller should stop). */
int fjl_work_offer(void);
int fjl_work_wait(int max_idle, int timeout_ms);
/* Idle workers not yet handed a job. */
int fjl_work_idle(void);

#endif
