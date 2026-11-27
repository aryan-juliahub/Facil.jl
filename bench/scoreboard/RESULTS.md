# Scoreboard results

Result directories (`results/<timestamp>/`) are not kept in the repository. This file keeps the numbers the README
and the docs quote, the full run they come from, the rerun that checked every changed verdict, and the
one-GC-thread variant. Verdicts are read against the approved exceptions in `rows.json` (EXCEPTION = under target
on a row with an approved exception).

**72 PASS, 9 FAIL, 19 EXCEPTION** (26 November 2026, code at `59c06d9`). The previous published numbers
(25 November 2026) were 76 PASS, 5 FAIL, 19 EXCEPTION.

Sources:

1. `20261126-212620`: full run, all rows, both sides, 3 runs per cell, `JULIA_NUM_GC_THREADS=4` (the default).
2. `20261126-234001`: rerun, both sides, 3 runs, of every row whose verdict in [1] differed from the published
   numbers (A6, A7, A14, A15c, A19d, 7-c100, 21b-p99, 21c, 22, 23a, 23b, 26, 29), plus A17, 25, 32 and the
   start-up rows, which moved most. Where a row is in both, [2] is used.
3. `20261127-000804`: the GC-sensitive rows with `JULIA_NUM_GC_THREADS=1`, both sides (not used in the totals).
4. `20261127-064501`: the start-up rows 12, 12-sysimg and 12-json, both sides, 3 runs, after `serve!` moved its
   keyword handling into precompiled code (sysimage rebuilt). The same rows on `ea172cc` that morning, Facil side:
   868, 411, 571 ms (`20261127-064547`).

Machine: Apple M5 Pro, 15 cores, macOS, on AC power, Spotlight indexing off, no sleep during the runs (checked
with `pmset -g log`). Julia 1.13.0, Node v22.23.2. No Facil server crashed in any run.

## Published numbers

| Row | Name | Metric | Facil | Node | Node opponent | Ratio | Verdict | Flags | Run |
|---|---|---|---|---|---|---|---|---|---|
| A1 | Tiny reply, 1 core | rps (↑) | 248,626 (243,783–250,633) | 179,610 (179,593–180,785) | node:http | 1.38× | PASS |  | [1] |
| A2 | 150-byte JSON, 1 core | rps (↑) | 231,505 (224,879–233,091) | 158,620 (156,310–160,103) | node:http | 1.46× | PASS |  | [1] |
| A3 | POST echo | rps (↑) | 214,696 (213,187–214,894) | 136,737 (132,307–137,078) | node:http | 1.57× | PASS |  | [1] |
| A4 | 100 KB response | rps (↑) | 108,805 (98,797–110,992) | 85,383 (80,905–86,385) | node:http | 1.27× | PASS |  | [1] |
| A5 | 1 MB response | rps (↑) | 16,454 (16,161–16,641) | 15,899 (15,609–16,056) | node:http | 1.03× | PASS |  | [1] |
| A6 | CPU-bound handler (FNV 3x16 KB), 1 core | rps (↑) | 17,049 (17,041–17,084) | 16,546 (16,294–16,615) | node:http | 1.03× | PASS |  | [2] |
| A7 | CPU-bound handler, 2 cores | rps (↑) | 35,970 (35,253–36,718) | 36,054 (35,882–36,126) | cluster W=2 | 0.998× | FAIL |  | [2] |
| A8 | CPU-bound handler, 4 cores | rps (↑) | 68,475 (68,325–68,576) | 62,980 (62,973–63,220) | cluster W=4 | 1.09× | PASS |  | [1] |
| A9 | 1M requests, 10 per connection (client resets) | rps (↑) | 186,781 (185,654–187,692) | 146,217 (144,476–146,395) | node:http | 1.28× | PASS |  | [1] |
| A9-p99 | 1M requests, 10 per connection: p99 | p99_ms (↓) | 1.24 (1.22–1.25) | 6.28 (6.25–6.29) | node:http | 5.07× | PASS |  | [1] |
| A10 | 10,000 keep-alive connections: server CPU per request | cpu_us_per_req (↓) | 5.33 (5.3–6.65) | 8.61 (8.52–8.71) | node:http | 1.61× | PASS | facil:errors | [1] |
| A11 | gzip responses (100 KB JSON, level 6, off the event loop) | rps (↑) | 11,936 (11,393–12,069) | 7,501 (7,494–7,671) | node:http | 1.59× | PASS |  | [1] |
| A12a | Upload 1 KB, in memory | rps (↑) | 205,115 (202,356–205,174) | 139,311 (139,222–139,399) | node:http | 1.47× | PASS |  | [1] |
| A12b | Upload 64 KB, in memory | rps (↑) | 98,315 (97,974–107,729) | 67,957 (66,011–68,498) | node:http | 1.45× | PASS |  | [1] |
| A12c | Upload 1 MB, in memory | rps (↑) | 12,452 (12,337–12,934) | 8,812 (8,209–9,075) | node:http | 1.41× | PASS |  | [1] |
| A13a | TLS handshakes, ECDSA full, 10 clients | rps (↑) | 7,153 (7,102–7,240) | 6,780 (6,698–6,791) | node:https | 1.05× | PASS |  | [1] |
| A13b | TLS handshakes, RSA full, 10 clients | rps (↑) | 2,281 (2,270–2,288) | 2,216 (2,215–2,225) | node:https | 1.03× | PASS |  | [1] |
| A13c | TLS handshakes, RSA resumed, 10 clients | rps (↑) | 8,079 (8,008–8,237) | 7,848 (7,580–8,050) | node:https | 1.03× | PASS |  | [1] |
| A14 | WebSocket broadcast, 1,000 subscribers x 1,000 Hz | deliveries_per_s (↑) | 999,968 (676,551–999,968) | 768,182 (437,995–999,809) | uWebSockets.js | 1.30× | PASS |  | [2] |
| A15a | Streaming 10 x 1 KB chunks, no delay, 50 conns | rps (↑) | 165,013 (162,987–165,269) | 90,197 (89,707–91,424) | node:http | 1.83× | PASS | facil:client | [1] |
| A15b | Streaming 100 x 16 KB chunks, no delay | rps (↑) | 3,756 (3,708–3,866) | 3,701 (3,530–3,729) | node:http | 1.01× | PASS | facil:client, node:client | [1] |
| A15c | Streaming 10 x 1 MB chunks, no delay | rps (↑) | 1,296 (1,201–1,361) | 1,328 (1,237–1,381) | node:http | 0.98× | FAIL |  | [2] |
| A16 | Keep-alive, 1,000 connections | rps (↑) | 212,510 (207,328–216,380) | 135,408 (132,048–136,524) | node:http | 1.57× | PASS |  | [1] |
| A17 | Keep-alive, 10,000 connections | rps (↑) | 170,352 (88,516–424,968) | 115,816 (115,276–117,874) | node:http | 1.47× | PASS | facil:errors | [2] |
| A18 | Keep-alive, 5,000 connections: p99 | p99_ms (↓) | 28.3 (28.1–31.7) | 61 (61–61.4) | node:http | 2.15× | PASS |  | [1] |
| A19a | 2 request headers | rps (↑) | 214,848 (210,463–219,614) | 151,081 (150,638–151,343) | node:http | 1.42× | PASS |  | [1] |
| A19b | 12 request headers | rps (↑) | 180,306 (180,011–186,451) | 119,792 (118,284–120,369) | node:http | 1.50× | PASS |  | [1] |
| A19c | 40 request headers | rps (↑) | 95,105 (95,045–98,583) | 64,912 (64,296–65,541) | node:http | 1.47× | PASS |  | [1] |
| A19d | 100 request headers | rps (↑) | 31,167 (30,608–32,198) | 31,900 (31,435–32,069) | node:http | 0.98× | FAIL |  | [2] |
| A19e | 4 KB cookie | rps (↑) | 196,719 (195,725–197,672) | 143,261 (142,799–144,003) | node:http | 1.37× | PASS |  | [1] |
| A19f | 2 KB query string, parsed | rps (↑) | 38,700 (38,274–39,465) | 37,382 (37,025–37,971) | node:http | 1.03× | PASS |  | [1] |
| A20a | Pipelining depth 1 | rps (↑) | 231,263 (230,771–232,768) | 159,188 (159,140–159,385) | node:http | 1.45× | PASS | facil:client | [1] |
| A20b | Pipelining depth 4 | rps (↑) | 345,916 (338,098–352,093) | 223,286 (222,736–225,238) | node:http | 1.55× | PASS |  | [1] |
| A20c | Pipelining depth 16 | rps (↑) | 374,122 (370,291–377,155) | 241,882 (238,646–243,757) | node:http | 1.55× | PASS |  | [1] |
| A21 | Fixed 50k req/s: p99 | p99_ms (↓) | 0.0594 (0.0584–0.0601) | 0.0687 (0.0626–0.0723) | node:http | 1.16× | PASS |  | [1] |
| A22 | Fixed 100k req/s: p99 | p99_ms (↓) | 0.0597 (0.0587–65.2) | 0.0925 (0.0885–27.1) | node:http | 1.55× | PASS |  | [1] |
| A24 | JSON parse 1 KB POST | rps (↑) | 133,121 (130,994–135,378) | 109,214 (107,541–110,322) | node:http | 1.22× | PASS |  | [1] |
| A25a | Float sum handler (1e5 floats) | rps (↑) | 87,259 (86,535–87,603) | 15,351 (15,084–15,664) | node:http | 5.68× | PASS |  | [1] |
| A25b | FNV-1a over 4 KB handler | rps (↑) | 126,767 (126,245–127,965) | 101,975 (101,765–102,417) | node:http | 1.24× | PASS |  | [1] |
| A26 | Task-based tiny handler, 4 Julia threads | rps (↑) | 209,930 (209,861–211,323) | 181,827 (179,144–181,830) | node:http | 1.16× | PASS |  | [1] |
| A27 | HTTPS JSON, keep-alive | rps (↑) | 156,651 (154,736–157,866) | 128,953 (126,732–129,398) | node:https | 1.22× | PASS |  | [1] |
| A28 | Memory per idle WebSocket (10,000 open) | bytes_per_conn (↓) | 303 (279–392) | 634 (626–637) | uWebSockets.js | 2.09× | PASS |  | [1] |
| A29 | WebSocket echo 64 B, 100 connections | msgs_per_s (↑) | 281,369 (280,595–281,951) | 276,838 (276,117–277,179) | uWebSockets.js | 1.02× | PASS |  | [1] |
| A30 | WebSocket echo 64 B, 100 connections, vs ws | msgs_per_s (↑) | 281,369 (280,595–281,951) | 215,912 (214,497–218,086) | ws | 1.30× | PASS |  | [1] |
| 1 | CPU-bound handler, 8 cores | rps (↑) | 125,159 (125,154–125,492) | 121,321 (120,253–123,312) | cluster W=8 | 1.03× | PASS |  | [1] |
| 2 | Tiny reply (JSON), 4 cores | rps (↑) | 186,603 (186,274–186,753) | 179,389 (179,282–179,790) | cluster W=4 | 1.04× | PASS |  | [1] |
| 3 | Tiny reply (JSON), 8 cores | rps (↑) | 171,092 (169,940–171,488) | 169,515 (169,293–169,678) | cluster W=8 | 1.01× | PASS |  | [1] |
| 4 | Async (task) handler, tiny reply, 1 reactor + 2 Julia threads | rps (↑) | 217,575 (216,386–219,195) | 153,190 (152,143–154,667) | node:http | 1.42× | PASS |  | [1] |
| 5a | HTTPS 100 KB, no-copy body | rps (↑) | 37,215 (36,890–37,244) | 29,855 (29,648–29,920) | node:https | 1.25× | PASS |  | [1] |
| 5b | HTTPS 1 MB, no-copy body | rps (↑) | 4,648 (4,644–4,687) | 4,018 (4,006–4,049) | node:https | 1.16× | PASS |  | [1] |
| 6a | Paced streaming from a Julia task, 10 x 1 KB, 1 ms apart | rps (↑) | 19,072 (19,016–19,096) | 8,227 (8,223–8,302) | node:http | 2.32× | PASS | facil:client | [1] |
| 6b | Paced streaming from a Julia task, 100 x 16 KB, 1 ms apart | rps (↑) | 1,874 (1,870–1,875) | 800 (800–833) | node:http | 2.34× | PASS | facil:client | [1] |
| 6c | Paced streaming from a Julia task, 1000 x 1 KB, 1 ms apart | rps (↑) | 183 (183–183) | 66.7 (66.7–66.7) | node:http | 2.74× | PASS |  | [1] |
| 7-c10 | WebSocket echo 256 KB, 10 connections | msgs_per_s (↑) | 36,428 (36,071–36,693) | 37,049 (36,895–37,609) | uWebSockets.js | 0.98× | EXCEPTION |  | [1] |
| 7-c100 | WebSocket echo 256 KB, 100 connections | msgs_per_s (↑) | 26,764 (26,520–26,828) | 26,850 (22,381–27,243) | uWebSockets.js | 0.997× | FAIL |  | [2] |
| 7-c1000 | WebSocket echo 256 KB, 1000 connections | msgs_per_s (↑) | 17,120 (15,015–18,086) | 18,412 (17,321–19,415) | uWebSockets.js | 0.93× | FAIL |  | [1] |
| 7b-64 | WebSocket echo 64 B, 10 connections | msgs_per_s (↑) | 249,904 (249,680–250,963) | 244,756 (244,554–245,058) | uWebSockets.js | 1.02× | PASS |  | [1] |
| 7b-1k | WebSocket echo 1 KB, 10 connections | msgs_per_s (↑) | 247,508 (247,305–248,023) | 240,894 (240,613–241,137) | uWebSockets.js | 1.03× | PASS |  | [1] |
| 7b-16k | WebSocket echo 16 KB, 10 connections | msgs_per_s (↑) | 187,787 (187,497–188,286) | 183,543 (182,685–184,285) | uWebSockets.js | 1.02× | PASS |  | [1] |
| 8 | WebSocket permessage-deflate, 4 KB JSON echo, 100 connections | msgs_per_s (↑) | 58,510 (58,408–58,568) | 54,616 (53,924–54,762) | uWebSockets.js | 1.07× | PASS |  | [1] |
| 9 | 10 MB chunked upload, buffered | rps (↑) | 697 (692–752) | 486 (486–495) | node:http | 1.43× | PASS |  | [1] |
| 10 | Memory, idle | rss_mb (↓) | 387 (387–390) | 51 (50.8–51.1) | node:http | 0.13× | EXCEPTION |  | [1] |
| 10-sysimg | Memory, idle (Facil: PackageCompiler sysimage, /json-only server) | rss_mb (↓) | 335 (335–335) | 51 (50.8–51.1) | node:http | 0.15× | EXCEPTION |  | [1] |
| 11 | Memory, 10,000 keep-alive connections under load | rss_max_mb (↓) | 433 (418–440) | 248 (230–289) | node:http | 0.57× | EXCEPTION | facil:errors | [1] |
| 12 | Start-up to first response | startup_ms (↓) | 701 (695–706) | 26.9 (26.4–28.2) | node:http | 0.038× | EXCEPTION |  | [4] |
| 12-sysimg | Start-up to first response (Facil: PackageCompiler sysimage, /json-only server) | startup_ms (↓) | 264 (264–333) | 26.9 (26.4–28.2) | node:http | 0.10× | EXCEPTION |  | [4] |
| 12-json | Start-up to first response (Facil: plain julia, /json-only server) | startup_ms (↓) | 427 (415–430) | 26.9 (26.4–28.2) | node:http | 0.063× | EXCEPTION |  | [4] |
| 13 | First request | first_req_ms (↓) | 310 (310–316) | 2.11 (2.05–2.14) | node:http | 0.0068× | EXCEPTION |  | [1] |
| 13-sysimg | First request (Facil: PackageCompiler sysimage, /json-only server) | first_req_ms (↓) | 5.2 (4.93–5.3) | 2.1 (2.09–2.13) | node:http | 0.40× | EXCEPTION |  | [2] |
| 13-json | First request (Facil: plain julia, /json-only server) | first_req_ms (↓) | 5.11 (4.99–5.61) | 2.1 (2.09–2.13) | node:http | 0.41× | EXCEPTION |  | [2] |
| 14 | 200 slow-header connections (slowloris), held after 150 s | held (↓) | 0 (0–0) | 0 (0–0) | node:http | 1.00× | PASS |  | [1] |
| 15 | 200 slow readers of 8 x 1 MB: RSS growth | rss_growth_mb (↓) | 2.5 (2.1–2.8) | 10.4 (8.8–10.6) | node:http | 4.16× | PASS |  | [1] |
| 17a | Handler waits 1 ms (Facil.sleep), 100 connections | rps (↑) | 85,941 (84,396–86,036) | 55,382 (55,372–55,836) | node:http | 1.55× | PASS |  | [1] |
| 17b | Handler waits 1 ms (Facil.sleep), 1000 connections | rps (↑) | 164,400 (159,274–172,488) | 124,145 (123,037–129,893) | node:http | 1.32× | PASS |  | [1] |
| 18a | Handler waits 10 ms (Facil.sleep), 100 connections | rps (↑) | 9,795 (9,756–9,800) | 7,624 (7,580–7,627) | node:http | 1.28× | PASS |  | [1] |
| 18b | Handler waits 10 ms (Facil.sleep), 1000 connections | rps (↑) | 96,309 (96,261–96,391) | 81,000 (79,721–81,088) | node:http | 1.19× | PASS |  | [1] |
| 19 | Build a 50 KB JSON response | rps (↑) | 2,333 (2,192–2,361) | 12,071 (11,185–12,155) | node:http | 0.19× | EXCEPTION |  | [1] |
| 19a | Build a 1 KB JSON response | rps (↑) | 67,053 (66,208–67,298) | 127,284 (125,974–127,944) | node:http | 0.53× | EXCEPTION |  | [1] |
| 20 | Task-based handler on 1 Julia thread | rps (↑) | 244,754 (243,000–245,741) | 181,827 (179,144–181,830) | node:http | 1.35× | PASS | facil:client | [1] |
| 21a-p99 | 100 KB garbage per request at 10k req/s: p99 | p99_ms (↓) | 0.229 (0.229–0.23) | 0.145 (0.144–0.145) | node:http | 0.63× | EXCEPTION |  | [1] |
| 21a-p999 | 100 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 2.94 (2.89–2.96) | 0.161 (0.16–0.161) | node:http | 0.055× | EXCEPTION |  | [1] |
| 21b | 100 KB garbage per request, max rate | rps (↑) | 195,114 (191,997–196,821) | 133,225 (130,872–134,420) | node:http | 1.47× | PASS |  | [2] |
| 21b-p99 | 100 KB garbage per request, max rate: p99 | p99_ms (↓) | 1.33 (1.32–1.35) | 0.943 (0.919–1.16) | node:http | 0.71× | FAIL |  | [2] |
| 21c | 10 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 0.274 (0.27–0.279) | 0.161 (0.157–0.191) | node:http | 0.59× | FAIL |  | [2] |
| 22 | p99.9 at a light 10k req/s | p999_ms (↓) | 0.189 (0.175–0.215) | 0.165 (0.159–0.204) | node:http | 0.87× | FAIL |  | [2] |
| 23a | New connection per request, 100 clients | rps (↑) | 34,188 (33,718–35,414) | 35,183 (33,637–36,815) | node:http | 0.97× | FAIL | facil:errors, node:errors | [2] |
| 23b | New connection per request, 10 clients | rps (↑) | 35,644 (35,143–35,750) | 34,900 (34,564–36,175) | node:http | 1.02× | PASS |  | [2] |
| 24a | Upload 10 MB, default body handling (no spooling) | rps (↑) | 990 (954–997) | 662 (651–668) | node:http | 1.50× | PASS |  | [1] |
| 24b | Upload 100 MB, default body handling (no spooling) | rps (↑) | 121 (120–122) | 73.3 (72.6–73.8) | node:http | 1.65× | PASS |  | [1] |
| 25 | Upload 1 MB streamed through a task: requests per server CPU-second | req_per_cpu_s (↑) | 2,431 (2,404–2,444) | 11,585 (11,493–12,260) | node:http | 0.21× | EXCEPTION |  | [2] |
| 26 | WebSocket broadcast, 10,000 subscribers x 100 Hz | deliveries_per_s (↑) | 192,679 (160,612–206,117) | 228,400 (193,176–235,306) | uWebSockets.js | 0.84× | EXCEPTION | facil:errors, node:errors | [2] |
| 27 | Streamed gzip of 100 KB JSON | rps (↑) | 11,257 (11,232–11,336) | 6,348 (6,279–6,509) | node:http | 1.77× | PASS |  | [1] |
| 28a | Whole response 32 KB (gather-write) | rps (↑) | 147,285 (146,091–147,904) | 103,605 (102,069–106,496) | node:http | 1.42× | PASS | facil:client | [1] |
| 28b | Whole response 100 KB (gather-write) | rps (↑) | 84,843 (83,968–85,579) | 70,219 (68,800–72,533) | node:http | 1.21× | PASS | facil:client | [1] |
| 29 | Whole response 1 MB (gather-write) | rps (↑) | 6,367 (6,213–6,395) | 6,343 (6,321–6,387) | node:http | 1.00× | PASS | facil:client, node:client | [2] |
| 30a | Brotli level 4, 100 KB JSON, on the event loop | rps (↑) | 3,330 (3,304–3,332) | 3,159 (3,073–3,166) | node:http | 1.05× | PASS |  | [1] |
| 30b | zstd level 3, 100 KB JSON, on the event loop | rps (↑) | 9,151 (9,131–9,193) | 8,299 (8,235–8,338) | node:http | 1.10× | PASS |  | [1] |
| 31-p99 | Task handler at 10k req/s: p99 | p99_ms (↓) | 0.171 (0.171–0.171) | 0.143 (0.142–0.143) | node:http | 0.84× | EXCEPTION |  | [1] |
| 31-cpu | Task handler at 10k req/s: server cores used | server_cores (↓) | 0.179 (0.177–0.181) | 0.15 (0.148–0.15) | node:http | 0.84× | EXCEPTION |  | [1] |
| 32 | Longest single pause at 10k req/s, no garbage | max_ms (↓) | 2.61 (2.53–3.13) | 0.419 (0.415–3.06) | node:http | 0.16× | EXCEPTION |  | [2] |

## What changed since 2026-11-25

Every row whose verdict changed or whose ratio moved more than 5%, published numbers against the new ones
(Facil / Node = ratio). "Both new runs" means the full run [1] and the rerun [2] agree.

| Row | 25 Nov | 26 Nov | Ratio | What moved | Read |
|---|---|---|---|---|---|
| A14 | 968,013 / 999,971 = 0.97× FAIL | 999,968 / 768,182 = 1.30× PASS | +35% | Node −23% | Facil at the 1M deliveries/s ceiling in both new runs; uWebSockets.js ranged 225k–1M. Node-side variance |
| A15c | 749 / 747 = 1.00× PASS | 1,296 / 1,328 = 0.98× FAIL | −3% | both +75% | Behind in both new runs (0.96×, 0.98×). Both sides moved together, so the client or the machine changed; a small real gap |
| A19d | 33,485 / 32,546 = 1.03× PASS | 31,167 / 31,900 = 0.98× FAIL | −5% | Facil −7% | Behind in both new runs (0.97×, 0.98×). 100 request headers; probably the header checks added for HTTP conformance (not confirmed) |
| 7-c100 | 25,508 / 25,247 = 1.01× PASS | 26,764 / 26,850 = 0.997× FAIL | −1% | both +5% | 0.98× and 0.997×: parity, on the wrong side of 1.0 |
| 7-c1000 | 17,539 / 17,650 = 0.99× FAIL | 17,120 / 18,412 = 0.93× FAIL | −6% | Node +4% | Still failing; Node's runs spread 17,321–19,415 |
| 21b-p99 | 1.22 / 1.34 = 1.10× PASS | 1.33 / 0.943 = 0.71× FAIL | −35% | Node −30% | Facil unchanged; the published Node number came from a slow Node run (25 Nov full run: 0.89 ms). Real gap |
| 21c | 0.321 / 0.347 = 1.08× PASS | 0.274 / 0.161 = 0.59× FAIL | −46% | Facil −15%, Node −54% | Facil better, but the published Node number was a slow run (25 Nov full run: 0.169 ms). Real gap |
| 22 | 0.247 / 0.271 = 1.10× PASS | 0.189 / 0.165 = 0.87× FAIL | −20% | Facil −23%, Node −39% | As 21c: Facil better, Node's published number was slow. Real gap |
| 23a | 33,981 / 33,334 = 1.02× PASS | 34,188 / 35,183 = 0.97× FAIL | −5% | Node +6% | 0.97× in both new runs, errors flagged on both sides; parity-level |
| 23b | 34,365 / 34,562 = 0.99× FAIL | 35,644 / 34,900 = 1.02× PASS | +3% | Facil +4% | 1.02× in both new runs; parity-level |
| 29 | 6,541 / 6,556 = 0.998× FAIL | 6,367 / 6,343 = 1.00× PASS | +1% | both −3% | 1.01× and 1.00×; client-bound on both sides, parity |
| 25 | 8,484 / 11,433 = 0.74× EXCEPTION | 2,431 / 11,585 = 0.21× EXCEPTION | −72% | Facil −71% | Not a regression in the repository: the 25 Nov number came from a working tree that set Julia's idle-thread spin (`JULIA_THREAD_SLEEP_THRESHOLD`) to 0 for task-handler servers, removed before the first commit. With Julia's default 100 µs spin the four worker threads spin between chunk hand-offs (4.6 cores against 1.56). `JULIA_THREAD_SLEEP_THRESHOLD=0` at launch gives 8,832 req/CPU-s (27 Nov, Facil side only) |
| 26 | 200,091 / 213,212 = 0.94× EXCEPTION | 192,679 / 228,400 = 0.84× EXCEPTION | −10% | Node +7% | 1.04× in the full run, 0.84× in the rerun; spreads of 160k–235k on both sides. Noise |
| 32 | 4.67 / 3.96 = 0.85× EXCEPTION | 2.61 / 0.419 = 0.16× EXCEPTION | −81% | Facil −44%, Node −89% | Facil's longest pause shorter; Node's published number was a slow run |
| 12, 12-sysimg, 12-json | 764, 314, 448 ms | 881, 397, 566 ms | −7 to −15% | Facil +15–26% | `serve!` compiled its keyword body for each script's handler and keyword types (about 230 ms, 110 ms before); it now hands the keywords to precompiled code. 27 Nov [4]: 701, 264, 427 ms |
| 13-sysimg | 6.92 ms | 5.20 ms | +36% | Facil −25% | First request faster with the sysimage |
| A17 | 234,442 / 111,387 = 2.10× | 170,352 / 115,816 = 1.47× | −30% | Facil −27% | Facil's runs spread 88,516–424,968 with errors; the median is not stable |
| A10 | 1.37× | 1.61× | +18% | Facil −11% CPU/request | Better |
| A12b | 1.55× | 1.45× | −6% | Facil −12%, Node −6% | Still well ahead |
| A12c | 1.23× | 1.41× | +15% | Facil +5%, Node −9% | |
| A19c | 1.55× | 1.47× | −6% | Facil −8% | 40 headers; same direction as A19d |
| A21, A22 | 1.09×, 1.64× | 1.16×, 1.55× | +6%, −6% | both slower | One A22 run saw a 65 ms Facil p99 and one a 27 ms Node p99 (a machine hiccup); medians unaffected |
| A28 | 2.21× | 2.09× | −5% | Facil +6% bytes/conn | |
| 6a, 6b, 6c, 18a | 2.09×, 2.16×, 2.20×, 1.17× | 2.32×, 2.34×, 2.74×, 1.28× | +8 to +25% | Node −8 to −20% | Facil unchanged, Node slower |
| 7-c10 | 0.93× | 0.98× | +6% | both +10–16% | Still an exception |
| 24a, 24b, 27 | 1.32×, 1.52×, 1.67× | 1.50×, 1.65×, 1.77× | +6 to +13% | Facil +4–7% | Better |

Rows that flipped in the full run and flipped back in the rerun, so noise: A6 (0.97× then 1.03×, PASS), A7
(1.04× then 0.998×, FAIL as published), 26 (1.04× then 0.84×, EXCEPTION as published).

## Apple silicon: one GC thread

Julia 1.12 and 1.13 can crash in GC marking on Apple silicon with more than one GC thread
(JuliaLang/julia#65301), so the deployment guide recommends `JULIA_NUM_GC_THREADS=1` there. The scoreboard keeps
4 as its default. The GC-sensitive rows with one GC thread [3], against the published numbers with four:

| Row | Name | Metric | Facil, 4 GC threads | Ratio, 4 | Facil, 1 GC thread | Ratio, 1 | Node |
|---|---|---|---|---|---|---|---|
| 19 | Build a 50 KB JSON response | rps (↑) | 2,333 | 0.19× EXCEPTION | 2,305 (2,288–2,309) | 0.19× EXCEPTION | 12,024 |
| 19a | Build a 1 KB JSON response | rps (↑) | 67,053 | 0.53× EXCEPTION | 67,137 (66,717–67,456) | 0.55× EXCEPTION | 121,102 |
| 21a-p99 | 100 KB garbage per request at 10k req/s: p99 | p99_ms (↓) | 0.229 | 0.63× EXCEPTION | 2.15 (2.05–2.33) | 0.067× EXCEPTION | 0.144 |
| 21a-p999 | 100 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 2.94 | 0.055× EXCEPTION | 7.18 (7.04–7.32) | 0.023× EXCEPTION | 0.163 |
| 21b | 100 KB garbage per request, max rate | rps (↑) | 195,114 | 1.47× PASS | 184,515 (184,219–185,342) | 1.36× PASS | 136,051 |
| 21b-p99 | 100 KB garbage per request, max rate: p99 | p99_ms (↓) | 1.33 | 0.71× FAIL | 2.33 (2.29–2.38) | 0.42× FAIL | 0.97 |
| 21c | 10 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 0.274 | 0.59× FAIL | 0.265 (0.264–0.281) | 0.64× FAIL | 0.168 |
| 22 | p99.9 at a light 10k req/s | p999_ms (↓) | 0.189 | 0.87× FAIL | 0.352 (0.18–0.924) | 0.45× FAIL | 0.159 |
| 25 | Upload 1 MB streamed through a task: requests per server CPU-second | req_per_cpu_s (↑) | 2,431 | 0.21× EXCEPTION | 2,498 (2,356–2,511) | 0.21× EXCEPTION | 12,033 |
| 32 | Longest single pause at 10k req/s, no garbage | max_ms (↓) | 2.61 | 0.16× EXCEPTION | 11.6 (4.26–12.6) | 0.050× EXCEPTION | 0.576 |

Throughput barely moves (21b −5%). Tails under allocation are longer with one GC thread: 21a p99 0.23 → 2.15 ms
and p99.9 2.9 → 7.2 ms, 21b p99 1.3 → 2.3 ms, 32 2.6 → 11.6 ms; 21c is unchanged. No verdict changes.

## Full run, 20261126-212620

runs per cell: 3; sides: both; machine: 15 cores; node v22.23.2; facil env: JULIA_NUM_GC_THREADS=4

Cells: median (min–max). ratio = facil/node for higher-is-better metrics, node/facil for lower-is-better, so >1 favours facil.
Flags: client = load client reached 90% of its cores (number is a lower bound); busy = machine under the idle bar before a run (verdict NOISY); errors = non-2xx/reset/stuck responses seen.

| row | name | metric | facil | node | ratio | target | verdict | opponent | node (validation) | flags |
|---|---|---|---|---|---|---|---|---|---|---|
| A1 | Tiny reply, 1 core | rps (↑) | 248,626 (243,783–250,633) | 179,610 (179,593–180,785) | 1.38× | ≥1.0 | PASS | node:http | 164,000 |  |
| A2 | 150-byte JSON, 1 core | rps (↑) | 231,505 (224,879–233,091) | 158,620 (156,310–160,103) | 1.46× | ≥1.0 | PASS | node:http | 146,000 |  |
| A3 | POST echo | rps (↑) | 214,696 (213,187–214,894) | 136,737 (132,307–137,078) | 1.57× | ≥1.0 | PASS | node:http | 133,000 |  |
| A4 | 100 KB response | rps (↑) | 108,805 (98,797–110,992) | 85,383 (80,905–86,385) | 1.27× | ≥1.0 | PASS | node:http | 78,182 |  |
| A5 | 1 MB response | rps (↑) | 16,454 (16,161–16,641) | 15,899 (15,609–16,056) | 1.03× | ≥1.0 | PASS | node:http | 9,100 |  |
| A6 | CPU-bound handler (FNV 3x16 KB), 1 core | rps (↑) | 17,106 (17,088–17,325) | 17,587 (17,328–17,805) | 0.973× | ≥1.0 | FAIL | node:http | 15,900 |  |
| A7 | CPU-bound handler, 2 cores | rps (↑) | 37,566 (37,197–37,589) | 35,973 (35,914–36,026) | 1.04× | ≥1.0 | PASS | cluster W=2 | 36,619 |  |
| A8 | CPU-bound handler, 4 cores | rps (↑) | 68,475 (68,325–68,576) | 62,980 (62,973–63,220) | 1.09× | ≥1.0 | PASS | cluster W=4 | 65,899 |  |
| A9 | 1M requests, 10 per connection (client resets) | rps (↑) | 186,781 (185,654–187,692) | 146,217 (144,476–146,395) | 1.28× | ≥1.0 | PASS | node:http | 150,966 |  |
| A9-p99 | 1M requests, 10 per connection: p99 | p99_ms (↓) | 1.24 (1.22–1.25) | 6.28 (6.25–6.29) | 5.06× | ≥1.0 | PASS | node:http | 5.95 |  |
| A10 | 10,000 keep-alive connections: server CPU per request | cpu_us_per_req (↓) | 5.33 (5.30–6.65) | 8.61 (8.52–8.71) | 1.62× | ≥1.0 | PASS | node:http | 9.92 | facil:errors |
| A11 | gzip responses (100 KB JSON, level 6, off the event loop) | rps (↑) | 11,936 (11,393–12,069) | 7,501 (7,494–7,671) | 1.59× | ≥1.0 | PASS | node:http | 7,614 |  |
| A12a | Upload 1 KB, in memory | rps (↑) | 205,115 (202,356–205,174) | 139,311 (139,222–139,399) | 1.47× | ≥1.0 | PASS | node:http | 143,185 |  |
| A12b | Upload 64 KB, in memory | rps (↑) | 98,315 (97,974–107,729) | 67,957 (66,011–68,498) | 1.45× | ≥1.0 | PASS | node:http | 72,813 |  |
| A12c | Upload 1 MB, in memory | rps (↑) | 12,452 (12,337–12,934) | 8,812 (8,209–9,075) | 1.41× | ≥1.0 | PASS | node:http | 9,797 |  |
| A13a | TLS handshakes, ECDSA full, 10 clients | rps (↑) | 7,153 (7,102–7,240) | 6,780 (6,698–6,791) | 1.06× | ≥1.0 | PASS | node:https | 6,267 |  |
| A13b | TLS handshakes, RSA full, 10 clients | rps (↑) | 2,281 (2,270–2,288) | 2,216 (2,215–2,225) | 1.03× | ≥1.0 | PASS | node:https | 2,270 |  |
| A13c | TLS handshakes, RSA resumed, 10 clients | rps (↑) | 8,079 (8,008–8,237) | 7,848 (7,580–8,050) | 1.03× | ≥1.0 | PASS | node:https | 7,552 |  |
| A14 | WebSocket broadcast, 1,000 subscribers x 1,000 Hz | deliveries_per_s (↑) | 999,958 (999,922–1,000,018) | 380,709 (225,070–591,285) | 2.63× | ≥1.0 | PASS | uWebSockets.js | 674,104 |  |
| A15a | Streaming 10 x 1 KB chunks, no delay, 50 conns | rps (↑) | 165,013 (162,987–165,269) | 90,197 (89,707–91,424) | 1.83× | ≥1.0 | PASS | node:http | 73,323 | facil:client |
| A15b | Streaming 100 x 16 KB chunks, no delay | rps (↑) | 3,756 (3,708–3,866) | 3,701 (3,530–3,729) | 1.01× | ≥1.0 | PASS | node:http | 3,947 | facil:client, node:client |
| A15c | Streaming 10 x 1 MB chunks, no delay | rps (↑) | 1,305 (1,269–1,338) | 1,360 (1,244–1,376) | 0.96× | ≥1.0 | FAIL | node:http | 575 |  |
| A16 | Keep-alive, 1,000 connections | rps (↑) | 212,510 (207,328–216,380) | 135,408 (132,048–136,524) | 1.57× | ≥1.0 | PASS | node:http | 139,607 |  |
| A17 | Keep-alive, 10,000 connections | rps (↑) | 160,740 (86,278–280,799) | 119,461 (117,655–120,120) | 1.35× | ≥1.0 | PASS | node:http | 86,667 | facil:errors |
| A18 | Keep-alive, 5,000 connections: p99 | p99_ms (↓) | 28.3 (28.1–31.7) | 61.0 (61.0–61.4) | 2.16× | ≥1.0 | PASS | node:http | 1,657 |  |
| A19a | 2 request headers | rps (↑) | 214,848 (210,463–219,614) | 151,081 (150,638–151,343) | 1.42× | ≥1.0 | PASS | node:http | 150,515 |  |
| A19b | 12 request headers | rps (↑) | 180,306 (180,011–186,451) | 119,792 (118,284–120,369) | 1.51× | ≥1.0 | PASS | node:http | 119,632 |  |
| A19c | 40 request headers | rps (↑) | 95,105 (95,045–98,583) | 64,912 (64,296–65,541) | 1.47× | ≥1.0 | PASS | node:http | 66,326 |  |
| A19d | 100 request headers | rps (↑) | 31,099 (30,370–31,447) | 32,061 (30,287–32,910) | 0.97× | ≥1.0 | FAIL | node:http | 33,126 |  |
| A19e | 4 KB cookie | rps (↑) | 196,719 (195,725–197,672) | 143,261 (142,799–144,003) | 1.37× | ≥1.0 | PASS | node:http | 144,787 |  |
| A19f | 2 KB query string, parsed | rps (↑) | 38,700 (38,274–39,465) | 37,382 (37,025–37,971) | 1.04× | ≥1.0 | PASS | node:http | 35,348 |  |
| A20a | Pipelining depth 1 | rps (↑) | 231,263 (230,771–232,768) | 159,188 (159,140–159,385) | 1.45× | ≥1.0 | PASS | node:http | 125,946 | facil:client |
| A20b | Pipelining depth 4 | rps (↑) | 345,916 (338,098–352,093) | 223,286 (222,736–225,238) | 1.55× | ≥1.0 | PASS | node:http | 157,706 |  |
| A20c | Pipelining depth 16 | rps (↑) | 374,122 (370,291–377,155) | 241,882 (238,646–243,757) | 1.55× | ≥1.0 | PASS | node:http | 171,229 |  |
| A21 | Fixed 50k req/s: p99 | p99_ms (↓) | 0.0594 (0.0584–0.0601) | 0.0687 (0.0626–0.0723) | 1.16× | ≥1.0 | PASS | node:http | 0.082 |  |
| A22 | Fixed 100k req/s: p99 | p99_ms (↓) | 0.0597 (0.0587–65.2) | 0.0925 (0.0885–27.1) | 1.55× | ≥1.0 | PASS | node:http | 2.37 |  |
| A24 | JSON parse 1 KB POST | rps (↑) | 133,121 (130,994–135,378) | 109,214 (107,541–110,322) | 1.22× | ≥1.0 | PASS | node:http | 94,806 |  |
| A25a | Float sum handler (1e5 floats) | rps (↑) | 87,259 (86,535–87,603) | 15,351 (15,084–15,664) | 5.68× | ≥1.0 | PASS | node:http | 13,623 |  |
| A25b | FNV-1a over 4 KB handler | rps (↑) | 126,767 (126,245–127,965) | 101,975 (101,765–102,417) | 1.24× | ≥1.0 | PASS | node:http | 80,922 |  |
| A26 | Task-based tiny handler, 4 Julia threads | rps (↑) | 209,930 (209,861–211,323) | 181,827 (179,144–181,830) | 1.15× | ≥1.0 | PASS | node:http | 127,616 |  |
| A27 | HTTPS JSON, keep-alive | rps (↑) | 156,651 (154,736–157,866) | 128,953 (126,732–129,398) | 1.21× | ≥1.0 | PASS | node:https | 130,803 |  |
| A28 | Memory per idle WebSocket (10,000 open) | bytes_per_conn (↓) | 303 (279–392) | 634 (626–637) | 2.09× | ≥1.0 | PASS | uWebSockets.js | 629 |  |
| A29 | WebSocket echo 64 B, 100 connections | msgs_per_s (↑) | 281,369 (280,595–281,951) | 276,838 (276,117–277,179) | 1.02× | ≥1.0 | PASS | uWebSockets.js | 266,428 |  |
| A30 | WebSocket echo 64 B, 100 connections, vs ws | msgs_per_s (↑) | 281,369 (280,595–281,951) | 215,912 (214,497–218,086) | 1.30× | ≥1.0 | PASS | ws | 208,438 |  |
| 1 | CPU-bound handler, 8 cores | rps (↑) | 125,159 (125,154–125,492) | 121,321 (120,253–123,312) | 1.03× | ≥1.0 | PASS | cluster W=8 | 126,001 |  |
| 2 | Tiny reply (JSON), 4 cores | rps (↑) | 186,603 (186,274–186,753) | 179,389 (179,282–179,790) | 1.04× | ≥1.0 | PASS | cluster W=4 | 178,490 |  |
| 3 | Tiny reply (JSON), 8 cores | rps (↑) | 171,092 (169,940–171,488) | 169,515 (169,293–169,678) | 1.01× | ≥1.0 | PASS | cluster W=8 | 169,429 |  |
| 4 | Async (task) handler, tiny reply, 1 reactor + 2 Julia threads | rps (↑) | 217,575 (216,386–219,195) | 153,190 (152,143–154,667) | 1.42× | ≥1.0 | PASS | node:http | 158,795 |  |
| 5a | HTTPS 100 KB, no-copy body | rps (↑) | 37,215 (36,890–37,244) | 29,855 (29,648–29,920) | 1.25× | ≥1.0 | PASS | node:https | 30,176 |  |
| 5b | HTTPS 1 MB, no-copy body | rps (↑) | 4,648 (4,644–4,687) | 4,018 (4,006–4,049) | 1.16× | ≥1.0 | PASS | node:https | 4,066 |  |
| 6a | Paced streaming from a Julia task, 10 x 1 KB, 1 ms apart | rps (↑) | 19,072 (19,016–19,096) | 8,227 (8,223–8,302) | 2.32× | ≥1.0 | PASS | node:http | 7,231 | facil:client |
| 6b | Paced streaming from a Julia task, 100 x 16 KB, 1 ms apart | rps (↑) | 1,874 (1,870–1,875) | 800 (800–833) | 2.34× | ≥1.0 | PASS | node:http | 700 | facil:client |
| 6c | Paced streaming from a Julia task, 1000 x 1 KB, 1 ms apart | rps (↑) | 183 (183–183) | 66.7 (66.7–66.7) | 2.75× | ≥1.0 | PASS | node:http | 66.7 |  |
| 7-c10 | WebSocket echo 256 KB, 10 connections | msgs_per_s (↑) | 36,428 (36,071–36,693) | 37,049 (36,895–37,609) | 0.983× | ≥1.0 | EXCEPTION | uWebSockets.js | 36,177 |  |
| 7-c100 | WebSocket echo 256 KB, 100 connections | msgs_per_s (↑) | 29,540 (28,851–29,758) | 30,121 (28,968–30,523) | 0.981× | ≥1.0 | FAIL | uWebSockets.js | 29,448 |  |
| 7-c1000 | WebSocket echo 256 KB, 1000 connections | msgs_per_s (↑) | 17,120 (15,015–18,086) | 18,412 (17,321–19,415) | 0.93× | ≥1.0 | FAIL | uWebSockets.js | 20,230 |  |
| 7b-64 | WebSocket echo 64 B, 10 connections | msgs_per_s (↑) | 249,904 (249,680–250,963) | 244,756 (244,554–245,058) | 1.02× | ≥1.0 | PASS | uWebSockets.js | 248,612 |  |
| 7b-1k | WebSocket echo 1 KB, 10 connections | msgs_per_s (↑) | 247,508 (247,305–248,023) | 240,894 (240,613–241,137) | 1.03× | ≥1.0 | PASS | uWebSockets.js | 246,611 |  |
| 7b-16k | WebSocket echo 16 KB, 10 connections | msgs_per_s (↑) | 187,787 (187,497–188,286) | 183,543 (182,685–184,285) | 1.02× | ≥1.0 | PASS | uWebSockets.js | 188,787 |  |
| 8 | WebSocket permessage-deflate, 4 KB JSON echo, 100 connections | msgs_per_s (↑) | 58,510 (58,408–58,568) | 54,616 (53,924–54,762) | 1.07× | ≥1.0 | PASS | uWebSockets.js | 56,286 |  |
| 9 | 10 MB chunked upload, buffered | rps (↑) | 697 (692–752) | 486 (486–495) | 1.43× | ≥1.0 | PASS | node:http | 495 |  |
| 10 | Memory, idle | rss_mb (↓) | 387 (387–390) | 51.0 (50.8–51.1) | 0.132× | ≥1.0 | EXCEPTION | node:http | 44.7 |  |
| 10-sysimg | Memory, idle (Facil: PackageCompiler sysimage, /json-only server) | rss_mb (↓) | 335 (335–335) | 51.0 (50.8–51.1) | 0.152× | ≥1.0 | EXCEPTION | node:http | 44.7 |  |
| 11 | Memory, 10,000 keep-alive connections under load | rss_max_mb (↓) | 433 (418–440) | 248 (230–289) | 0.572× | ≥1.0 | EXCEPTION | node:http | 223 | facil:errors |
| 12 | Start-up to first response | startup_ms (↓) | 866 (853–875) | 29.4 (28.8–30.9) | 0.0339× | ≥1.0 | EXCEPTION | node:http | 31.3 |  |
| 12-sysimg | Start-up to first response (Facil: PackageCompiler sysimage, /json-only server) | startup_ms (↓) | 397 (393–412) | 29.4 (28.8–30.9) | 0.074× | ≥1.0 | EXCEPTION | node:http | 31.3 |  |
| 12-json | Start-up to first response (Facil: plain julia, /json-only server) | startup_ms (↓) | 573 (567–575) | 29.4 (28.8–30.9) | 0.0513× | ≥1.0 | EXCEPTION | node:http | 31.3 |  |
| 13 | First request | first_req_ms (↓) | 310 (310–316) | 2.11 (2.05–2.14) | 0.00681× | ≥1.0 | EXCEPTION | node:http | 2.42 |  |
| 13-sysimg | First request (Facil: PackageCompiler sysimage, /json-only server) | first_req_ms (↓) | 5.16 (5.02–5.18) | 2.11 (2.05–2.14) | 0.41× | ≥1.0 | EXCEPTION | node:http | 2.42 |  |
| 13-json | First request (Facil: plain julia, /json-only server) | first_req_ms (↓) | 5.51 (5.27–5.55) | 2.11 (2.05–2.14) | 0.384× | ≥1.0 | EXCEPTION | node:http | 2.42 |  |
| 14 | 200 slow-header connections (slowloris), held after 150 s | held (↓) | 0 (0–0) | 0 (0–0) | 1.00× | ≥1.0 | PASS | node:http | 0 |  |
| 15 | 200 slow readers of 8 x 1 MB: RSS growth | rss_growth_mb (↓) | 2.50 (2.10–2.80) | 10.4 (8.80–10.6) | 4.16× | ≥1.0 | PASS | node:http | 6.20 |  |
| 17a | Handler waits 1 ms (Facil.sleep), 100 connections | rps (↑) | 85,941 (84,396–86,036) | 55,382 (55,372–55,836) | 1.55× | ≥1.0 | PASS | node:http | 48,600 |  |
| 17b | Handler waits 1 ms (Facil.sleep), 1000 connections | rps (↑) | 164,400 (159,274–172,488) | 124,145 (123,037–129,893) | 1.32× | ≥1.0 | PASS | node:http | 145,680 |  |
| 18a | Handler waits 10 ms (Facil.sleep), 100 connections | rps (↑) | 9,795 (9,756–9,800) | 7,624 (7,580–7,627) | 1.28× | ≥1.0 | PASS | node:http | 7,545 |  |
| 18b | Handler waits 10 ms (Facil.sleep), 1000 connections | rps (↑) | 96,309 (96,261–96,391) | 81,000 (79,721–81,088) | 1.19× | ≥1.0 | PASS | node:http | 81,000 |  |
| 19 | Build a 50 KB JSON response | rps (↑) | 2,333 (2,192–2,361) | 12,071 (11,185–12,155) | 0.193× | ≥1.0 | EXCEPTION | node:http | 12,266 |  |
| 19a | Build a 1 KB JSON response | rps (↑) | 67,053 (66,208–67,298) | 127,284 (125,974–127,944) | 0.527× | ≥1.0 | EXCEPTION | node:http | 96,768 |  |
| 20 | Task-based handler on 1 Julia thread | rps (↑) | 244,754 (243,000–245,741) | 181,827 (179,144–181,830) | 1.35× | ≥1.0 | PASS | node:http | 127,616 | facil:client |
| 21a-p99 | 100 KB garbage per request at 10k req/s: p99 | p99_ms (↓) | 0.229 (0.229–0.23) | 0.145 (0.144–0.145) | 0.633× | ≥1.0 | EXCEPTION | node:http | 0.145 |  |
| 21a-p999 | 100 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 2.94 (2.89–2.96) | 0.161 (0.16–0.161) | 0.0548× | ≥1.0 | EXCEPTION | node:http | 0.24 |  |
| 21b | 100 KB garbage per request, max rate | rps (↑) | 200,466 (199,359–200,594) | 136,824 (135,873–137,323) | 1.47× | ≥1.0 | PASS | node:http | 138,000 |  |
| 21b-p99 | 100 KB garbage per request, max rate: p99 | p99_ms (↓) | 1.32 (1.31–1.34) | 0.929 (0.913–1.10) | 0.702× | ≥1.0 | FAIL | node:http | 0.839 |  |
| 21c | 10 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 0.273 (0.273–0.28) | 0.176 (0.158–0.19) | 0.646× | ≥1.0 | FAIL | node:http | 0.164 |  |
| 22 | p99.9 at a light 10k req/s | p999_ms (↓) | 0.18 (0.178–0.222) | 0.157 (0.155–0.194) | 0.871× | ≥1.0 | FAIL | node:http | 0.262 |  |
| 23a | New connection per request, 100 clients | rps (↑) | 33,833 (33,778–36,378) | 34,917 (32,416–36,996) | 0.969× | ≥1.0 | FAIL | node:http | 36,742 | facil:errors, node:errors |
| 23b | New connection per request, 10 clients | rps (↑) | 36,049 (32,898–36,145) | 35,197 (35,122–36,676) | 1.02× | ≥1.0 | PASS | node:http | 36,032 |  |
| 24a | Upload 10 MB, default body handling (no spooling) | rps (↑) | 990 (954–997) | 662 (651–668) | 1.50× | ≥1.0 | PASS | node:http | 720 |  |
| 24b | Upload 100 MB, default body handling (no spooling) | rps (↑) | 121 (120–122) | 73.3 (72.6–73.8) | 1.65× | ≥1.0 | PASS | node:http | 75.2 |  |
| 25 | Upload 1 MB streamed through a task: requests per server CPU-second | req_per_cpu_s (↑) | 2,425 (2,397–2,511) | 11,641 (10,545–12,115) | 0.208× | ≥1.0 | EXCEPTION | node:http | 12,853 |  |
| 26 | WebSocket broadcast, 10,000 subscribers x 100 Hz | deliveries_per_s (↑) | 198,813 (197,319–206,353) | 190,638 (160,762–193,489) | 1.04× | ≥1.0 | PASS | uWebSockets.js | 206,142 | facil:errors, node:errors |
| 27 | Streamed gzip of 100 KB JSON | rps (↑) | 11,257 (11,232–11,336) | 6,348 (6,279–6,509) | 1.77× | ≥1.0 | PASS | node:http | 6,583 |  |
| 28a | Whole response 32 KB (gather-write) | rps (↑) | 147,285 (146,091–147,904) | 103,605 (102,069–106,496) | 1.42× | ≥1.0 | PASS | node:http | 81,760 | facil:client |
| 28b | Whole response 100 KB (gather-write) | rps (↑) | 84,843 (83,968–85,579) | 70,219 (68,800–72,533) | 1.21× | ≥1.0 | PASS | node:http | 60,560 | facil:client |
| 29 | Whole response 1 MB (gather-write) | rps (↑) | 6,412 (6,277–6,546) | 6,342 (5,933–6,377) | 1.01× | ≥1.0 | PASS | node:http | 6,575 | facil:client, node:client |
| 30a | Brotli level 4, 100 KB JSON, on the event loop | rps (↑) | 3,330 (3,304–3,332) | 3,159 (3,073–3,166) | 1.05× | ≥1.0 | PASS | node:http | 3,169 |  |
| 30b | zstd level 3, 100 KB JSON, on the event loop | rps (↑) | 9,151 (9,131–9,193) | 8,299 (8,235–8,338) | 1.10× | ≥1.0 | PASS | node:http | 8,197 |  |
| 31-p99 | Task handler at 10k req/s: p99 | p99_ms (↓) | 0.171 (0.171–0.171) | 0.143 (0.142–0.143) | 0.837× | ≥1.0 | EXCEPTION | node:http | 0.145 |  |
| 31-cpu | Task handler at 10k req/s: server cores used | server_cores (↓) | 0.179 (0.177–0.181) | 0.15 (0.148–0.15) | 0.838× | ≥1.0 | EXCEPTION | node:http | 0.15 |  |
| 32 | Longest single pause at 10k req/s, no garbage | max_ms (↓) | 3.62 (3.03–4.20) | 0.622 (0.352–3.04) | 0.172× | ≥1.0 | EXCEPTION | node:http | 1.60 |  |

EXCEPTION = under target on a row with an approved exception:

- 7-c10: macOS kernel networking limits (writev-bound, socket-memory exhaustion and retransmits); recheck on Linux
- 10: Julia runtime start-up, memory and first-request cost
- 10-sysimg: Julia runtime start-up, memory and first-request cost
- 11: Julia runtime start-up, memory and first-request cost
- 12: Julia runtime start-up, memory and first-request cost
- 12-sysimg: Julia runtime start-up, memory and first-request cost
- 12-json: Julia runtime start-up, memory and first-request cost
- 13: Julia runtime start-up, memory and first-request cost
- 13-sysimg: Julia runtime start-up, memory and first-request cost
- 13-json: Julia runtime start-up, memory and first-request cost
- 19: Cost of Julia's JSON library serialising the body, not of the server
- 19a: Cost of Julia's JSON library serialising the body, not of the server
- 21a-p99: Julia GC pauses; still under target with JULIA_NUM_GC_THREADS=4
- 21a-p999: Julia GC pauses; still under target with JULIA_NUM_GC_THREADS=4
- 25: Task handlers pay two cross-thread hand-offs per request or chunk; use inline=true or on_chunk, which beat Node
- 26: macOS kernel networking limits (writev-bound, socket-memory exhaustion and retransmits); recheck on Linux
- 31-p99: Task handlers pay two cross-thread hand-offs per request or chunk; use inline=true or on_chunk, which beat Node
- 31-cpu: Task handlers pay two cross-thread hand-offs per request or chunk; use inline=true or on_chunk, which beat Node
- 32: Julia GC pauses; still under target with JULIA_NUM_GC_THREADS=4

## Rerun of changed rows, 20261126-234001

runs per cell: 3; sides: both; machine: 15 cores; node v22.23.2; facil env: JULIA_NUM_GC_THREADS=4

Cells: median (min–max). ratio = facil/node for higher-is-better metrics, node/facil for lower-is-better, so >1 favours facil.
Flags: client = load client reached 90% of its cores (number is a lower bound); busy = machine under the idle bar before a run (verdict NOISY); errors = non-2xx/reset/stuck responses seen.

| row | name | metric | facil | node | ratio | target | verdict | opponent | node (validation) | flags |
|---|---|---|---|---|---|---|---|---|---|---|
| A6 | CPU-bound handler (FNV 3x16 KB), 1 core | rps (↑) | 17,049 (17,041–17,084) | 16,546 (16,294–16,615) | 1.03× | ≥1.0 | PASS | node:http | 15,900 |  |
| A7 | CPU-bound handler, 2 cores | rps (↑) | 35,970 (35,253–36,718) | 36,054 (35,882–36,126) | 0.998× | ≥1.0 | FAIL | cluster W=2 | 36,619 |  |
| A14 | WebSocket broadcast, 1,000 subscribers x 1,000 Hz | deliveries_per_s (↑) | 999,968 (676,551–999,968) | 768,182 (437,995–999,809) | 1.30× | ≥1.0 | PASS | uWebSockets.js | 674,104 |  |
| A15c | Streaming 10 x 1 MB chunks, no delay | rps (↑) | 1,296 (1,201–1,361) | 1,328 (1,237–1,381) | 0.976× | ≥1.0 | FAIL | node:http | 575 |  |
| A17 | Keep-alive, 10,000 connections | rps (↑) | 170,352 (88,516–424,968) | 115,816 (115,276–117,874) | 1.47× | ≥1.0 | PASS | node:http | 86,667 | facil:errors |
| A19d | 100 request headers | rps (↑) | 31,167 (30,608–32,198) | 31,900 (31,435–32,069) | 0.977× | ≥1.0 | FAIL | node:http | 33,126 |  |
| 7-c100 | WebSocket echo 256 KB, 100 connections | msgs_per_s (↑) | 26,764 (26,520–26,828) | 26,850 (22,381–27,243) | 0.997× | ≥1.0 | FAIL | uWebSockets.js | 29,448 |  |
| 12 | Start-up to first response | startup_ms (↓) | 881 (879–883) | 29.3 (29.1–31.2) | 0.0333× | ≥1.0 | EXCEPTION | node:http | 31.3 |  |
| 12-sysimg | Start-up to first response (Facil: PackageCompiler sysimage, /json-only server) | startup_ms (↓) | 397 (395–427) | 29.3 (29.1–31.2) | 0.074× | ≥1.0 | EXCEPTION | node:http | 31.3 |  |
| 12-json | Start-up to first response (Facil: plain julia, /json-only server) | startup_ms (↓) | 566 (555–583) | 29.3 (29.1–31.2) | 0.0519× | ≥1.0 | EXCEPTION | node:http | 31.3 |  |
| 13-sysimg | First request (Facil: PackageCompiler sysimage, /json-only server) | first_req_ms (↓) | 5.20 (4.93–5.30) | 2.10 (2.09–2.13) | 0.404× | ≥1.0 | EXCEPTION | node:http | 2.42 |  |
| 13-json | First request (Facil: plain julia, /json-only server) | first_req_ms (↓) | 5.11 (4.99–5.61) | 2.10 (2.09–2.13) | 0.411× | ≥1.0 | EXCEPTION | node:http | 2.42 |  |
| 21b | 100 KB garbage per request, max rate | rps (↑) | 195,114 (191,997–196,821) | 133,225 (130,872–134,420) | 1.46× | ≥1.0 | PASS | node:http | 138,000 |  |
| 21b-p99 | 100 KB garbage per request, max rate: p99 | p99_ms (↓) | 1.33 (1.32–1.35) | 0.943 (0.919–1.16) | 0.707× | ≥1.0 | FAIL | node:http | 0.839 |  |
| 21c | 10 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 0.274 (0.27–0.279) | 0.161 (0.157–0.191) | 0.59× | ≥1.0 | FAIL | node:http | 0.164 |  |
| 22 | p99.9 at a light 10k req/s | p999_ms (↓) | 0.189 (0.175–0.215) | 0.165 (0.159–0.204) | 0.872× | ≥1.0 | FAIL | node:http | 0.262 |  |
| 23a | New connection per request, 100 clients | rps (↑) | 34,188 (33,718–35,414) | 35,183 (33,637–36,815) | 0.972× | ≥1.0 | FAIL | node:http | 36,742 | facil:errors, node:errors |
| 23b | New connection per request, 10 clients | rps (↑) | 35,644 (35,143–35,750) | 34,900 (34,564–36,175) | 1.02× | ≥1.0 | PASS | node:http | 36,032 |  |
| 25 | Upload 1 MB streamed through a task: requests per server CPU-second | req_per_cpu_s (↑) | 2,431 (2,404–2,444) | 11,585 (11,493–12,260) | 0.21× | ≥1.0 | EXCEPTION | node:http | 12,853 |  |
| 26 | WebSocket broadcast, 10,000 subscribers x 100 Hz | deliveries_per_s (↑) | 192,679 (160,612–206,117) | 228,400 (193,176–235,306) | 0.844× | ≥1.0 | EXCEPTION | uWebSockets.js | 206,142 | facil:errors, node:errors |
| 29 | Whole response 1 MB (gather-write) | rps (↑) | 6,367 (6,213–6,395) | 6,343 (6,321–6,387) | 1.00× | ≥1.0 | PASS | node:http | 6,575 | facil:client, node:client |
| 32 | Longest single pause at 10k req/s, no garbage | max_ms (↓) | 2.61 (2.53–3.13) | 0.419 (0.415–3.06) | 0.161× | ≥1.0 | EXCEPTION | node:http | 1.60 |  |

EXCEPTION = under target on a row with an approved exception:

- 12: Julia runtime start-up, memory and first-request cost
- 12-sysimg: Julia runtime start-up, memory and first-request cost
- 12-json: Julia runtime start-up, memory and first-request cost
- 13-sysimg: Julia runtime start-up, memory and first-request cost
- 13-json: Julia runtime start-up, memory and first-request cost
- 25: Task handlers pay two cross-thread hand-offs per request or chunk; use inline=true or on_chunk, which beat Node
- 26: macOS kernel networking limits (writev-bound, socket-memory exhaustion and retransmits); recheck on Linux
- 32: Julia GC pauses; still under target with JULIA_NUM_GC_THREADS=4

## One GC thread, 20261127-000804

runs per cell: 3; sides: both; machine: 15 cores; node v22.23.2; facil env: JULIA_NUM_GC_THREADS=1

Cells: median (min–max). ratio = facil/node for higher-is-better metrics, node/facil for lower-is-better, so >1 favours facil.
Flags: client = load client reached 90% of its cores (number is a lower bound); busy = machine under the idle bar before a run (verdict NOISY); errors = non-2xx/reset/stuck responses seen.

| row | name | metric | facil | node | ratio | target | verdict | opponent | node (validation) | flags |
|---|---|---|---|---|---|---|---|---|---|---|
| 19 | Build a 50 KB JSON response | rps (↑) | 2,305 (2,288–2,309) | 12,024 (11,488–12,139) | 0.192× | ≥1.0 | EXCEPTION | node:http | 12,266 |  |
| 19a | Build a 1 KB JSON response | rps (↑) | 67,137 (66,717–67,456) | 121,102 (120,738–121,188) | 0.554× | ≥1.0 | EXCEPTION | node:http | 96,768 |  |
| 21a-p99 | 100 KB garbage per request at 10k req/s: p99 | p99_ms (↓) | 2.15 (2.05–2.33) | 0.144 (0.144–0.144) | 0.0669× | ≥1.0 | EXCEPTION | node:http | 0.145 |  |
| 21a-p999 | 100 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 7.18 (7.04–7.32) | 0.163 (0.16–0.171) | 0.0227× | ≥1.0 | EXCEPTION | node:http | 0.24 |  |
| 21b | 100 KB garbage per request, max rate | rps (↑) | 184,515 (184,219–185,342) | 136,051 (132,310–136,209) | 1.36× | ≥1.0 | PASS | node:http | 138,000 |  |
| 21b-p99 | 100 KB garbage per request, max rate: p99 | p99_ms (↓) | 2.33 (2.29–2.38) | 0.97 (0.927–0.971) | 0.417× | ≥1.0 | FAIL | node:http | 0.839 |  |
| 21c | 10 KB garbage per request at 10k req/s: p99.9 | p999_ms (↓) | 0.265 (0.264–0.281) | 0.168 (0.155–0.203) | 0.636× | ≥1.0 | FAIL | node:http | 0.164 |  |
| 22 | p99.9 at a light 10k req/s | p999_ms (↓) | 0.352 (0.18–0.924) | 0.159 (0.157–0.211) | 0.452× | ≥1.0 | FAIL | node:http | 0.262 |  |
| 25 | Upload 1 MB streamed through a task: requests per server CPU-second | req_per_cpu_s (↑) | 2,498 (2,356–2,511) | 12,033 (10,549–12,141) | 0.208× | ≥1.0 | EXCEPTION | node:http | 12,853 |  |
| 32 | Longest single pause at 10k req/s, no garbage | max_ms (↓) | 11.6 (4.26–12.6) | 0.576 (0.47–2.14) | 0.0498× | ≥1.0 | EXCEPTION | node:http | 1.60 |  |

EXCEPTION = under target on a row with an approved exception:

- 19: Cost of Julia's JSON library serialising the body, not of the server
- 19a: Cost of Julia's JSON library serialising the body, not of the server
- 21a-p99: Julia GC pauses; still under target with JULIA_NUM_GC_THREADS=4
- 21a-p999: Julia GC pauses; still under target with JULIA_NUM_GC_THREADS=4
- 25: Task handlers pay two cross-thread hand-offs per request or chunk; use inline=true or on_chunk, which beat Node
- 32: Julia GC pauses; still under target with JULIA_NUM_GC_THREADS=4
