# Scoreboard results

Result directories (`results/<timestamp>/`) are not kept in the repository. This file keeps the latest full run
and the verification run that decided the GC exceptions. Verdicts are re-read against the approved exceptions in
`rows.json` (EXCEPTION = under target on a row with an approved exception).

Latest full run, 20261125-094221: 70 PASS, 12 FAIL, 18 EXCEPTION. It ran before `JULIA_NUM_GC_THREADS=4` became the default.

## Facil.jl vs Node.js scoreboard — 20261125-094221

runs per cell: 3; sides: both; machine: 15 cores; node v22.23.2

Cells: median (min–max). ratio = facil/node for higher-is-better metrics, node/facil for lower-is-better, so >1 favours facil.
Flags: client = load client reached 90% of its cores (number is a lower bound); busy = machine under the idle bar before a run (verdict NOISY); errors = non-2xx/reset/stuck responses seen.

| row | name | metric | facil | node | ratio | target | verdict | opponent | node (validation) | flags |
|---|---|---|---|---|---|---|---|---|---|---|
| A1 | Tiny reply, 1 core | rps (↑) | 246,006 (243,901–248,050) | 179,029 (176,986–181,032) | 1.37× | ≥1.0 | PASS | node:http | 164,000 |  |
| A2 | 150-byte JSON, 1 core | rps (↑) | 237,781 (237,309–238,001) | 161,129 (160,669–162,014) | 1.48× | ≥1.0 | PASS | node:http | 146,000 |  |
| A3 | POST echo | rps (↑) | 218,288 (217,806–219,315) | 139,026 (137,560–139,558) | 1.57× | ≥1.0 | PASS | node:http | 133,000 |  |
| A4 | 100 KB response | rps (↑) | 111,611 (111,108–111,706) | 87,291 (87,042–87,694) | 1.28× | ≥1.0 | PASS | node:http | 78,182 |  |
| A5 | 1 MB response | rps (↑) | 16,909 (16,899–16,924) | 16,219 (16,082–16,233) | 1.04× | ≥1.0 | PASS | node:http | 9,100 |  |
| A6 | CPU-bound handler (FNV 3x16 KB), 1 core | rps (↑) | 17,128 (17,053–17,133) | 17,122 (16,859–17,753) | 1.00× | ≥1.0 | PASS | node:http | 15,900 |  |
| A7 | CPU-bound handler, 2 cores | rps (↑) | 35,731 (35,710–35,739) | 36,278 (36,180–36,313) | 0.985× | ≥1.0 | FAIL | cluster W=2 | 36,619 |  |
| A8 | CPU-bound handler, 4 cores | rps (↑) | 69,330 (69,296–69,355) | 64,236 (64,223–64,244) | 1.08× | ≥1.0 | PASS | cluster W=4 | 65,899 |  |
| A9 | 1M requests, 10 per connection (client resets) | rps (↑) | 188,361 (187,903–189,057) | 149,197 (147,878–149,715) | 1.26× | ≥1.0 | PASS | node:http | 150,966 |  |
| A9-p99 | 1M requests, 10 per connection: p99 | p99_ms (↓) | 1.21 (1.15–1.21) | 6.16 (6.09–6.16) | 5.09× | ≥1.0 | PASS | node:http | 5.95 |  |
| A10 | 10,000 keep-alive connections: server CPU per request | cpu_us_per_req (↓) | 6.01 (4.74–6.17) | 8.22 (8.18–8.26) | 1.37× | ≥1.0 | PASS | node:http | 9.92 | facil:errors |
| A11 | gzip responses (100 KB JSON, level 6, off the event loop) | rps (↑) | 10,596 (10,481–10,631) | 7,771 (7,743–7,773) | 1.36× | ≥1.0 | PASS | node:http | 7,614 |  |
| A12a | Upload 1 KB, in memory | rps (↑) | 205,291 (203,947–206,127) | 140,637 (140,146–140,989) | 1.46× | ≥1.0 | PASS | node:http | 143,185 |  |
| A12b | Upload 64 KB, in memory | rps (↑) | 112,278 (111,994–112,350) | 72,584 (72,211–72,642) | 1.55× | ≥1.0 | PASS | node:http | 72,813 |  |
| A12c | Upload 1 MB, in memory | rps (↑) | 11,904 (11,892–12,000) | 9,644 (9,574–9,693) | 1.23× | ≥1.0 | PASS | node:http | 9,797 |  |
| A13a | TLS handshakes, ECDSA full, 10 clients | rps (↑) | 7,299 (7,216–7,309) | 6,857 (6,786–6,872) | 1.06× | ≥1.0 | PASS | node:https | 6,267 |  |
| A13b | TLS handshakes, RSA full, 10 clients | rps (↑) | 2,282 (2,260–2,285) | 2,221 (2,219–2,226) | 1.03× | ≥1.0 | PASS | node:https | 2,270 |  |
| A13c | TLS handshakes, RSA resumed, 10 clients | rps (↑) | 8,229 (8,142–8,238) | 8,031 (8,023–8,067) | 1.02× | ≥1.0 | PASS | node:https | 7,552 |  |
| A14 | WebSocket broadcast, 1,000 subscribers x 1,000 Hz | deliveries_per_s (↑) | 968,013 (764,709–999,976) | 999,971 (999,796–1,000,000) | 0.968× | ≥1.0 | FAIL | uWebSockets.js | 674,104 |  |
| A15a | Streaming 10 x 1 KB chunks, no delay, 50 conns | rps (↑) | 168,405 (168,384–169,003) | 92,992 (92,011–93,024) | 1.81× | ≥1.0 | PASS | node:http | 73,323 | facil:client |
| A15b | Streaming 100 x 16 KB chunks, no delay | rps (↑) | 3,905 (3,902–3,906) | 3,877 (3,865–3,883) | 1.01× | ≥1.0 | PASS | node:http | 3,947 | facil:client, node:client |
| A15c | Streaming 10 x 1 MB chunks, no delay | rps (↑) | 751 (748–751) | 752 (750–753) | 0.999× | ≥1.0 | FAIL | node:http | 575 | facil:client, node:client |
| A16 | Keep-alive, 1,000 connections | rps (↑) | 222,037 (219,850–225,363) | 141,560 (140,286–142,650) | 1.57× | ≥1.0 | PASS | node:http | 139,607 |  |
| A17 | Keep-alive, 10,000 connections | rps (↑) | 118,999 (115,801–217,762) | 123,839 (123,456–124,764) | 0.961× | ≥1.0 | FAIL | node:http | 86,667 | facil:errors |
| A18 | Keep-alive, 5,000 connections: p99 | p99_ms (↓) | 26.9 (26.3–27.0) | 58.7 (58.2–59.0) | 2.19× | ≥1.0 | PASS | node:http | 1,657 |  |
| A19a | 2 request headers | rps (↑) | 217,614 (216,741–218,800) | 152,558 (152,516–153,263) | 1.43× | ≥1.0 | PASS | node:http | 150,515 |  |
| A19b | 12 request headers | rps (↑) | 181,567 (181,416–185,140) | 121,380 (121,329–123,602) | 1.50× | ≥1.0 | PASS | node:http | 119,632 |  |
| A19c | 40 request headers | rps (↑) | 102,924 (98,491–103,631) | 66,218 (66,214–66,700) | 1.55× | ≥1.0 | PASS | node:http | 66,326 |  |
| A19d | 100 request headers | rps (↑) | 33,485 (33,331–33,657) | 32,546 (31,214–32,944) | 1.03× | ≥1.0 | PASS | node:http | 33,126 |  |
| A19e | 4 KB cookie | rps (↑) | 198,226 (191,994–200,895) | 140,593 (138,087–143,630) | 1.41× | ≥1.0 | PASS | node:http | 144,787 |  |
| A19f | 2 KB query string, parsed | rps (↑) | 39,287 (38,685–39,730) | 37,068 (36,351–37,347) | 1.06× | ≥1.0 | PASS | node:http | 35,348 |  |
| A20a | Pipelining depth 1 | rps (↑) | 233,642 (232,048–234,119) | 161,553 (160,943–162,057) | 1.45× | ≥1.0 | PASS | node:http | 125,946 | facil:client |
| A20b | Pipelining depth 4 | rps (↑) | 348,049 (343,500–351,870) | 222,951 (220,190–224,800) | 1.56× | ≥1.0 | PASS | node:http | 157,706 |  |
| A20c | Pipelining depth 16 | rps (↑) | 373,962 (372,646–377,600) | 245,715 (245,616–247,430) | 1.52× | ≥1.0 | PASS | node:http | 171,229 |  |
| A21 | Fixed 50k req/s: p99 | p99_ms (↓) | 0.0553 (0.0551–0.0558) | 0.0605 (0.0605–0.0606) | 1.09× | ≥1.0 | PASS | node:http | 0.082 |  |
| A22 | Fixed 100k req/s: p99 | p99_ms (↓) | 0.0499 (0.0496–0.0513) | 0.082 (0.0813–0.083) | 1.64× | ≥1.0 | PASS | node:http | 2.37 |  |
| A24 | JSON parse 1 KB POST | rps (↑) | 134,780 (133,647–136,120) | 111,431 (110,949–112,196) | 1.21× | ≥1.0 | PASS | node:http | 94,806 |  |
| A25a | Float sum handler (1e5 floats) | rps (↑) | 88,119 (87,431–88,492) | 15,407 (15,328–15,486) | 5.72× | ≥1.0 | PASS | node:http | 13,623 |  |
| A25b | FNV-1a over 4 KB handler | rps (↑) | 129,581 (129,451–129,656) | 102,904 (102,850–103,162) | 1.26× | ≥1.0 | PASS | node:http | 80,922 |  |
| A26 | Task-based tiny handler, 4 Julia threads | rps (↑) | 213,184 (213,098–215,253) | 183,183 (181,825–183,575) | 1.16× | ≥1.0 | PASS | node:http | 127,616 |  |
| A27 | HTTPS JSON, keep-alive | rps (↑) | 156,251 (154,998–157,322) | 130,859 (129,202–130,945) | 1.19× | ≥1.0 | PASS | node:https | 130,803 |  |
| A28 | Memory per idle WebSocket (10,000 open) | bytes_per_conn (↓) | 285 (280–331) | 629 (628–639) | 2.21× | ≥1.0 | PASS | uWebSockets.js | 629 |  |
| A29 | WebSocket echo 64 B, 100 connections | msgs_per_s (↑) | 282,130 (281,616–282,168) | 279,283 (279,186–279,512) | 1.01× | ≥1.0 | PASS | uWebSockets.js | 266,428 |  |
| A30 | WebSocket echo 64 B, 100 connections, vs ws | msgs_per_s (↑) | 282,130 (281,616–282,168) | 220,829 (217,486–222,582) | 1.28× | ≥1.0 | PASS | ws | 208,438 |  |
| 1 | CPU-bound handler, 8 cores | rps (↑) | 126,025 (125,880–126,178) | 123,511 (122,036–124,298) | 1.02× | ≥1.0 | PASS | cluster W=8 | 126,001 |  |
| 2 | Tiny reply (JSON), 4 cores | rps (↑) | 188,512 (188,352–189,165) | 180,387 (180,262–180,679) | 1.05× | ≥1.0 | PASS | cluster W=4 | 178,490 |  |
| 3 | Tiny reply (JSON), 8 cores | rps (↑) | 170,554 (170,172–171,600) | 168,574 (168,436–168,611) | 1.01× | ≥1.0 | PASS | cluster W=8 | 169,429 |  |
| 4 | Async (task) handler, tiny reply, 1 reactor + 2 Julia threads | rps (↑) | 225,109 (224,667–226,086) | 157,042 (154,978–157,167) | 1.43× | ≥1.0 | PASS | node:http | 158,795 |  |
| 5a | HTTPS 100 KB, no-copy body | rps (↑) | 37,681 (37,345–37,700) | 30,140 (30,027–30,591) | 1.25× | ≥1.0 | PASS | node:https | 30,176 |  |
| 5b | HTTPS 1 MB, no-copy body | rps (↑) | 4,702 (4,656–4,710) | 4,104 (3,861–4,129) | 1.15× | ≥1.0 | PASS | node:https | 4,066 |  |
| 6a | Paced streaming from a Julia task, 10 x 1 KB, 1 ms apart | rps (↑) | 18,872 (17,929–19,043) | 8,590 (8,534–9,127) | 2.20× | ≥1.0 | PASS | node:http | 7,231 |  |
| 6b | Paced streaming from a Julia task, 100 x 16 KB, 1 ms apart | rps (↑) | 1,760 (1,689–1,812) | 833 (833–867) | 2.11× | ≥1.0 | PASS | node:http | 700 | facil:client |
| 6c | Paced streaming from a Julia task, 1000 x 1 KB, 1 ms apart | rps (↑) | 183 (183–183) | 66.7 (66.7–83.3) | 2.75× | ≥1.0 | PASS | node:http | 66.7 |  |
| 7-c10 | WebSocket echo 256 KB, 10 connections | msgs_per_s (↑) | 35,490 (32,616–36,006) | 35,520 (35,208–35,797) | 0.999× | ≥1.0 | EXCEPTION | uWebSockets.js | 36,177 |  |
| 7-c100 | WebSocket echo 256 KB, 100 connections | msgs_per_s (↑) | 29,683 (25,606–30,038) | 30,054 (27,091–30,189) | 0.988× | ≥1.0 | FAIL | uWebSockets.js | 29,448 |  |
| 7-c1000 | WebSocket echo 256 KB, 1000 connections | msgs_per_s (↑) | 18,064 (17,080–18,212) | 16,145 (15,518–19,285) | 1.12× | ≥1.0 | PASS | uWebSockets.js | 20,230 |  |
| 7b-64 | WebSocket echo 64 B, 10 connections | msgs_per_s (↑) | 233,625 (219,688–244,953) | 241,786 (238,109–241,852) | 0.966× | ≥1.0 | FAIL | uWebSockets.js | 248,612 |  |
| 7b-1k | WebSocket echo 1 KB, 10 connections | msgs_per_s (↑) | 238,681 (237,069–240,242) | 233,710 (225,206–235,732) | 1.02× | ≥1.0 | PASS | uWebSockets.js | 246,611 |  |
| 7b-16k | WebSocket echo 16 KB, 10 connections | msgs_per_s (↑) | 179,430 (175,897–185,412) | 170,236 (167,608–188,447) | 1.05× | ≥1.0 | PASS | uWebSockets.js | 188,787 |  |
| 8 | WebSocket permessage-deflate, 4 KB JSON echo, 100 connections | msgs_per_s (↑) | 58,304 (55,659–59,624) | 55,009 (54,435–56,068) | 1.06× | ≥1.0 | PASS | uWebSockets.js | 56,286 |  |
| 9 | 10 MB chunked upload, buffered | rps (↑) | 686 (656–725) | 501 (459–508) | 1.37× | ≥1.0 | PASS | node:http | 495 |  |
| 10 | Memory, idle | rss_mb (↓) | 384 (383–384) | 50.7 (50.7–50.9) | 0.132× | ≥1.0 | EXCEPTION | node:http | 44.7 |  |
| 10-sysimg | Memory, idle (Facil: PackageCompiler sysimage, /json-only server) | rss_mb (↓) | 324 (324–324) | 50.7 (50.7–50.9) | 0.156× | ≥1.0 | EXCEPTION | node:http | 44.7 |  |
| 11 | Memory, 10,000 keep-alive connections under load | rss_max_mb (↓) | 449 (441–449) | 248 (221–269) | 0.552× | ≥1.0 | EXCEPTION | node:http | 223 | facil:errors |
| 12 | Start-up to first response | startup_ms (↓) | 764 (764–767) | 27.4 (27.4–30.6) | 0.0359× | ≥1.0 | EXCEPTION | node:http | 31.3 |  |
| 12-sysimg | Start-up to first response (Facil: PackageCompiler sysimage, /json-only server) | startup_ms (↓) | 314 (313–317) | 27.4 (27.4–30.6) | 0.0873× | ≥1.0 | EXCEPTION | node:http | 31.3 |  |
| 12-json | Start-up to first response (Facil: plain julia, /json-only server) | startup_ms (↓) | 448 (447–450) | 27.4 (27.4–30.6) | 0.0612× | ≥1.0 | EXCEPTION | node:http | 31.3 |  |
| 13 | First request | first_req_ms (↓) | 318 (317–319) | 2.06 (2.01–2.39) | 0.00648× | ≥1.0 | EXCEPTION | node:http | 2.42 |  |
| 13-sysimg | First request (Facil: PackageCompiler sysimage, /json-only server) | first_req_ms (↓) | 6.92 (6.67–6.99) | 2.06 (2.01–2.39) | 0.298× | ≥1.0 | EXCEPTION | node:http | 2.42 |  |
| 13-json | First request (Facil: plain julia, /json-only server) | first_req_ms (↓) | 4.93 (4.89–5.94) | 2.06 (2.01–2.39) | 0.418× | ≥1.0 | EXCEPTION | node:http | 2.42 |  |
| 14 | 200 slow-header connections (slowloris), held after 150 s | held (↓) | 0 (0–0) | 0 (0–0) | 1.00× | ≥1.0 | PASS | node:http | 0 |  |
| 15 | 200 slow readers of 8 x 1 MB: RSS growth | rss_growth_mb (↓) | 2.30 (1.90–2.70) | 10.0 (9.30–11.1) | 4.35× | ≥1.0 | PASS | node:http | 6.20 |  |
| 17a | Handler waits 1 ms (Facil.sleep), 100 connections | rps (↑) | 89,085 (88,417–89,220) | 59,689 (59,009–59,752) | 1.49× | ≥1.0 | PASS | node:http | 48,600 |  |
| 17b | Handler waits 1 ms (Facil.sleep), 1000 connections | rps (↑) | 144,578 (134,486–145,379) | 133,736 (125,306–135,750) | 1.08× | ≥1.0 | PASS | node:http | 145,680 |  |
| 18a | Handler waits 10 ms (Facil.sleep), 100 connections | rps (↑) | 9,747 (9,743–9,778) | 8,311 (8,276–8,385) | 1.17× | ≥1.0 | PASS | node:http | 7,545 |  |
| 18b | Handler waits 10 ms (Facil.sleep), 1000 connections | rps (↑) | 97,766 (97,735–97,779) | 83,085 (83,063–83,096) | 1.18× | ≥1.0 | PASS | node:http | 81,000 |  |
| 19 | Build a 50 KB JSON response | rps (↑) | 2,329 (2,327–2,339) | 12,309 (12,248–12,318) | 0.189× | ≥1.0 | EXCEPTION | node:http | 12,266 |  |
| 19a | Build a 1 KB JSON response | rps (↑) | 69,314 (66,985–69,867) | 130,005 (123,614–130,158) | 0.533× | ≥1.0 | EXCEPTION | node:http | 96,768 |  |
| 20 | Task-based handler on 1 Julia thread | rps (↑) | 240,814 (239,743–241,526) | 183,183 (181,825–183,575) | 1.31× | ≥1.0 | PASS | node:http | 127,616 | facil:client |
| 21a-p99 | 100 KB garbage per request at 10k req/s: p99 | p99_ms (↓) | 1.95 (1.90–2.14) | 0.159 (0.144–0.192) | 0.0815× | ≥1.0 | EXCEPTION | node:http | 0.145 |  |
| 21a-p999 | 100 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 6.51 (6.26–6.58) | 0.369 (0.207–0.436) | 0.0567× | ≥1.0 | EXCEPTION | node:http | 0.24 |  |
| 21b | 100 KB garbage per request, max rate | rps (↑) | 185,751 (184,763–185,991) | 138,812 (132,280–140,078) | 1.34× | ≥1.0 | PASS | node:http | 138,000 |  |
| 21b-p99 | 100 KB garbage per request, max rate: p99 | p99_ms (↓) | 2.09 (2.07–2.17) | 0.892 (0.887–1.72) | 0.426× | ≥1.0 | FAIL | node:http | 0.839 |  |
| 21c | 10 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 0.242 (0.23–0.26) | 0.169 (0.155–0.171) | 0.697× | ≥1.0 | FAIL | node:http | 0.164 |  |
| 22 | p99.9 at a light 10k req/s | p999_ms (↓) | 0.594 (0.245–0.826) | 0.321 (0.148–0.496) | 0.541× | ≥1.0 | FAIL | node:http | 0.262 |  |
| 23a | New connection per request, 100 clients | rps (↑) | 33,981 (33,419–34,299) | 33,334 (33,199–33,408) | 1.02× | ≥1.0 | PASS | node:http | 36,742 | facil:errors, node:errors |
| 23b | New connection per request, 10 clients | rps (↑) | 34,365 (32,539–35,178) | 34,562 (30,479–35,943) | 0.994× | ≥1.0 | FAIL | node:http | 36,032 |  |
| 24a | Upload 10 MB, default body handling (no spooling) | rps (↑) | 926 (899–958) | 699 (675–711) | 1.33× | ≥1.0 | PASS | node:http | 720 |  |
| 24b | Upload 100 MB, default body handling (no spooling) | rps (↑) | 116 (115–116) | 76.3 (76.0–77.3) | 1.52× | ≥1.0 | PASS | node:http | 75.2 |  |
| 25 | Upload 1 MB streamed through a task: requests per server CPU-second | req_per_cpu_s (↑) | 7,898 (7,826–7,907) | 12,761 (12,706–12,834) | 0.619× | ≥1.0 | EXCEPTION | node:http | 12,853 |  |
| 26 | WebSocket broadcast, 10,000 subscribers x 100 Hz | deliveries_per_s (↑) | 207,549 (206,133–231,565) | 180,948 (168,982–267,500) | 1.15× | ≥1.0 | PASS | uWebSockets.js | 206,142 | facil:errors, node:errors |
| 27 | Streamed gzip of 100 KB JSON | rps (↑) | 2,821 (2,813–2,823) | 6,775 (6,645–6,913) | 0.416× | ≥1.0 | FAIL | node:http | 6,583 |  |
| 28a | Whole response 32 KB (gather-write) | rps (↑) | 152,256 (151,424–153,173) | 107,072 (106,219–107,509) | 1.42× | ≥1.0 | PASS | node:http | 81,760 | facil:client |
| 28b | Whole response 100 KB (gather-write) | rps (↑) | 89,248 (88,683–89,515) | 73,109 (72,917–73,568) | 1.22× | ≥1.0 | PASS | node:http | 60,560 | facil:client |
| 29 | Whole response 1 MB (gather-write) | rps (↑) | 6,541 (6,523–6,559) | 6,556 (6,431–6,569) | 0.998× | ≥1.0 | FAIL | node:http | 6,575 | facil:client, node:client |
| 30a | Brotli level 4, 100 KB JSON, on the event loop | rps (↑) | 3,317 (3,304–3,331) | 3,150 (3,147–3,151) | 1.05× | ≥1.0 | PASS | node:http | 3,169 |  |
| 30b | zstd level 3, 100 KB JSON, on the event loop | rps (↑) | 9,224 (9,217–9,235) | 8,425 (8,423–8,427) | 1.09× | ≥1.0 | PASS | node:http | 8,197 |  |
| 31-p99 | Task handler at 10k req/s: p99 | p99_ms (↓) | 0.167 (0.167–0.167) | 0.139 (0.139–0.14) | 0.835× | ≥1.0 | EXCEPTION | node:http | 0.145 |  |
| 31-cpu | Task handler at 10k req/s: server cores used | server_cores (↓) | 0.166 (0.165–0.166) | 0.142 (0.142–0.143) | 0.859× | ≥1.0 | EXCEPTION | node:http | 0.15 |  |
| 32 | Longest single pause at 10k req/s, no garbage | max_ms (↓) | 8.99 (8.27–10.9) | 1.89 (0.352–2.49) | 0.21× | ≥1.0 | EXCEPTION | node:http | 1.60 |  |

## GC verification, 20261125-115157

Rows 21a–22 and 32 with `JULIA_NUM_GC_THREADS=4` (now the scoreboard default). 21a-p99, 21a-p999 and 32 stayed under
target and became approved exceptions.

| row | name | metric | facil | node | ratio | target | verdict | opponent | node (validation) | flags |
|---|---|---|---|---|---|---|---|---|---|---|
| 19 | Build a 50 KB JSON response | rps (↑) | 2,402 (2,332–2,406) | 12,410 (11,396–12,427) | 0.194× | ≥1.0 | EXCEPTION | node:http | 12,266 |  |
| 19a | Build a 1 KB JSON response | rps (↑) | 69,271 (69,255–69,372) | 131,376 (130,560–131,661) | 0.527× | ≥1.0 | EXCEPTION | node:http | 96,768 |  |
| 21a-p99 | 100 KB garbage per request at 10k req/s: p99 | p99_ms (↓) | 0.223 (0.207–0.248) | 0.142 (0.141–0.142) | 0.637× | ≥1.0 | EXCEPTION | node:http | 0.145 |  |
| 21a-p999 | 100 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 2.92 (2.66–3.04) | 0.156 (0.155–0.177) | 0.0536× | ≥1.0 | EXCEPTION | node:http | 0.24 |  |
| 21b | 100 KB garbage per request, max rate | rps (↑) | 195,378 (191,889–198,106) | 133,111 (126,255–138,319) | 1.47× | ≥1.0 | PASS | node:http | 138,000 |  |
| 21b-p99 | 100 KB garbage per request, max rate: p99 | p99_ms (↓) | 1.22 (1.20–1.26) | 1.34 (1.06–1.83) | 1.10× | ≥1.0 | PASS | node:http | 0.839 |  |
| 21c | 10 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 0.321 (0.315–0.354) | 0.347 (0.295–0.445) | 1.08× | ≥1.0 | PASS | node:http | 0.164 |  |
| 22 | p99.9 at a light 10k req/s | p999_ms (↓) | 0.247 (0.205–0.335) | 0.271 (0.183–0.331) | 1.10× | ≥1.0 | PASS | node:http | 0.262 |  |
| 32 | Longest single pause at 10k req/s, no garbage | max_ms (↓) | 4.67 (3.64–5.06) | 3.96 (2.10–4.50) | 0.847× | ≥1.0 | EXCEPTION | node:http | 1.60 |  |
