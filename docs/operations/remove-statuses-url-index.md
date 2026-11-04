# P2 / Issue #693: retire the `statuses.url` index

## Why

P1 (#694) changed local recognition of remote ActivityPub objects to search by
`Status.uri`, with an optional Mastodon-style public-URL-to-URI guess whose
stored `Status.url` is checked only after URI lookup. `Status.url` is still
stored and displayed, but third-party `url` claims do not identify an object.

Production observations supplied on 2026-11-04 JST:

| Index | Size | `idx_scan` before | `idx_scan` after | Delta |
| --- | ---: | ---: | ---: | ---: |
| `index_statuses_on_uri` | 16 GB | 956,526,239 | 956,535,992 | +9,753 |
| `index_statuses_on_url` | 31 GB | 811,433,445 | 811,433,445 | **0** |

The URL index also had zero change in `idx_tup_read` and `idx_tup_fetch`.
These are cumulative counters, **not** proof that an infrequent or scheduled
query never needs the index. The interval between snapshots and reset epoch
were not supplied. Observe a representative interval before approval.

## Scope and safety

- The migration **only** removes `index_statuses_on_url`, using
  `remove_index :statuses, name: ..., algorithm: :concurrently` in a
  `disable_ddl_transaction!` migration.
- It does not remove or rewrite the `statuses.url` column or its contents,
  `index_statuses_on_uri`, or `index_accounts_on_url`.
- It intentionally does **not** use `if_exists`: an unexpected schema should
  fail visibly instead of appearing successful.
- It includes a concurrent `down` migration for recovery, but index creation
  can need an extended window and substantial **additional** disk space.
- **Do not merge this Draft PR or run the migration before the checks below.**
  When merged, normal deployment migrations may execute it automatically.

## Mandatory preflight (read-only)

1. Verify every use of `statuses.url` and raw `status.url` predicates,
   including dynamic SQL, custom tasks, cron/reporting, external clients, and
   other branches; code-path review and grep are complementary:

   ```sh
   rg -n 'index_statuses_on_url|statuses[.]url|statuses\[.url.|Status[.](where|find_by)|status_url|holding_status' app lib db config
   ```

   In particular, inspect calls that filter only by `url`. A query with
   `WHERE uri = ? AND url = ?` is covered by the unique URI index.

2. Check the actual index definition and size in production:

   ```sql
   SELECT c.relname AS index_name,
          pg_get_indexdef(i.indexrelid) AS definition,
          i.indisunique, i.indisvalid, i.indisready,
          pg_size_pretty(pg_relation_size(i.indexrelid)) AS size
   FROM pg_index i
   JOIN pg_class c ON c.oid = i.indexrelid
   WHERE i.indrelid = 'public.statuses'::regclass
     AND c.relname IN ('index_statuses_on_url', 'index_statuses_on_uri');
   ```

3. Measure index usage **twice** with a representative interval that covers
   ordinary traffic and scheduled jobs, and record the timestamp and statistics
   reset time:

   ```sql
   SELECT now() AS observed_at, d.stats_reset, s.indexrelname,
          s.idx_scan, s.idx_tup_read, s.idx_tup_fetch,
          pg_size_pretty(pg_relation_size(s.indexrelid)) AS size
   FROM pg_stat_user_indexes s
   JOIN pg_stat_database d ON d.datname = current_database()
   WHERE s.relname = 'statuses'
     AND s.indexrelname IN ('index_statuses_on_url', 'index_statuses_on_uri')
   ORDER BY s.indexrelname;
   ```

   An increase on the URL index means investigate the SQL or worker before
   dropping it. `pg_stat_statements` (if configured) and Postgres slow-query
   logs can reveal less-obvious users. Do not reset statistics just to test.

4. Check that URI-based lookup uses its index, without executing a potentially
   expensive query on the live table:

   ```sql
   EXPLAIN
   SELECT id FROM statuses
   WHERE uri = 'https://remote.example/users/alice/statuses/123'
     AND url = 'https://remote.example/@alice/123'
   LIMIT 1;
   ```

5. Before executing, check free disk space, long-running transactions,
   concurrent DDL/maintenance on `statuses`, and the deployer's migration
   automation. Have a recovery plan agreed by the DBA/operator.

## Review and deployment gate

- Run `bundle exec rubocop db/migrate/20261114120000_remove_index_url_from_statuses.rb`
  and inspect the generated `db/schema.rb` after applying migrations in a
  **test or staging** database. Check `db:migrate:status`.
- On staging: run migrations, verify that only the URL index disappeared and
  normal AP URI lookup, public profile links, and StatusReference processing
  still work.
- Schedule production migration **only after** the preflight is signed off.
  `DROP INDEX CONCURRENTLY` allows concurrent reads/writes but may wait for
  conflicting transactions; it cannot run within a transaction block and
  must not run alongside another incompatible DDL operation.
- Post-deploy: verify absence of the URL index via `pg_indexes`, confirm
  `index_statuses_on_uri` remains, record disk space, query latency/errors,
  reference notifications, ActivityPub resolution, and PostgreSQL logs.

## Rollback / stop conditions

If index-dependent code is discovered **before** the migration, stop and
repair it rather than dropping the index. If errors or unexpected latency
appear **after** the migration, investigate query plans and app versions first.

Restore through the migration's `down` method in a deliberately scheduled
maintenance window (do **not** automatically execute it as part of a general
application rollback):

```sh
RAILS_ENV=production bundle exec rails db:migrate:down VERSION=20261114120000
```

This uses `CREATE INDEX CONCURRENTLY` and may be expensive on the multi-hundred-
million-row `statuses` table. Verify headroom for a new index on the order of
the previous **31 GB** plus operational overhead. It does not restore lost
application functionality instantly. After a failed concurrent build, check
`pg_index.indisvalid` and the schema migration state before retrying.

Do not redeploy pre-P1 URL-reverse-lookup code until the necessary index has
been restored or the code has been made index-independent.

References:
- https://github.com/fedibird/mastodon/issues/693
- https://github.com/fedibird/mastodon/pull/694
- https://www.postgresql.org/docs/current/sql-dropindex.html
