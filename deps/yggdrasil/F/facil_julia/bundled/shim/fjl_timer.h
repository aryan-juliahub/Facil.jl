#ifndef FJL_TIMER_H
#define FJL_TIMER_H

#include <stddef.h>
#include <stdint.h>

/* Exact one-shot timers on a dedicated thread (kqueue EVFILT_TIMER with
 * NOTE_CRITICAL on macOS, timerfd on Linux). Each timer carries an opaque
 * token; when timers fall due, `fire(tokens, n)` runs on the timer thread
 * with a batch of them. Times are nanoseconds on fjl_timer_now's clock. */

/* Starts the thread on the first call; later calls only return 0. -1 on failure. */
int fjl_timer_init(void (*fire)(void *const *tokens, int n));
uint64_t fjl_timer_now(void);
/* 0 ok, -1 when the thread is not running or memory ran out. */
int fjl_timer_at(uint64_t due_ns, void *token);
int fjl_timer_after(uint64_t delay_ns, void *token);
/* 1 when the pending timer with this token was removed, 0 when none was
 * pending (it already fired, or is firing now). */
int fjl_timer_cancel(void *token);
/* Blocks the calling thread for `ns`, with the same precision. */
void fjl_timer_sleep(uint64_t ns);
/* out[0..2] = pending timers, thread wake-ups, timers fired. */
void fjl_timer_stats(uint64_t *out);

#endif
