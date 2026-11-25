/* Mixed-load fixture: plain HTTP, optional HTTPS, WebSocket echo and uploads on
 * one reactor. usage: server <port> <threads> [tls_port cert key]
 *   GET /tiny         small copied body
 *   GET /big          1 MiB through http_send_body_nocopy (gather)
 *   GET /big2         1 MiB through http_send_body_nocopy (two packets)
 *   POST /upload      body read via http1_body_info; replies "<len> <fnv1a64>"
 *   GET /stats        "<nocopy sends> <nocopy deallocs>"
 *   upgrade /ws       echo */
#include <fio.h>
#include <fio_tls.h>
#include <http.h>
#include <http1_body.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <websockets.h>

static char BIG[1 << 20];
static atomic_size_t nocopy_sent, nocopy_freed;
static void big_free(void *p) {
  (void)p;
  atomic_fetch_add(&nocopy_freed, 1);
}
static uint64_t fnv(const uint8_t *p, size_t n) {
  uint64_t h = 14695981039346656037ULL;
  for (size_t i = 0; i < n; ++i)
    h = (h ^ p[i]) * 1099511628211ULL;
  return h;
}
static int is(http_s *h, const char *path) {
  fio_str_info_s s = fiobj_obj2cstr(h->path);
  return s.len == strlen(path) && !memcmp(s.data, path, s.len);
}
static void on_request(http_s *h) {
  char buf[96];
  if (is(h, "/tiny")) {
    http_send_body(h, "ok", 2);
  } else if (is(h, "/big") || is(h, "/big2")) {
    atomic_fetch_add(&nocopy_sent, 1);
    http_send_body_nocopy(h, BIG, sizeof(BIG), big_free, is(h, "/big"));
  } else if (is(h, "/upload")) {
    http1_body_info_s b;
    http1_body_info(h, &b);
    uint64_t sum = fnv(b.data, b.len);
    if (b.mode == HTTP1_BODY_NONE && h->body) {
      fio_str_info_s s = fiobj_data_read(h->body, 0);
      sum = fnv((uint8_t *)s.data, s.len);
      b.len = s.len;
    }
    int n = snprintf(buf, sizeof(buf), "%zu %016llx", b.len, (unsigned long long)sum);
    http_send_body(h, buf, n);
  } else if (is(h, "/stats")) {
    int n = snprintf(buf, sizeof(buf), "%zu %zu", atomic_load(&nocopy_sent),
                     atomic_load(&nocopy_freed));
    http_send_body(h, buf, n);
  } else {
    http_send_error(h, 404);
  }
}
static void ws_echo(ws_s *ws, fio_str_info_s msg, uint8_t is_text) {
  websocket_write(ws, msg, is_text);
}
static void on_upgrade(http_s *h, char *proto, size_t len) {
  (void)len;
  if (proto && proto[0] == 'w')
    http_upgrade2ws(h, .on_message = ws_echo);
  else
    http_send_error(h, 400);
}
int main(int argc, char **argv) {
  if (argc < 3)
    return 2;
  memset(BIG, 'x', sizeof(BIG));
  for (size_t i = 0; i < sizeof(BIG); i += 4096)
    BIG[i] = 'a' + (i / 4096) % 26;
  http1_body_configure((http1_body_config_s){.mem_limit = 64u << 20});
  fio_signal_handler_reset();
  if (http_listen(argv[1], "127.0.0.1", .on_request = on_request,
                  .on_upgrade = on_upgrade, .max_body_size = 64u << 20,
                  .ws_max_msg_size = 4u << 20) == -1)
    return 1;
  if (argc >= 6) {
    fio_tls_s *tls = fio_tls_new("localhost", argv[4], argv[5], NULL);
    if (http_listen(argv[3], "127.0.0.1", .on_request = on_request,
                    .on_upgrade = on_upgrade, .max_body_size = 64u << 20,
                    .ws_max_msg_size = 4u << 20, .tls = tls) == -1)
      return 1;
  }
  fio_start(.threads = (int16_t)atoi(argv[2]), .workers = 1);
  return 0;
}
