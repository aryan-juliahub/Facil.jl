/* Timer accuracy and idle cost of facil.io's reactor timers (fio_run_every).
 * Prints the median and p90 delay of 1 ms and 10 ms one-shot timers (the last
 * series arms each timer 5 ms into a busy task), then the CPU used over 3 s
 * while only a 500 ms repeating timer is pending. */
#include <fio.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>

#define RUNS 60
static double samples[RUNS];
static int run, interval_ms, busy_ms;

static double now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}
static double cpu_s(void) {
  struct rusage u;
  getrusage(RUSAGE_SELF, &u);
  return u.ru_utime.tv_sec + u.ru_stime.tv_sec +
         (u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6;
}
static int cmp(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}
static double t0;
static void fired(void *arg);
static void arm(void) {
  if (busy_ms) {
    double until = now_ms() + busy_ms;
    while (now_ms() < until)
      ;
  }
  t0 = now_ms();
  fio_run_every(interval_ms, 1, fired, NULL, NULL);
}
static void fired(void *arg) {
  (void)arg;
  samples[run++] = now_ms() - t0;
  if (run < RUNS)
    arm();
  else
    fio_stop();
}
static void start_series(void *arg) { (void)arg; arm(); }
static void noop(void *arg) { (void)arg; }
static void stop_task(void *arg) { (void)arg; fio_stop(); }

int main(void) {
  int ms[] = {1, 10, 10}, busy[] = {0, 0, 5};
  for (int k = 0; k < 3; ++k) {
    run = 0;
    interval_ms = ms[k];
    busy_ms = busy[k];
    fio_state_callback_add(FIO_CALL_ON_START, start_series, NULL);
    fio_start(.threads = 1, .workers = 1);
    fio_state_callback_remove(FIO_CALL_ON_START, start_series, NULL);
    qsort(samples, RUNS, sizeof(double), cmp);
    printf("timer %d ms busy %d: median %.3f p90 %.3f\n", ms[k], busy[k],
           samples[RUNS / 2], samples[RUNS * 9 / 10]);
  }
  fio_run_every(500, 0, noop, NULL, NULL);
  fio_run_every(3000, 1, stop_task, NULL, NULL);
  double c0 = cpu_s(), w0 = now_ms();
  fio_start(.threads = 1, .workers = 1);
  printf("idle cpu with 500 ms timer: %.2f%%\n",
         100.0 * (cpu_s() - c0) / ((now_ms() - w0) / 1e3));
  return 0;
}
