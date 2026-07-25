# FIXES.md

Running list of identified issues and proposed patches. Entries marked
"applied" have been committed (see each entry's Status line); the rest are
writeups awaiting design, profiling, or review.

---

## 1. Unbounded prepared-statement cache on the single long-lived DB connection

**Status:** applied — as a **bounded cache** (`DB::StringKeyCache` capped at 512
entries with close-on-evict) in `src/framework/ext/sqlite3.cr`, **not** via
`prepared_statements_cache=false` as originally proposed below.

> **Revision discovered during verification:** the originally proposed
> `prepared_statements_cache=false` crashes on first boot ("unable to close
> due to unfinalized statements") and would leak native `sqlite3_stmt`
> handles at runtime. Root cause is an upstream crystal-db defect on the
> `Database#exec` path: `PoolPreparedStatement#build_statement` builds via
> `conn.prepared.build`, which deliberately skips the `auto_close` flag
> (`session_methods.cr` expects "the user" to close explicitly), and
> `perform_exec_and_release` only releases the *connection* — nothing ever
> closes the statement. With the cache on, the cache close at connection
> shutdown was what finalized statements; with it off, nothing does.
> A bounded cache keeps the fast path and caps the leak instead.
**Area:** memory (steady-state, grows for the life of the process)
**Files:** `src/framework/database.cr`

### The problem

`crystal-db`'s `DB::Connection` caches every prepared statement it ever
builds, keyed by the literal SQL text, with no eviction, no size cap, and no
TTL:

```crystal
# lib/db/src/db/string_key_cache.cr
class StringKeyCache(T)
  @cache = {} of String => T

  def fetch(key : String, &) : T
    value = @cache.fetch(key, nil)
    value = @cache[key] = yield unless value
    value
  end
  # cleared only when the connection itself closes
end
```

Caching is enabled by default (`prepared_statements_cache : Bool = true` in
`lib/db/src/db/connection.cr`), and is configurable per-connection via a
standard URI query parameter (`prepared_statements_cache=false`,
`DB::Connection::Options.from_http_params`).

Ktistec opens exactly **one** `DB::Database` connection for the entire life
of the server process:

```crystal
# src/framework/database.cr
@@database : DB::Database = begin
  ...
  DB.open(db_uri)
end
```

`db_uri` never sets `prepared_statements_cache`, so the default (`true`)
applies, and that single connection's statement cache grows for as long as
the process runs — it is never released short of a restart.

### Why this matters (history)

This is precisely the mechanism behind a memory leak reported and fixed
twice in 2022 (CHANGELOG entries under `v2.0.0-4` and `v2.0.0-6`, "Fix a
memory leak caused by string interpolation in query string construction"):

- `00b6395a` "Pass values to queries as arguments" (`src/framework/rule.cr`,
  the old "School" rule-engine pattern matcher — since removed entirely in
  `aea9ab55 Remove School.`)
- `d87000a9` "Pass values to queries as arguments" (`src/workers/task_worker.cr`)
  — changed `ids.map(&.id.to_s).join(",")` interpolated into
  `WHERE id IN (#{ids})` to a parameterized query, because a fresh SQL
  string (and therefore a fresh permanently-cached prepared statement) was
  being minted on every call, one per distinct set of task IDs.

Both known trigger sites were fixed or removed. **The cache itself was never
bounded** — the fixes just stopped those two code paths from feeding it.
Any other code path that builds SQL text with runtime-variable content
(present now or added later) will silently reproduce the same leak, with no
warning, visible only via the `heap-size` / `sqlite-kilobytes` charts that
`Task::Performance` already tracks.

I searched the current codebase for a recurrence of the original pattern
(interpolated ID/IRI lists, dynamic-length placeholder strings, raw search
terms in `LIKE`) and didn't find one — everything I checked now uses `?` +
`args:` correctly. That doesn't retire the underlying risk, though.

### Proposed patch

```diff
--- a/src/framework/database.cr
+++ b/src/framework/database.cr
@@ -6,9 +6,9 @@ require "./ext/sqlite3"
 module Ktistec
   @@db_uri : String = begin
-    ENV["KTISTEC_DB"]?.try { |db| "sqlite3://#{db}" } ||
+    ENV["KTISTEC_DB"]?.try { |db| "sqlite3://#{db}?prepared_statements_cache=false" } ||
       if ENV["KEMAL_ENV"]? == "production"
-        "sqlite3://#{File.expand_path("~/.ktistec.db", home: true)}"
+        "sqlite3://#{File.expand_path("~/.ktistec.db", home: true)}?prepared_statements_cache=false"
       else
-        "sqlite3://ktistec.db"
+        "sqlite3://ktistec.db?prepared_statements_cache=false"
       end
   end
```

### Trade-off

Disabling the cache means every `.exec`/`.query`/`.scalar` call re-parses
its SQL text with SQLite instead of reusing a compiled statement. SQLite's
parser is fast and the app is already I/O-bound rather than CPU-bound on
this box, so this should be a clearly good trade against unbounded growth —
but it's worth confirming with a quick before/after latency check under
normal request load before rolling it out, since it does add per-query
parse overhead on every request, not just the rare cold path.

### Verification plan (not yet done)

1. Apply the patch on a test copy of the DB.
2. Run a long-lived local server under synthetic load (or just leave it
   running idle overnight) and watch `Task::Performance`'s `heap-size` /
   `total-kilobytes` charts flatten out instead of trending upward.
3. Spot-check request latency before/after to quantify the re-parse cost.

---

## 2. N+1 queries rendering every object in every timeline/thread/list view

**Status:** not yet applied (needs design, not a one-line patch)
**Area:** running time (every page load, not just migrations)
**Files:** `src/views/partials/object/content.html.slang`, and (indirectly)
`src/models/activity_pub/object.cr`

### The problem

`content.html.slang` is the partial rendered once **per object** in every
list-of-posts view in the app — `objects/index`, `mentions/index`,
`tags/index`, `objects/thread`, `objects/branch`, `actors/remote`,
`actors/known_posts`, `relationships/objects`, `actors/featured`, and more.

For a logged-in viewer, rendering a single object in that partial issues,
conservatively:

| Call | Line | Query? |
|---|---|---|
| `Tag::Emoji.where(subject: actor)` | 5 | 1 |
| `Tag::Emoji.where(subject: author)` (if `author != actor`) | 6 | 0-1 |
| `Relationship::Content::Pin.find?(actor: for_actor, ...)` (thread context) | ~23 | 0-1 |
| `object.with_statistics!` | 120, 209 | 1 |
| `object.with_replies_count!` (recursive CTE over the reply tree) | 120, 209 | 1 |
| `account.actor.find_like_for(object)` (if `likes_count > 0`) | ~175 | 0-1 |
| `account.actor.find_announce_for(object)` (if `announces_count > 0`) | ~183 | 0-1 |
| `Relationship::Content::Bookmark.find?(...)` | 152 | 1 |
| `Relationship::Content::Pin.find?(actor: account.actor, ...)` (if author is viewer) | 161 | 0-1 |
| `object.translations.first?` | 169 | 1 |
| `object.approved_by?(account.actor)` (if reply-in-own-thread) | 180 | 0-1 |
| `object.activities(inclusion: [...])` (if `with_detail`) | ~272 (per earlier read) | 1 |

That's roughly **6-10 individual queries per rendered object**, none of
which are batched — every one is a separate round trip keyed to that one
object's IRI. A single page of a default-size (10-20 item) timeline
therefore issues on the order of **60-200 queries** just to render the list
that page's own fetch already produced in one query.

`with_replies_count!` is the most expensive of these per-call — it's a
`WITH RECURSIVE` CTE walking the reply chain, not an indexed point lookup —
and it runs once per rendered object, every time that object appears in any
list, anywhere.

### Why this is worse than it looks with SQLite

SQLite is embedded (no network round trip), so the naive "N+1 = death by
network latency" framing undersells the cost here but doesn't erase it:
each call still pays SQL parse + plan + execute. Which brings up an
important interaction with **Fix #1**: right now, `prepared_statements_cache`
being *on* means all these repeated small queries (same SQL shape, just a
different bound IRI each time) reuse a cached, already-parsed statement —
so this N+1 pattern is currently *cheaper than it will be* once #1 ships.
Disabling the cache to fix the memory growth removes that hidden subsidy
and makes every one of these calls pay full parse cost again, every time.
**These two fixes should be evaluated together** — #2 reduces query
*count*, which offsets the added per-query cost that #1 introduces.

### Proposed direction (not a ready patch)

Batch-load per-object data for an entire rendered page in one pass instead
of once per object:

1. Before rendering the list, collect the IRIs of every object on the page.
2. Replace `with_statistics!` with a bulk variant — one query that
   `GROUP BY object_iri` across all IRIs on the page, returning a
   `Hash(String, {announces: Int64, likes: Int64, dislikes: Int64})` — and
   have the per-object call become a hash lookup.
3. Same treatment for replies-count (harder, because of the recursive
   per-object thread walk — may need a single recursive CTE seeded with
   all page IRIs at once rather than one CTE per object), bookmarks, pins,
   and likes/announces-by-viewer (`Bookmark`/`Pin` `.find?` calls collapse
   naturally into one `WHERE object_iri IN (...)` query each, keyed to a
   `Set` for O(1) lookup during render).
4. Emoji lookups (`Tag::Emoji.where(subject: ...)`) collapse into one query
   over the distinct set of actors/authors appearing on the page.

This is a real refactor (touches the partial's calling convention and
several model methods), not a one-liner — I'd want to scope and prototype
it properly rather than patch it blind. Flagging it here so it's tracked;
let me know if you want me to build this out as a real change.

---

## 3. SQLite runs in rollback-journal mode with no busy timeout — writers block all readers

**Status:** applied — `journal_mode=WAL&synchronous=NORMAL&busy_timeout=5000` via `DB_PARAMS` in `src/framework/database.cr`
**Area:** running time (request latency under concurrent load) + robustness
**Files:** `src/framework/database.cr` (same line as Fix #1)

### The problem

Ktistec never configures SQLite's journal mode, busy timeout, or
synchronization level. Verified directly:

- The database file header (bytes 18-19 of the 2024-05-05 production
  backup) reads `1 1` = **rollback (DELETE) journal mode**, not WAL.
  Journal mode is a persistent property of the db file and nothing in
  the code changes it, so production is in the same mode.
- `busy_timeout` is never set (crystal-sqlite3 default: none), so any
  lock contention fails **immediately** with SQLITE_BUSY instead of
  waiting a few milliseconds for the lock to clear.

Consequences in rollback mode:

- **Every write transaction takes an exclusive lock that blocks every
  reader**, and any open reader blocks the writer. A federated server is
  write-heavy in the background (inbox deliveries, 13 materialized-view
  reconciliations per activity — see Fix #6, task bookkeeping every ≤5s —
  see Fix #5) while serving interactive reads. Under rollback mode these
  serialize against each other; page loads stall behind background writes.
- With no busy timeout, contention doesn't even wait — it *errors*.
  Upstream's own history shows this being fought symptomatically:
  `57dd8c0` "Keep the task worker alive in the face of database problems"
  wraps the worker loop in a `rescue SQLite3::Exception`, and
  `77659592` "Reduce database lock time when reconciling tags" shrinks
  one contended window. `busy_timeout` addresses the class.
- Every committed write in rollback mode creates + fsyncs + deletes a
  journal file. On this I/O-starved host (956MB RAM, we observed ~40%
  iowait during migration), fsync count is the dominant cost of writes.

### Proposed patch

The crystal-sqlite3 driver applies pragmas from URI query parameters on
**every** connection open (`lib/sqlite3/src/sqlite3/connection.cr`,
`Options.from_uri` / `pragma_statement`), so this composes with Fix #1
into the same line of `src/framework/database.cr`:

```diff
--- a/src/framework/database.cr
+++ b/src/framework/database.cr
@@ -5,11 +5,13 @@ require "./ext/sqlite3"
 module Ktistec
+  DB_PARAMS = "journal_mode=WAL&synchronous=NORMAL&busy_timeout=5000&prepared_statements_cache=false"
+
   @@db_uri : String = begin
-    ENV["KTISTEC_DB"]?.try { |db| "sqlite3://#{db}" } ||
+    ENV["KTISTEC_DB"]?.try { |db| "sqlite3://#{db}?#{DB_PARAMS}" } ||
       if ENV["KEMAL_ENV"]? == "production"
-        "sqlite3://#{File.expand_path("~/.ktistec.db", home: true)}"
+        "sqlite3://#{File.expand_path("~/.ktistec.db", home: true)}?#{DB_PARAMS}"
       else
-        "sqlite3://ktistec.db"
+        "sqlite3://ktistec.db?#{DB_PARAMS}"
       end
   end
```

- `journal_mode=WAL`: readers no longer block the writer or vice versa;
  writes append to a WAL file instead of journal create/delete cycles.
  The single most impactful concurrency change available to this app.
- `synchronous=NORMAL`: safe in WAL mode (durability of the last commit
  on power loss is traded away; corruption is not a risk). Cuts fsyncs
  from one-per-transaction to one-per-checkpoint. Given hundreds of
  small write transactions per hour, this is a large I/O reduction.
- `busy_timeout=5000`: waits up to 5s for a lock instead of failing
  instantly.

### Caveats

- WAL is persistent: the first boot with this flag converts the db file;
  rolling back the binary does *not* revert the mode (it's harmless for
  old binaries anyway — SQLite ≥3.7 reads WAL databases fine).
- WAL creates `-wal` / `-shm` sidecar files next to the db. **The backup
  target must account for them**: a raw `tar` of just `ktistec.db` can
  miss up-to-64MB of recent writes sitting in the WAL. Using
  `sqlite3 ... ".backup out.db"` (as recommended for live backups)
  handles this correctly; the current tar-based Makefile target is only
  safe when the server is stopped.
- `KTISTEC_DB` values that already contain `?params` would need a `&`
  join — current deployment (`KTISTEC_DB=/db/ktistec.db` in Docker, bare
  path on instance-web) is fine.

---

## 4. Connection-pool churn: every burst of concurrency opens cold connections, then closes them through `PRAGMA optimize`

**Status:** applied — `max_pool_size=4&max_idle_pool_size=4` via `DB_PARAMS` in `src/framework/database.cr`
**Area:** running time (latency spikes under concurrent requests)
**Files:** `src/framework/database.cr` (same URI line), `src/framework/ext/sqlite3.cr`

### The problem

crystal-db pool defaults (verified in `lib/db/src/db/pool.cr`):
`initial_pool_size = 1`, `max_pool_size = 0` (**unlimited**),
`max_idle_pool_size = 1`.

So the steady state is one connection, and any moment of overlap (a page
load racing an inbox delivery racing the task worker) opens brand-new
connections — each paying `sqlite3_open`, the `regexp` and `strip` UDF
registrations, and a cold prepared-statement cache. When released, all
but one idle connection are **closed immediately**, and ktistec's
`do_close` override (`src/framework/ext/sqlite3.cr`) runs
`PRAGMA analysis_limit=400; PRAGMA optimize;` on each close — an ANALYZE
pass on the way out. Under oscillating load this open/optimize/close
cycle repeats continuously.

Unbounded `max_pool_size` is also wrong for SQLite specifically: beyond
a handful of connections there's nothing to parallelize (one writer at a
time), just more lock contention and more memory (each connection has
its own page cache and statement cache).

### Proposed patch

Same URI line as Fixes #1/#3 — crystal-db reads pool options from the
same query string:

```
max_pool_size=4&max_idle_pool_size=4
```

(Keep the two numbers equal: connections then stay warm instead of
churning, `PRAGMA optimize` runs only at real shutdown, and total
connection count is capped at a level SQLite can actually use.)

---

## 5. Task worker issues write transactions every ≤5 seconds, even when idle

**Status:** applied — retention sweep gated to `CLEANUP_INTERVAL` (1 hour) in `src/models/task.cr`; the reservation `UPDATE ... RETURNING` is unchanged (it is the atomic work-claiming mechanism, `4b3a0c3`)
**Area:** running time / background I/O (constant, 24/7)
**Files:** `src/workers/task_worker.cr`, `src/models/task.cr`

### The problem

The worker loop (`src/workers/task_worker.cr:29-55`) wakes at least
every 5 seconds (`timeout(5.seconds)`) and calls
`Task.scheduled(now, reserve: true)` (`src/models/task.cr:148`), which
executes **two write statements per wake, forever, even with zero
pending tasks**:

1. a retention-cleanup `DELETE FROM tasks WHERE ...` (old
   completed/failed tasks), and
2. an `UPDATE tasks SET running = 1 ... RETURNING` reservation.

That's ~17,000 write transactions per day of pure bookkeeping. In the
current rollback journal mode each is a journal-file create/fsync/delete
cycle (see Fix #3); even after WAL they're pointless work — old-task
retention does not need re-checking every 5 seconds.

### Proposed patch (sketch)

Gate the cleanup to a coarse cadence; the reservation UPDATE stays as-is
(a zero-row UPDATE dirties nothing and is the mechanism that atomically
claims work — `4b3a0c3` made it this shape deliberately):

```diff
--- a/src/models/task.cr
+++ b/src/models/task.cr
@@ class Task
+  # tasks are retained for days; checking retention every poll (5s) is waste
+  CLEANUP_INTERVAL = 1.hour
+
+  @@last_cleanup_at : Time = Time::UNIX_EPOCH
+
   def self.scheduled(now = Time.utc, reserve = false)
     if reserve
-      cleanup = <<-SQL
-         DELETE FROM tasks
-         ...
-      SQL
-      exec(cleanup, now - SUCCESSFUL_TASK_RETENTION, now - FAILED_TASK_RETENTION)
+      if now - @@last_cleanup_at >= CLEANUP_INTERVAL
+        @@last_cleanup_at = now
+        cleanup = <<-SQL
+           DELETE FROM tasks
+           ...
+        SQL
+        exec(cleanup, now - SUCCESSFUL_TASK_RETENTION, now - FAILED_TASK_RETENTION)
+      end
```

(Diff is illustrative — the elided SQL is unchanged. Behavior change:
old tasks are purged within an hour instead of within 5 seconds of
eligibility, which is well inside the multi-day retention windows.)

---

## 6. Thirteen materialized views reconciled synchronously inside every activity delivery (observation — profile before touching)

**Status:** observation only, no patch proposed
**Area:** running time (inbox/outbox processing latency)
**Files:** `src/rules/trigger.cr`, `src/rules/maintainer.cr`, `src/rules/view/*.cr`

Every processed activity — inbound (`inbox_activity_processor.cr:100`)
and outbound (`outbox_activity_processor.cr:114`) — synchronously runs
`Rules::Trigger.reconcile_for_activity`, which iterates all **13**
registered views (`src/rules/view/`: announce, dislike, follow,
follow_hashtag, follow_mention, follow_thread, like, mention,
public_tagged, public_timeline, reply, timeline_announce,
timeline_create), projects the object into each, and for each affected
key runs the 2-3-statement reconcile (INSERT-where-missing /
DELETE-where-stale, with correlated `NOT EXISTS` subqueries).

This is upstream's deliberate new architecture (just merged), and most
views project to zero keys for any given activity, so the per-view cost
may be one cheap query. Flagging rather than proposing: after the
deployment settles, use the built-in slow-query log (`log_query` in
`src/framework/model.cr` reports any query >50ms at NOTICE, including
the query plan) to see whether reconciliation shows up in practice
before considering making it asynchronous (e.g., moving it behind the
task worker the way federation delivery already is).

Note the interaction with Fix #3: these reconciliations are write
transactions on the delivery path, so in rollback journal mode they
also stall concurrent page reads. WAL alone may make this a non-issue.

---

## 7. `reconcile-materialized-views` migration runs for days: stale planner statistics

**Status:** applied — `ANALYZE` before the reconcile in
`src/database/migrations/20260612215000-reconcile-materialized-views.cr`

### The problem

The one-time materialized-view cutover migration
(`reconcile-materialized-views`, upstream `20260612215000`) ran for **more
than 24 hours of CPU without completing** on a copy of the production
database (3.8GB, 1.34M relationships, 1.46M activities, single account) —
on a fast machine with the whole database in page cache. On production
hardware (956MB RAM) the projected runtime was weeks.

Per-statement timing of all 13 views' reconcile statements (90s cap)
isolated the bomb: only `Timeline::Announce`'s INSERT and DELETE blew the
cap; every other view finished in seconds.

`EXPLAIN QUERY PLAN` showed why: `sqlite_stat1` on the production database
contained just **two stale rows** (relationships row count claimed 608,244;
actual 1,343,387 — the incremental `PRAGMA analysis_limit=400; PRAGMA
optimize` run at connection close had only ever analyzed two indexes, and
badly). With garbage stats, the planner anchored the view's correlated
`NOT EXISTS` subquery on `idx_relationships_from_iri_type (from_iri=?,
type=?)` — and on a single-account instance that arm matches the entire
~1.1M-row Inbox, re-scanned **per announce activity** (~205k of them):
~2×10¹¹ inner row visits.

After a full `ANALYZE` (8s), the planner enters the same subquery via
`idx_activities_object_iri` + `idx_relationships_to_iri` instead:

| Measurement | before ANALYZE | after ANALYZE |
|---|---|---|
| `Timeline::Announce` membership query | >90s, capped (app: >24h) | **4.4s** |
| Full 13-view reconcile + orphan deletes | never finished | **42.4s** |

Verified end-to-end on an exact replica of the stuck state (same binary,
same migration sequence, same SQLite 3.45.1 the static binary embeds),
inside a rolled-back transaction so the rehearsal database stayed clean.

### The fix

One statement at the top of the migration's `up`: `db.exec "ANALYZE"`.
Statistics persist in the database file, so the later
`reconcile-public-tagged` migration inherits them too.

### Related observations (not fixed here)

- The connection-close `PRAGMA analysis_limit=400; PRAGMA optimize` in
  `ext/sqlite3.cr` is what left the stats in this misleading state —
  two partial rows are worse than none, because the planner trusts them.
  A periodic full `ANALYZE` (e.g. in `Task::Performance`, hourly is
  overkill — daily) would keep runtime plans honest as tables grow.
  Worth considering as a follow-up; it also interacts with Fix #6
  (the per-delivery reconciles use these same membership queries).
- The maintainer's batch DELETE re-evaluates the membership query inside
  a correlated `NOT EXISTS`. With good stats SQLite handles it; a
  temp-table materialization would make the batch path robust to planner
  regressions regardless of stats. Not needed once ANALYZE landed, but
  the natural hardening if this ever recurs.

---

## 8. `ReconcileTagStatistics` full-scans a million tags every 12 hours, starving the event loop

**Status:** mitigated and verified — `Fiber.yield` between scan windows in
`Tag.reconcile_statistics` (`src/models/tag.cr`). Production verification
2026-07-17: during a full cold-cache recount (20:02–20:21 UTC, 19 minutes),
480 front-page probes at 10s intervals all returned HTTP 200, worst latency
3.6s, no 504s at nginx — versus 99 × 504 during that morning's recount on
the previous binary. Confirmed as the cause of
recurring production outages (2026-07-17: site returned 504s for ~40
minutes while the task ran; caught live with the task's `running=1` and a
20s front-page timeout). The yield caps request latency at one window
(~1s on production hardware) instead of the whole recount. The recount's
total I/O cost (full scan of ~1.1M tags with per-row object/actor lookups,
twice daily) still stands — the "cheap no-drift skip" and interval ideas
below remain open.

### The problem

`Task::ReconcileTagStatistics` (new upstream feature) recounts **every
tracked tag** on every run: a windowed scan (window = 500 rows,
`Tag.reconcile_window_size`) over the full `tags` table with per-row
LEFT JOINs into `objects` and `actors`. On the production instance that
is ~1.09M tag rows (768k mentions + 321k hashtags) doing random point
reads across a 3.8GB database on a 956MB host — the first post-upgrade
run read >12GB from disk in its first ten minutes.

Two compounding effects on constrained hardware:

1. **Event-loop starvation.** Crystal is single-threaded; each window
   query is a blocking C call into SQLite, so while a window runs *no*
   fiber runs — including the HTTP accept loop. During the initial
   reconcile the site timed out (>15s) even though the process was
   healthy. The keyset cursor guarantees forward progress, but
   interactivity only returns between windows.
2. **It reruns in full every 12 hours** (`randomized_next_attempt_at`).
   The scan is a recount-from-truth, not incremental over changes, so
   steady-state cost equals first-run cost as the tags table grows.

### Possible directions (needs upstream-minded design)

- Shrink `reconcile_window_size` on small hosts (class property; not
  currently exposed via env/settings) — trades total runtime for
  interactivity between windows.
- Schedule at a longer interval and/or detect "no drift since last run"
  cheaply (e.g. compare `max(tags.id)` + counts by type) before paying
  for a full recount.
- The underlying drift being healed comes from `#update_count`; if
  drift sources were transactional, the reconcile could be a rare
  consistency check instead of a 12-hourly rebuild.

---

## 9. Remote avatar/banner (and attachment) images are hotlinked with no size or dimension cap

**Status:** partially mitigated — banner display height hardened (`min-height`
→ `height` in `.ui.actor.segments > .segment:first-child`,
`src/assets/css/main.less`) so the rendered box can never grow past 18rem
regardless of source image size. The underlying fetch-side exposure below is
**not yet fixed** — tracked here for later, more complete work.
**Area:** bandwidth / privacy / potential DoS via hotlinking
**Files:** `src/utils/avatar.cr`, `src/views/partials/actor-panel.html.slang`,
`src/views/partials/object/content/attachments.html.slang`, and any other
view that renders `actor.icon`, `actor.image`, or attachment URLs

### The problem

Found while looking at a real remote actor's profile (`kaiser_franz@infosec.exchange`,
1405×533px / 330KB header image, unremarkable) and asking why the banner
container has no upper size bound. It turns out the *rendered* box was
already safe (see status above) — `.actor-icon-container` and the type badge
are both `position: absolute`, so nothing in-flow could ever push
`.segment:first-child` taller than its `min-height`. The real gap is one
level up: **Ktistec never fetches, validates, or caches any remote media
before linking to it.**

`Utils::Avatar.url_for` (avatar icons) and `actor_background_style`
(banners) both do the same thing: if the remote actor supplies a
same-scheme, safe-scheme URL, that URL is emitted directly as `src=`/
`background-image: url(...)`, unmodified. Post image attachments
(`attachments.html.slang`, `attachment.url_safe`) follow the identical
pattern. Every viewer's browser fetches the file directly from the remote
origin, full-size, with:

- no `Content-Length` check (and it can't be trusted even if present —
  a malicious server can lie or stream indefinitely),
- no pixel-dimension check,
- no local caching, so the cost repeats on every page view by every
  visitor, and
- no isolation — the remote origin sees every viewer's IP/UA directly
  (a minor privacy leak: viewing a post exposes readers to the
  attributed actor's/attacher's home server).

This is consistent everywhere remote media is shown (avatars, banners,
attachments) — it is not a banner-specific bug, so a real fix should be
scoped as a general media-handling change, not patched per-callsite.

### Why this wasn't fixed now

A proper fix is a new subsystem, not a patch: fetch-with-a-hard-byte-cap
(abort the connection once N bytes have arrived, since headers can't be
trusted), decode-and-validate as an actual image, resize/cache the result,
and rewrite every view that currently emits a raw remote URL to point at
the cached copy instead. That has real design decisions (cache storage
location and eviction, whether fetching happens inline in the request path
or via the task worker, size/dimension limits) and real cost if done
carelessly: this host is 956MB RAM, no swap, single-threaded — synchronous
image fetch/decode in the request path is exactly the shape of problem
that already caused two real outages here (see #7, #8). It needs its own
design pass rather than a same-session patch.

### Possible directions (not yet designed)

- Fetch remote media through the existing task worker (already the
  pattern for federation delivery) rather than inline during page render,
  writing a resized/re-encoded local copy keyed by URL or IRI.
- Cap accepted size during fetch by reading the stream incrementally and
  aborting past a hard limit (e.g. 5–10MB), independent of any
  `Content-Length` header.
- Decide retention/eviction policy for cached media up front — this class
  of "grows forever" mistake is exactly what #1 and #5 were about.
- Consider whether avatars/banners specifically warrant a smaller
  independent limit than post attachments, given they're fetched far more
  often (once per rendered card/panel, vs. once per post view).

---

<!-- Next findings appended below as they're identified. -->
