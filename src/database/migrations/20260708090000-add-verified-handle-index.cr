require "../../framework/database"

extend Ktistec::Database::Migration

# `Actor.find_by_handle?` resolves `/remote/actors/user@host` URLs by
# exact `verified_handle` match. Without an index that lookup is a
# full scan of the actors table (measured: 30s over 460k rows) on
# every request for a handle-addressed page -- and queries block the
# event loop, stalling the whole server. The index is partial: only a
# small fraction of cached actors ever have a verified handle, and
# `verified_handle = ?` implies the IS NOT NULL predicate, so SQLite
# uses it. NOCASE matches the query's collation.
up do |db|
  db.exec <<-STR
    CREATE INDEX IF NOT EXISTS idx_actors_verified_handle
      ON actors (verified_handle COLLATE NOCASE)
      WHERE verified_handle IS NOT NULL
  STR
end

down do |db|
  db.exec <<-STR
    DROP INDEX IF EXISTS idx_actors_verified_handle
  STR
end
