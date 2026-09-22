# Cursor task: add read-only Follow Reject signal decomposition

## Goal

Add a small, analysis-only decomposition of received `follow_reject` signals so we can distinguish:

- immediate vs delayed rejection timing
- responder Actor type / current bot-like metadata
- responder-domain concentration

This is for calibration and moderator diagnostics only.

Do NOT change:

- RiskEvaluationService scoring
- AdaptiveFollowGateDecisionService rules
- FollowImport::ReviewSignalClassifier
- Action Review policy/enforcement
- Moderation::NegativeSignalQualification
- PrecedingContactLink semantics
- EventRecorder
- database schema

The feature must remain read-only and observational.

## Branch / base

Work on:

`feature/follow-reject-signal-decomposition`

Base:

`6f9c679399cb6fe6968f464efb95a113391a8632`

---

# Why

A qualified Follow Reject is a useful negative signal, but not every reject has the same interpretation.

Examples of legitimate/noisy cases include:

- bots that only accept follows under their own protocol/relationship conditions
- bots that automatically Reject unexpected follows
- accounts that previously used follow-based operation but now reject all follows
- server-side automated defenses

Very fast rejection may therefore be more automation-heavy than a delayed response.

Also, Mastodon/Fediverse Actor metadata can indicate:

- `Service`
- `Application`
- `Person`
- `Group`
- other ActivityPub actor types

In this Fedibird codebase, `Account#bot?` is currently true for `Application` and `Service`.

This metadata is imperfect. A Service/Application may still be human-operated, and a Person may still automate rejection.

Therefore:

**Never turn any of these observations into a bot/abuse verdict.**

They are descriptive decomposition only.

---

# Part A: add a dedicated read-only service

Suggested:

`Moderation::FollowRejectObservationService`

Suggested file:

`app/services/moderation/follow_reject_observation_service.rb`

No writes.

Accept:

```ruby
call(subject_or_account, now: Time.now.utc, windows: DEFAULT_WINDOWS)
```

Suggested windows:

```ruby
DEFAULT_WINDOWS = {
  '1h'  => 1.hour,
  '24h' => 24.hours,
  '7d'  => 7.days,
}.freeze
```

Read-only subject resolution only:

- ModerationSubject input -> use it
- Account input -> `ModerationSubject.find_by(account_id: ...)`
- never `ModerationSubject.for_account!`

---

# Part B: cohort

For each window, inspect:

```ruby
ModerationRejectionEvent
  .where(rejected_subject_id: subject.id, event_type: :follow_reject)
  .where(occurred_at: window_start..window_end)
```

Preload:

- `preceding_interaction_event`
- `rejector_subject: :account`

Use existing:

`Moderation::NegativeSignalQualification.qualified?(event)`

Do NOT create another qualification rule.

Detailed timing / actor / domain decomposition below applies to the **qualified Follow Reject subset**.

Still report:

- raw_follow_reject_events
- qualified_follow_reject_events
- unqualified_follow_reject_events

This keeps the decomposition anchored to existing qualification semantics.

---

# Part C: rejection latency buckets

Use:

`ModerationRejectionEvent#time_to_rejection`

Do not recompute from unrelated rows.

For qualified Follow Rejects, count:

```text
lte_5s
gt_5s_lte_30s
gt_30s_lte_5m
gt_5m
unknown
```

Exact boundaries:

- `0 <= t <= 5s` -> `lte_5s`
- `5s < t <= 30s` -> `gt_5s_lte_30s`
- `30s < t <= 300s` -> `gt_30s_lte_5m`
- `t > 300s` -> `gt_5m`
- nil/unusable -> `unknown`

Qualified events should normally have a usable non-negative latency, but keep a stable unknown bucket.

Do not label any bucket:

- automated
- human
- malicious
- safe

Timing is descriptive only.

Also expose:

- `immediate_lte_5s_events`

as a simple alias/count for convenience.

---

# Part D: responder Actor metadata

Use CURRENT Account metadata when the rejector subject still resolves to an Account.

This is not event-time historical metadata.

Make this limitation explicit in output notes/tests/comments.

## Actor type buckets

Stable keys:

```text
Person
Service
Application
Group
Organization
Other
unknown
```

Rules:

- no current Account -> `unknown`
- blank actor_type -> `Person` (matches Account#person_type? legacy semantics)
- exact known type -> corresponding bucket
- any other nonblank string -> `Other`

Count both:

- qualified event counts
- unique qualified responder counts

Suggested shape:

```json
"actor_types": {
  "event_counts": {
    "Person": 0,
    "Service": 0,
    "Application": 0,
    "Group": 0,
    "Organization": 0,
    "Other": 0,
    "unknown": 0
  },
  "unique_responder_counts": { ...same keys... }
}
```

Do not output actor IDs or acct values.

## Bot-like metadata

Use current:

`account.bot?`

In this codebase that means `Application` or `Service`.

Expose for qualified Follow Rejects:

- `bot_like_events`
- `bot_like_unique_responders`
- `current_actor_metadata_known_unique_responders`
- `current_actor_metadata_unknown_unique_responders`

Also expose the useful intersection:

- `immediate_lte_5s_bot_like_events`
- `immediate_lte_5s_bot_like_unique_responders`

This is NOT an automation classification.

Name it `bot_like` or `current_bot_flag`, not `automated_rejection`.

---

# Part E: responder domain concentration

We want to know whether many qualified rejects came from many independent domains or are concentrated.

Compute this over **unique qualified rejector subjects**, not event rows, so duplicate events from one responder do not inflate domain concentration.

Use `ModerationSubject#domain` retained metadata.

Internally:

- local subject -> one local bucket
- remote subject with domain -> normalized/stored subject.domain
- remote subject without domain -> unknown bucket

Do NOT return domain names.

Expose:

- `unique_responder_domains`
- `largest_domain_responder_count`
- `largest_domain_responder_share`
- `local_unique_responders`
- `unknown_domain_unique_responders`

For share:

```text
largest domain unique responders / qualified unique responders
```

Return `0.0` for zero denominator.

A local bucket counts as one domain/group for concentration.

Do not describe concentration as coordination.

---

# Part F: suggested stable output

Suggested service output:

```json
{
  "generated_at": "...",
  "windows": {
    "1h": {
      "window_start": "...",
      "window_end": "...",
      "raw_follow_reject_events": 0,
      "qualified_follow_reject_events": 0,
      "unqualified_follow_reject_events": 0,
      "qualified_unique_responders": 0,
      "latency_buckets": {
        "lte_5s": 0,
        "gt_5s_lte_30s": 0,
        "gt_30s_lte_5m": 0,
        "gt_5m": 0,
        "unknown": 0
      },
      "immediate_lte_5s_events": 0,
      "actor_types": {
        "event_counts": { ... },
        "unique_responder_counts": { ... }
      },
      "bot_like_events": 0,
      "bot_like_unique_responders": 0,
      "immediate_lte_5s_bot_like_events": 0,
      "immediate_lte_5s_bot_like_unique_responders": 0,
      "current_actor_metadata_known_unique_responders": 0,
      "current_actor_metadata_unknown_unique_responders": 0,
      "unique_responder_domains": 0,
      "largest_domain_responder_count": 0,
      "largest_domain_responder_share": 0.0,
      "local_unique_responders": 0,
      "unknown_domain_unique_responders": 0
    },
    "24h": { ... },
    "7d": { ... }
  },
  "notes": [
    "latency buckets are descriptive and do not classify a rejection as automated or human",
    "actor type and bot-like metadata are current Account attributes, not event-time historical snapshots",
    "Service/Application metadata does not prove automation or malicious behavior",
    "domain concentration does not prove coordination",
    "absence of observed negatives is not evidence of absence"
  ]
}
```

Exact wording can be polished, but preserve these semantics.

---

# Part G: integrate only into SubjectDiagnostics

Compose the new service into:

`Moderation::SubjectDiagnosticsService`

Suggested initializer dependency:

```ruby
follow_reject_observer: FollowRejectObservationService.new
```

Suggested output location:

```ruby
result['negative_signals']['follow_reject_observation']
```

or an equally clear nested location.

Do NOT duplicate these fields into BehavioralMetricsService in this PR.

Do NOT alter existing keys in:

- `negative_signals['24h']`
- `evaluation`
- `follow_gate`

Existing evaluation/follow-gate output must remain byte/structurally equivalent except for the new diagnostics subtree outside them.

Add an injected observer spec proving composition without changing evaluation output.

---

# Part H: no schema / no event metadata snapshot yet

Do NOT add Account actor metadata to ModerationRejectionEvent.

That would be a separate design choice because:

- current account metadata can change
- account deletion removes live actor_type metadata
- event-time actor snapshot would require privacy/retention decisions

For this quick PR, current metadata is sufficient for shadow observation.

Unknown must be first-class.

---

# Part I: tests

Add focused service specs.

Minimum matrix:

## Stable empty shape

No subject / no rejects:

- all windows present
- all counts zero
- all actor type keys present
- share 0.0
- no ModerationSubject created

## Latency boundaries

Qualified Follow Rejects at exactly:

- 0s
- 5s
- just over 5s
- 30s
- just over 30s
- 300s
- just over 300s

Assert exact buckets.

Use real preceding interaction linkage / EventRecorder where practical.

## Qualification

- linked Follow Reject -> qualified
- unlinked synthetic/protocol Follow Reject -> raw/unqualified only
- unqualified does NOT enter latency/actor/domain detailed qualified counts

## Actor type

Create responders with:

- actor_type nil/blank -> Person
- Person
- Service
- Application
- Group
- Organization
- unknown/unrecognized -> Other
- detached/deleted Account / subject without Account -> unknown

Assert both event and unique responder counts.

## Bot-like

- Service -> bot_like
- Application -> bot_like
- Person -> not bot_like
- immediate intersection counts correctly
- same responder with duplicate qualified events counts multiple events but one unique responder

## Domain concentration

Example:

- 3 unique qualified responders on domain A
- 1 on domain B
- 1 local

Expect:

- qualified unique responders = 5
- unique_responder_domains = 3
- largest_domain_responder_count = 3
- largest_domain_responder_share = 0.6
- local_unique_responders = 1

Also test unknown domain.

Do not expose actual domain names in result.

## Time windows

Place events so:

- one only in 1h
- one in 24h but not 1h
- one in 7d but not 24h

Assert nesting.

## Read-only

Assert no changes to:

- ModerationSubject
- ModerationInteractionEvent
- ModerationRejectionEvent
- ModerationAction
- ModerationEvidenceSnapshot
- Follow
- Block
- Mute

## Privacy

Recursively inspect keys/values if useful.

Output must not contain:

- acct
- username
- account IDs of responders
- moderation subject IDs of responders
- domain names
- IP
- post/profile/report/DM bodies

SubjectDiagnostics already emits the diagnosed subject/account id; do not expand privacy scope beyond that existing behavior.

---

# Part J: regression guarantees

Run existing:

- BehavioralMetricsService specs
- SubjectDiagnosticsService specs
- RiskEvaluationService specs
- AdaptiveFollowGateDecisionService specs
- FollowImport ReviewSignalClassifier / ShadowEvaluator specs

Prove no scoring/threshold behavior changes.

PR body must explicitly state:

- no scoring change
- no Follow Gate change
- no Action Review change
- no DB migration
- current Actor metadata only
- timing does not classify human vs automated
- bot-like means current Account#bot? only
- no domain names emitted

---

# Scope exclusions

Do NOT implement weighting such as:

- immediate rejection = 0.5
- Service rejection = 0.25
- domain de-duplication in RiskEvaluation

Do NOT change `follow_reject_rate`.

Do NOT change qualified negative event counts.

Do NOT change continuation anchor semantics.

Do NOT infer:

- same person
- sockpuppet
- coordinated behavior
- malicious bot
- human/manual rejection

This PR only makes calibration variables observable.

---

# PR

Create one Draft PR against `fedibird`.

Suggested title:

`Expose Follow Reject signal decomposition for moderation diagnostics`

Keep it small.

No migration.

Delete this temporary task file before final PR diff.

Completion report:

- Draft PR number / URL
- head/base SHA
- changed files
- exact service output shape
- exact latency boundaries
- actor type bucketing
- bot-like definition
- domain concentration denominator
- SubjectDiagnostics integration path
- proof evaluation/follow_gate unchanged
- exact RSpec result
- exact RuboCop result
- deviations / follow-ups
