#ifndef FJL_WS_H
#define FJL_WS_H

#include "fjl.h"

/* WebSocket connections are addressed by uuid; facil.io frees the socket
 * object on close. `jl` is an opaque Julia handle passed back to every
 * callback; it stays valid until on_close has run for it. */
typedef struct {
  void (*on_open)(void *jl, intptr_t uuid);
  void (*on_message)(void *jl, intptr_t uuid, const char *data, size_t len,
                     int is_text);
  void (*on_ready)(void *jl, intptr_t uuid);
  void (*on_shutdown)(void *jl, intptr_t uuid);
  /* `opened` is 0 when the upgrade failed and on_open never ran. */
  void (*on_close)(void *jl, intptr_t uuid, int opened);
} fjl_ws_callbacks_s;

void fjl_ws_init(const fjl_ws_callbacks_s *cb);

enum {
  FJL_WS_DEFLATE = 1,   /* accept permessage-deflate when the client offers it */
  FJL_WS_READY = 2,     /* call on_ready */
  FJL_WS_SHUTDOWN = 4,  /* call on_shutdown */
  FJL_WS_NO_UTF8 = 8,   /* skip the UTF-8 check on text messages */
};

/* Answers `h` with 101 and attaches the WebSocket protocol. Call on the
 * reactor thread with a live `h`. Returns 0, or -1 when the request is not a
 * valid upgrade (a 400 was sent and on_close ran with opened = 0). */
int fjl_ws_upgrade(http_s *h, void *jl, unsigned flags, size_t max_msg,
                   const char *subprotocol, size_t sp_len);

/* Process-wide permessage-deflate settings: zlib level and the smallest
 * message that is compressed. */
void fjl_ws_deflate_config(int level, size_t min_size);

/* permessage-deflate through zlib-ng (zng_deflateInit2, zng_deflate,
 * zng_deflateReset, zng_deflateEnd) and libdeflate (alloc_decompressor,
 * deflate_decompress) instead of zlib; NULLs go back to zlib. */
void fjl_ws_codec(void *init2, void *deflate, void *reset, void *end,
                  void *alloc_d, void *decompress);

/* Any thread. Return 0, or -1 when the connection is gone or closing. A send
 * copies whatever the socket does not take at once. */
int fjl_ws_send(intptr_t uuid, const char *data, size_t len, int is_text);
int fjl_ws_close(intptr_t uuid, int code, const char *reason, size_t len);
/* mode: 0 text when valid UTF-8, 1 text, 2 binary. Subscribing twice to one
 * channel is a no-op. */
int fjl_ws_subscribe(intptr_t uuid, const char *ch, size_t len, int mode);
int fjl_ws_unsubscribe(intptr_t uuid, const char *ch, size_t len);
int fjl_ws_read_pause(intptr_t uuid, int pause);
/* Unsent bytes queued for the connection. */
size_t fjl_ws_pending(intptr_t uuid);

/* Process-local pub/sub. Messages are delivered on a reactor thread through
 * on_message(jl, channel, msg); on_unsubscribe(jl) runs once afterwards. */
void fjl_ps_init(void (*on_message)(void *jl, const char *ch, size_t ch_len,
                                    const char *msg, size_t len),
                 void (*on_unsubscribe)(void *jl));
void *fjl_ps_subscribe(const char *ch, size_t len, void *jl);
void fjl_ps_unsubscribe(void *sub);
int fjl_ps_publish(const char *ch, size_t ch_len, const char *msg, size_t len);

#endif
