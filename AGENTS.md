# AGENTS.md — Operating manual for this repository

This file explains how to build, deploy, migrate, back up, and roll back this
system. It is written so that someone (or some tool) with no prior context can
follow it. Read it fully before changing anything. When in doubt, do the
smaller, reversible thing.

Last verified: 2026-07-20.

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

### Branch state (as of 2026-07-20)

- Local `main` = upstream **v3.9.0** + ~21 local commits rebased on top.
- Because of the rebase, pushing to the fork requires:
  `git push --force-with-lease origin main`
- Production runs **3.8.0** (the 3.9 rebase is built and verified but not yet
  deployed). Check the live version any time with:
  `ssh web 'curl -s -H "Host: gopinath.org" http://localhost:3000/.well-known/nodeinfo/2.1'`

### Taking future upstream releases

1. `git fetch o`
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

```sh
cd /home/rahul.gopinath/Ktistec/ktistec
KEMAL_ENV=test ~/toolchains/crystal-1.19.1-1/bin/crystal spec          # full suite (slow)
# or targeted, e.g.:
KEMAL_ENV=test ~/toolchains/crystal-1.19.1-1/bin/crystal spec spec/models/task_spec.cr spec/models/tag_spec.cr
```

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
- **Watchdog:** a tmux window named **`watchdog`** (session `0`) runs
  `~/ktistec/watchdog.sh` in a loop forever. It checks every 15 s for a
  running `server` process (`pgrep -x server`); if the process is gone
  (e.g. OOM-killed — this has happened on this 956 MB/no-swap host), it
  sends `cd ~/ktistec && make start-server` to the `server` window. It does
  NOT do HTTP health checks — the app can be slow-but-alive for tens of
  seconds under load (see 3.3), and restarting a merely-slow server would
  be actively harmful.
  - The script targets tmux windows **by name** (`0:server`), not index —
    window indices shift whenever any window opens/closes (e.g. someone
    attaching interactively and closing panes), which has already caused a
    silent failure once. **Do not rename these two windows**, and if you
    manually create/close other windows in this session, verify with
    `tmux list-windows -t 0` that `server` and `watchdog` still exist
    afterward.
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
  - **If the `watchdog` window itself ever disappears, there is no
    auto-recovery for it** — check for it periodically
    (`tmux list-windows -t 0`) after attaching to the session interactively.
    Recreate with:
    `tmux new-window -t 0: -n watchdog 'bash ~/ktistec/watchdog.sh'`

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
ls ktistec.db-wal 2>/dev/null   # after a clean stop this is usually gone (checkpointed)

# 2. Back up the database (server MUST be stopped):
cp ktistec.db ktistec.db.pre-$(date +%F)
# (equally valid: sqlite3 ktistec.db ".backup ktistec.db.pre-$(date +%F)")

# 3. Keep the old binary (rollback path):
cp server server.$(date +%F)-pre-deploy

# 4. Swap in the new binary:
mv server-new server && chmod +x server

# 5. Start (inside tmux! run `tmux attach` first, or `tmux new -s ktistec`):
cd ~/ktistec && make start-server
# Watch the output: migrations print as "<name>: applied in X.XXs",
# then "Ktistec is ready to lead at http://0.0.0.0:3000".
```

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
