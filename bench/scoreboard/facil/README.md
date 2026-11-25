# Facil side of the scoreboard

`server.jl` is the one Facil server every scoreboard row runs against. It was written before
Facil existed, against the API in the plan, so expect to rename calls; keep the routes and the
response contracts below, because the driver checks them before each run and Node answers the
same way (`../node/http_server.js`, `../node/uws_server.js`, `../node/https_server.js`).

The driver starts it as

```
julia -t<threads> --project=bench/scoreboard/facil bench/scoreboard/facil/server.jl <port> key=value ...
```

prints nothing it needs except a listener on `<port>` owned by that exact pid (not a juliaup
launcher, not a child). `READY` on stdout is logged but not required. Keys come from the row's
`facil` entry in `rows.json`:

| key | meaning |
|---|---|
| `handler=inline` / `handler=task` | `serve(...; inline=true/false)` for every route |
| `reactors=N` | number of reactor threads (`serve(...; threads=N)`); `-t` sets Julia threads |
| `tls=rsa\|ec`, `cert=…`, `key=…` | serve HTTPS with that certificate (`TLSConfig(cert, key)`) |
| `ws_deflate=L` | permessage-deflate at level L on `/echo` |

The environment needs `using Pkg; Pkg.instantiate()` once in this folder (it adds `JSON` for the
two JSON-handler rows). The driver reports "Facil not built" until `src/Facil.jl` exists and
`using Facil, JSON` works in this environment.

## API the file assumes

`serve(handler, host, port; inline, threads, max_body, tls)` returning a server for `wait`;
`Response(status[, body]; headers)`; `StatusCodes.OK/NOT_FOUND`; `header.CONTENT_TYPE`,
`CONTENT_ENCODING`, `VARY`, `COOKIE`; `path(uri(req))`, `headers(req)` (with `get`), `body(req)`;
`query(uri)` (Facil has no query-string parser; `server.jl` decodes it itself); `Facil.sleep(seconds)`; `Facil.body_chunks(req)` (streamed upload);
`Facil.stream(f, req; headers, compress, level)` (chunked response, `write(w, bytes)`);
`Facil.gzip/brotli/zstd(bytes; level)`; `Facil.is_upgrade(req)`;
`websocket(req; deflate, on_open, on_message, on_close)`, `send(ws, msg)`, `subscribe(ws, ch)`,
`publish(ch, msg)`; `every(f, ms)` (stops when `f` returns false); `TLSConfig(cert, key)`.

## Endpoints, and the rows that use them

Response bodies of `/bytes`, `/stream`, `/pstream` are all `'x'`. Upload bodies sent by the
clients are all `'x'`. `checksum(b)` = sum of `b[i]` for `i = 1, 1025, 2049, …` plus the last byte.

| Endpoint | Contract | Rows | Server keys |
|---|---|---|---|
| `GET /tiny` | 200, empty body | A1 | inline, -t1 |
| `GET /atiny` | 200, empty body | A26 (task, -t4), 20 (task, -t1: plan says run inline automatically) | |
| `GET /json` | 200, the 150-byte JSON | A2, A10, A16–A18, A20, A21, A22, 2, 3, 4, 11, 22, 31, 32; `/json` also probes 12, 13, 14, 15, 23 | 2/3: `reactors=4/8`; 4, 31: task |
| `POST /echo` | 200, request body back, `x-echo` header copied | A3 | |
| `GET /bytes/<n>` | 200, `n` bytes, Content-Length | A4, A5, 15 (1 MB, slow readers), 28a/b, 29; HTTPS: 5a, 5b | 5a/5b: `tls=rsa` |
| `GET /hdr` | `"<header count> <cookie length>"` | A19a–e (2–100 headers, 4 KB cookie) | |
| `GET /query?…` | `"<param count> <value of k7>"` (decoded) | A19f | |
| `GET /fnv16k` | FNV-1a over 16 KB, 3 passes, hex | A6, A7, A8, 1 | `reactors=1/2/4/8`, `-t` same |
| `GET /floatsum` | sum of 1e5 floats | A25a | |
| `GET /hash` | FNV-1a over 4 KB | A25b | |
| `POST /parse` | parse the 1 KB JSON, reply with its `name` (`benchmark-user`) | A24 | |
| `GET /gen1k`, `/gen50k` | build and serialise 9 / 440 records | 19a, 19 | |
| `GET /gc`, `/gc10` | allocate 100 KB / 10 KB garbage, reply JSON | 21a, 21b, 21c | |
| `GET /wait1`, `/wait10` | `Facil.sleep(0.001/0.010)` in a task, reply JSON | 17a, 17b, 18a, 18b | task, -t4 |
| `POST /upload` | buffered body, `"<len> <checksum>"`; 200 MB limit; chunked accepted | A12a–c, 9 (10 MB chunked), 24a/b (10/100 MB, no spooling) | |
| `POST /upload/stream` | same reply, body consumed as it arrives through a task | 25 (metric: requests per server CPU-second) | task, -t4 |
| `GET /stream/<n>/<kb>` | chunked response, `n` chunks of `kb` KB, no delay | A15a–c | |
| `GET /pstream/<n>/<kb>` | same, 1 ms (`Facil.sleep`) before each chunk, from a Julia task | 6a–c | task, -t4 |
| `GET /z/<algo><level>[stream\|sync]/json_100k` | body of `data/json_100k.json` compressed (`gz`→gzip, `br`, `zstd`), Content-Encoding set | A11 (`gz6`, task -t5), 27 (`gz6stream`, task -t5), 30a (`br4sync`), 30b (`zstd3sync`) | |
| WS `/echo` | echo every message, text or binary, same opcode | A29, 7-*, 7b-*, A28 (10,000 idle), probe for all WS rows | 8: `ws_deflate=6` |
| WS `/sub` | subscribe to channel `room`; never sends otherwise | A14, 26 | |
| `GET /start?n=&rate=&size=` | publish `n` messages of `size` bytes at `rate`/s to `room`, each starting `"<seq:10> <scheduled ns:20> "` | A14, 26 | |
| `GET /stats` | JSON `{opens, closes, published}` | A14, 26 (logged) | |
| HTTPS `GET /json` | as `/json`, over TLS 1.3, keep-alive and handshake-per-request | A13a (`tls=ec`), A13b/c (`tls=rsa`; c resumes sessions), A27 | `tls=…` |
| (process) | — | 10: RSS 5 s after start; 12/13: launch → first response, first request | |
| (connection behaviour) | slow headers must be timed out; slow readers must not grow memory | 14 (200 slowloris, 150 s), 15 (200 readers × 8 MB) | |
