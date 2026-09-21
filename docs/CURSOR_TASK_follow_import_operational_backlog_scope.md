# Cursor task: separate historical Follow Import backlog from the operational dispatch cohort

> **TEMPORARY IMPLEMENTATION INSTRUCTION**
>
> Read this document first, create a new implementation branch from the latest
> `fedibird`, implement the task, run the required tests, open a Draft PR, and
> **delete this file from the implementation branch before finishing**.
>
> The finished PR must not retain this temporary instruction document.

## Goal

Implement I2 from the Follow Import rollout:

> Separate the historical/stale pending universe from the current operational
> dispatch cohort so shadow telemetry and later GLOBAL dispatch no longer treat
> old pre-controlled-execution rows as live scheduler backlog.

This is a **scope / provenance / telemetry correctness** change.

It is **not**:

- cleanup/deletion of historical targets
- a retry/pacing-policy change
- a moderation change
- GLOBAL enablement
- a bulk ownership conversion
- a heuristic that guesses history from import date or target state

GLOBAL must remain off in production after this PR until later canary work.

---

## Production evidence motivating I2

Latest production observation export: 2026-09-21 ~13:02 JST.

Follow Import rows:

- 56 selected batches
- 46,203 targets
- 25,951 targets currently `pending`
- those 25,951 pending rows belong to exactly 16 batches
- all 16 batches are `dispatch_owner=legacy`
- imports are from 2026-09-10 through 2026-09-13
- every target in those 16 batches is still `pending`; they have no queued /
  delivery / response state transition in this ledger era
- real follow interactions nevertheless occurred for the affected actors, so these
  rows are historical state pollution, not a safe list of work to replay

After #137 was deployed, the lease is healthy:

- `lease_strategy=durable_row_v1`
- 38/38 observed post-cutover ticks were `shadow_observed`
- 0 post-cutover ticks were `lease_busy`
- scheduler cadence is approximately 60 seconds

Now that the lease is healthy, every shadow tick cleanly sees the same polluted
historical universe:

```text
global_pending_count       = 25951
active_batch_count         = 16
executable_owner_count     = 6
executable_batch_count     = 16
planned_count              = 50
```

This makes the next blocker explicit: the scheduler is functioning correctly,
but the **candidate cohort is wrong** for ongoing calibration.

Important: do **not** conclude that `dispatch_owner=legacy` means historical.
After I2, a newly-created batch while GLOBAL is off is still legitimately owned
by the legacy worker and must be part of the current shadow cohort.

---

## Architectural invariant: ownership and cohort are independent axes

Keep these concepts separate.

### Existing axis: `dispatch_owner`

Answers:

> Who is allowed to claim this batch?

Current values:

- `legacy` — `BatchExecutionWorker`
- `scheduler` — global `DispatchScheduler`

Do not change these semantics.

### New axis: dispatch cohort / provenance

Add a durable batch-level marker that answers:

> Was this batch recorded before or after I2's controlled scheduler-cohort boundary?

Preferred representation:

```text
follow_import_batches.dispatch_cohort
  historical  = 0
  operational = 1
```

Equivalent naming is acceptable only if the semantics stay equally explicit.

The two axes must form this matrix:

| dispatch_cohort | dispatch_owner | Meaning / I2 behavior |
| --- | --- | --- |
| historical | legacy | existing pre-I2 data; exclude from scheduler planning; legacy execution behavior unchanged |
| historical | scheduler | defensive/edge state; exclude from scheduler planning unless explicitly promoted in a later operator/drain feature |
| operational | legacy | new current import while GLOBAL is off; legacy worker executes it, SHADOW may plan/observe it |
| operational | scheduler | new current import while GLOBAL is on; GLOBAL scheduler may plan/claim it |

Do **not** overload `dispatch_owner` to represent history.

Do **not** derive the cohort dynamically from:

- `imported_at`
- target state distribution
- account age
- number of attempts
- presence/absence of transport observations
- completed metadata
- specific subject ids
- the current GLOBAL/SHADOW flag at read time

The boundary must be durable and explicit.

---

## Migration / rollout semantics

Add a migration for the cohort field.

Preferred safe rollout:

- existing rows become `historical`
- database default remains the fail-safe historical value
- the I2-aware application recorder explicitly writes `operational` for every
  newly-created Follow Import batch

Why this shape:

- existing production rows are not silently promoted
- an old application process during rolling deployment can at worst create a
  historical/legacy row, which remains on the legacy path and is omitted from
  scheduler planning
- no old process can accidentally create scheduler-claimable work merely because
  the database default changed
- after the deployment is fully restarted, all newly-recorded batches are
  explicitly operational

If a different migration shape is chosen, preserve those fail-safe properties.

Do not bulk update target states.

Do not change existing `dispatch_owner` values.

Do not auto-promote the 16 historical batches.

---

## Recorder/idempotency contract

Update `Moderation::FollowImportRecorder`.

For a **new** batch:

- explicitly persist `dispatch_cohort: :operational`

For an existing batch found by `import_id`:

- return it unchanged
- do not rewrite `dispatch_owner`
- do not rewrite `dispatch_cohort`

The uniqueness-race recovery path must likewise return the committed row without
changing either axis.

A retry of an old historical Import after I2 must remain historical.

A retry after a feature-flag change must keep both its original owner and cohort.

Update model validation/scopes and annotation.

---

## Scheduler planning scope

This is the central behavioral change.

### SHADOW mode

Today SHADOW uses:

```ruby
FollowImportBatch.all
```

Change it to the **operational cohort, all owners**.

Reason:

- operational + legacy batches are the live comparison cohort while GLOBAL is off
- historical rows must not consume shadow fairness/planning slots
- SHADOW still claims nothing

### GLOBAL mode

Today GLOBAL uses:

```ruby
FollowImportBatch.scheduler_owned
```

Change it to:

```text
operational cohort
AND
scheduler_owned
```

Both conditions are required.

A historical scheduler-owned row must not become claimable merely because its
owner flag says scheduler.

No GLOBAL behavior is enabled by this PR; this is the future-safe scope.

---

## Legacy executor behavior must remain unchanged

Do not add `dispatch_cohort` gating to `BatchExecutionWorker` in I2.

Existing legacy chains remain governed by `dispatch_owner=legacy` and their
current execution/recheck rules.

I2 is not a historical cleanup job and must not resurrect stopped old chains.

Do not enqueue workers for historical rows.

Do not cancel workers for historical rows.

---

## Fairness cursor behavior

Historical owners/batches must no longer participate in the scheduler's active
set.

Once SHADOW plans only the operational cohort:

- `active_owner_keys` supplied to `FairnessCursor#write` must contain only
  operational planning owners
- `active_batch_ids` must contain only operational planning batches
- stale historical cursor entries may be pruned naturally by the existing
  reconstructable-cursor behavior

Do not create a destructive/manual Redis cleanup requirement.

Fairness state is simulation state, not a work ledger.

---

## Backlog telemetry: separate the universes explicitly

Do not silently change the meaning of the existing fields without versioning.

Current fields:

```text
global_pending_count
active_batch_count
```

currently mean the all-pending universe. Preserve that historical meaning for
continuity (or, if you intentionally redefine them, make the schema/version
break explicit and update every consumer; preserving them is preferred).

Add explicit scoped backlog measurements to tick telemetry.

Required semantic information:

```text
historical_pending_count
operational_pending_count
planning_pending_count

historical_active_batch_count
operational_active_batch_count
planning_active_batch_count
```

Preferred meaning:

- `global_pending_count`: all pending targets, legacy compatibility field
- `active_batch_count`: all batches with at least one pending target, legacy compatibility field
- `historical_*`: historical cohort regardless of owner
- `operational_*`: operational cohort regardless of owner
- `planning_*`: the exact batch scope used by this tick's planner
  - SHADOW = operational, all owners
  - GLOBAL = operational + scheduler-owned

If better field names are chosen, keep these distinctions exact and document
them.

Do not call a target-level count `executable` unless it actually proves target
recoverability. `Eligibility.executable?` is currently batch-level and
`ImportUnitResolver#work_for` is only checked later by the executor.

Existing `executable_owner_count` / `executable_batch_count` may retain their
current meaning.

### Failure semantics

As with existing `DispatchCounts`:

- measurement failure => NULL / unavailable
- observed empty => 0
- never turn a failed count into zero

### GLOBAL zero-budget contract

Preserve the existing important optimization/safety contract:

When GLOBAL effective budget is zero:

- do not discover pending work
- do not read/write fairness cursor
- do not instantiate target feeds
- do not instantiate remote admission runtime state
- do not run backlog count queries

Therefore all newly-added scoped backlog count fields must also be NULL on that
path.

---

## DispatchCounts implementation

Refactor `FollowImport::DispatchCounts` as needed so scoped counts are explicit
and testable.

Avoid date-based logic.

Prefer queries that continue to use the pending partial index and batch ids /
batch scopes.

Do not introduce an unbounded target materialization.

A compact grouped snapshot is acceptable if it keeps the code clear; a small
number of scoped COUNT queries is also acceptable. Correct semantics matter more
than premature cleverness.

---

## Tick schema / model / exportability

Update:

- `FollowImportDispatchTickObservation`
- migration(s)
- `FollowImport::DispatchPlan`
- `FollowImport::DispatchTickObserver`
- telemetry recording plumbing
- permanent Follow Import docs

Bump the tick schema version because the observation contract changes.

Expose a stable scope identity in `execution_config`, for example:

```json
{
  "backlog_scope_strategy": "dispatch_cohort_v1"
}
```

or equivalent.

The anonymized observation exporter used by the operator is not obviously stored
in this repository. If it is present, update it to export the new cohort/count
columns. If it is not present, do not invent unrelated export code; state in the
PR that the operator-side export query/script needs to include the new fields.

---

## Expected production result after I2

Immediately after deployment, before any new imports:

```text
global_pending_count       ~= 25951   # preserved all-universe diagnostic
historical_pending_count   ~= 25951
operational_pending_count  = 0
planning_pending_count     = 0
planned_count              = 0
```

The exact all-universe value may naturally change between export and deploy; do
not hard-code 25,951 in code or tests.

After a new Follow Import arrives while GLOBAL is still OFF:

```text
dispatch_cohort = operational
dispatch_owner  = legacy
```

The legacy worker remains authoritative, while a SHADOW tick can observe that
batch if pending rows still exist at tick time.

Later, when GLOBAL is enabled for new imports:

```text
dispatch_cohort = operational
dispatch_owner  = scheduler
```

Only that intersection is authoritative scheduler work.

---

## Required tests

At minimum cover the following.

### Model / recorder

1. existing/default batch value is historical/fail-safe
2. a newly-recorded batch is explicitly operational
3. default owner remains legacy when no owner is supplied
4. new scheduler-owned batch is operational + scheduler
5. retry of existing historical batch does not promote cohort
6. retry of existing operational batch preserves cohort
7. retry after owner request changes preserves stored owner and cohort
8. uniqueness-race recovery preserves committed owner/cohort

### Shadow scheduler

Construct:

- one historical + legacy pending batch
- one operational + legacy pending batch

Verify:

- shadow plan includes only the operational batch
- neither target is mutated
- historical row does not appear in active fairness owner/batch set
- all-universe pending count includes both
- historical count includes the historical one
- operational count includes the operational one
- planning count includes only the operational one

### GLOBAL scheduler

Construct at least:

- historical + scheduler pending
- operational + legacy pending
- operational + scheduler pending

Verify:

- only operational + scheduler is planned/claimed
- historical + scheduler remains pending
- operational + legacy remains pending for legacy ownership
- planning backlog counts match the operational+scheduler scope
- all/historical/operational counts remain truthful

### Zero budget

Preserve the existing GLOBAL-zero-budget spec and extend it:

- no `PendingBatchSource`
- no `FairScheduler`
- no `PendingTargetFeed`
- no `FairnessCursor`
- no old or new `DispatchCounts` queries
- all backlog count columns are NULL
- no target mutation / enqueue

### Telemetry

Verify:

- tick schema version bumped
- scope strategy identity emitted
- 0 vs NULL semantics
- scoped counts serialize into observation rows

### Query / boundedness regression

Keep pending discovery lazy/bounded.

Do not load all historical targets merely to classify backlog.

---

## Tests to run

Run at least the materially affected suites, including:

```bash
RAILS_ENV=test bundle exec rspec \
  spec/services/moderation/follow_import_recorder_spec.rb \
  spec/models/follow_import_batch_spec.rb \
  spec/services/follow_import/dispatch_scheduler_spec.rb \
  spec/services/follow_import/dispatch_scheduler_global_spec.rb
```

Also run any specs for `DispatchCounts`, `DispatchPlan`,
`DispatchTickObserver`, `PendingBatchSource`, telemetry, migrations, and
ImportService that exist or are added.

Run RuboCop on every changed Ruby file.

Report exact example/failure counts and RuboCop result in the PR.

---

## Permanent documentation updates

Update at minimum:

```text
docs/follow_import_dispatch_pacing_design.md
docs/follow_import_dispatch_shadow.md
```

Document:

- why historical pending state exists
- ownership vs cohort as separate axes
- shadow planning scope
- GLOBAL planning scope
- telemetry field meanings
- old all-universe fields vs scoped fields
- no target cleanup in I2
- no automatic historical promotion
- future drain/promotion must be explicit
- GLOBAL remains off

Do not describe historical pending as failed delivery work.

Do not claim the old 25,951 rows are safe to replay.

---

## Out of scope

Do not implement any of the following in this PR:

- deleting or terminalizing historical pending targets
- replaying historical pending work
- automatic owner/cohort promotion
- GLOBAL enablement
- pacing threshold calibration
- destination/origin cap tuning
- Retry-After-aware retry changes
- transport retry policy
- Follow Gate / moderation scoring changes
- migration/restoration relationship inference
- completion-email repair for historical batches
- broad cleanup of old Import rows

Those are separate tasks.

---

## PR deliverables

Open one focused Draft PR against `fedibird`.

PR body must include:

1. production evidence for the historical pollution
2. the owner × cohort matrix
3. migration/default semantics
4. exact SHADOW and GLOBAL planning scopes
5. telemetry contract and schema version
6. test results
7. expected production validation after deploy
8. confirmation GLOBAL remains off
9. confirmation no historical target rows were mutated/promoted

Suggested production validation:

- after deploy, before a new import, operational/planning pending should be near
  zero while historical/all pending still exposes the old backlog
- after a new GLOBAL-OFF import, verify its batch is operational+legacy
- verify SHADOW never plans a historical batch id
- verify no historical target state changes as a result of scheduler ticks

---

## Mandatory cleanup of this instruction

Before declaring the task complete:

1. ensure code/spec/migration/permanent-doc changes are committed
2. **delete `docs/CURSOR_TASK_follow_import_operational_backlog_scope.md`**
3. commit the deletion on the implementation branch
4. open/update the Draft PR
5. report:
   - PR URL
   - head SHA
   - changed files
   - migration name
   - chosen field/value names
   - test counts
   - RuboCop result
   - confirmation this temporary instruction is absent from PR HEAD

The temporary instruction is only a handoff artifact.
