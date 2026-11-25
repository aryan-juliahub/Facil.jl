#ifndef FJL_STREAM_H
#define FJL_STREAM_H

#include "fjl.h"

/* Streamed responses (unknown length) on a live keep-alive connection, and
 * EventSource (SSE) connections. Writes are addressed by uuid and may come
 * from any thread; `h` is only touched by the begin/upgrade calls, which run
 * on the reactor. */

enum {
  FJL_STREAM_TLS = 1,     /* begin: the connection has a TLS layer */
  FJL_STREAM_HEAD = 2,    /* begin: a HEAD request, no body may follow */
  FJL_STREAM_CHUNKED = 4, /* begin: chunked framing (HTTP/1.1) */
};

enum {
  FJL_W_MODE = 3,     /* FIO_WRITE_* mode */
  FJL_W_CHUNKED = 4,  /* frame as one chunk */
  FJL_W_LAST = 8,     /* append the terminating chunk */
  FJL_W_COPY = 16,    /* copy the buffer (dealloc runs at once) */
  FJL_W_WAKE = 32,    /* wake the reactor when a flush task was queued */
};

/* Sends the head of `h` with `status` and holds the parser. HTTP/1.1 gets
 * chunked framing; older clients a connection-delimited body. Returns the
 * uuid (or -1) and sets `*info` to FJL_STREAM_* bits. Reactor only. */
intptr_t fjl_stream_begin(http_s *h, int status, int *info);
/* `on_gone(udata)` runs (on the reactor) if the connection closes first. */
int fjl_stream_link(intptr_t uuid, void *udata, void (*on_gone)(void *));
/* Queues `len` bytes. Returns the connection's pending bytes, or -1 when it
 * is gone (dealloc then ran). */
ssize_t fjl_stream_write(intptr_t uuid, const char *data, size_t len,
                         void (*dealloc)(void *), int flags);
/* Ends the body: the terminating chunk when chunked, then lets the parser go
 * on (or closes the connection when the head said so). `how`: 0 inside the
 * request callback, 1 elsewhere on the reactor, 2 another thread. */
void fjl_stream_end(intptr_t uuid, void *udata, int chunked, int how);
/* Flushes on this thread (plain sockets), or asks the reactor to. */
void fjl_stream_flush(intptr_t uuid, int on_caller);

/* SSE: upgrades `h` (reactor only). Returns a handle of our own (released
 * with fjl_sse_free) or NULL; `*uuid` is the connection. `on_close(udata)`
 * runs on the reactor when the connection ends. */
http_sse_s *fjl_sse_upgrade(http_s *h, void *udata, void (*on_close)(void *),
                            intptr_t *uuid, int *tls);
int fjl_sse_close(http_sse_s *sse);
void fjl_sse_free(http_sse_s *sse);

/* Registers (or replaces) the MIME type of a file extension. */
void fjl_mime_register(const char *ext, size_t elen, const char *type,
                       size_t tlen);
/* Copies the content type for an extension into buf; 0 when unknown. */
size_t fjl_mime_find(const char *ext, size_t elen, char *buf, size_t cap);
/* Sends the file at `path` (no URL decoding) with `status`, ETag,
 * Last-Modified, conditional requests, single ranges and HEAD. -1 when it is not a regular
 * file or the method is not GET/HEAD/OPTIONS (`h` stays valid then). */
int fjl_sendfile(http_s *h, int status, const char *path, size_t len);

#endif
