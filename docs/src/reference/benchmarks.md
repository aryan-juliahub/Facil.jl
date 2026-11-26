# [Benchmarks](@id benchmarks)

This page is the full record of how Facil performs against Node.js: all 100
rows of the scoreboard, including the ones where Facil is behind, the
conditions they were measured under, and how to reproduce them. For advice
drawn from these numbers, see [Performance tuning](../guide/performance.md).

Facil is compared against Node.js on every row of a scoreboard, using for each
row the fastest Node option for that job: `node:http` (with `cluster` for several
cores), `node:https`, uWebSockets.js or `ws` for WebSockets. The target for every
row is at least 1.0× Node.

![Dumbbell chart of requests per second for Facil.jl and Node.js on 23 scoreboard rows, log scale. Facil is ahead on 20 rows, from 1.01× to 2.10×, and behind on building a 1 KB JSON response (0.53×, approved exception), 256 KB WebSocket echo with 10 connections (0.93×, approved exception) and WebSocket broadcast (0.97×).](../assets/bench-throughput-light.svg)

![Facil ÷ Node ratio for all 100 scoreboard rows, sorted, log scale: 76 rows at or above 1.0×, 5 failing rows all within 4% of Node, and 19 approved exceptions, the lowest being start-up (0.036×) and first request (0.0065×).](../assets/bench-ratio-light.svg)

The charts are drawn by `python3 bench/scoreboard/chart.py` from
`bench/scoreboard/chart_data.csv` (light and dark variants in
`docs/src/assets/`).

## Conditions

- Machine: Apple M5 Pro, 15 cores, macOS. Julia 1.13.0, Node v22.23.2.
- Client and server on the same machine, over loopback.
- 3 runs per cell. Each cell shows the median and, in brackets, the min–max.
- Before each run the driver checks that the machine is at least 90% idle, that
  the port belongs to the server it started, and that the endpoint returns the
  right status and body.
- Ratio is Facil/Node when higher is better (↑) and Node/Facil when lower is better
  (↓), so above 1 favours Facil.
- Clients, parameters and the Facil setup (handler mode, Julia threads, reactor
  threads) for each row are in `bench/scoreboard/rows.json`.
- Flags: `client` means the load client reached 90% of its cores, so the number
  is a lower bound; `errors` means non-2xx, reset or stuck responses were seen.

Each row comes from the full run of 25 November 2026 [1], except rows that a later
run re-measured on both sides: rows 19–22 and 32 with `JULIA_NUM_GC_THREADS=4`
(now the scoreboard default) [2], and the verification runs after the
WebSocket and HTTP fixes [3] and the task-pool fixes [4]. The Run column names
the source.

## Scoreboard

76 rows pass, 5 fail and 19 are approved exceptions.

| Row | Name | Metric | Facil | Node | Node opponent | Ratio | Verdict | Flags | Run |
|---|---|---|---|---|---|---|---|---|---|
| A1 | Tiny reply, 1 core | rps (↑) | 232,517 (228,547–248,560) | 170,961 (162,924–177,054) | node:http | 1.36× | PASS |  | [3] |
| A2 | 150-byte JSON, 1 core | rps (↑) | 237,781 (237,309–238,001) | 161,129 (160,669–162,014) | node:http | 1.48× | PASS |  | [1] |
| A3 | POST echo | rps (↑) | 218,288 (217,806–219,315) | 139,026 (137,560–139,558) | node:http | 1.57× | PASS |  | [1] |
| A4 | 100 KB response | rps (↑) | 111,611 (111,108–111,706) | 87,291 (87,042–87,694) | node:http | 1.28× | PASS |  | [1] |
| A5 | 1 MB response | rps (↑) | 16,909 (16,899–16,924) | 16,219 (16,082–16,233) | node:http | 1.04× | PASS |  | [1] |
| A6 | CPU-bound handler (FNV 3x16 KB), 1 core | rps (↑) | 17,128 (17,053–17,133) | 17,122 (16,859–17,753) | node:http | 1.00× | PASS |  | [1] |
| A7 | CPU-bound handler, 2 cores | rps (↑) | 35,731 (35,710–35,739) | 36,278 (36,180–36,313) | cluster W=2 | 0.98× | FAIL |  | [1] |
| A8 | CPU-bound handler, 4 cores | rps (↑) | 69,330 (69,296–69,355) | 64,236 (64,223–64,244) | cluster W=4 | 1.08× | PASS |  | [1] |
| A9 | 1M requests, 10 per connection (client resets) | rps (↑) | 188,361 (187,903–189,057) | 149,197 (147,878–149,715) | node:http | 1.26× | PASS |  | [1] |
| A9-p99 | 1M requests, 10 per connection: p99 | p99_ms (↓) | 1.21 (1.15–1.21) | 6.16 (6.09–6.16) | node:http | 5.09× | PASS |  | [1] |
| A10 | 10,000 keep-alive connections: server CPU per request | cpu_us_per_req (↓) | 6.01 (4.74–6.17) | 8.22 (8.18–8.26) | node:http | 1.37× | PASS | facil:errors | [1] |
| A11 | gzip responses (100 KB JSON, level 6, off the event loop) | rps (↑) | 12,169 (12,149–12,288) | 7,662 (7,534–7,674) | node:http | 1.59× | PASS |  | [4] |
| A12a | Upload 1 KB, in memory | rps (↑) | 205,291 (203,947–206,127) | 140,637 (140,146–140,989) | node:http | 1.46× | PASS |  | [1] |
| A12b | Upload 64 KB, in memory | rps (↑) | 112,278 (111,994–112,350) | 72,584 (72,211–72,642) | node:http | 1.55× | PASS |  | [1] |
| A12c | Upload 1 MB, in memory | rps (↑) | 11,904 (11,892–12,000) | 9,644 (9,574–9,693) | node:http | 1.23× | PASS |  | [1] |
| A13a | TLS handshakes, ECDSA full, 10 clients | rps (↑) | 7,299 (7,216–7,309) | 6,857 (6,786–6,872) | node:https | 1.06× | PASS |  | [1] |
| A13b | TLS handshakes, RSA full, 10 clients | rps (↑) | 2,282 (2,260–2,285) | 2,221 (2,219–2,226) | node:https | 1.03× | PASS |  | [1] |
| A13c | TLS handshakes, RSA resumed, 10 clients | rps (↑) | 8,229 (8,142–8,238) | 8,031 (8,023–8,067) | node:https | 1.02× | PASS |  | [1] |
| A14 | WebSocket broadcast, 1,000 subscribers x 1,000 Hz | deliveries_per_s (↑) | 968,013 (764,709–999,976) | 999,971 (999,796–1,000,000) | uWebSockets.js | 0.97× | FAIL |  | [1] |
| A15a | Streaming 10 x 1 KB chunks, no delay, 50 conns | rps (↑) | 168,405 (168,384–169,003) | 92,992 (92,011–93,024) | node:http | 1.81× | PASS | facil:client | [1] |
| A15b | Streaming 100 x 16 KB chunks, no delay | rps (↑) | 3,905 (3,902–3,906) | 3,877 (3,865–3,883) | node:http | 1.01× | PASS | facil:client, node:client | [1] |
| A15c | Streaming 10 x 1 MB chunks, no delay | rps (↑) | 749 (748–750) | 747 (719–748) | node:http | 1.00× | PASS | facil:client, node:client | [3] |
| A16 | Keep-alive, 1,000 connections | rps (↑) | 222,037 (219,850–225,363) | 141,560 (140,286–142,650) | node:http | 1.57× | PASS |  | [1] |
| A17 | Keep-alive, 10,000 connections | rps (↑) | 234,442 (79,714–289,752) | 111,387 (109,051–120,001) | node:http | 2.10× | PASS | facil:errors | [3] |
| A18 | Keep-alive, 5,000 connections: p99 | p99_ms (↓) | 26.9 (26.3–27) | 58.7 (58.2–59) | node:http | 2.18× | PASS |  | [1] |
| A19a | 2 request headers | rps (↑) | 217,614 (216,741–218,800) | 152,558 (152,516–153,263) | node:http | 1.43× | PASS |  | [1] |
| A19b | 12 request headers | rps (↑) | 181,567 (181,416–185,140) | 121,380 (121,329–123,602) | node:http | 1.50× | PASS |  | [1] |
| A19c | 40 request headers | rps (↑) | 102,924 (98,491–103,631) | 66,218 (66,214–66,700) | node:http | 1.55× | PASS |  | [1] |
| A19d | 100 request headers | rps (↑) | 33,485 (33,331–33,657) | 32,546 (31,214–32,944) | node:http | 1.03× | PASS |  | [1] |
| A19e | 4 KB cookie | rps (↑) | 198,226 (191,994–200,895) | 140,593 (138,087–143,630) | node:http | 1.41× | PASS |  | [1] |
| A19f | 2 KB query string, parsed | rps (↑) | 39,287 (38,685–39,730) | 37,068 (36,351–37,347) | node:http | 1.06× | PASS |  | [1] |
| A20a | Pipelining depth 1 | rps (↑) | 233,642 (232,048–234,119) | 161,553 (160,943–162,057) | node:http | 1.45× | PASS | facil:client | [1] |
| A20b | Pipelining depth 4 | rps (↑) | 348,049 (343,500–351,870) | 222,951 (220,190–224,800) | node:http | 1.56× | PASS |  | [1] |
| A20c | Pipelining depth 16 | rps (↑) | 373,962 (372,646–377,600) | 245,715 (245,616–247,430) | node:http | 1.52× | PASS |  | [1] |
| A21 | Fixed 50k req/s: p99 | p99_ms (↓) | 0.0553 (0.0551–0.0558) | 0.0605 (0.0605–0.0606) | node:http | 1.09× | PASS |  | [1] |
| A22 | Fixed 100k req/s: p99 | p99_ms (↓) | 0.0499 (0.0496–0.0513) | 0.082 (0.0813–0.083) | node:http | 1.64× | PASS |  | [1] |
| A24 | JSON parse 1 KB POST | rps (↑) | 134,780 (133,647–136,120) | 111,431 (110,949–112,196) | node:http | 1.21× | PASS |  | [1] |
| A25a | Float sum handler (1e5 floats) | rps (↑) | 88,119 (87,431–88,492) | 15,407 (15,328–15,486) | node:http | 5.72× | PASS |  | [1] |
| A25b | FNV-1a over 4 KB handler | rps (↑) | 129,581 (129,451–129,656) | 102,904 (102,850–103,162) | node:http | 1.26× | PASS |  | [1] |
| A26 | Task-based tiny handler, 4 Julia threads | rps (↑) | 207,469 (205,008–209,276) | 174,635 (161,802–174,714) | node:http | 1.19× | PASS |  | [3] |
| A27 | HTTPS JSON, keep-alive | rps (↑) | 156,251 (154,998–157,322) | 130,859 (129,202–130,945) | node:https | 1.19× | PASS |  | [1] |
| A28 | Memory per idle WebSocket (10,000 open) | bytes_per_conn (↓) | 285 (280–331) | 629 (628–639) | uWebSockets.js | 2.21× | PASS |  | [1] |
| A29 | WebSocket echo 64 B, 100 connections | msgs_per_s (↑) | 282,130 (281,616–282,168) | 279,283 (279,186–279,512) | uWebSockets.js | 1.01× | PASS |  | [1] |
| A30 | WebSocket echo 64 B, 100 connections, vs ws | msgs_per_s (↑) | 282,130 (281,616–282,168) | 220,829 (217,486–222,582) | ws | 1.28× | PASS |  | [1] |
| 1 | CPU-bound handler, 8 cores | rps (↑) | 125,898 (125,728–126,026) | 121,492 (120,301–122,990) | cluster W=8 | 1.04× | PASS |  | [3] |
| 2 | Tiny reply (JSON), 4 cores | rps (↑) | 185,948 (184,838–186,748) | 179,037 (178,150–179,342) | cluster W=4 | 1.04× | PASS |  | [3] |
| 3 | Tiny reply (JSON), 8 cores | rps (↑) | 170,497 (170,351–171,400) | 167,826 (167,826–168,197) | cluster W=8 | 1.02× | PASS |  | [3] |
| 4 | Async (task) handler, tiny reply, 1 reactor + 2 Julia threads | rps (↑) | 209,424 (209,207–211,741) | 147,050 (146,284–147,057) | node:http | 1.42× | PASS |  | [4] |
| 5a | HTTPS 100 KB, no-copy body | rps (↑) | 37,681 (37,345–37,700) | 30,140 (30,027–30,591) | node:https | 1.25× | PASS |  | [1] |
| 5b | HTTPS 1 MB, no-copy body | rps (↑) | 4,702 (4,656–4,710) | 4,104 (3,861–4,129) | node:https | 1.15× | PASS |  | [1] |
| 6a | Paced streaming from a Julia task, 10 x 1 KB, 1 ms apart | rps (↑) | 19,027 (18,901–19,032) | 9,104 (9,029–9,205) | node:http | 2.09× | PASS |  | [4] |
| 6b | Paced streaming from a Julia task, 100 x 16 KB, 1 ms apart | rps (↑) | 1,876 (1,867–1,900) | 867 (833–867) | node:http | 2.16× | PASS | facil:client | [4] |
| 6c | Paced streaming from a Julia task, 1000 x 1 KB, 1 ms apart | rps (↑) | 183 (183–183) | 83.3 (83.3–83.3) | node:http | 2.20× | PASS |  | [4] |
| 7-c10 | WebSocket echo 256 KB, 10 connections | msgs_per_s (↑) | 31,275 (30,435–34,396) | 33,762 (33,640–35,603) | uWebSockets.js | 0.93× | EXCEPTION |  | [3] |
| 7-c100 | WebSocket echo 256 KB, 100 connections | msgs_per_s (↑) | 25,508 (24,617–26,203) | 25,247 (23,179–26,789) | uWebSockets.js | 1.01× | PASS |  | [3] |
| 7-c1000 | WebSocket echo 256 KB, 1000 connections | msgs_per_s (↑) | 17,539 (17,261–17,598) | 17,650 (15,263–18,157) | uWebSockets.js | 0.99× | FAIL |  | [3] |
| 7b-64 | WebSocket echo 64 B, 10 connections | msgs_per_s (↑) | 236,774 (234,401–240,443) | 221,249 (96,984–235,812) | uWebSockets.js | 1.07× | PASS |  | [3] |
| 7b-1k | WebSocket echo 1 KB, 10 connections | msgs_per_s (↑) | 237,687 (230,569–237,710) | 229,519 (224,194–235,476) | uWebSockets.js | 1.04× | PASS |  | [3] |
| 7b-16k | WebSocket echo 16 KB, 10 connections | msgs_per_s (↑) | 186,228 (181,046–190,067) | 182,505 (159,091–186,287) | uWebSockets.js | 1.02× | PASS |  | [3] |
| 8 | WebSocket permessage-deflate, 4 KB JSON echo, 100 connections | msgs_per_s (↑) | 57,931 (56,457–59,058) | 53,917 (51,057–54,964) | uWebSockets.js | 1.07× | PASS |  | [3] |
| 9 | 10 MB chunked upload, buffered | rps (↑) | 686 (656–725) | 501 (459–508) | node:http | 1.37× | PASS |  | [1] |
| 10 | Memory, idle | rss_mb (↓) | 384 (383–384) | 50.7 (50.7–50.9) | node:http | 0.13× | EXCEPTION |  | [1] |
| 10-sysimg | Memory, idle (Facil: PackageCompiler sysimage, /json-only server) | rss_mb (↓) | 324 (324–324) | 50.7 (50.7–50.9) | node:http | 0.16× | EXCEPTION |  | [1] |
| 11 | Memory, 10,000 keep-alive connections under load | rss_max_mb (↓) | 449 (441–449) | 248 (221–269) | node:http | 0.55× | EXCEPTION | facil:errors | [1] |
| 12 | Start-up to first response | startup_ms (↓) | 764 (764–767) | 27.4 (27.4–30.6) | node:http | 0.036× | EXCEPTION |  | [1] |
| 12-sysimg | Start-up to first response (Facil: PackageCompiler sysimage, /json-only server) | startup_ms (↓) | 314 (313–317) | 27.4 (27.4–30.6) | node:http | 0.087× | EXCEPTION |  | [1] |
| 12-json | Start-up to first response (Facil: plain julia, /json-only server) | startup_ms (↓) | 448 (447–450) | 27.4 (27.4–30.6) | node:http | 0.061× | EXCEPTION |  | [1] |
| 13 | First request | first_req_ms (↓) | 318 (317–319) | 2.06 (2.01–2.39) | node:http | 0.0065× | EXCEPTION |  | [1] |
| 13-sysimg | First request (Facil: PackageCompiler sysimage, /json-only server) | first_req_ms (↓) | 6.92 (6.67–6.99) | 2.06 (2.01–2.39) | node:http | 0.30× | EXCEPTION |  | [1] |
| 13-json | First request (Facil: plain julia, /json-only server) | first_req_ms (↓) | 4.93 (4.89–5.94) | 2.06 (2.01–2.39) | node:http | 0.42× | EXCEPTION |  | [1] |
| 14 | 200 slow-header connections (slowloris), held after 150 s | held (↓) | 0 (0–0) | 0 (0–0) | node:http | 1.00× | PASS |  | [1] |
| 15 | 200 slow readers of 8 x 1 MB: RSS growth | rss_growth_mb (↓) | 2.3 (1.9–2.7) | 10 (9.3–11.1) | node:http | 4.35× | PASS |  | [1] |
| 17a | Handler waits 1 ms (Facil.sleep), 100 connections | rps (↑) | 90,131 (90,077–90,138) | 60,409 (59,949–60,630) | node:http | 1.49× | PASS |  | [4] |
| 17b | Handler waits 1 ms (Facil.sleep), 1000 connections | rps (↑) | 182,376 (167,031–186,807) | 134,946 (126,709–139,810) | node:http | 1.35× | PASS |  | [4] |
| 18a | Handler waits 10 ms (Facil.sleep), 100 connections | rps (↑) | 9,786 (9,780–9,792) | 8,384 (8,253–8,444) | node:http | 1.17× | PASS |  | [4] |
| 18b | Handler waits 10 ms (Facil.sleep), 1000 connections | rps (↑) | 97,189 (95,296–97,454) | 83,366 (82,634–83,427) | node:http | 1.17× | PASS |  | [4] |
| 19 | Build a 50 KB JSON response | rps (↑) | 2,402 (2,332–2,406) | 12,410 (11,396–12,427) | node:http | 0.19× | EXCEPTION |  | [2] |
| 19a | Build a 1 KB JSON response | rps (↑) | 69,271 (69,255–69,372) | 131,376 (130,560–131,661) | node:http | 0.53× | EXCEPTION |  | [2] |
| 20 | Task-based handler on 1 Julia thread | rps (↑) | 242,086 (231,756–242,639) | 180,258 (178,972–181,258) | node:http | 1.34× | PASS | facil:client | [4] |
| 21a-p99 | 100 KB garbage per request at 10k req/s: p99 | p99_ms (↓) | 0.223 (0.207–0.248) | 0.142 (0.141–0.142) | node:http | 0.64× | EXCEPTION |  | [2] |
| 21a-p999 | 100 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 2.92 (2.66–3.04) | 0.156 (0.155–0.177) | node:http | 0.053× | EXCEPTION |  | [2] |
| 21b | 100 KB garbage per request, max rate | rps (↑) | 195,378 (191,889–198,106) | 133,111 (126,255–138,319) | node:http | 1.47× | PASS |  | [2] |
| 21b-p99 | 100 KB garbage per request, max rate: p99 | p99_ms (↓) | 1.22 (1.2–1.26) | 1.34 (1.06–1.83) | node:http | 1.10× | PASS |  | [2] |
| 21c | 10 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 0.321 (0.315–0.354) | 0.347 (0.295–0.445) | node:http | 1.08× | PASS |  | [2] |
| 22 | p99.9 at a light 10k req/s | p999_ms (↓) | 0.247 (0.205–0.335) | 0.271 (0.183–0.331) | node:http | 1.10× | PASS |  | [2] |
| 23a | New connection per request, 100 clients | rps (↑) | 33,981 (33,419–34,299) | 33,334 (33,199–33,408) | node:http | 1.02× | PASS | facil:errors, node:errors | [1] |
| 23b | New connection per request, 10 clients | rps (↑) | 34,365 (32,539–35,178) | 34,562 (30,479–35,943) | node:http | 0.99× | FAIL |  | [1] |
| 24a | Upload 10 MB, default body handling (no spooling) | rps (↑) | 926 (899–958) | 699 (675–711) | node:http | 1.32× | PASS |  | [1] |
| 24b | Upload 100 MB, default body handling (no spooling) | rps (↑) | 116 (115–116) | 76.3 (76–77.3) | node:http | 1.52× | PASS |  | [1] |
| 25 | Upload 1 MB streamed through a task: requests per server CPU-second | req_per_cpu_s (↑) | 8,484 (8,448–8,549) | 11,433 (11,119–11,483) | node:http | 0.74× | EXCEPTION |  | [4] |
| 26 | WebSocket broadcast, 10,000 subscribers x 100 Hz | deliveries_per_s (↑) | 200,091 (155,504–229,910) | 213,212 (163,857–228,051) | uWebSockets.js | 0.94× | EXCEPTION | facil:errors, node:errors | [3] |
| 27 | Streamed gzip of 100 KB JSON | rps (↑) | 10,523 (10,396–10,727) | 6,297 (6,217–6,468) | node:http | 1.67× | PASS |  | [4] |
| 28a | Whole response 32 KB (gather-write) | rps (↑) | 152,256 (151,424–153,173) | 107,072 (106,219–107,509) | node:http | 1.42× | PASS | facil:client | [1] |
| 28b | Whole response 100 KB (gather-write) | rps (↑) | 89,248 (88,683–89,515) | 73,109 (72,917–73,568) | node:http | 1.22× | PASS | facil:client | [1] |
| 29 | Whole response 1 MB (gather-write) | rps (↑) | 6,541 (6,523–6,559) | 6,556 (6,431–6,569) | node:http | 1.00× | FAIL | facil:client, node:client | [1] |
| 30a | Brotli level 4, 100 KB JSON, on the event loop | rps (↑) | 3,317 (3,304–3,331) | 3,150 (3,147–3,151) | node:http | 1.05× | PASS |  | [1] |
| 30b | zstd level 3, 100 KB JSON, on the event loop | rps (↑) | 9,224 (9,217–9,235) | 8,425 (8,423–8,427) | node:http | 1.09× | PASS |  | [1] |
| 31-p99 | Task handler at 10k req/s: p99 | p99_ms (↓) | 0.173 (0.172–0.224) | 0.142 (0.14–0.147) | node:http | 0.82× | EXCEPTION |  | [4] |
| 31-cpu | Task handler at 10k req/s: server cores used | server_cores (↓) | 0.179 (0.175–0.179) | 0.147 (0.143–0.148) | node:http | 0.82× | EXCEPTION |  | [4] |
| 32 | Longest single pause at 10k req/s, no garbage | max_ms (↓) | 4.67 (3.64–5.06) | 3.96 (2.1–4.5) | node:http | 0.85× | EXCEPTION |  | [2] |

### Failing rows

| Row | What | Ratio |
|---|---|---|
| A7 | CPU-bound handler, 2 cores, against Node `cluster` | 0.98× |
| A14 | WebSocket broadcast, 1,000 subscribers × 1,000 Hz, against uWebSockets.js | 0.97× |
| 7-c1000 | WebSocket echo 256 KB, 1,000 connections, against uWebSockets.js | 0.99× |
| 23b | New connection per request, 10 clients | 0.99× |
| 29 | Whole response 1 MB (gather-write) | 1.00× (0.998) |

All five are within 4% of Node, and A7, A14 and 29 were at or above 1.0× in other
both-side runs on 25 November 2026 (A7 1.03×, A14 1.00×, 29 1.02× in
`results/20261125-120653`).

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

- A17 (10,000 keep-alive connections): Facil's three runs ranged from 79,714 to
  289,752 req/s and some saw errors; treat the 2.10× median with caution.
- Row 20 runs a task-handler server on one Julia thread. With one thread Facil
  runs handlers inline, so this row measures inline handlers.

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

Requests per second, median of 3 runs [5].

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

Result directories are not kept in the repository. `bench/scoreboard/chart_data.csv`
holds every number above (`python3 bench/scoreboard/chart.py data` rebuilds it from
the result directories below), and `bench/scoreboard/RESULTS.md` holds the full run
and the GC verification run as printed by the driver.

1. `bench/scoreboard/results/20261125-094221/table.md`: full run, all rows (runs per cell: 3; sides: both; machine: 15 cores; node v22.23.2)
2. `bench/scoreboard/results/20261125-115157/table.md`: rows 19, 19a, 21a–22, 32 with `JULIA_NUM_GC_THREADS=4`
3. `bench/scoreboard/results/20261125-163117/table.md` (7*, 8, 26) and `20261125-171547/table.md` (A1, A15c, A17, A26, 1, 2, 3): verification after the WebSocket and HTTP fixes
4. `bench/scoreboard/results/20261125-164821/table.md` (A11, 4, 25, 27, 31), `20261125-165520/table.md` (17a–18b, 20) and `20261125-170441/table.md` (6a–6c): verification after the task-pool fixes
5. Validation run, not in the repository: `v3_speed/results/table.txt` in the planning session's scratch directory (rows `tiny`, `json`, `json12h`, `large`, client `c100w4`; Facil column `facil-c`).
