# Benchmarks

Facil is compared against Node.js on every row of a scoreboard, using for each
row the fastest Node option for that job: `node:http` (with `cluster` for several
cores), `node:https`, uWebSockets.js or `ws` for WebSockets. The target for every
row is at least 1.0× Node.

## Conditions

- Machine: Apple M5 Pro, 15 cores, macOS. Julia 1.13.0, Node v22.23.2.
- Client and server on the same machine, over loopback.
- 3 runs per cell. Each cell shows the median and, in brackets, the min–max.
- Before each run the driver checks that the machine is at least 90% idle, that
  the port belongs to the server it started, and that the endpoint returns the
  right status and body.
- Ratio is Facil/Node when higher is better (↑) and Node/Facil when lower is better
  (↓), so above 1 favours Facil.
- "Facil setup" is the handler mode and the number of Julia threads (`-t`) and
  reactor threads. Clients and parameters for each row are in
  `bench/scoreboard/rows.json`.
- Flags: `client` means the load client reached 90% of its cores, so the number
  is a lower bound; `errors` means non-2xx, reset or stuck responses were seen;
  `failed runs` means a run did not complete.

Each row shows the latest run that measured both sides. Quick (indicative-only)
runs are left out.

## Scoreboard

51 rows pass and 9 fail.

| Row | Name | Metric | Facil | Node | Node opponent | Ratio | Verdict | Facil setup | Flags | Run |
|---|---|---|---|---|---|---|---|---|---|---|
| A1 | Tiny reply, 1 core | rps (↑) | 235,333 (228,443–238,302) | 176,314 (171,378–177,386) | node:http | 1.33× | PASS | inline, -t 1 |  | [1] |
| A2 | 150-byte JSON, 1 core | rps (↑) | 210,965 (208,676–218,843) | 155,535 (153,686–157,338) | node:http | 1.36× | PASS | inline, -t 1 |  | [1] |
| A3 | POST echo | rps (↑) | 200,698 (199,246–204,937) | 134,631 (133,451–135,251) | node:http | 1.49× | PASS | inline, -t 1 |  | [3] |
| A4 | 100 KB response | rps (↑) | 103,359 (97,588–103,472) | 81,929 (67,047–85,746) | node:http | 1.26× | PASS | inline, -t 1 |  | [6] |
| A5 | 1 MB response | rps (↑) | 15,904 (13,307–16,478) | 15,337 (10,459–16,023) | node:http | 1.04× | PASS | inline, -t 1 |  | [6] |
| A6 | CPU-bound handler (FNV 3x16 KB), 1 core | rps (↑) | 17,520 (17,374–17,758) | 5,239 (5,042–5,240) | node:http | 3.34× | PASS | inline, -t 1 |  | [2] |
| A7 | CPU-bound handler, 2 cores | rps (↑) | 36,522 (36,403–36,642) | 10,032 (9,961–10,158) | cluster W=2 | 3.64× | PASS | inline, -t 2, reactors = 2 | facil:failed runs | [2] |
| A8 | CPU-bound handler, 4 cores | rps (↑) | 65,995 (64,506–66,009) | 18,353 (18,306–19,166) | cluster W=4 | 3.60× | PASS | inline, -t 4, reactors = 4 |  | [2] |
| A11 | gzip responses (100 KB JSON, level 6, off the event loop) | rps (↑) | 11,019 (10,581–11,121) | 6,859 (6,557–6,928) | node:http | 1.61× | PASS | task, -t 5 |  | [6] |
| A12a | Upload 1 KB, in memory | rps (↑) | 194,369 (183,100–194,904) | 141,955 (140,955–142,905) | node:http | 1.37× | PASS | inline, -t 1 |  | [4] |
| A12b | Upload 64 KB, in memory | rps (↑) | 100,798 (100,717–100,836) | 70,108 (69,427–70,482) | node:http | 1.44× | PASS | inline, -t 1 |  | [4] |
| A12c | Upload 1 MB, in memory | rps (↑) | 11,743 (11,743–11,775) | 9,068 (9,062–9,307) | node:http | 1.29× | PASS | inline, -t 1 |  | [4] |
| A13a | TLS handshakes, ECDSA full, 10 clients | rps (↑) | 7,052 (7,018–7,076) | 6,687 (6,155–6,816) | node:https | 1.05× | PASS | inline, -t 1 |  | [5] |
| A13b | TLS handshakes, RSA full, 10 clients | rps (↑) | 2,289 (2,279–2,300) | 2,235 (2,215–2,265) | node:https | 1.02× | PASS | inline, -t 1 |  | [5] |
| A13c | TLS handshakes, RSA resumed, 10 clients | rps (↑) | 7,905 (7,241–7,907) | 7,764 (7,709–7,960) | node:https | 1.02× | PASS | inline, -t 1 |  | [5] |
| A14 | WebSocket broadcast, 1,000 subscribers x 1,000 Hz | deliveries_per_s (↑) | 1,000,000 (803,213–1,000,000) | 648,340 (559,566–999,800) | uWebSockets.js | 1.54× | PASS | inline, -t 1 |  | [7] |
| A15a | Streaming 10 x 1 KB chunks, no delay, 50 conns | rps (↑) | 148,693 (130,485–154,880) | 83,872 (66,520–87,744) | node:http | 1.77× | PASS | inline, -t 1 | facil:client | [6] |
| A15b | Streaming 100 x 16 KB chunks, no delay | rps (↑) | 3,715 (3,682–3,739) | 3,590 (3,581–3,715) | node:http | 1.03× | PASS | inline, -t 1 | facil:client, node:client | [6] |
| A15c | Streaming 10 x 1 MB chunks, no delay | rps (↑) | 718 (714–720) | 699 (674–702) | node:http | 1.03× | PASS | inline, -t 1 | facil:client, node:client | [6] |
| A19b | 12 request headers | rps (↑) | 171,771 (171,467–172,536) | 121,050 (120,994–121,798) | node:http | 1.42× | PASS | inline, -t 1 |  | [1] |
| A24 | JSON parse 1 KB POST | rps (↑) | 116,168 (109,146–123,750) | 99,202 (92,660–104,506) | node:http | 1.17× | PASS | inline, -t 1 |  | [3] |
| A26 | Task-based tiny handler, 4 Julia threads | rps (↑) | 163,839 (154,286–172,374) | 165,992 (147,471–171,044) | node:http | 0.987× | FAIL | task, -t 4 |  | [2] |
| A27 | HTTPS JSON, keep-alive | rps (↑) | 144,779 (140,048–146,398) | 128,407 (118,706–128,949) | node:https | 1.13× | PASS | inline, -t 1 |  | [5] |
| A28 | Memory per idle WebSocket (10,000 open) | bytes_per_conn (↓) | 551 (523–580) | 637 (632–639) | uWebSockets.js | 1.16× | PASS | inline, -t 1 |  | [7] |
| A29 | WebSocket echo 64 B, 100 connections | msgs_per_s (↑) | 251,333 (246,873–251,963) | 253,778 (253,585–254,145) | uWebSockets.js | 0.99× | FAIL | inline, -t 1 |  | [7] |
| A30 | WebSocket echo 64 B, 100 connections, vs ws | msgs_per_s (↑) | 251,333 (246,873–251,963) | 203,495 (202,726–203,975) | ws | 1.24× | PASS | inline, -t 1 |  | [7] |
| 1 | CPU-bound handler, 8 cores | rps (↑) | 91,648 (83,972–94,642) | 28,128 (26,970–31,337) | cluster W=8 | 3.26× | PASS | inline, -t 8, reactors = 8 |  | [2] |
| 2 | Tiny reply (JSON), 4 cores | rps (↑) | 165,607 (161,766–175,420) | 149,359 (142,007–167,453) | cluster W=4 | 1.11× | PASS | inline, -t 4, reactors = 4 |  | [2] |
| 3 | Tiny reply (JSON), 8 cores | rps (↑) | 156,233 (146,890–162,346) | 148,489 (144,639–150,484) | cluster W=8 | 1.05× | PASS | inline, -t 8, reactors = 8 |  | [2] |
| 4 | Async (task) handler, tiny reply, 1 reactor + 2 Julia threads | rps (↑) | 193,216 (171,347–205,463) | 144,921 (132,589–147,160) | node:http | 1.33× | PASS | task, -t 2 |  | [2] |
| 5a | HTTPS 100 KB, no-copy body | rps (↑) | 33,983 (33,205–36,097) | 29,250 (29,068–29,679) | node:https | 1.16× | PASS | inline, -t 1 |  | [5] |
| 5b | HTTPS 1 MB, no-copy body | rps (↑) | 4,483 (4,428–4,485) | 3,944 (3,779–3,976) | node:https | 1.14× | PASS | inline, -t 1 |  | [5] |
| 6a | Paced streaming from a Julia task, 10 x 1 KB, 1 ms apart | rps (↑) | 18,779 (18,739–18,837) | 10,412 (10,372–10,740) | node:http | 1.80× | PASS | task, -t 4 | facil:client | [6] |
| 6b | Paced streaming from a Julia task, 100 x 16 KB, 1 ms apart | rps (↑) | 1,827 (1,502–1,869) | 800 (767–826) | node:http | 2.28× | PASS | task, -t 4 | facil:client | [6] |
| 6c | Paced streaming from a Julia task, 1000 x 1 KB, 1 ms apart | rps (↑) | 183 (183–183) | 83.3 (83.3–83.3) | node:http | 2.20× | PASS | task, -t 4 |  | [6] |
| 7-c10 | WebSocket echo 256 KB, 10 connections | msgs_per_s (↑) | 34,546 (34,137–34,725) | 34,980 (34,784–35,144) | uWebSockets.js | 0.988× | FAIL | inline, -t 1 |  | [7] |
| 7-c100 | WebSocket echo 256 KB, 100 connections | msgs_per_s (↑) | 27,161 (26,589–27,471) | 27,816 (27,275–28,338) | uWebSockets.js | 0.976× | FAIL | inline, -t 1 |  | [7] |
| 7-c1000 | WebSocket echo 256 KB, 1000 connections | msgs_per_s (↑) | 18,679 (18,365–19,609) | 19,241 (18,731–20,104) | uWebSockets.js | 0.971× | FAIL | inline, -t 1 |  | [7] |
| 7b-64 | WebSocket echo 64 B, 10 connections | msgs_per_s (↑) | 247,209 (243,375–247,848) | 245,252 (245,238–245,573) | uWebSockets.js | 1.01× | PASS | inline, -t 1 |  | [7] |
| 7b-1k | WebSocket echo 1 KB, 10 connections | msgs_per_s (↑) | 244,098 (243,410–245,365) | 240,340 (239,017–240,566) | uWebSockets.js | 1.02× | PASS | inline, -t 1 |  | [7] |
| 7b-16k | WebSocket echo 16 KB, 10 connections | msgs_per_s (↑) | 187,645 (184,897–189,077) | 184,558 (184,503–185,199) | uWebSockets.js | 1.02× | PASS | inline, -t 1 |  | [7] |
| 8 | WebSocket permessage-deflate, 4 KB JSON echo, 100 connections | msgs_per_s (↑) | 59,617 (59,035–59,867) | 55,608 (55,382–55,673) | uWebSockets.js | 1.07× | PASS | inline, -t 1 |  | [7] |
| 9 | 10 MB chunked upload, buffered | rps (↑) | 712 (672–730) | 493 (477–499) | node:http | 1.45× | PASS | inline, -t 1 |  | [4] |
| 17a | Handler waits 1 ms (Facil.sleep), 100 connections | rps (↑) | 85,227 (85,202–85,305) | 58,992 (57,218–59,281) | node:http | 1.44× | PASS | task, -t 4 |  | [2] |
| 17b | Handler waits 1 ms (Facil.sleep), 1000 connections | rps (↑) | 128,450 (124,814–155,206) | 119,887 (109,191–132,298) | node:http | 1.07× | PASS | task, -t 4 |  | [2] |
| 18a | Handler waits 10 ms (Facil.sleep), 100 connections | rps (↑) | 9,834 (9,755–9,905) | 8,500 (8,432–8,542) | node:http | 1.16× | PASS | task, -t 4 |  | [2] |
| 18b | Handler waits 10 ms (Facil.sleep), 1000 connections | rps (↑) | 95,644 (92,389–95,733) | 81,264 (68,217–81,752) | node:http | 1.18× | PASS | task, -t 4 |  | [2] |
| 20 | Task-based handler on 1 Julia thread | rps (↑) | 205,511 (199,022–212,197) | 165,992 (147,471–171,044) | node:http | 1.24× | PASS | task, -t 1 |  | [2] |
| 24a | Upload 10 MB, default body handling (no spooling) | rps (↑) | 848 (817–881) | 680 (660–686) | node:http | 1.25× | PASS | inline, -t 1 |  | [3] |
| 24b | Upload 100 MB, default body handling (no spooling) | rps (↑) | 114 (108–117) | 74.4 (72.4–75.1) | node:http | 1.53× | PASS | inline, -t 1 |  | [3] |
| 25 | Upload 1 MB streamed through a task: requests per server CPU-second | req_per_cpu_s (↑) | 1,907 (1,869–1,912) | 10,975 (10,531–11,501) | node:http | 0.174× | FAIL | task, -t 4 |  | [4] |
| 26 | WebSocket broadcast, 10,000 subscribers x 100 Hz | deliveries_per_s (↑) | 192,677 (161,846–223,834) | 220,999 (208,729–253,198) | uWebSockets.js | 0.872× | FAIL | inline, -t 1 | facil:errors, node:errors | [7] |
| 27 | Streamed gzip of 100 KB JSON | rps (↑) | 10,767 (10,632–10,916) | 6,355 (6,305–6,392) | node:http | 1.69× | PASS | task, -t 5 |  | [6] |
| 28a | Whole response 32 KB (gather-write) | rps (↑) | 151,723 (145,408–152,149) | 111,445 (110,688–114,624) | node:http | 1.36× | PASS | inline, -t 1 | facil:client | [6] |
| 28b | Whole response 100 KB (gather-write) | rps (↑) | 87,797 (86,976–87,883) | 76,512 (71,816–76,896) | node:http | 1.15× | PASS | inline, -t 1 | facil:client, node:client | [6] |
| 29 | Whole response 1 MB (gather-write) | rps (↑) | 6,570 (6,429–6,647) | 6,030 (5,936–6,279) | node:http | 1.09× | PASS | inline, -t 1 | facil:client, node:client | [6] |
| 30a | Brotli level 4, 100 KB JSON, on the event loop | rps (↑) | 3,301 (3,229–3,310) | 2,998 (2,967–3,042) | node:http | 1.10× | PASS | inline, -t 1 |  | [6] |
| 30b | zstd level 3, 100 KB JSON, on the event loop | rps (↑) | 9,061 (8,556–9,087) | 8,159 (8,139–8,384) | node:http | 1.11× | PASS | inline, -t 1 |  | [6] |
| 31-p99 | Task handler at 10k req/s: p99 | p99_ms (↓) | 0.347 (0.305–6.94) | 0.168 (0.142–0.294) | node:http | 0.483× | FAIL | task, -t 4 |  | [2] |
| 31-cpu | Task handler at 10k req/s: server cores used | server_cores (↓) | 2.13 (2.08–2.14) | 0.152 (0.144–0.159) | node:http | 0.0714× | FAIL | task, -t 4 |  | [2] |
### Failing rows

| Row | What | Ratio |
|---|---|---|
| A26 | Task-based tiny handler, 4 Julia threads | 0.987× |
| A29 | WebSocket echo 64 B, 100 connections, against uWebSockets.js | 0.99× |
| 7-c10, 7-c100, 7-c1000 | WebSocket echo of 256 KB messages, against uWebSockets.js | 0.971–0.988× |
| 25 | 1 MB uploads streamed through a task, requests per server CPU-second | 0.174× |
| 26 | WebSocket broadcast to 10,000 subscribers at 100 Hz (both sides had errors) | 0.872× |
| 31-p99 | Task handler at a fixed 10k req/s: p99 latency | 0.483× |
| 31-cpu | Task handler at a fixed 10k req/s: server cores used | 0.0714× |

Rows 31-p99 and 31-cpu show that task handlers cost more CPU than Node at
light, steady load: each request is handed between threads twice. See
[Idle CPU](guide/threads.md#Idle-CPU).

### Approved exceptions

These rows are approved exceptions to the "at least 1.0× Node" target
(2026-11-25). `bench/scoreboard/rows.json` gives each an `exception` reason, and
the scoreboard reports them as EXCEPTION, not FAIL, when they are under target.

| Rows | What | Reason |
|---|---|---|
| 10, 10-sysimg, 11 | Memory, idle and with 10,000 connections | Julia runtime start-up and memory cost |
| 12, 12-sysimg, 12-json, 13, 13-sysimg, 13-json | Start-up to first response, first request | Julia runtime start-up and first-request (compilation) cost |
| 19, 19a | Build a 50 KB / 1 KB JSON response | Cost of Julia's JSON library serialising the body, not of the server |
| 25 | 1 MB upload streamed through a task, per CPU-second | Task handlers pay two cross-thread hand-offs per chunk; `Stream(on_chunk)` beats Node |
| 31-p99, 31-cpu | Task handler at a light 10k req/s: p99, CPU | Two cross-thread hand-offs per request; `inline = true` beats Node |
| 7-c10 | WebSocket echo 256 KB, 10 connections | macOS kernel networking limit (bound by `writev`); recheck on Linux |
| 26 | WebSocket broadcast to 10,000 subscribers | macOS socket-memory exhaustion and retransmits; recheck on Linux |
| 21a-p99, 21a-p999, 32 | Tail latency and longest pause at 10k req/s | Julia GC pauses; still under target with `JULIA_NUM_GC_THREADS=4` |

The scoreboard starts every Facil server with `JULIA_NUM_GC_THREADS=4`
(`--facil-env KEY=VAL` overrides it); the table header records the value.

### Notes on some rows

- A6, A7, A8 and 1 (CPU-bound FNV handler): Node's results here are far below
  the Node numbers recorded for the same rows during validation (for A6, 5,239
  against 15,900, the "node (validation)" column of the result file). The cause
  has not been checked. Treat these ratios with caution.
- Row 20 runs a task-handler server on one Julia thread. With one thread Facil
  runs handlers inline, so this row measures inline handlers.

### Later Facil-only runs

These rows were run again for Facil only, after the run above. No Node side was
measured in that run; the Node column repeats the earlier Node result.

| Row | Name | Metric | Facil (later run) | Node (earlier run) | Run |
|---|---|---|---|---|---|
| A26 | Task-based tiny handler, 4 Julia threads | rps (↑) | 147,686 (146,411–153,301) | 165,992 (147,471–171,044) (run [2]) | [8] |
| 17a | Handler waits 1 ms (Facil.sleep), 100 connections | rps (↑) | 87,463 (87,290–89,698) | 58,992 (57,218–59,281) (run [2]) | [8] |
| 31-p99 | Task handler at 10k req/s: p99 | p99_ms (↓) | 0.306 (0.284–0.429) | 0.168 (0.142–0.294) (run [2]) | [8] |
| 31-cpu | Task handler at 10k req/s: server cores used | server_cores (↓) | 0.231 (0.222–0.239) | 0.152 (0.144–0.159) (run [2]) | [8] |

### Rows not yet measured

These scoreboard rows have no full (non-quick) run yet:
A9 (1M requests, 10 per connection (client resets)), A9-p99 (1M requests, 10 per connection: p99), A10 (10,000 keep-alive connections: server CPU per request), A16 (Keep-alive, 1,000 connections), A17 (Keep-alive, 10,000 connections), A18 (Keep-alive, 5,000 connections: p99), A19a (2 request headers), A19c (40 request headers), A19d (100 request headers), A19e (4 KB cookie), A19f (2 KB query string, parsed), A20a (Pipelining depth 1), A20b (Pipelining depth 4), A20c (Pipelining depth 16), A21 (Fixed 50k req/s: p99), A22 (Fixed 100k req/s: p99), A25a (Float sum handler (1e5 floats)), A25b (FNV-1a over 4 KB handler), 10 (Memory, idle), 11 (Memory, 10,000 keep-alive connections under load), 12 (Start-up to first response), 13 (First request), 14 (200 slow-header connections (slowloris), held after 150 s), 15 (200 slow readers of 8 x 1 MB: RSS growth), 19 (Build a 50 KB JSON response), 19a (Build a 1 KB JSON response), 21a-p99 (100 KB garbage per request at 10k req/s: p99), 21a-p999 (100 KB garbage per request at 10k req/s: p99.9), 21b (100 KB garbage per request, max rate), 21b-p99 (100 KB garbage per request, max rate: p99), 21c (10 KB garbage per request at 10k req/s: p99.9), 22 (p99.9 at a light 10k req/s), 23a (New connection per request, 100 clients), 23b (New connection per request, 10 clients), 32 (Longest single pause at 10k req/s, no garbage).

## Against HTTP.jl

HTTP.jl is not part of the scoreboard. The only measurement against it is from
the validation run, before the package was built, with a prototype Facil server
(1 thread, eager request objects) and `autocannon -c 100 -w 4`. The large-body
row used a copy path that the package no longer uses; compare row A4 above.

| Endpoint | Facil prototype | Node | HTTP.jl 2.16 | Facil / HTTP.jl |
|---|---|---|---|---|
| Empty reply | 236,422 | 163,904 | 52,540 | 4.50× |
| 150-byte JSON | 230,452 | 145,638 | 51,619 | 4.46× |
| JSON, 12 request headers | 190,426 | 123,424 | 46,884 | 4.06× |
| 100 KB response | 51,370 | 83,447 | 38,381 | 1.34× |

Requests per second, median of 3 runs [9].

## Reproducing

The scoreboard lives in `bench/scoreboard`. It needs Node.js, a C compiler and
the Facil build. Run it alone on a quiet machine; one full run takes a long time.

```sh
bench/scoreboard/build.sh                               # clients, pinned Node packages, payloads, certificates
bench/scoreboard/run.sh --list                          # the rows
bench/scoreboard/run.sh                                 # every row, both sides, 3 runs per cell
bench/scoreboard/run.sh --rows A1,A4 --runs 3 --side both
```

Results go to `bench/scoreboard/results/<timestamp>/table.md`, with every run in
`raw.jsonl` and server output in `logs/`. The driver uses ports 3510 (Node) and
3520 (Facil).

## Sources

Result directories are not kept in the repository. `bench/scoreboard/RESULTS.md`
holds the latest full run (20261125-094221) and the GC verification run
(20261125-115157), with approved exceptions marked.

1. `bench/scoreboard/results/20261123-150238/table.md` (runs per cell: 3; sides: both; machine: 15 cores; node v22.23.2)
2. `bench/scoreboard/results/20261123-152722/table.md` (runs per cell: 3; sides: both; machine: 15 cores; node v22.23.2)
3. `bench/scoreboard/results/20261123-155604/table.md` (runs per cell: 3; sides: both; machine: 15 cores; node v22.23.2)
4. `bench/scoreboard/results/20261123-161830/table.md` (runs per cell: 3; sides: both; machine: 15 cores; node v22.23.2)
5. `bench/scoreboard/results/20261123-165839/table.md` (runs per cell: 3; sides: both; machine: 15 cores; node v22.23.2)
6. `bench/scoreboard/results/20261123-170601/table.md` (runs per cell: 3; sides: both; machine: 15 cores; node v22.23.2)
7. `bench/scoreboard/results/20261123-185039/table.md` (runs per cell: 3; sides: both; machine: 15 cores; node v22.23.2)
8. `bench/scoreboard/results/20261123-155059/table.md` (runs per cell: 3; sides: facil; machine: 15 cores; node v22.23.2)
9. Validation run, not in the repository: `v3_speed/results/table.txt` in the planning session's scratch directory (rows `tiny`, `json`, `json12h`, `large`, client `c100w4`; Facil column `facil-c`).
