/* Level-triggered read readiness for the test load clients: kqueue on BSD and
 * macOS, epoll on Linux. */
#ifndef RDPOLL_H
#define RDPOLL_H
#include <time.h>
#if defined(__linux__)
#include <sys/epoll.h>
typedef struct epoll_event rdpoll_ev;
static inline int rdpoll_new(void) { return epoll_create1(0); }
static inline int rdpoll_add(int q, int fd, void *udata) {
  struct epoll_event e = {.events = EPOLLIN, .data.ptr = udata};
  return epoll_ctl(q, EPOLL_CTL_ADD, fd, &e);
}
static inline int rdpoll_del(int q, int fd) {
  struct epoll_event e = {0};
  return epoll_ctl(q, EPOLL_CTL_DEL, fd, &e);
}
static inline int rdpoll_wait(int q, rdpoll_ev *ev, int n, int ms) {
  return epoll_wait(q, ev, n, ms);
}
#define RDPOLL_UDATA(e) ((e).data.ptr)
#else
#include <sys/event.h>
typedef struct kevent rdpoll_ev;
static inline int rdpoll_new(void) { return kqueue(); }
static inline int rdpoll_add(int q, int fd, void *udata) {
  struct kevent e;
  EV_SET(&e, fd, EVFILT_READ, EV_ADD, 0, 0, udata);
  return kevent(q, &e, 1, NULL, 0, NULL);
}
static inline int rdpoll_del(int q, int fd) {
  struct kevent e;
  EV_SET(&e, fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
  return kevent(q, &e, 1, NULL, 0, NULL);
}
static inline int rdpoll_wait(int q, rdpoll_ev *ev, int n, int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  return kevent(q, NULL, 0, ev, n, &ts);
}
#define RDPOLL_UDATA(e) ((e).udata)
#endif
#endif
