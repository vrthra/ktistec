# AGENTS.md — Operating manual for this repository

This file explains how to build, deploy, migrate, back up, and roll back this
system. It is written so that someone (or some tool) with no prior context can
follow it. Read it fully before changing anything. When in doubt, do the
smaller, reversible thing.

Last verified: 2026-11-04.

---

## 1. What this is

- This is a **custom fork of Ktistec** (an ActivityPub / Fediverse server
  written in Crystal, using SQLite). Upstream is
  https://github.com/toddsundsted/ktistec
- The fork carries **performance fixes for a memory-constrained production
  host**. The fixes and their reasoning are documented in `FIXES.md` in this
  repository. Read `FIXES.md` before touching anything related to the
  database, background tasks, or migrations.
- It powers the single-user instance at **https://gopinath.org** (also
  www.gopinath.org).

### Git remotes

| Remote   | URL                                          | Meaning                     |
|----------|----------------------------------------------|-----------------------------|
| `origin` | git@github.com:vrthra/ktistec.git            | Our fork (push target)      |
| `o`      | https://github.com/toddsundsted/ktistec.git  | Upstream (pull only)        |

### Branch state (as of 2026-11-04)

- Local `main` = upstream **v3.14.0** + ~27 local commits rebased on top
  (rebased onto `o/main`, which at deploy time was 12 commits past the
  v3.14.0 tag itself — see "Taking future upstream releases" below for why
  that's the correct target).
- Because of the rebase, pushing to the fork requires:
  `git push --force-with-lease origin main`
- Production runs **3.14.0**, deployed 2026-11-04 (binary `server`, dated
  Nov 4; rollback copy `server.2026-11-04-pre-deploy`; db backup
  `ktistec.db.pre-2026-11-04`). This upgrade jumped three upstream releases
  (3.12.0 → 3.12.1 → 3.13.0 → 3.14.0) in one rebase; the headline upstream
  change was a ground-up rearchitecture of feeds (`Feed::Version`,
  `Feed::Question`, executable judges, batched reconciliation via
  `Rules::Maintainer.reconcile_objects`), which builds directly on the
  feed-migration state our fork already created in the 3.12 upgrade (one of
  upstream's new migrations literally comments "copied from
  `20260825140851-rebuild-feeds-on-the-object-clock.cr`"). Also notable:
  upstream independently converged on two of our own FIXES.md items —
  removing the `PRAGMA optimize`-on-connection-close override, and adding a
  startup-time `ANALYZE` (superseding our one-time migration fix, FIXES.md
  #7) — both merged with zero semantic conflict. One real gap was found by
  the test suite and fixed as part of the rebase: `actor-line.html.slang`
  (our replacement for upstream's `actor-card.html.slang`) was missing the
  `data-controller="icon-load-error"` attribute upstream's new icon-repair
  feature expects; ported it over. Check the live version any time with:
  `ssh web 'curl -s -H "Host: gopinath.org" http://localhost:3000/.well-known/nodeinfo/2.1'`
- No local commits are undeployed as of 2026-11-04 — production and `main`
  are in sync.
- No migrations are pending: as of 2026-11-04 the repo/production migration
  diff shows only the documented zero-padding difference and production's
  extra ids 10 and 19 (see section 4.0). The 6 feed-version/feed-question
  migrations that came in with this upgrade all touch only small tables
  (`feeds`, `feed_verdicts`, `feed_versions`, `feed_questions`, `tasks`);
  the slowest (`create-feed-questions`, which backfills a cursor via a
  correlated subquery against `objects`) took 65.8s on production.

### Taking future upstream releases

**Rebase onto `o/main`, NEVER onto the `vX.Y.Z` tag.** Upstream tags its
releases on a separate `dist` branch that additionally commits the built
`public/dist/` bundles (38 files). Our fork descends from upstream `main`,
which does not track them, and deliberately untracks them (`.gitignore`).
Rebasing onto the tag pulls generated assets into our history. Check with
`git ls-tree <ref> public/dist/ | wc -l` — `o/main` gives 0, the tag gives 38.

Because `public/dist/` is untracked here, a checkout that *would* introduce
those files aborts with "untracked working tree files would be overwritten".
Move `public/dist` aside, rebase, then move it back.

1. `git fetch o --tags`
2. Inspect: `git log --oneline main..o/main` and
   `git diff --stat main...o/main`
3. Check for overlap with our fixes (files listed in `FIXES.md`; especially
   `src/framework/database.cr`, `src/framework/ext/sqlite3.cr`,
   `src/models/task.cr`, `src/models/tag.cr`). Check new migrations for
   long-running full-table work — see section 6 ("Constraints").
4. `git rebase o/main`
5. Type-check and test (section 2), then deploy (section 4).

---

## 2. How to build

### 2.1 Machines

- **Build machine: this machine** (where this repository lives:
  `/home/rahul.gopinath/Ktistec/ktistec`). Linux Mint 22.2, glibc 2.39.
- **Do NOT use Docker.** The owner has asked that Docker not be used.
- **Do NOT ssh to `vm1`.** It was the old build machine; it is retired. Any
  README on the production server mentioning vm1 or "compile without static"
  is stale — ignore it.

### 2.2 Crystal compiler

- The **system Crystal on this machine is 1.11.2 and is TOO OLD. It will not
  compile this project.** The project requires **Crystal >= 1.19.1**, and
  exactly-1.20.0 is banned (compiler bug). Versions 1.17.0–1.18.2 are also
  banned (libxml memory bug). These bans are enforced by macros at the top of
  `src/ktistec/server.cr` — the build fails fast with a clear message.
- Use a **portable Crystal tarball**; no system install is needed:

```sh
mkdir -p ~/toolchains && cd ~/toolchains
curl -sSL -O https://github.com/crystal-lang/crystal/releases/download/1.19.1/crystal-1.19.1-1-linux-x86_64.tar.gz
tar xzf crystal-1.19.1-1-linux-x86_64.tar.gz
# compiler is now at: ~/toolchains/crystal-1.19.1-1/bin/crystal
```

(Any 1.19.x or >= 1.20.1 release should work; 1.19.1 is the verified one.)

### 2.3 Fast type-check (no binary produced)

Run this after any code change or rebase; it catches compile errors in ~1–2
minutes:

```sh
cd /home/rahul.gopinath/Ktistec/ktistec
~/toolchains/crystal-1.19.1-1/bin/crystal build --no-codegen src/ktistec/server.cr && echo BUILD_OK
```

### 2.4 Running tests

**`crystal spec` with no arguments does NOT work on this machine.** Linking
the whole suite into one binary produces an executable that dies in the
dynamic loader before running a single example:

```
crystal-run-spec.tmp: symbol lookup error: ... undefined symbol:
__libc_start_main, version Hash(K, V)#malloc_entries<Int32>:...
```

The corrupted symbol-version string is the tell: this is a link-stage
problem at that binary's size/shape, not a code error. Verified 2026-08-05 —
a trivial `crystal run` program works, `LD_PRELOAD`/`LD_LIBRARY_PATH` are
empty, and wiping `~/.cache/crystal` does not help. Any single spec
directory or file links and runs fine.

Run the suite **per directory** instead:

```sh
cd /home/rahul.gopinath/Ktistec/ktistec
for d in models controllers rules services views framework utils api \
         handlers workers channels mcp ktistec safe slang integrations; do
  echo "##### spec/$d"
  KEMAL_ENV=test ~/toolchains/crystal-1.19.1-1/bin/crystal spec spec/$d
done
# or targeted, e.g.:
KEMAL_ENV=test ~/toolchains/crystal-1.19.1-1/bin/crystal spec spec/models/task_spec.cr spec/models/tag_spec.cr
```

Reading the results — two traps, both hit on 2026-08-05:

- **Do not pipe through `tail` and read `$?`** — that reports *`tail`'s*
  exit status, so a failing chunk looks like a pass. Redirect to a file and
  check the compiler's own exit code.
- **`spec/controllers` prints stack traces AFTER its summary line.** They
  are log noise from passing examples, not failures; a short `tail` crops
  the "N examples, 0 failures" line and makes a green run look like a crash.
  Grep for `examples,` rather than tailing.

Baseline as of 2026-11-04 (3.14.0 rebase): **10,356 examples, 0 failures**
across all 16 directories (models 2544 [split models-a/models-b, 44 files
each], controllers 3128 [split ctrl-a/ctrl-b, ~18 files each], framework
978, views 962, services 681, utils 562, rules 395, api 368, mcp 190,
safe 122, slang 389, workers 15, handlers 12, channels 8, ktistec 1,
integrations 1). `spec/models` (88 files) and `spec/controllers` (37 files)
have both grown large enough to trip the link-stage bug as whole
directories now too — split each into two halves and run separately.

### 2.5 Production (static) build — THE DEPLOY ARTIFACT

Production binaries are **fully static** (so they run on the production
host's older glibc 2.35 and ancient system SQLite). All needed static `.a`
libraries are already installed on this machine.

**Known trap:** Ubuntu/Mint's `libxml2.a` drags in ICU, and ICU needs
`libstdc++` linked *after* it on the link line. Crystal's `--link-flags`
places flags too early, so the link fails with `undefined reference to
std::...` errors. The fix is a 2-line compiler wrapper that appends
`-lstdc++` at the end:

```sh
cd /home/rahul.gopinath/Ktistec/ktistec
printf '#!/bin/sh\nexec cc "$@" -lstdc++\n' > /tmp/cc-wrapper
chmod +x /tmp/cc-wrapper
CC=/tmp/cc-wrapper ~/toolchains/crystal-1.19.1-1/bin/crystal build --static --release -o server-new src/ktistec/server.cr
```

- `--release` makes it slow to compile (many minutes). That is normal.
- **Expected, harmless warnings** during linking: "Using 'getaddrinfo' /
  'gethostbyname' / 'getpwuid_r' in statically linked applications requires
  at runtime the shared libraries from the glibc version used for linking."
  The currently-running production binary has the same trait and works.
- Verify the result: `file server-new` must say
  `statically linked` (and "for GNU/Linux"). If it says "dynamically
  linked", do NOT deploy it.
- Do not switch to a musl build without strong reason: it would need every C
  dependency rebuilt against musl (huge effort without Docker) and is
  slightly slower (musl malloc hurts SQLite). Decision recorded 2026-07-20.

### 2.6 Frontend assets

- JS/CSS live in `public/dist/` and are built with `npm run build` (needs
  Node.js). Only needed when `src/assets/`, `package.json`, or webpack config
  change — server-side `.slang` view changes are compiled INTO the binary and
  do not need an asset rebuild.
- **`public/dist/` is NOT tracked in our fork** (untracked working files;
  upstream tracks it only on its `dist` branch — see the tag warning in
  section 1). Rebuilt bundles therefore never show in `git status`. They
  must be copied to production by hand.
- **Node on this machine is v18.19.1, and two things break on it**
  (verified 2026-08-07):
  1. `npm run build` fails with `ReferenceError: crypto is not defined`
     (`serialize-javascript` via `css-minimizer-webpack-plugin` wants the
     global Web Crypto API, which Node exposes by default only from v19).
     **Workaround — use this instead of a bare `npm run build`:**
     ```sh
     NODE_OPTIONS=--experimental-global-webcrypto npm run build
     ```
  2. `npx vitest run` (the JS suite, and the `prebuild` hook) cannot start
     at all: `SyntaxError: The requested module 'node:util' does not
     provide an export named 'styleText'` — that export needs Node 20.12+.
     **The JS tests cannot be run on this machine.** Mitigating factors:
     our fork changes no JavaScript, and upstream gates its own releases
     on this suite (`6c539394`). Installing Node 20+ would close both gaps.
- Sanity-check a rebuild without running the tests: webpack prints
  `modules by path ./src/assets/js/controllers/*.js ... N modules`; `N` must
  equal `ls src/assets/js/controllers/*.js | wc -l`. Controllers are
  auto-registered by `require.context` in `src/assets/js/main.js`, so a
  missing file fails silently at runtime rather than at build time.
- If assets changed, the changed files under `public/` must be copied to the
  production host's `~/ktistec/rootdir/app/public/` as part of the deploy.

---

## 3. The production server

### 3.1 Access and layout

- Reachable as: `ssh web` (host `instance-web`, Oracle Cloud, Ubuntu 22.04,
  user `rahul`). **Only this host. Never ssh anywhere else.**
- App directory: `/home/rahul/ktistec/rootdir/app/` containing:
  - `server` — the live binary (static ELF)
  - `server.YYYY-MM-DD*` — dated previous binaries (the rollback mechanism)
  - `ktistec.db` — SQLite database, ~3.8 GB, in **WAL mode**
    (`ktistec.db-wal` and `ktistec.db-shm` sidecar files are normal)
  - `etc/` — runtime files incl. `etc/database/schema.sql` (needed at boot)
  - `public/` — static assets incl. `public/uploads` (user media)
- Control directory: `/home/rahul/ktistec/` with a `Makefile`:
  - `make start-server` — runs the server in the foreground
    (`LOG_LEVEL=INFO ./server` in the app dir)
  - `make stop` — `killall -9 server` (blunt but the established method)
  - `make checklock` — shows who holds the database file
  - `make backup` — tars db + uploads. **ONLY SAFE WITH THE SERVER STOPPED**
    (WAL mode; a raw tar of a live db can miss up to 64 MB of recent writes).
- The server runs **inside a tmux session** owned by user `rahul`, in a
  window named **`server`** (session `0`), in the foreground. There is NO
  systemd unit for it. To restart it you attach to tmux (`tmux attach`),
  Ctrl-C the running server (or `make stop` from another shell), and run
  `make start-server` again.
- Docker artifacts on the server (docker Makefile targets, docker.pid, etc.)
  are legacy. The app runs as a bare binary.
- **Watchdog:** `~/ktistec/watchdog.sh` runs in a loop forever, in its own
  tmux window in session `0` — intended to be a window named **`watchdog`**.
  **Reality as of 2026-08-05: it is running, but from an ordinary
  interactive window (`0:1`, named `bash`), not from a window named
  `watchdog`.** So the "is it alive?" check below must be by process, not by
  window name:
  `ssh web 'pgrep -af watchdog.sh'` (authoritative) — `tmux list-windows -t 0`
  will show no `watchdog` window even though it is running. If you get the
  chance during a maintenance window, restart it in a properly named window
  (see the recreate command below) so the name-based check works again.
  It checks every 15 s for a
  running `server` process (`pgrep -x server`); if the process is gone
  (e.g. OOM-killed — this has happened on this 956 MB/no-swap host), it
  sends `cd ~/ktistec && make start-server` to the `server` window. It does
  NOT do HTTP health checks — the app can be slow-but-alive for tens of
  seconds under load (see 3.3), and restarting a merely-slow server would
  be actively harmful.
  - The script targets tmux windows **by name** (`0:server`), not index —
    window indices shift whenever any window opens/closes (e.g. someone
    attaching interactively and closing panes), which has already caused a
    silent failure once. What matters for the script to work is that the
    window named **`server`** exists; that is what it sends the restart
    command to. **Do not rename it**, and if you manually create/close
    windows in this session, verify with `tmux list-windows -t 0` that
    `server` is still there afterward.
  - Crash-loop guard: if it has to restart 3 times within 5 minutes, it
    touches `~/ktistec/watchdog.pause` and stops acting (still logs), so a
    truly broken binary doesn't get restart-looped on this host. Needs
    manual investigation + `make watchdog-resume` after.
  - **Before any manual stop/start or deploy (section 4), run
    `make watchdog-pause` first**, and `make watchdog-resume` after
    verifying the new process is up — otherwise the watchdog may try to
    restart the OLD binary out from under you mid-deploy, right after
    `make stop`.
  - Logs: `~/ktistec/watchdog.log`. State file (recent restart timestamps):
    `~/ktistec/watchdog.restarts`.
  - **If the watchdog process itself ever dies, there is no auto-recovery
    for it** — check periodically with `ssh web 'pgrep -af watchdog.sh'`
    (and `tail ~/ktistec/watchdog.log`, whose last line is normally either a
    `watchdog started` or a restart record). Recreate with:
    `tmux new-window -t 0: -n watchdog 'bash ~/ktistec/watchdog.sh'`
  - Observed history: restarts logged 2026-07-25 00:02 and 2026-07-28 08:02
    (the current server process dates from the latter), and the watchdog was
    last (re)started 2026-07-28 09:19. Those restarts are the OOM-kill
    scenario this host is prone to — see 3.3.

### 3.2 Front end (nginx)

- nginx on `web` proxies port 80 → app on port 3000 for gopinath.org and
  www.gopinath.org.
- An **anonymous-page microcache** is configured:
  - zone: `/etc/nginx/conf.d/ktistec-cache.conf`
  - per-location snippet: `/etc/nginx/snippets/ktistec-microcache.conf`
  - master copies kept in `~/nginx-microcache/` on the server
  - Signed-in users (cookie `__Host-AuthToken`), API clients (Bearer/Basic),
    and SSE streams bypass it. Anonymous pages cached 60 s; 404s 10 s;
    cache key includes a collapsed Accept class (html/ap/json).
  - `proxy_cache_use_stale` means anonymous visitors may be served stale
    pages while the backend is slow — this masks brief backend stalls.

### 3.3 System constraints (IMPORTANT — these drive every decision)

- **RAM: 956 MB total, NO swap, ~180 MB available in steady state.** Do not
  run anything memory-hungry on `web`. Never run two server binaries against
  real load at once for longer than a quick test.
- Disk: 45 GB root, ~25 GB free. A full copy of the 3.8 GB database fits.
- **Crystal is effectively single-threaded**: any long blocking SQLite call
  starves ALL fibers including the HTTP accept loop. This has caused real
  outages (504s for ~40 min — see `FIXES.md` items #7 and #8). Any new code
  that scans large tables must yield between windows
  (see `Fiber.yield` in `src/models/tag.cr`).
- The database is in **WAL mode with busy_timeout=5000 and
  synchronous=NORMAL**, set via URI params in `src/framework/database.cr`.
  Do not remove these.
- Upstream invariant (documented in `src/services/feed/judging.cr`): a feed
  judge pass must NOT yield to another fiber between candidate selection and
  its last verdict write. Do not add `Fiber.yield` there.
- SQLite versions 3.39.x and 3.40.x are banned (recursive-query bugs). The
  static binary embeds its own SQLite (3.45.1 from this build machine's
  libsqlite3-dev), so the server is safe regardless of the host's sqlite.
- `FIXES.md` items #2 (N+1 queries in timeline rendering) and #6
  (13 materialized views reconciled synchronously per delivery) are known,
  still-open performance issues. Keep them in mind when reviewing upstream
  changes.

---

## 4. How to deploy / migrate

Migrations run **automatically when the server binary starts**. There is no
separate migrate command. Deploying a new binary = migrating.

### 4.0 Before deploying: know what migrations will run

Compare repo migrations against what production has applied (read-only,
safe while the server runs):

```sh
# List migration ids present in the repo:
ls src/database/migrations/ | sed 's/-.*//' | sort -n > /tmp/repo-mig.txt
# List migration ids applied in production:
ssh web 'sqlite3 "file:/home/rahul/ktistec/rootdir/app/ktistec.db?mode=ro" "SELECT id FROM migrations ORDER BY id"' | sort -n > /tmp/prod-mig.txt
diff /tmp/repo-mig.txt /tmp/prod-mig.txt
```

Notes:
- Ids compare **numerically** (`000011` in a filename equals `11` in the
  table — not a discrepancy).
- Production legitimately contains two ids (10, 19) whose files upstream
  later deleted. Ignore them.
- For each genuinely pending migration, READ ITS SOURCE in
  `src/database/migrations/`. If it scans or rewrites a large table
  (`objects`, `activities`, `relationships`, `tags` — all million-row scale),
  expect long runtime and test it against a copy of the database first.
  History: an unbatched reconcile migration once ran >24 h until an
  `ANALYZE` was added (FIXES.md #7). Small-table migrations (feeds, accounts,
  etc.) take seconds.

### 4.1 Build and stage

```sh
# on the build machine, in the repo (after type-check + tests pass):
CC=/tmp/cc-wrapper ~/toolchains/crystal-1.19.1-1/bin/crystal build --static --release -o server-new src/ktistec/server.cr
file server-new                      # MUST say "statically linked"
scp server-new web:/home/rahul/ktistec/rootdir/app/server-new
```

### 4.2 Stop, back up, swap, start

Do all of this in one sitting; the site is down from "stop" to "start".

```sh
ssh web
cd ~/ktistec && make watchdog-pause   # stop the watchdog from "helping" mid-deploy
cd ~/ktistec/rootdir/app

# 1. Stop the server (or Ctrl-C inside the tmux session):
cd ~/ktistec && make stop && sleep 2 && make checklock   # should show nothing holding the db
cd ~/ktistec/rootdir/app

# 2. CHECKPOINT THE WAL, then back up (server MUST be stopped):
#    `make stop` is `killall -9`, NOT a clean shutdown, so the WAL is NOT
#    checkpointed and `ktistec.db-wal` still holds recent writes (4.2 MB on
#    2026-08-07). A plain `cp` of ktistec.db alone would SILENTLY LOSE them.
#    Opening the db with sqlite3 recovers the WAL; TRUNCATE then removes it.
sqlite3 ktistec.db "PRAGMA wal_checkpoint(TRUNCATE);"   # prints "0|0|0"
ls ktistec.db-wal 2>/dev/null   # must now be GONE before you copy
cp ktistec.db ktistec.db.pre-$(date +%F)                # ~90s for 2.4 GB
# (equally valid, and WAL-safe without the checkpoint:
#  sqlite3 ktistec.db ".backup ktistec.db.pre-$(date +%F)")

# Do NOT run `PRAGMA quick_check` here. On this host it reads the whole
# 2.4 GB database and had not finished after 10 minutes of extra downtime
# (tried 2026-08-07, abandoned). It is safe to interrupt (read-only), but
# it is not part of the procedure — run it offline against a copy instead.

# 3. Keep the old binary (rollback path):
cp server server.$(date +%F)-pre-deploy

# 4. Swap in the new binary:
mv server-new server && chmod +x server

# 5. Start (inside tmux! run `tmux attach` first, or `tmux new -s ktistec`):
cd ~/ktistec && make start-server
# Watch the output: migrations print as "<name>: applied in X.XXs",
# then "Ktistec is ready to lead at http://0.0.0.0:3000".
```

Starting it **non-interactively** (no attach) — send the command to the
`server` window, the same way the watchdog does:

```sh
ssh web 'tmux send-keys -t 0:server "cd ~/ktistec && make start-server" Enter'
ssh web 'tmux capture-pane -t 0:server -p | tail -25'          # live tail
ssh web 'tmux capture-pane -t 0:server -p -S -3000 | grep -iE "applied in|ready to lead"'
```

Reading that log after a deploy — two things that look alarming and are not:

- **`make: *** [Makefile:2: start-server] Error 137`** is the OLD server
  dying from your own `make stop` (137 = 128+SIGKILL). Expected.
- **Timestamps matter.** The tmux scrollback still holds the previous
  process's output, including its slow queries. Check the clock before
  attributing a slow query to the new binary.

### 4.3 Verify after start

```sh
# from anywhere:
ssh web 'curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://localhost:3000/'
ssh web 'curl -s -H "Host: gopinath.org" http://localhost:3000/.well-known/nodeinfo/2.1'  # check "version"
```

Also load https://gopinath.org in a browser, and watch the tmux log for
errors for a few minutes. Once satisfied, resume the watchdog:
`cd ~/ktistec && make watchdog-resume`.

### 4.4 ROLLBACK (if migration fails or the new binary misbehaves)

A binary rollback alone is NOT sufficient once migrations have run
(migrations can drop/alter columns the old code needs). Roll back BOTH:

```sh
ssh web
cd ~/ktistec && make watchdog-pause          # if not already paused from the deploy
make stop
cd ~/ktistec/rootdir/app
rm -f ktistec.db-wal ktistec.db-shm          # discard sidecars of the bad run
mv ktistec.db ktistec.db.failed-$(date +%F)  # keep for diagnosis
cp ktistec.db.pre-YYYY-MM-DD ktistec.db      # the backup made in step 4.2(2)
cp server.YYYY-MM-DD-pre-deploy server       # the binary saved in step 4.2(3)
cd ~/ktistec && make start-server            # inside tmux
# once verified: make watchdog-resume
```

Anything federated (posts received) between deploy and rollback is lost from
the local db; the Fediverse largely redelivers/refetches over time. That is
accepted.

### 4.5 Testing a new binary on `web` without touching production

Verified-safe pattern (used 2026-07-20): run the binary from /tmp against a
scratch database on a spare port. It needs `etc/database/schema.sql`
relative to its working directory:

```sh
scp server-new web:/tmp/server-test
ssh web 'mkdir -p /tmp/kt-test/etc/database'
scp etc/database/schema.sql web:/tmp/kt-test/etc/database/
ssh web 'cd /tmp/kt-test && chmod +x /tmp/server-test && \
  KTISTEC_DB=/tmp/kt-test/test.db /tmp/server-test -p 3999 > boot.log 2>&1 & \
  sleep 20 && curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3999/ && \
  pkill -f server-test'
ssh web 'rm -rf /tmp/kt-test /tmp/server-test'    # clean up
```

Expect `200`. Keep such tests short (memory is tight).

For a realistic migration rehearsal, copy the production db (server stopped,
or use `sqlite3 ... ".backup"` live) to `/tmp` — 25 GB free is enough — and
boot the new binary against the copy with `KTISTEC_DB=` pointing at it, then
delete the copy.

---

## 5. Quick path reference

| What | Where |
|---|---|
| Repo (build machine) | `/home/rahul.gopinath/Ktistec/ktistec` |
| Performance findings / applied fixes | `FIXES.md` (repo root) |
| Watchdog script (source of truth; copy to `web:~/ktistec/watchdog.sh` if it changes) | `ops/watchdog.sh` (repo root) |
| Portable Crystal (install if missing) | `~/toolchains/crystal-1.19.1-1/bin/crystal` |
| Production ssh alias | `ssh web` (user `rahul`) — the ONLY remote host |
| Live app dir | `web:/home/rahul/ktistec/rootdir/app/` |
| Live database | `web:/home/rahul/ktistec/rootdir/app/ktistec.db` |
| Ops Makefile | `web:/home/rahul/ktistec/Makefile` |
| Migration-timing log (2026-07 upgrade) | `web:/home/rahul/ktistec/REMAINING.md` |
| nginx cache configs (masters) | `web:~/nginx-microcache/`, installed under `/etc/nginx/` |
| Server run context | tmux session on `web`, foreground process |

## 6. Rules that must not be broken

1. **No Docker.** Anywhere.
2. **No ssh to any host except `web`.**
3. **Never back up `ktistec.db` with tar/cp while the server is running**
   (WAL). Stop it first, or use `sqlite3 ... ".backup"`.
4. **Always take a database backup + keep the old binary before deploying**;
   a deploy runs migrations, and rollback needs both.
5. **Deploy binaries must be static** (`file` says "statically linked").
6. **Read pending migrations before deploying**; anything touching
   `objects`, `activities`, `relationships`, or `tags` needs a rehearsal on
   a database copy first.
7. **Mind the 956 MB / no-swap host** — don't run heavy extra processes on
   `web`.
8. Long scans in server code must `Fiber.yield` between windows — except in
   feed judging, where yielding is forbidden (see 3.3).
9. **Pause the watchdog (`make watchdog-pause`) before any manual stop/start
   or deploy**, and resume it (`make watchdog-resume`) only after verifying
   the new process is healthy (see 3.1).
