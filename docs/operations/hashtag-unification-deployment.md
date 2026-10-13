# Hashtag unification deployment and rollback runbook

**Reviewed against the `fedibird` codebase: 2026-10-13 (JST), through U3b-3e / PR #134.**

This is an **operator runbook** for Fedibird server administrators, including
third-party deployments. The corresponding implementation history and detailed
contracts are in [the hashtag subsystem design document](../hashtag-subsystem-upstream-unification.md).

**Code merged is not proof of code deployed.** Check the running Git revision on
*each* web/worker/streaming host, the applied migrations, and the actual database
state before selecting a procedure. This document does not assert that any
particular production server has deployed U3b-3e.

## 1. Stage and authority map

| Stage in repository | Storage authority | Deployment / rollback boundary |
| --- | --- | --- |
| Before U1 | legacy `follow_tags` | No canonical tables; U2 tools cannot be run yet |
| U1 / U2 (#120 / #122) | legacy `follow_tags` | Additive schema; explicit legacy -> canonical backfill and parity |
| U3a (#124) | legacy `follow_tags` | Legacy writes mirror to canonical; after all old processes exit, a catch-up backfill is valid |
| U3b-1 / -2 (#127 / #128) | canonical reads and delivery admission; legacy write paths still exist | Read/fan-out cutover, require synchronized representations |
| U3b-3a / -3b (#130 / #131) | canonical management reads; legacy writes still exist | Compatibility resource IDs and management read cutover |
| U3b-3c / -3d / -3e (#132 / #133 / #134) | **canonical `tag_follows` + `tag_follow_deliveries` for intended normal writes** | `follow_tags` is a transactionally maintained, callback-free rollback shadow / compatibility-ID allocator |
| U4 and later | not yet implemented here | Separate cleanup, old-table removal, and eventual destructive Tag-identity migration |

U3b-3e is **merged in source**. There is no automatic implication that U4 or
Tag identity canonicalization has occurred. U3a's `FollowTagMirror` code is
still retained as a rollback facility, not the intended normal writer.

In the current canonical model:

- `TagFollow` expresses a followed-tag **relation**. It does **not** imply
  delivery to Home.
- `TagFollowDelivery` supplies explicit Home/List destinations and each
  destination's `media_only` value.
- A `legacy_follow_tag_id` maintains the old API/Settings resource identity.
  The matching `follow_tags` row must stay in lockstep with the canonical
  destination during the rollback window.
- Standard `POST /api/v1/tags/:id/follow` ensures Home, keeping existing Lists.
  Standard `POST /api/v1/tags/:id/unfollow` deletes the **entire relation**
  (Home and *all* Lists). For one destination only, use Fedibird's
  `/api/v1/follow_tags` or Settings.

Do not silently substitute older U3a behavior for these contracts.

## 2. Non-negotiable safety rules

1. **Record each deployed revision and the current stage** before the rollout.
   A release's Git history is not a substitute for checking live processes.
2. **Back up the database and establish a tested restore path** according to
   the site's operating policy. A backup is essential before irreversible work.
3. **Retain `follow_tags` and its schema throughout U3b soak.** Dropping it is
   not an ordinary rolling deployment or a safe accompaniment to read/write
   cutover.
4. **Do not use legacy -> canonical `APPLY=1` backfill after canonical writes
   are authoritative.** That task can overwrite canonical state from stale
   shadows, or re-create state the canonical writer deliberately removed.
5. **Never run `PRUNE=1` as routine repair.** It can delete canonical-only
   relations/destinations according to the legacy source. Its original purpose
   was controlled source-authoritative U2/U3a reconciliation.
6. **Do not overlap legacy-only writers with canonical-authoritative writers
   during a stage transition unless that exact mixed-version path has been
   validated.** Drain workers and control writes where necessary.
7. Treat non-parity and any `InconsistentLegacyShadowError` as **stop and
   investigate**, not permission to repair in an arbitrary direction.

## 3. Read-only preflight for an installation with U1+ schema

First record the version on all running roles, the active revision, migration
state, and the time of the planned rollback point. Run from the matching
application release after its required schema migrations have been applied:

```bash
RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity
```

The task is **read-only**. Its JSON includes `source` (legacy shadow),
`target` (canonical state), `differences`, `ok`, and
`management_ready`. For any U3b management/write cutover or promotion,
require both:

```json
{
  "ok": true,
  "management_ready": true
}
```

These are fields within a larger response, not the full expected output.
`management_ready` additionally requires
`source.duplicate_destination_groups == 0`. Parity checks include
missing/extra relations and destinations, `media_only` differences, legacy
resource-ID mismatches, orphaned Lists, ownership violations, and zero-delivery
relations. Check the detailed counters; **equal table row counts are not
parity**.

If either gate is false, **stop the upgrade/promotion**. Save the full JSON,
check recent tag-follow mutations and mixed-version processes, and determine
which representation was authoritative *at the time the divergence occurred*.
Do not run `APPLY=1` or `PRUNE=1` simply to turn the output green.

This command needs the additive U1 tables; it is not a pre-U1 migration
probe. On large installations, plan its read cost and run it in a suitable
operational window.

## 4. Upgrade from a legacy (pre-U3b) installation

A jump directly from a much older Fedibird release to current U3b-3e code
**must not be assumed safe** merely because Rails migrations are additive.
Prefer a verified staged rollout through U1/U2/U3a, with backfill and parity
while legacy is still authoritative, followed by a controlled U3b cutover.

### 4.1 U1/U2/U3a preparation (legacy is still authoritative)

Apply the additive migrations before starting processes that depend on new
tables. On multi-host installations, identify the old web/worker processes
that may still write `follow_tags`. Complete the legacy-authoritative
transition and catch-up **before** allowing canonical-authoritative code
to serve writes.

During this stage only, the following reconciliation is valid after ensuring
the old legacy-source authority and stopping/draining unmapped writers:

```bash
# Inspect without changing rows
RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_backfill

# ONLY while legacy follow_tags is definitively authoritative
RAILS_ENV=production APPLY=1 bundle exec rake hashtag_unification:follow_tag_backfill

RAILS_ENV=production bundle exec rake hashtag_unification:follow_tag_parity
```

Do not proceed until `ok: true` and (before U3b management features)
`management_ready: true`.

If the rollout uses U3a with a rolling restart, processes still on older
legacy code may create changes that were not mirrored. Only while legacy is
still the source of truth, stop that old-writer overlap, do a **final catch-up
backfill**, then check parity. Do not carry the old U3a instruction to
"backfill after each restart" into U3b.

If the installation cannot reliably stage and reconcile legacy state before
switching authority, stop and prepare a version-specific migration/recovery
plan. Do not improvise a direct cutover under active mixed writers.

### 4.2 Crossing into U3b authority

1. Complete schema migrations required by the selected target revision,
   including the U3b-3a compatibility-ID schema, before running new code.
2. Confirm the legacy-authoritative preparation and both parity gates, then
   quiesce tag-follow writes and drain relevant jobs across **all** hosts.
3. Deploy the approved U3b build consistently. Avoid legacy-only
   web/worker processes continuing to mutate the same data while canonical
   writers are active; use a controlled handover, not an unverified mixed
   rolling deployment.
4. Resume operations on the canonical code and run the read-only parity
   task again. From this point, `follow_tags` is a rollback shadow, **not**
   the source for an unconditional `APPLY` backfill.
5. Exercise the U3b canary matrix below before the release is promoted.

Do not interpret applying database migrations as proof that the cutover
completed successfully; the application processes and data invariants must
also agree.

## 5. Routine U3b-3e deployment and canary verification

For a server **already on U3b canonical writers**, ordinary deployments
should retain the existing canonical/shadow contract. Check both parity
gates before and after deploying and do **not** run a legacy backfill.

For official Fedibird's canary-first promotion, the recommended order is:

```text
nightly.fedibird.com (or smaller canary)
  -> version / migration / parity checks
  -> Home/List writes and real delivery smoke tests
  -> fedibird.com (or next production environment)
  -> repeat the post-deploy checks
```

For third-party operators, use your own canary and data. Do not use row
counts, sample user IDs, or collision results from another installation as
success criteria.

Minimum U3b canary matrix (perform with temporary test follows where
appropriate):

| Operation | Required result |
| --- | --- |
| Standard follow of a new tag | Relation and explicit Home destination created; shadow matches |
| Existing Lists-only -> standard follow | Home added; every existing List and its `media_only` kept |
| Repeat standard follow | Idempotent; no duplicate Home or unintended `media_only` change |
| Home + multiple Lists -> standard unfollow | **All** destinations and relation removed; matching shadows removed |
| `/api/v1/follow_tags` create/edit/delete | One destination only; stable resource ID, peers preserved |
| Settings destination edit/move/`media_only` | Same canonical destination and compatibility ID reflected by API |
| Home and Lists hashtag fan-out | Only the explicitly configured destinations receive eligible posts |
| Final read-only parity | Both `ok` and `management_ready` remain true |

Also monitor newly introduced request failures (especially 422),
Sidekiq errors, follow-rate-limit behavior, and discrepancies between UI
following indicators and Home/List delivery. The read-only parity task is
necessary but cannot prove the actual streaming/fan-out behavior by itself.

## 6. Handling parity failures and 422 responses

The canonical writer deliberately **fails closed** if an existing relation
has an inconsistent rollback shadow. For example: missing/extra/wrong
`follow_tags` rows, an incorrect `legacy_follow_tag_id`,
`media_only` mismatch, or a relation with no delivery. The standard API
can return 422 instead of silently guessing which side is correct.

On detecting a new problem:

1. Stop promoting releases; consider quiescing tag-follow writes if the
   mismatch is spreading. Preserve application/worker error logs and the
   complete parity JSON.
2. Identify the affected account, tag, Home/List destination, matching
   compatibility IDs, and last successful transaction. Audit any SQL,
   bulk updates, or mixed old/new process overlap.
3. Determine whether this is an incomplete pre-cutover import, a
   missing/stale legacy **shadow**, or a canonical write failure.
4. Repair only against a reviewed, documented authority decision with
   backup/recovery available. There is **no universal automatic
   direction-of-repair command** once U3b writers are authoritative.
5. Re-run both parity gates and canary reads/writes before promotion.

In particular, `APPLY=1` is a **legacy -> canonical** operation. It is not a
canonical -> legacy shadow repair tool. `PRUNE=1` is potentially destructive.
Neither should be a reflexive response to U3b parity failures.

## 7. Rollback while the legacy shadow still exists (before U4)

Keep a revision-by-revision rollback map. U3b releases can generally be
rolled back at the **application-code** boundary while retaining the
additive database schema, provided the rollback target understands the
maintained legacy shadow and that shadow is exact. This is a **conditional**
rollback path, not a guarantee for arbitrary old releases.

Before rolling code back to a legacy-writer revision:

1. Stop/drain new canonical writes across web/workers/other writing
   processes. Record the last known-good revision and back up current state.
2. Inspect parity and compatibility IDs: require `ok: true` and
   `management_ready: true`; investigate any mismatch first.
3. Choose an explicitly compatible rollback target (for example, the
   previous U3b stage or tested U3a revision), accounting for the code's
   expected table/column shape and API semantics.
4. Switch writing processes consistently. Do not run U3a and U3b writers
   concurrently without a separately validated mixed-version procedure.
5. Verify Home/List data and `media_only` values, API and Settings access,
   actual delivery, and parity after the rollback.

If parity is already broken, **do not blindly revert to legacy reads and
writes**. That may expose stale shadows as user state. Investigate a
forward-fix or restore from the verified backup with the site's recovery
procedure.

A prior **successful** standard U3b unfollow intentionally deleted the
whole relation (including Lists). Rollback will not resurrect that
legitimate deletion. Changes in endpoint semantics must be understood
separately from data parity.

Do not roll back the U1 schema simply to revert U3b application code.
After U4 deletes the shadow, these legacy rollback steps no longer apply;
U4 needs an independently reviewed recovery plan.

## 8. Soak and U4 legacy cleanup boundary

After U3b-3e, the remaining work includes production soak of canonical
writers and removal of old associations/runtime paths before U4.
During soak monitor:

- both parity gates and their detailed counters;
- canonical relation/delivery counts, including zero-delivery parents;
- compatibility-ID coverage and shadow mismatches;
- duplicate Home/List destination attempts and ownership issues;
- fan-out/FeedManager behavior and delivery errors;
- API / Settings errors, users' followed-tag counts, and rollback readiness.

Do **not** drop `follow_tags`, remove `FollowTagMirror`, or remove the
legacy compatibility-ID mechanism merely because a single parity check
passes. U4 must be a separate PR/release with a documented minimum starting
stage, old-path audit, backup and restore rehearsal, destructive migration
review, and explicit downgrade limitations. Do not mix it with another
cutover.

## 9. Tag identity canonicalization (later Phase B)

Structural hashtag-follow unification is **not** Tag identity migration.
`HashtagNormalizer` identity convergence and collision merging can touch
`statuses_tags`, FeaturedTags, filters, existing follows, references, and
other dependent records. This work may be destructive and needs its own
production-scale analysis and rehearsal.

Read-only planning tools exist:

```bash
RAILS_ENV=production bundle exec rake hashtag_unification:tag_collision_analysis
RAILS_ENV=production bundle exec rake hashtag_unification:tag_migration_plan
```

The planner can consume operator-provided manifests; see the task comments
in `lib/tasks/hashtag_unification.rake`. These tools do **not** authorize
a live merge. Fresh counts, collision mappings, locks, recovery time, and
irreversible boundaries are installation-specific. Never copy survivor
mappings or collision counts from another server.

## 10. Command reference and authority warning

| Command | Effect | When appropriate |
| --- | --- | --- |
| `hashtag_unification:follow_tag_parity` | Read-only symmetric diagnostics | Before/after U3b, during soak, and rollback preflight |
| `hashtag_unification:follow_tag_backfill` | Dry-run of **legacy -> canonical** backfill | Review during legacy-authoritative U2/U3a preparation |
| `APPLY=1 ... follow_tag_backfill` | Mutates canonical data **from legacy** | **Only** when legacy is conclusively authoritative, before U3b cutover, with controlled writers |
| `APPLY=1 PRUNE=1 ... follow_tag_backfill` | In addition removes target-only relations/destinations | Exceptional reviewed legacy-authoritative reconciliation only; **not routine** and **never a U3b repair recipe** |
| `tag_collision_analysis` / `tag_migration_plan` | Read-only identity/collision diagnostics | Separate Tag identity migration planning |

**Promotion gate:** both `ok: true` and `management_ready: true`, plus
successful real Home/List delivery smoke tests. A third-party operator
should retain site-specific logs, SQL diagnostics, backups, revision IDs,
and its own deployment/rollback checklist.

## 11. Change history and source references

- U1/U2/U3a: #120, #122, #124
- U3b read/delivery/management cutover: #127, #128, #130, #131
- U3b canonical writers: #132, #133, #134
- Design and next phases: `docs/hashtag-subsystem-upstream-unification.md`
- Command implementations:
  `lib/tasks/hashtag_unification.rake`,
  `app/services/hashtag_unification/follow_tag_parity.rb`, and
  `app/services/hashtag_unification/follow_tag_backfill.rb`

This runbook intentionally does **not** make any claim about the current
deployment versions, runtime database invariants, or actual recovery
readiness of `nightly.fedibird.com` or `fedibird.com` without
operator-side verification.
