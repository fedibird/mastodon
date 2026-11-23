-- PR #710 / Issue #707: read-only PostgreSQL baseline (no EXPLAIN ANALYZE).
-- Run with: psql -X -v ON_ERROR_STOP=1 -f script/feed_delivery_reason_pg_baseline.sql
-- Values are instance-wide/cumulative; compare with matching workload and stats_reset.
BEGIN TRANSACTION READ ONLY;

SELECT clock_timestamp() AS sampled_at,
       datname, stats_reset, numbackends,
       xact_commit, xact_rollback, blks_read, blks_hit,
       tup_returned, tup_fetched, tup_inserted, tup_updated,
       tup_deleted, deadlocks
FROM pg_stat_database
WHERE datname = current_database();

SELECT clock_timestamp() AS sampled_at,
       relname, seq_scan, idx_scan, n_tup_ins, n_tup_upd, n_tup_del,
       n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE relname IN ('keyword_subscribes', 'statuses', 'lists', 'list_accounts')
ORDER BY relname;

SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pg_stat_statements';

COMMIT;
