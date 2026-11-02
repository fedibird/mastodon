# Group management P3-A: local roles and two-party ownership transfer

Source: #657 / #685. Builds on the merged P0–P2 code; unrelated to remote GroupAffiliation.

## Boundaries

- The active owner is the one `GroupRoleAssignment.active.owner` row, not `Account.user` or a Follow.
- Only the active owner can appoint or remove moderators or propose/cancel an owner-transfer offer. A moderator can resign their own role. A successor can accept **only** an unexpired offer addressed to their own local functional Person Account.
- No action from this phase changes a Follow/FollowRequest, GroupAffiliation, group posts/Announce, server privileges, or login sessions.
- `GroupCreationRequest.initial_owner_account_id` is a historical snapshot and never changes during a transfer. Legacy groups remain outside P3-A.
- Transfer offers last 7 days. A subsequent offer supersedes an earlier one only under the same ManagedGroup row lock. There is one pending offer per group at the DB level; expiration is checked on acceptance, not by a background job.
- A successor who is currently a moderator has that moderator row revoked in the same transaction before the new owner row is inserted. Role assignment history stays intact.

## Concurrency and audit

All mutations lock the corresponding ManagedGroup row before checking current roles and writing. Acceptance locks the offer after the group, and the P0 transfer method locks the owner row. A concurrent owner change, resignation, double acceptance, or revoke therefore cannot produce two active owners. The P0 partial unique indexes remain the final defense. Audit is written inside the mutation transaction; a failed audit rolls back roles/offers. The existing server-admin log viewer can display these events for the ManagedGroup.

## Rollout and rollback

1. Review model/migration, authorization and request specs. Apply the empty-table migration in staging; verify that existing groups, users and Follow counts are unchanged.
2. Sign in as the owner of a newly approved local Group. Assign a moderator, have the moderator resign, send a transfer offer, and sign in as the successor to accept. Repeat with a current moderator as successor. Verify one active owner, historical initial owner unchanged, no Follow changes.
3. Test a refused/expired/replaced offer, a suspended candidate, CSRF and another user's group ID. The candidate must not see the owner's private settings.
4. The schema rollback drops *offers* but cannot undo an already accepted role transfer. Disable the new UI/routes before rolling back the migration; restore role ownership only via a reviewed administrator data repair, never by repopulating Followers or choosing an owner automatically.
5. Do not enable production flags, deploy, merge, or remove Draft status as part of this implementation.

P3-B (manual enrollment of login-backed legacy Groups, explicit owner selection, and legacy login/session/token revocation) must be separately audited and reviewed before rollout.
