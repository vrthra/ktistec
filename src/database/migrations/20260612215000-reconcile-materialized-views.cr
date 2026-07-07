require "../../framework/database"
require "../../utils/database/reconcile_materialized_views"

extend Ktistec::Database::Migration

up do |db|
  # Refresh planner statistics before reconciling. On real instances
  # sqlite_stat1 is stale or nearly empty (the incremental `PRAGMA
  # optimize` run at connection close only ever analyzed a couple of
  # indexes, with a 400-row sampling limit), and with garbage stats
  # the planner anchors Timeline::Announce's correlated NOT EXISTS on
  # idx_relationships_from_iri_type -- on a single-account instance
  # that arm matches the entire Inbox (~1.1M rows on the reference
  # database), re-scanned once per announce activity (~200k), i.e.
  # ~2e11 row visits: the reconcile ran for days. With fresh stats
  # the same subquery enters via idx_activities_object_iri +
  # idx_relationships_to_iri and the full reconcile takes seconds.
  # Measured on a 3.8GB production copy: ANALYZE 8s; membership query
  # >90s (uncompleted, capped) before vs 4.4s after. See FIXES.md #7.
  db.exec "ANALYZE"
  Ktistec::Database::ReconcileMaterializedViews.run(db)
end

down do
end
