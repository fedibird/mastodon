# Cursor task: Follow Import pacing backtest privacy-export compatibility

> **TEMPORARY IMPLEMENTATION INSTRUCTION**
>
> Branch from the latest `fedibird`, implement this focused task, run the
> required tests, open a Draft PR against `fedibird`, and **delete this file
> from the implementation branch before finishing**.

## Purpose

Make the I3 offline pacing backtest added in #139 consume the
privacy-minimized Follow Import transport export directly, without requiring
raw destination domains or raw endpoint origins.

This is a small compatibility PR only.

It must not:

- change Follow Import runtime dispatch behavior
- change fixed/adaptive profile semantics
- change production defaults or feature flags
- enable GLOBAL
- change Retry-After behavior
- add database migrations
- add production telemetry rows/columns
- add external dependencies

## Current mismatch

`FollowImport::PacingBacktest::Input` currently requires transport headers:

```text
destination_domain
endpoint_origin
```

The operator privacy export uses:

```text
anon_destination_domain
anon_endpoint_origin
```

Those identifiers are intentionally stable only within the export and reveal
neither the raw destination domain nor endpoint origin.

Simply aliasing the names is not enough: the current backtest uses
`TagManager.instance.local_domain?` / `web_domain?` to exclude local
destinations from remote destination/origin pressure. Once the destination has
been pseudonymized, that classification can no longer be reconstructed from the
identifier.

Therefore anonymous routing input must carry an explicit
`destination_is_local` observation.

## Input modes

Support exactly two transport routing identity modes.

### 1. Raw mode — existing compatibility

Headers:

```text
destination_domain
endpoint_origin
```

Behavior remains backward compatible.

- `destination_is_local` may be absent.
- If it is absent, determine locality using the existing
  `TagManager.instance.local_domain?` / `web_domain?` logic.
- If `destination_is_local` is present, parse and use it as an explicit hint.
  This makes raw-mode fixtures/exporters able to exercise the same code path.

### 2. Anonymous mode — privacy export

Headers:

```text
anon_destination_domain
anon_endpoint_origin
destination_is_local
```

Map them internally to the existing logical destination/origin identity fields.

The pseudonyms are opaque routing identities. Do not try to parse them as host
names.

For anonymous mode:

- `destination_is_local` is required.
- Every row with a nonblank anonymous destination must have a valid explicit
  boolean locality value.
- A blank destination may have blank locality; it remains the existing
  UNKNOWN_DESTINATION case.
- Never fall back to `TagManager` for an anonymous destination.

Accepted boolean cells should be intentionally narrow and documented. Prefer
the values emitted by PostgreSQL CSV plus common explicit equivalents:

```text
t / f
true / false
1 / 0
```

Case-insensitive for words is fine.

Do not silently coerce an unknown value to false. For anonymous rows where
locality is required, invalid/missing locality must fail the backtest with a
clear row/field error because treating a local destination as remote would
corrupt calibration numbers.

## Header-mode selection

Determine routing identity mode from headers once per transport file.

Preferred contract:

- raw destination + raw origin headers -> `raw`
- anonymous destination + anonymous origin + destination_is_local -> `anonymous`
- incomplete or mixed routing header sets -> fail clearly

Do not silently combine a raw destination with an anonymous origin.

If both complete raw and complete anonymous sets are present, prefer failing as
ambiguous unless there is a compelling reason to choose one. Explicitness is
more valuable than convenience for calibration tooling.

Expose the selected mode in the result, e.g.:

```json
"routing_identity_mode": "raw"
```

or

```json
"routing_identity_mode": "anonymous"
```

Place it in the baseline dataset/input metadata so reviewers can tell which
semantics were used.

## Attempt model

Extend the in-memory `Attempt` with a locality field, e.g.:

```ruby
:destination_is_local
```

The field represents an input observation/hint, not a raw domain-derived value
unless the loader explicitly computed it.

Do not expose raw domains in output.

## Routing semantics

Refactor `FollowImport::PacingBacktest::Routing` so every place that needs
locality can use the explicit locality observation.

The production semantics must remain:

### Local destination

```text
destination pressure -> none
origin pressure      -> none
destination adaptive persistence -> none
origin adaptive persistence      -> none
```

### Missing destination

```text
destination pressure -> UNKNOWN_DESTINATION
origin pressure      -> none
destination adaptive persistence -> none
observed origin adaptive persistence -> allowed after an actual HTTP delivery
```

This is the #139 contract already established.

### Remote destination

Normal fixed/adaptive destination pressure applies. Retrospective observed-origin
pressure remains the existing I3-v1 behavior and limitation.

Do not change the current warning that origin pressure is retrospective and does
not reconstruct claim-time mapping-cache availability/TTL.

## Privacy behavior

The backtest currently hashes routing identities again in default output.

That is acceptable and preferable for anonymous input too:

```text
input anon_destination_domain d0000972
-> output privacy label d_<sha256-prefix>
```

Do not special-case pseudonyms into user-visible output.

Update documentation to make stability precise:

- with raw input, the same raw key produces the same output hash;
- with anonymous input, labels inherit the operator export's identity stability
  and are not guaranteed to be stable across separately generated exports.

Do not claim cross-export stable destination labels for anonymous mode.

## Exporter contract documentation

The SQL exporter itself is operator-side and is not currently repository code.
Do not invent a repository exporter implementation in this PR.

Document the anonymous transport contract expected by the backtest:

```text
anon_destination_domain
anon_endpoint_origin
destination_is_local
```

The operator export will be updated separately to emit
`destination_is_local` from the raw destination before pseudonymization.

The backtest must never require the raw destination to accompany anonymous mode.

## Tests

Add focused regression coverage.

### Header/input mode

1. existing raw transport fixture still loads unchanged
2. anonymous destination/origin headers + valid locality load successfully
3. selected dataset reports `routing_identity_mode=anonymous`
4. raw dataset reports `routing_identity_mode=raw`
5. incomplete anonymous headers fail clearly
6. mixed raw/anonymous header set fails clearly
7. anonymous nonblank destination with missing locality fails clearly
8. anonymous invalid locality value fails clearly
9. blank anonymous destination may have blank locality

### Boolean parsing

10. parse at least PostgreSQL `t/f`
11. parse `true/false`
12. parse `1/0`
13. never coerce arbitrary text to false

### Fixed pressure

14. anonymous local destination never consumes destination/origin cap
15. anonymous remote destination does consume destination/origin cap
16. anonymous missing destination uses UNKNOWN destination pressure and no origin pressure

### Adaptive replay

17. anonymous local destination creates no remote adaptive destination/origin state
18. anonymous remote destination behaves like raw remote input
19. anonymous missing destination keeps the established #139 behavior:
    UNKNOWN destination pressure, no origin claim pressure, no destination state,
    but observed origin state may be learned after actual HTTP

### Output/privacy

20. raw anonymous identifiers are not surfaced directly in default concentration
    detail output
21. routing mode is exposed
22. docs/result warnings do not claim anonymous labels are cross-export stable

Keep existing #139 replay semantics unchanged.

## Relevant existing specs to rerun

Run the complete I3 suite plus the production profile/controller specs used by
#139:

```bash
RAILS_ENV=test bundle exec rspec \
  spec/services/follow_import/pacing_backtest \
  spec/services/follow_import/pacing_backtest_spec.rb \
  spec/services/follow_import/remote_admission_profile_spec.rb \
  spec/services/follow_import/adaptive_remote_profile_spec.rb \
  spec/services/follow_import/adaptive_remote_compatibility_spec.rb \
  spec/services/follow_import/adaptive_remote_controller_spec.rb \
  spec/services/follow_import/adaptive_remote_observation_spec.rb
```

Run RuboCop on all changed Ruby/spec files.

Report exact counts.

## Permanent docs

Update `docs/follow_import_pacing_backtest.md` with:

- raw vs anonymous routing input modes
- required anonymous headers
- explicit-locality requirement
- boolean encoding
- local/missing/remote routing semantics
- privacy/stability behavior
- example header snippets only; do not add raw production data

If another existing pacing telemetry/design doc describes exporter/backtest
integration, add only a short pointer there. Keep the PR focused.

## PR body

Open one focused Draft PR against `fedibird`.

The PR body must say:

1. this is input compatibility only
2. runtime behavior is unchanged
3. raw mode remains backward compatible
4. anonymous mode requires explicit locality
5. no raw destination/origin is needed in anonymous mode
6. exact tests/RuboCop results
7. no production data or numeric pacing recommendations are committed

## Mandatory cleanup

Before completion:

1. commit implementation/spec/permanent-doc changes
2. **delete `docs/CURSOR_TASK_follow_import_backtest_privacy_export_compat.md`**
3. commit that deletion
4. open/update the Draft PR
5. report:
   - PR URL
   - head SHA
   - changed files
   - input mode contract
   - exact tests
   - RuboCop
   - confirmation temporary task file is absent from PR HEAD
