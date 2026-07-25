# Shards the Ktistec sqlite database by year, and reconstructs the original
# from a set of shards. See AGENTS.md and ops/README-sharding.md for usage.
#
# Design:
#   - "Owned fact" tables (objects, activities) hold a mix of YOUR OWN
#     authored content (attributed_to_iri / actor_iri matching an account in
#     `accounts`) and cached remote content. Rows you own are NEVER
#     date-partitioned -- they always land in base.db and survive every
#     `prune`, regardless of age. Only remote-authored rows are split by
#     year (2022.db, 2023.db, ...).
#   - "Plain fact" tables (collections, points) are pure caches/metrics with
#     no ownership concept, and are split by year unconditionally.
#   - `relationships` and `tags` are treated as REFERENCE tables (always
#     kept whole, never date-partitioned). On a single-user instance,
#     `relationships.from_iri` is almost always the local actor for
#     bookkeeping rows (inbox/timeline/outbox/notifications) regardless of
#     whether the referenced content is yours or remote, so it can't be
#     used to safely separate "about my content" from "about remote
#     content" -- and the two tables combined are a modest fraction of
#     total size, so there's little to gain from the added risk.
#   - "Reference" tables (accounts, actors, sessions, relationships, tags,
#     etc. -- shared/cross-cutting, not meaningfully date-partitionable)
#     go into a single base.db.
#   - Every shard file gets the FULL schema (all tables + indexes), just
#     sparsely populated, so each .db is independently valid and queryable
#     with plain sqlite3.
#   - manifest.json records, for every table: count/min(id)/max(id)/sum(id)
#     (a cheap fingerprint that catches misclassified or dropped rows, not
#     just a row-count match), plus the exact sqlite_sequence state, so
#     reconstruction can be verified against the original and AUTOINCREMENT
#     continues correctly afterward.

require "sqlite3"
require "db"
require "json"

# table => {date column, ownership column (checked against accounts.iri)}
OWNED_FACT_TABLES = {
  "objects"    => {"created_at", "attributed_to_iri"},
  "activities" => {"created_at", "actor_iri"},
}

# table => date column -- no ownership concept, safe to split purely by date
PLAIN_FACT_TABLES = {
  "collections" => "created_at",
  "points"      => "timestamp",
}

REFERENCE_TABLES = %w[
  accounts actors migrations options sessions tasks
  filter_terms last_times translations oauth_clients
  oauth_access_tokens polls feeds tag_statistics
  relationships tags feed_verdicts quote_decisions
]

def all_tables
  REFERENCE_TABLES + OWNED_FACT_TABLES.keys + PLAIN_FACT_TABLES.keys
end

def schema_statements(db : DB::Database)
  tables = [] of String
  indexes = [] of String
  db.query("SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY name") do |rs|
    rs.each do
      type = rs.read(String)
      name = rs.read(String)
      sql = rs.read(String)
      case type
      when "table" then tables << sql
      when "index" then indexes << sql
      end
    end
  end
  {tables, indexes}
end

def has_id_column?(db : DB::Database, table : String) : Bool
  found = false
  db.query("PRAGMA table_info(#{table})") do |rs|
    rs.each do
      rs.read(Int64)                 # cid
      name = rs.read(String)         # name
      rs.read(String)                # type
      rs.read(Int64 | Int32 | Bool)  # notnull
      rs.read(String?)               # dflt_value
      rs.read(Int64)                 # pk
      found = true if name == "id"
    end
  end
  found
end

# count / min(id) / max(id) / sum(id) -- or just count for id-less tables
# (tag_statistics uses a composite WITHOUT ROWID key).
def fingerprint(db : DB::Database, table : String, with_id : Bool) : Hash(String, Int64)
  if with_id
    count, min_id, max_id, sum_id = db.query_one("SELECT COUNT(*), COALESCE(MIN(id),0), COALESCE(MAX(id),0), COALESCE(SUM(id),0) FROM #{table}") do |rs|
      {rs.read(Int64), rs.read(Int64), rs.read(Int64), rs.read(Int64)}
    end
    {"count" => count, "min_id" => min_id, "max_id" => max_id, "sum_id" => sum_id}
  else
    count = db.query_one("SELECT COUNT(*) FROM #{table}") { |rs| rs.read(Int64) }
    {"count" => count}
  end
end

# sqlite_sequence has NO unique constraint on `name` at the SQL level (SQLite
# maintains it internally without one), so "INSERT OR REPLACE" does not
# de-duplicate -- it just appends. Clear whatever the merge inserts
# auto-populated and replay the captured original rows fresh.
def restore_sequence(db : DB::Database, sequence : Array(JSON::Any))
  db.exec("DELETE FROM sqlite_sequence")
  sequence.each do |row|
    db.exec("INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)", row["name"].as_s, row["seq"].as_i64)
  end
end

def create_schema_db(path : String, tables : Array(String), indexes : Array(String)) : DB::Database
  File.delete(path) if File.exists?(path)
  db = DB.open("sqlite3://#{path}")
  db.exec("PRAGMA synchronous=OFF")
  db.exec("PRAGMA journal_mode=MEMORY")
  tables.each { |sql| db.exec(sql) }
  indexes.each { |sql| db.exec(sql) }
  db
end

def write_json(path : String, & : JSON::Builder ->)
  File.open(path, "w") do |f|
    JSON.build(f, indent: "  ") { |json| yield json }
  end
end

def cmd_shard(source_path : String, out_dir : String)
  abort "source db not found: #{source_path}" unless File.exists?(source_path)
  Dir.mkdir_p(out_dir)

  src = DB.open("sqlite3://#{source_path}?mode=ro")
  tables_sql, indexes_sql = schema_statements(src)

  id_tables = all_tables.to_h { |t| {t, has_id_column?(src, t)} }

  # original per-table fingerprints, for later verification
  totals = all_tables.to_h { |t| {t, fingerprint(src, t, id_tables[t])} }

  sequence = [] of {String, Int64}
  src.query("SELECT name, seq FROM sqlite_sequence") do |rs|
    rs.each { sequence << {rs.read(String), rs.read(Int64)} }
  end

  local_iris = [] of String
  src.query("SELECT iri FROM accounts") { |rs| rs.each { local_iris << rs.read(String) } }
  abort "no local accounts found -- refusing to guess ownership" if local_iris.empty?
  puts "local account iri(s): #{local_iris.join(", ")} (rows owned by these are never date-pruned)"
  owned_placeholders = local_iris.map { "?" }.join(",")

  # year range spanned by every date-bearing fact table (owned tables use
  # their full range too, even though owned rows themselves never land in a
  # year shard -- this just ensures year files exist to cover remote data).
  min_year = nil.as(Int32?)
  max_year = nil.as(Int32?)
  date_cols = OWNED_FACT_TABLES.map { |table, cols| {table, cols[0]} } + PLAIN_FACT_TABLES.to_a
  date_cols.each do |table, col|
    y_min, y_max = src.query_one("SELECT MIN(strftime('%Y', #{col})), MAX(strftime('%Y', #{col})) FROM #{table}") do |rs|
      {rs.read(String?), rs.read(String?)}
    end
    next unless y_min && y_max
    yi_min, yi_max = y_min.to_i, y_max.to_i
    min_year = yi_min if min_year.nil? || yi_min < min_year.not_nil!
    max_year = yi_max if max_year.nil? || yi_max > max_year.not_nil!
  end
  abort "no fact-table data found; nothing to shard" unless min_year && max_year
  years = (min_year.not_nil!..max_year.not_nil!).to_a

  shards = {} of String => NamedTuple(file: String, tables: Hash(String, Hash(String, Int64)))

  # base shard: all reference tables (full copy) + rows YOU own from the
  # owned-fact tables, regardless of how old they are.
  base_file = "base.db"
  base_path = File.join(out_dir, base_file)
  puts "creating #{base_file} (reference tables + your own content, any age)..."
  base_db = create_schema_db(base_path, tables_sql, indexes_sql)
  base_db.exec("ATTACH DATABASE ? AS src", source_path)
  base_counts = {} of String => Hash(String, Int64)
  REFERENCE_TABLES.each do |table|
    base_db.exec("INSERT INTO main.#{table} SELECT * FROM src.#{table}")
    base_counts[table] = fingerprint(base_db, table, id_tables[table])
    puts "  #{table}: #{base_counts[table]["count"]} rows"
  end
  OWNED_FACT_TABLES.each do |table, cols|
    _, owner_col = cols
    base_db.exec("INSERT INTO main.#{table} SELECT * FROM src.#{table} WHERE #{owner_col} IN (#{owned_placeholders})", args: local_iris)
    base_counts[table] = fingerprint(base_db, table, id_tables[table])
    puts "  #{table} (yours, any year): #{base_counts[table]["count"]} rows"
  end
  base_db.exec("DETACH DATABASE src")
  base_db.exec("ANALYZE")
  base_db.close
  shards["base"] = {file: base_file, tables: base_counts}

  # one shard per year: plain fact tables filtered by year; owned fact
  # tables filtered by year AND excluding anything you own (that already
  # went into base above, unconditionally).
  years.each do |year|
    file = "#{year}.db"
    path = File.join(out_dir, file)
    puts "creating #{file}..."
    ydb = create_schema_db(path, tables_sql, indexes_sql)
    ydb.exec("ATTACH DATABASE ? AS src", source_path)
    counts = {} of String => Hash(String, Int64)
    OWNED_FACT_TABLES.each do |table, cols|
      col, owner_col = cols
      ydb.exec(
        "INSERT INTO main.#{table} SELECT * FROM src.#{table} " \
        "WHERE strftime('%Y', #{col}) = ? AND (#{owner_col} IS NULL OR #{owner_col} NOT IN (#{owned_placeholders}))",
        args: [year.to_s] + local_iris
      )
      counts[table] = fingerprint(ydb, table, id_tables[table])
      puts "  #{table} (not yours): #{counts[table]["count"]} rows"
    end
    PLAIN_FACT_TABLES.each do |table, col|
      ydb.exec("INSERT INTO main.#{table} SELECT * FROM src.#{table} WHERE strftime('%Y', #{col}) = ?", year.to_s)
      counts[table] = fingerprint(ydb, table, id_tables[table])
      puts "  #{table}: #{counts[table]["count"]} rows"
    end
    ydb.exec("DETACH DATABASE src")
    ydb.exec("ANALYZE")
    ydb.close
    shards[year.to_s] = {file: file, tables: counts}
  end

  src.close

  # verify: sums across shards must match the original totals exactly
  puts "\nverifying shard totals against source..."
  ok = true
  all_tables.each do |table|
    summed = if id_tables[table]
      {"count" => 0i64, "min_id" => Int64::MAX, "max_id" => 0i64, "sum_id" => 0i64}
    else
      {"count" => 0i64}
    end
    shards.each_value do |shard|
      next unless (t = shard[:tables][table]?)
      summed["count"] = summed["count"] + t["count"]
      if id_tables[table] && t["count"] > 0
        summed["min_id"] = Math.min(summed["min_id"], t["min_id"])
        summed["max_id"] = Math.max(summed["max_id"], t["max_id"])
        summed["sum_id"] = summed["sum_id"] + t["sum_id"]
      end
    end
    summed["min_id"] = 0i64 if id_tables[table] && summed["count"] == 0
    expected = totals[table]
    if summed != expected
      ok = false
      puts "  MISMATCH #{table}: expected #{expected} got #{summed}"
    else
      puts "  ok #{table}: #{summed["count"]} rows"
    end
  end
  abort "\nSHARD VERIFICATION FAILED -- shards do not reconstruct the original" unless ok
  puts "\nall tables verified: shards sum to exactly the original data."

  manifest_path = File.join(out_dir, "manifest.json")
  write_json(manifest_path) do |json|
    json.object do
      json.field "tool_version", 1
      json.field "generated_at", Time.utc.to_rfc3339
      json.field "source_db", File.expand_path(source_path)
      json.field "source_size_bytes", File.size(source_path)
      json.field "granularity", "year"
      json.field "local_iris" { json.array { local_iris.each { |i| json.string i } } }
      json.field "owned_fact_tables" do
        json.object { OWNED_FACT_TABLES.each { |t, cols| json.field(t) { json.array { json.string cols[0]; json.string cols[1] } } } }
      end
      json.field "plain_fact_tables" { json.object { PLAIN_FACT_TABLES.each { |t, c| json.field t, c } } }
      json.field "reference_tables" { json.array { REFERENCE_TABLES.each { |t| json.string t } } }
      json.field "schema" do
        json.object do
          json.field "tables" { json.array { tables_sql.each { |s| json.string s } } }
          json.field "indexes" { json.array { indexes_sql.each { |s| json.string s } } }
        end
      end
      json.field "sqlite_sequence" do
        json.array do
          sequence.each do |name, seq|
            json.object do
              json.field "name", name
              json.field "seq", seq
            end
          end
        end
      end
      json.field "totals" do
        json.object do
          all_tables.each do |table|
            json.field table do
              json.object { totals[table].each { |k, v| json.field k, v } }
            end
          end
        end
      end
      json.field "shards" do
        json.object do
          shards.each do |key, shard|
            json.field key do
              json.object do
                json.field "file", shard[:file]
                json.field "tables" do
                  json.object do
                    shard[:tables].each do |table, fp|
                      json.field(table) { json.object { fp.each { |k, v| json.field k, v } } }
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  puts "\nmanifest written: #{manifest_path}"
end

def cmd_reconstruct(shards_dir : String, out_path : String)
  manifest_path = File.join(shards_dir, "manifest.json")
  abort "manifest not found: #{manifest_path}" unless File.exists?(manifest_path)
  manifest = JSON.parse(File.read(manifest_path))

  tables_sql = manifest["schema"]["tables"].as_a.map(&.as_s)
  indexes_sql = manifest["schema"]["indexes"].as_a.map(&.as_s)

  abort "output already exists, refusing to overwrite: #{out_path}" if File.exists?(out_path)
  puts "creating #{out_path} with full schema..."
  out_db = create_schema_db(out_path, tables_sql, indexes_sql)

  shards = manifest["shards"].as_h
  shards.each do |key, shard|
    file = shard["file"].as_s
    path = File.join(shards_dir, file)
    abort "missing shard file: #{path}" unless File.exists?(path)
    puts "merging #{file}..."
    out_db.exec("ATTACH DATABASE ? AS shard", path)
    all_tables.each do |table|
      out_db.exec("INSERT INTO main.#{table} SELECT * FROM shard.#{table}")
    end
    out_db.exec("DETACH DATABASE shard")
  end

  # restore AUTOINCREMENT counters exactly as they were in the source
  restore_sequence(out_db, manifest["sqlite_sequence"].as_a)

  out_db.exec("PRAGMA synchronous=NORMAL")
  out_db.exec("PRAGMA journal_mode=DELETE")

  # Without this, the query planner has no statistics for the merged data's
  # actual row-count distribution and can pick catastrophic join plans (this
  # caused a real production incident: a query hung, pegging one CPU core
  # for 6+ minutes, blocking all other requests on this single-threaded
  # server, until ANALYZE was run by hand).
  puts "running ANALYZE..."
  out_db.exec("ANALYZE")

  puts "\nverifying reconstructed data against manifest totals..."
  totals = manifest["totals"].as_h
  ok = true
  id_tables = all_tables.to_h { |t| {t, has_id_column?(out_db, t)} }
  all_tables.each do |table|
    expected = totals[table].as_h.transform_values(&.as_i64)
    actual = fingerprint(out_db, table, id_tables[table])
    if expected != actual
      ok = false
      puts "  MISMATCH #{table}: expected #{expected} got #{actual}"
    else
      puts "  ok #{table}: #{actual["count"]} rows"
    end
  end

  integrity = out_db.query_one("PRAGMA integrity_check") { |rs| rs.read(String) }
  puts "\nintegrity_check: #{integrity}"
  ok &&= integrity == "ok"

  out_db.close

  if ok
    puts "\nRECONSTRUCTION VERIFIED: #{out_path} matches the original data exactly."
  else
    abort "\nRECONSTRUCTION FAILED VERIFICATION -- do not trust #{out_path}"
  end
end

# Builds a lean database containing the base (reference) shard plus only
# fact-table shards from `cutoff_year` onward -- for shrinking a live
# database while keeping the excluded years safely in the shard archive.
def cmd_prune(shards_dir : String, out_path : String, cutoff_year : Int32)
  manifest_path = File.join(shards_dir, "manifest.json")
  abort "manifest not found: #{manifest_path}" unless File.exists?(manifest_path)
  manifest = JSON.parse(File.read(manifest_path))

  tables_sql = manifest["schema"]["tables"].as_a.map(&.as_s)
  indexes_sql = manifest["schema"]["indexes"].as_a.map(&.as_s)

  abort "output already exists, refusing to overwrite: #{out_path}" if File.exists?(out_path)

  shards = manifest["shards"].as_h
  kept_keys = shards.keys.select { |key| key == "base" || key.to_i >= cutoff_year }
  dropped_keys = shards.keys - kept_keys
  abort "nothing would be dropped -- cutoff_year #{cutoff_year} keeps everything" if dropped_keys.empty?

  puts "keeping shards: #{kept_keys.sort.join(", ")}"
  puts "archiving only (dropped from production): #{dropped_keys.sort.join(", ")}"

  puts "\ncreating #{out_path} with full schema..."
  out_db = create_schema_db(out_path, tables_sql, indexes_sql)

  kept_keys.each do |key|
    file = shards[key]["file"].as_s
    path = File.join(shards_dir, file)
    abort "missing shard file: #{path}" unless File.exists?(path)
    puts "merging #{file}..."
    out_db.exec("ATTACH DATABASE ? AS shard", path)
    all_tables.each do |table|
      out_db.exec("INSERT INTO main.#{table} SELECT * FROM shard.#{table}")
    end
    out_db.exec("DETACH DATABASE shard")
  end

  # Restore AUTOINCREMENT counters from the ORIGINAL (full) data, not just
  # the kept subset. This guarantees future ids on the pruned production db
  # never collide with ids already used in the archived (dropped) shards,
  # so a later full reconstruction (archive + a future production backup)
  # stays valid.
  restore_sequence(out_db, manifest["sqlite_sequence"].as_a)

  out_db.exec("PRAGMA synchronous=NORMAL")
  out_db.exec("PRAGMA journal_mode=DELETE")

  # See the matching comment in cmd_reconstruct -- skipping this caused a
  # real production incident (query planner picked a catastrophic plan with
  # no stats for the new row-count distribution, pegging one CPU core for
  # 6+ minutes and blocking every other request on this single-threaded
  # server).
  puts "running ANALYZE..."
  out_db.exec("ANALYZE")

  puts "\nverifying pruned data against kept-shard totals..."
  id_tables = all_tables.to_h { |t| {t, has_id_column?(out_db, t)} }
  ok = true
  all_tables.each do |table|
    expected = if id_tables[table]
      {"count" => 0i64, "min_id" => Int64::MAX, "max_id" => 0i64, "sum_id" => 0i64}
    else
      {"count" => 0i64}
    end
    kept_keys.each do |key|
      t = shards[key]["tables"][table]?
      next unless t
      tc = t["count"].as_i64
      expected["count"] = expected["count"] + tc
      if id_tables[table] && tc > 0
        expected["min_id"] = Math.min(expected["min_id"], t["min_id"].as_i64)
        expected["max_id"] = Math.max(expected["max_id"], t["max_id"].as_i64)
        expected["sum_id"] = expected["sum_id"] + t["sum_id"].as_i64
      end
    end
    expected["min_id"] = 0i64 if id_tables[table] && expected["count"] == 0
    actual = fingerprint(out_db, table, id_tables[table])
    if expected != actual
      ok = false
      puts "  MISMATCH #{table}: expected #{expected} got #{actual}"
    else
      puts "  ok #{table}: #{actual["count"]} rows"
    end
  end

  integrity = out_db.query_one("PRAGMA integrity_check") { |rs| rs.read(String) }
  puts "\nintegrity_check: #{integrity}"
  ok &&= integrity == "ok"

  out_db.close

  if ok
    puts "\nPRUNE VERIFIED: #{out_path} contains exactly the kept shards' data."
    puts "Dropped years are archived ONLY in the shard set (#{shards_dir}), not in this file: #{dropped_keys.sort.join(", ")}"
  else
    abort "\nPRUNE FAILED VERIFICATION -- do not deploy #{out_path}"
  end
end

case ARGV[0]?
when "shard"
  source = ARGV[1]? || abort "usage: db_shard_tool shard <source.db> <out_dir>"
  out_dir = ARGV[2]? || abort "usage: db_shard_tool shard <source.db> <out_dir>"
  cmd_shard(source, out_dir)
when "reconstruct"
  shards_dir = ARGV[1]? || abort "usage: db_shard_tool reconstruct <shards_dir> <out.db>"
  out_path = ARGV[2]? || abort "usage: db_shard_tool reconstruct <shards_dir> <out.db>"
  cmd_reconstruct(shards_dir, out_path)
when "prune"
  shards_dir = ARGV[1]? || abort "usage: db_shard_tool prune <shards_dir> <out.db> <cutoff_year>"
  out_path = ARGV[2]? || abort "usage: db_shard_tool prune <shards_dir> <out.db> <cutoff_year>"
  cutoff_year = (ARGV[3]? || abort "usage: db_shard_tool prune <shards_dir> <out.db> <cutoff_year>").to_i
  cmd_prune(shards_dir, out_path, cutoff_year)
else
  abort "usage: db_shard_tool shard <source.db> <out_dir>\n" \
        "       db_shard_tool reconstruct <shards_dir> <out.db>\n" \
        "       db_shard_tool prune <shards_dir> <out.db> <cutoff_year>  (keep cutoff_year..present, archive the rest)"
end
