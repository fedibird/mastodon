# Hashtag unification deployment runbook

This document is for administrators who operate Fedibird servers.

It describes how to deploy the staged hashtag-unification work safely. It is
not a developer implementation guide.

The migration is intentionally split into reversible stages. Do not treat all
hashtag-unification updates as equivalent. The operational procedure depends
on which stage a release contains.

## 1. Current state

As of commit `e9681bc57003e95c697d2ddee3d8b05703b045ac`:

- U1 schema expansion is merged.
- U2 backfill and parity tooling is merged.
- U3a legacy-to-new dual-write is merged.
- Runtime reads, hashtag fan-out, API responses, Settings UI, and FeedManager
  still use the legacy `FollowTag` representation.
- The new `TagFollow` + `TagFollowDelivery` representation is a synchronized
  mirror.
- Legacy `follow_tags` remains authoritative.
- Read cutover has not happened yet.

The additive schema migration is:

```text
db/migrate/20260919213000_create_tag_follows_and_deliveries.rb
```

## 2. Safety rule

At every stage before legacy cleanup:

> Do not continue to a read cutover unless `hashtag_unification:follow_tag_parity`
> reports `"ok": true`.

Do not use row counts alone as a substitute for parity. The validator also
checks missing/extra relations, missing/extra destinations, destination
`media_only`, zero-delivery relations, orphaned Lists, and List ownership.

Do not drop `follow_tags` merely because the new tables are populated.

## 3. Release channels

Operators maintaining more than one Fedibird server should use a canary-first
rollout.

Recommended order:

```text
small canary / nightly server
        ↓
parity + normal user-operation verification
        ↓
main production server
        ↓
wider third-party rollout
```

For the official Fedibird deployment this means:

```text
nightly.fedibird.com
        ↓
fedibird.com
```

Do not promote a hashtag-unification stage from the canary to the main server
while parity is false or hashtag-follow operations are producing application
errors.

## 4. Before every hashtag-unification deployment

Record the currently deployed Git commit so rollback has an unambiguous target.

Take the normal database backup required by your site's upgrade policy.

If the new release contains U3a or any later stage, inspect current parity
before deploying:

```bash
RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity
```

If the task reports `"ok": true`, continue.

If it reports differences while legacy `follow_tags` is still authoritative,
repair the mirror before continuing:

```bash
RAILS_ENV=production APPLY=1 bundle exec rake hashtag_unification:follow_tag_backfill
```

Then rerun parity.

Do not continue to a read-cutover release while parity remains false.

## 5. Deploying U1/U2/U3a for the first time

An administrator may upgrade directly from an older Fedibird revision to a
revision containing U1, U2, and U3a. Intermediate releases do not need to be
deployed separately.

### 5.1 Apply schema expansion before starting U3a application processes

Run the normal application update steps, but ensure the database migration is
applied before web/worker processes running U3a begin accepting writes:

```bash
RAILS_ENV=production bundle exec rails db:migrate
```

The migration creates additive tables and constraints. It does not remove
`follow_tags`.

For a multi-process or multi-node installation, the safest order is:

```text
old application code still running
        ↓
apply additive db:migrate
        ↓
roll application/worker processes to new code
        ↓
final catch-up backfill
        ↓
parity check
```

Old processes may still write only `follow_tags` during a rolling restart.
This is expected. The final catch-up backfill closes that deployment window.

### 5.2 Run one final catch-up backfill after all processes use U3a

After all web and worker processes have been restarted on the new code:

```bash
RAILS_ENV=production APPLY=1 bundle exec rake hashtag_unification:follow_tag_backfill
```

Do not use `PRUNE=1` during a normal deployment.

Then run:

```bash
RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity
```

The required result is:

```json
{
  "differences": {
    "missing_tag_follows": 0,
    "extra_tag_follows": 0,
    "missing_deliveries": 0,
    "extra_deliveries": 0,
    "media_only_mismatches": 0
  },
  "ok": true
}
```

Exact row counts vary by server and are not success criteria.

## 6. U3a post-deployment verification

U3a changes the write path but not the read path.

After deployment, use the existing Fedibird UI/API to exercise ordinary
hashtag-follow operations. At minimum verify:

```text
create Home hashtag follow
create List-only hashtag follow
change media_only
add/remove a List destination
remove a Home destination while a List destination remains
remove the final destination
```

Then run parity again:

```bash
RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity
```

It should remain `"ok": true` without another bulk backfill.

U3a mirrors normal Active Record `FollowTag` create/update/destroy operations
inside the same database transaction.

Raw SQL and callback-bypassing operations such as `insert_all`, `update_all`,
or `delete_all` do not run the mirror callback. If administrative maintenance
uses those operations against `follow_tags`, rerun the APPLY backfill and
parity afterwards.

## 7. U3a rollback

U3a is deliberately rollback-friendly because legacy `follow_tags` remains
authoritative and all runtime reads still use it.

If U3a causes write errors:

1. roll application code back to the previously known-good revision;
2. do not drop `tag_follows` or `tag_follow_deliveries`;
3. keep the U1 migration applied;
4. continue operating from legacy `follow_tags`;
5. before attempting U3a again, rerun APPLY backfill and parity.

After code rollback, new legacy writes will no longer be mirrored until U3a is
deployed again. That is acceptable because U2 backfill can catch the new tables
up later.

Do not attempt a schema rollback merely to roll back U3a application code.

## 8. U3b read/fan-out cutover

U3b is a future stage and must be treated as a higher-risk release.

A U3b release may switch any of the following to the new representation:

```text
standard hashtag follow/unfollow API
followed-tags reads
Fedibird follow_tags compatibility API
Settings UI
FanOutOnWriteService
FeedManager
relationship presentation / serializers
```

Before deploying U3b:

- U3a must already be deployed and stable.
- parity must be `"ok": true` immediately before deployment.
- no unresolved mirror/write errors should exist.
- the canary server must complete normal hashtag-follow/fan-out verification.
- legacy `follow_tags` must remain present during the initial U3b soak period.

During U3b, continue dual-writing legacy and new structures until the new read
path has been proven in production. This preserves a rollback route.

If a U3b problem occurs, revert application code to the U3a revision and use
legacy reads again. Do not drop either representation during the rollback
window.

## 9. Legacy cleanup / table removal

Removing `follow_tags` is a separate operational boundary.

A release that removes legacy writes, legacy reads, or the legacy table must
not be treated as an ordinary rolling update.

Before such a release, the project should publish explicit release notes
covering:

- the minimum required prior version/stage;
- required parity/preflight commands;
- backup requirements;
- whether maintenance mode is required;
- downgrade limitations;
- any irreversible migration.

Administrators should not manually remove `follow_tags` ahead of that release.

## 10. Tag identity canonicalization is a separate migration

The later Tag identity work (HashtagNormalizer canonicalization and collision
merging) is distinct from FollowTag structural unification and is more
destructive.

Do not infer that successful U3 parity means Tag canonicalization is safe to run.

When that stage is released, administrators must follow its dedicated
preflight/planner instructions. It should include a fresh collision analysis
and migration plan generated from the server's own database.

Do not copy collision counts or survivor mappings from another Fedibird server.

## 11. Meaning of the maintenance commands

Read-only parity:

```bash
RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity
```

Safe to run repeatedly. It does not repair data.

Default backfill command without `APPLY=1`:

```bash
RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_backfill
```

This is a dry run.

Apply/reconcile from authoritative legacy `follow_tags`:

```bash
RAILS_ENV=production APPLY=1 bundle exec rake hashtag_unification:follow_tag_backfill
```

This is idempotent and is the normal repair/catch-up command while legacy
`follow_tags` remains authoritative.

Explicit prune mode:

```bash
RAILS_ENV=production APPLY=1 PRUNE=1 bundle exec rake hashtag_unification:follow_tag_backfill
```

Do not use this as part of routine deployment. It deletes target-only
relations/destinations and is intended only for deliberate reconciliation while
legacy `follow_tags` is unquestionably authoritative.

Never use `PRUNE=1` after the project has declared the new representation
authoritative.

## 12. Promotion criteria for nightly.fedibird.com -> fedibird.com

A hashtag-unification release may be promoted from the canary to the main
Fedibird server when all of the following are true:

```text
db:migrate completed normally
post-deploy catch-up completed normally
parity reports ok: true
ordinary Home follow works
ordinary List-only follow works
media_only update works
destination removal works
final unfollow works
no new hashtag-follow write errors are observed
parity remains ok: true after those operations
```

For U3b and later, also verify actual Home/List delivery behavior before
promotion, because those stages change the read/fan-out path.

## 13. Third-party Fedibird administrators

Third-party installations should not need server-specific migration code.

Each server must, however, run analysis/backfill/parity against its own database.
Do not assume the official fedibird.com row counts apply elsewhere.

An administrator who is unsure whether the server has completed the structural
migration should first run normal `db:migrate`, then run the APPLY backfill
and parity commands in this document.

If parity is false, stop the hashtag-unification promotion at the current
reversible stage and inspect the reported source/target difference rather than
continuing into read cutover or cleanup.
