# Node.js scoreboard (release gate, milestone M10)

Runs every row of the plan's "faster than Node.js" section against the fastest Node option for
that job and prints facil/Node ratios. The package is not released while a row is under its
target without an approved exception.

```
bench/scoreboard/build.sh                          # clients, pinned Node packages, payloads, certs
bench/scoreboard/run.sh --list                     # the rows
bench/scoreboard/run.sh                            # everything, both sides, 3 runs per cell
bench/scoreboard/run.sh --rows A1,A4 --runs 3 --side both
bench/scoreboard/run.sh --rows A1 --runs 1 --side node --quick   # smoke check only
bench/scoreboard/run.sh --resume results/<timestamp>          # continue a stopped run: keeps its good runs, appends the rest
bench/scoreboard/facil/sysimage/build.sh           # sysimage for the *-sysimg rows (about 1 minute)
```

Output: `results/<timestamp>/table.md` (row | facil | node | ratio | target | verdict …),
`raw.jsonl` (one line per run, every measured field), `logs/` (server output). `results/` is not
committed; `RESULTS.md` keeps the latest full run.

- `rows.json` — one entry per row: plan id (`A*` = "Already ahead" table, numbers = work lists),
  client and parameters, Node opponent (`node:http`, `cluster W=N`, `uWebSockets.js`, `ws`,
  `node:https`), Facil server keys, metric, higher/lower is better, target, `exception` (the one-line reason for an
  approved exception: the row reads EXCEPTION instead of FAIL when under target), and the clean
  validation numbers it should reproduce.
  Rows with identical measurements (e.g. A10, A17 and 11 at 10,000 connections) share runs.
- `node/` — Node servers; `package.json` + lockfile pin autocannon, uWebSockets.js, ws.
- `clients/` — `lat.c` (kqueue HTTP client: ramped connects, start barrier, open/closed loop,
  any response size), `wsbench.c`, `tlsload.c`, `conn_client.js` (connection-per-request,
  churn, slowloris, slow readers).
- `facil/server.jl` — the Facil side; `facil/README.md` lists what each row needs from it.

Rules the driver enforces: servers it starts get their own process group and are the only
processes it kills; a run is refused unless the port's listener is that server (or its cluster
workers); every cell is probed for the right status and body first; idle CPU is checked before
each run (`--idle-min`, default 90%) and a run below it marks the row NOISY instead of PASS;
client CPU is recorded and a client at 90% of its cores is flagged. Every Facil server starts with
`JULIA_NUM_GC_THREADS=4` (override with `--facil-env KEY=VAL`); the table header records the Facil env. Ports 3510 (Node) and
3520 (Facil). Run it alone on a quiet machine.

Start-up rows come in three forms: `10`/`12`/`13` run the full `facil/server.jl` with plain `julia`, so the
first request compiles the handler for every endpoint; `12-json`/`13-json` serve only `/json`
(`routes=json`); `*-sysimg` also load Facil from the PackageCompiler sysimage. Row 26 (`wsbcast`) splits
its 10,000 subscribers over `procs` wsbench processes so the client never caps the number.

