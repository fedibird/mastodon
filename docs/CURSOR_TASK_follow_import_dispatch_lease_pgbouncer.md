# Cursor task: make Follow Import dispatch lease safe behind PgBouncer transaction pooling

> **TEMPORARY IMPLEMENTATION INSTRUCTION**
>
> Read this document first, implement the task on a new branch from the current
> `fedibird` branch, open a Draft PR, and **delete this file in the implementation
> branch before finishing the PR**. The finished working tree/PR must not retain
> this temporary instruction document.
>
> Do not delete the permanent Follow Import design/telemetry documentation. Update
> those permanent docs where the old session-advisory-lock contract is now wrong.

## Goal

Replace the Follow Import dispatcher single-flight mechanism introduced/followed
up through #135 with a design that is safe when the Rails PostgreSQL connection
goes through **PgBouncer transaction pooling**.

This is a correctness follow-up to:

- #63 / the original Follow Import dispatcher lease
- #135 / `ab00ef25cd384b38733016ac21f5278c53acc208`
  (`Recover stale Follow Import dispatcher session locks`)

The production evidence below shows that #135 is running, but its fundamental
assumption — one ActiveRecord connection == one PostgreSQL server session across
autocommit statements — is false in the production topology.

Do **not** enable authoritative GLOBAL dispatch in this PR. The scheduler remains
shadow/observation-only in production until this lease is fixed and verified.

---

## Production facts / root cause evidence

### Deployment

#135 is merged as:

```text
ab00ef25c Recover stale Follow Import dispatcher session locks (#135)
```

The relevant Sidekiq processes were restarted after that merge (around
2026-09-21 07:40:50 JST), so this is not an old-Ruby-process problem.

### Production DB topology clue

The operator confirms that `.env.production` on fedibird.com contains:

```text
PREPARED_STATEMENTS=false
```

This is intentionally used in the PgBouncer deployment.

The repository already supports this in `config/database.yml`:

```yaml
production:
  ...
  prepared_statements: <%= ENV['PREPARED_STATEMENTS'] || 'true' %>
```

**Do not commit production .env contents, credentials, hosts, or secrets.**
Also do not use `PREPARED_STATEMENTS=false` itself as a lease-mode feature flag;
it is evidence of the topology, not a reliable general PgBouncer detector.

### Confirmed failure after #135

Production repeatedly logged:

```text
[FollowImport::DispatchLease] advisory unlock not confirmed after dispatcher tick; isolating connection
[FollowImport::DispatchLease] disconnecting advisory-lock connection so it is not returned to the pool
[Scheduler::FollowImportDispatchScheduler] outcome=shadow_observed lease_acquired=true
```

and later:

```text
[FollowImport::DispatchLease] current DB session already owned dispatcher advisory lock before acquisition; recovering stale lease
[FollowImport::DispatchLease] stale advisory unlock could not be confirmed; isolating connection
[FollowImport::DispatchLease] disconnecting advisory-lock connection so it is not returned to the pool
[Scheduler::FollowImportDispatchScheduler] outcome=lease_busy lease_acquired=false
```

A PostgreSQL backend was then observed idle while still holding the Follow Import
advisory key:

```text
locktype = advisory
mode     = ExclusiveLock
classid  = 17993
objid    = 1
objsubid = 2
granted  = true
state    = idle
```

while its most recent query was unrelated normal application work.

The important impossible-under-a-direct-session sequence is:

1. `CURRENT_SESSION_LOCK_SQL` says the current backend owns the advisory key.
2. The following `pg_advisory_unlock(17993, 1)` returns false.

With PgBouncer transaction pooling, those autocommit statements may run on
different PostgreSQL server backends. Likewise, disconnecting the Rails/PgBouncer
client connection does not imply that the PostgreSQL server backend that owns a
session advisory lock is terminated.

That explains:

- session advisory locks leaking into PgBouncer's server pool
- unrelated later queries running on a backend that still owns the Follow Import key
- most ticks seeing `lease_busy`
- occasional ticks landing on the owning backend and appearing to acquire/recover

## Root architectural correction

A **PostgreSQL session advisory lock is not compatible with transaction pooling**
as the dispatcher correctness boundary.

Remove the assumption from code and permanent docs.

The follow-up must not depend on PostgreSQL session identity persisting between
autocommit statements.

---

## Required correctness properties

These are acceptance criteria, not suggestions.

### 1. Transaction-pooler safe

The implementation must work when one logical ActiveRecord/PgBouncer client
connection can use different PostgreSQL server sessions between transactions.

Do not use any of these as the correctness mechanism:

- `pg_try_advisory_lock`
- `pg_advisory_lock`
- `pg_advisory_unlock`
- `pg_advisory_unlock_all`
- checking `pg_backend_pid()` in one transaction and assuming it remains the same
  in a later transaction
- explicit disconnect of the Rails connection as a way to release a server-session lock

After this PR, Follow Import dispatcher code should not create new session-level
advisory lock state.

### 2. Preserve global single-flight semantics

Two scheduler ticks must not independently consume the full global admission
budget at the same time.

Target row locking is still necessary and prevents duplicate work for a target,
but it is **not sufficient** to enforce one global budget. Keep that distinction.

The existing Sidekiq unique job remains useful as a first layer, but Redis/UniqueJobs
must not silently become the only claimed correctness boundary.

### 3. Do not silently weaken correctness on lease-connection loss

A tempting implementation is:

1. open a dedicated connection
2. BEGIN
3. `pg_try_advisory_xact_lock`
4. run the dispatcher body on an unrelated ActiveRecord connection
5. COMMIT the lease connection afterward

This is transaction-pooler compatible while the lease transaction exists, but it
has a subtle failure mode: if the lease connection dies, PostgreSQL releases the
xact lock while the dispatcher body on the other connection may continue. A
second scheduler can then enter.

**Do not ship that split-connection design unless the lease-loss/fencing problem
is actually solved and covered by tests.**

If a durable lease token / fencing generation is needed to preserve the invariant,
implement the minimum durable mechanism needed. A short
`pg_try_advisory_xact_lock` transaction may be used as a serialization primitive
for acquisition/update because PgBouncer pins a server backend for the duration
of an explicit transaction.

Equivalent designs are acceptable if they preserve the stated invariants and are
simpler/safer.

### 4. Do not wrap the entire GLOBAL claim+enqueue tick in one long DB transaction

The current executor intentionally persists target claim state before Sidekiq
enqueue and has a release-on-enqueue-failure path.

Do not casually put all planning, target updates, Redis work, and
`Import::RelationshipWorker.perform_async` calls inside one outer PostgreSQL
transaction merely to keep an xact advisory lock alive.

That would change commit/enqueue semantics and can produce queued jobs whose DB
claim later rolls back, or long transactions with undesirable MVCC/lock behavior.

If you choose a transaction-scoped design, explicitly preserve the existing
claim/enqueue invariants or refactor them safely with tests. Do not hide the
semantic change.

### 5. Fail closed

If the lease mechanism cannot establish safe ownership, return the existing
`:busy`/equivalent non-executing result. Do not continue unleased.

An internal lease error must not increase the budget or fall back to unrestricted
dispatch.

### 6. Crash/restart recovery

A crashed scheduler must not leave a permanent lease that requires manual
operator cleanup.

Recovery must be bounded and automatic.

If the design uses a durable lease/expiry:

- use database time, not app-host wall-clock comparison, for ownership expiry
- use an unguessable owner token and/or monotonic fencing generation
- release/update only when the caller still owns the same token/generation
- document the expiry/renewal semantics
- do not introduce an uncalibrated pacing number disguised as a lease timeout
- ensure a long/stuck old owner cannot continue making authoritative claims after
  ownership has moved to a newer generation

### 7. No moderation coupling

This PR is dispatch infrastructure only.

Do not add or consume:

- moderation scores
- block/mute/report signals
- Follow Gate decisions
- user reputation

### 8. No pacing calibration in this PR

Do not change:

- global dispatch budget
- tick cadence
- destination/origin caps
- adaptive remote coefficients
- retry/backoff policy

This PR fixes the lease/correctness boundary only.

---

## Preferred direction

Use **transaction-level**, not session-level, PostgreSQL primitives where an
advisory primitive is useful:

```sql
SELECT pg_try_advisory_xact_lock(17993, 1);
```

A transaction-level advisory lock is compatible with PgBouncer transaction
pooling because the pooler pins the PostgreSQL backend for the explicit
transaction.

However, as described above, an xact lock held on an otherwise independent
lease connection is not by itself a complete proof of single-flight for a body
running elsewhere. Solve that ownership/loss problem rather than merely changing
the function name.

A reasonable architecture may be:

- a **short** xact advisory lock to serialize lease-state acquisition
- durable ownership/fencing state in PostgreSQL for the scheduler critical section
- ordinary ActiveRecord connections for plan/claim/enqueue
- ownership/fencing validation at the point where authoritative GLOBAL claims
  could occur
- bounded crash recovery

But inspect the current code and choose the smallest design that genuinely
satisfies the invariants. Do not add a durable table if an equally strong,
simpler solution exists.

If you determine that exact hard single-flight cannot be preserved without a
larger follow-up, **fail GLOBAL closed** and make shadow operation safe rather
than silently shipping a weaker guarantee. Explain that decision in the PR.

---

## Existing code to inspect

At minimum read all of these before changing anything:

```text
app/services/follow_import/dispatch_lease.rb
app/services/follow_import/dispatch_scheduler.rb
app/services/follow_import/dispatch_executor.rb
app/services/follow_import/target_transition_service.rb
app/services/follow_import/fair_scheduler.rb
app/services/follow_import/fairness_cursor.rb
app/services/follow_import/dispatch_tick_observer.rb
app/services/follow_import/dispatch_plan.rb
app/workers/scheduler/follow_import_dispatch_scheduler.rb

spec/services/follow_import/dispatch_lease_spec.rb
spec/services/follow_import/dispatch_scheduler_spec.rb
spec/services/follow_import/dispatch_executor_spec.rb

config/database.yml
docs/follow_import_dispatch_pacing_design.md
docs/follow_import_dispatch_shadow.md
docs/follow_import_pacing_telemetry.md
```

Also inspect any callers/specs discovered by repository search. Do not assume this
list is exhaustive.

---

## #135 cleanup expectations

#135 added defensive machinery for leaked session locks:

- `CURRENT_SESSION_LOCK_SQL`
- `UNLOCK_SQL`
- `MAX_STALE_LOCK_DEPTH`
- stale-current-session drain/recovery
- disconnect/remove behavior intended to isolate a locked PostgreSQL session

Once the dispatcher no longer uses session advisory locks, delete obsolete
session-lock recovery code and obsolete specs instead of preserving dead
complexity.

Keep useful tests/structure where they still express valid invariants.

Do not use `pg_terminate_backend` from application code.

---

## Tests / proof required

### A. Lease unit/contract specs

Cover at least:

1. uncontended acquisition yields exactly once
2. competing acquisition returns busy and does not yield
3. block exception releases/relinquishes ownership automatically/safely
4. acquisition/setup exception fails closed
5. no session-level advisory SQL is used
6. process/connection failure model has a documented safe outcome
7. any durable token/generation cannot be released by a non-owner
8. stale/crashed ownership has bounded recovery
9. if fencing is used, an older generation cannot make a valid authoritative claim
   after a newer generation owns the lease

### B. PostgreSQL integration behavior

Use the real test PostgreSQL where useful.

If using `pg_try_advisory_xact_lock`, verify:

- the lock exists only for the transaction lifetime
- commit releases it
- rollback/raised exception releases it
- a concurrent connection cannot acquire it while the transaction is open
- after the transaction ends, a new connection can acquire it

Do **not** write tests whose correctness depends on one ActiveRecord connection
mapping to one server `pg_backend_pid()` across separate autocommit transactions.

### C. Scheduler regression

Run the lease and scheduler suites together. Preserve:

- `lease_busy` observation path
- shadow mode mutates no targets
- GLOBAL effective-budget-zero behavior
- one plan per tick
- current error observation behavior unless intentionally improved/documented
- no duplicate target claim/enqueue

### D. Executor / claim invariants

If lease/fencing changes touch authoritative claims, prove:

- pending -> queued remains concurrency-safe
- only the current lease owner/fencing generation can make an authoritative claim
- successful enqueue remains counted exactly once
- enqueue failure releases the claim as before
- already-enqueued work is not rolled back by a later lease error

### E. Style/tests

At minimum run:

```bash
RAILS_ENV=test bundle exec rspec   spec/services/follow_import/dispatch_lease_spec.rb   spec/services/follow_import/dispatch_scheduler_spec.rb   spec/services/follow_import/dispatch_executor_spec.rb

bundle exec rubocop   app/services/follow_import/dispatch_lease.rb   app/services/follow_import/dispatch_scheduler.rb   app/services/follow_import/dispatch_executor.rb   spec/services/follow_import/dispatch_lease_spec.rb   spec/services/follow_import/dispatch_scheduler_spec.rb   spec/services/follow_import/dispatch_executor_spec.rb
```

Adjust the explicit RuboCop file list for any new/renamed Ruby files.

Also run any new migration/model specs and the broader Follow Import service specs
that are materially affected.

Report exact example/failure counts and RuboCop results in the PR.

---

## Permanent documentation updates

Update the permanent design docs so they no longer claim:

> DB session advisory lease is the correctness boundary and one checked-out
> ActiveRecord connection guarantees one PostgreSQL session.

That statement is false behind PgBouncer transaction pooling.

Document instead:

- transaction pooling is a supported deployment topology
- session-level PostgreSQL features must not be used as cross-transaction
  dispatcher state
- the new lease/fencing contract and crash recovery
- why target row locks remain necessary but do not by themselves provide a global
  budget
- why Sidekiq UniqueJobs remains a deduplication layer rather than the sole
  correctness mechanism
- GLOBAL must remain off until production shadow verification confirms the new
  mechanism

Keep the docs transport/pacing-only; do not introduce moderation language.

---

## Observability / production verification

Make the new strategy identifiable in scheduler telemetry or execution config
without logging secrets. Prefer a stable string such as a strategy/schema
identifier rather than backend PID identity.

After deploy, the operator must be able to verify:

1. shadow scheduler succeeds at approximately the configured cadence
2. `lease_busy` occurs only for genuine overlap/contention, not because a
   PgBouncer server backend retained session state
3. this old session-lock query returns **zero rows** between ticks:

```sql
SELECT
  l.pid,
  l.mode,
  l.granted,
  l.classid,
  l.objid,
  l.objsubid,
  a.state,
  a.state_change,
  left(a.query, 200) AS query
FROM pg_locks l
LEFT JOIN pg_stat_activity a ON a.pid = l.pid
WHERE l.locktype = 'advisory'
  AND l.classid = 17993
  AND l.objid = 1
  AND l.objsubid = 2;
```

For an xact advisory design, seeing the key transiently **during the explicit
lease transaction** is expected; seeing it stranded on an idle backend between
scheduler ticks is not.

Add a concise operator verification section to the PR body.

---

## PR scope / deliverables

Create one focused Draft PR against `fedibird`.

The PR should contain:

- transaction-pooler-safe dispatcher lease implementation
- necessary schema/model support if the chosen correct design requires it
- regression/integration specs
- permanent Follow Import documentation corrections
- telemetry strategy/schema identity if appropriate
- no pacing-threshold changes
- no GLOBAL enablement
- no moderation changes

PR body must explain:

1. the production PgBouncer failure mechanism
2. why #135 could not fix it
3. the new correctness model
4. failure/crash recovery
5. whether/how fencing is used
6. tests run and exact results
7. post-deploy shadow verification steps

Do not claim stronger guarantees than the implementation actually provides.

---

## Mandatory cleanup of this instruction

Before declaring the task complete:

1. ensure the implementation branch contains all code/spec/doc changes
2. **delete `docs/CURSOR_TASK_follow_import_dispatch_lease_pgbouncer.md`**
3. commit that deletion on the same implementation branch
4. open/update the Draft PR
5. report the PR URL, head SHA, changed files, design chosen, test results, and
   confirmation that this temporary instruction file is absent from the PR result

The temporary instruction is part of the handoff workflow, not a permanent
Fedibird document.
