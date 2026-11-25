# Composer drafts (P0 local recovery)

P0 stores a versioned snapshot of a new post in IndexedDB so a reload can offer it back. It does not create a server draft, a draft list, or a public compose control. Recovery stays off unless this browser opts in:

```js
localStorage.setItem('fedibird:composer-draft-recovery', '1');
location.reload();
```

Remove the key and reload to turn it off. While the key is absent, the composer does not open the draft database and does not autosave.

The database is `fedibird-composer-drafts`, separate from the service worker's `mastodon` database. Records are keyed by the signed-in account id and a `client_draft_uuid`. The on-screen `composerId` is not the storage key. A new post mints a new id and does not replace a different draft. Two tabs that edit one restored id and diverge each keep a copy.

## What a snapshot keeps

`schema_version` is `1`. The body is the raw `text` the user typed. `materializeComposerText` output, generated HTML, suggestions, upload progress, `is_submitting`, `instanceId`, `draftGeneration`, and `idempotencyKey` are not the saved source. Restoring bumps the surface epoch, the redraft epoch, and the sender change epoch so an older async result is not applied to the restored draft.

| Kept as entered | Restored, then resolved again | Not saved |
| --- | --- | --- |
| Raw text, content warning, privacy, searchability, circle, language, sensitive | Reply and quote ids (the status card is loaded again) | Suggestions and completion tokens |
| Reply id, quote id, quote URL, reference ids | Sender permission, from the current identity catalog | `is_submitting`, upload progress, processing flags |
| Poll options, multiple choice, poll duration | Group and delegated permission at send time | `instanceId`, `draftGeneration`, `idempotencyKey` |
| Schedule and expiry text the user entered | Posting-style destination that was `failed` (`needs_resolve`) | Materialized text and HTML |
| Completed media id, order, ALT, focus. Posting stays off while the attachment is unresolved | | In-progress upload bytes and preview-only attachments |
| Managed hashtags and mentions, suppressions, context source id and revision | | Permission caches and `interactionCheck` |
| Selected posting style, revision, manual overrides, usage | | Display objects such as `reply_status` |
| Sender id and whether the choice was explicit | | Redraft and existing-post edit state |
| Surface kind and key, group destination account id | | |

Completed media is restored as an id plus ALT, order, and focus, and marked unresolved. The thumbnail, type, and owner are not part of the snapshot. Posting stays off, and new files cannot be added, until those attachments are removed. An upload that has not finished is not described as saved. Keeping the files across reloads belongs to P1-B.

A reply or quote id is restored, then the target post is loaded again. Posting stays off while that load is in progress and if it fails. The reply or quote indicator appears after the post is in the local cache. Typing while the load is in progress still accepts the result. A later restore, or a change of the reply or quote target, ignores the older result. Canceling the reply or quote still clears the text. A control that drops only the failed target and keeps the text is left for a later change.

Restoring onto a screen whose group or hashtag destination differs from the draft keeps the draft destination and sets the existing surface mismatch. Posting stays off until the destination shown on that screen is applied. The screen is the destination the column is showing. A posting surface left by an earlier restore is not that screen, so restoring the same group or hashtag draft onto the primary composer asks for confirmation again after the previous confirmation. Restoring a group or hashtag draft onto the primary composer, which has no displayed destination, also keeps posting off until that saved destination is confirmed. The confirmation names that destination and its surface epoch. If the screen has since moved to a different group or hashtag, the confirmation does not clear the mismatch. The newest saved draft is offered on an empty composer. Preferring the draft for the open destination, and showing its destination, text, and time before restore, belongs to a later change. A record with a nested field of the wrong shape still restores: that field is dropped, and the restore does not throw. The restore banner names the draft's surface, and says when the draft is a reply or a quote. A list-to-list change does not hold the post. While a write is waiting, the save state is `saving`. It becomes `saved` only after the acknowledgement for the current edit.

Clearing the text does not delete a draft that was already saved. That copy stays available to restore, and the next text starts a new draft instead of replacing it. The clear action deletes the draft it belongs to when the stored row is still the version this tab saved. Another tab's newer text stays. A late acknowledgement records that stored hash together with its revision. The saved indicator still waits for the current edit. A successful post deletes the draft that was sent, including when the composer is replaced before the result arrives. The result is matched to the submit that sent it, so an older success does not delete a newer draft that reused the composer. That newer draft's save is left running. While that submit is still open, the sent draft is not offered to another composer. Restoring it anyway keeps the new composer's text under a different id, so the sent draft's deletion does not remove that text. A failed submit leaves the sent draft available again. Text typed while that post is in flight stays, under a new id. A late write cannot put the sent draft back. A successful post deletes the stored draft when its text is still the version that was sent, and also when the row is still the saved version this tab held before a newer edit that had not been written yet. Another tab's newer text stays. If the delete happens first, the other tab's next save keeps that text under a new id. A failed submit does not delete the draft. The clear action also drops a restored reply or quote hold, an unconfirmed restored destination, and unresolved restored attachments. An attachment the user uploaded in this composer stays, and that remaining composer starts a new draft. The draft that was cleared is deleted even when the attachment stays. Canceling a reply or quote does the same. If the screen has already moved to another destination, the clear action does not approve the old one.

Existing-post edit, scheduled-post edit, and delete-and-redraft are not stored as new drafts. Clearing a new post deletes that post's local draft. Closing a portable composer keeps the draft and does not put it back automatically.

`copyComposerDraftSnapshot` returns a frozen copy of the same raw snapshot. A later preflight can read that copy. This change does not add preflight checks, suggestions, or formatting, and the copy is not written back onto the draft.

## Manual check

1. Sign in, set the localStorage key above, and reload.
2. On one desktop window, type in the main composer and in two portable composers. Wait briefly. Reload. Each empty composer offers a restore. Restoring one does not fill the others. A composer that already has text does not change.
3. Open the same account in a second tab and edit a restored draft in both. Each tab keeps a copy; neither replaces the other.
4. Switch accounts in another profile. The first account's drafts are not offered.
5. Start a post, edit an existing post, edit a scheduled post, and delete-and-redraft. Reload. Only the new post is offered.
6. While a video is still uploading, reload. The text can be restored. The banner does not claim the unfinished file was saved.
7. In a private window, or after filling storage, the composer says the draft was not saved.
8. Repeat the restore once in iOS Safari and once as an installed home-screen app. `pagehide` is best-effort there; confirm the text is present after a normal reload and that a crash during the first second can still lose the last keystroke.

Automated coverage is the Jest suite under `app/javascript/mastodon/drafts` and the recovery component test. Those tests do not drive Safari or a second browser profile.

## Server sync (P1-C foundation)

Server sync stays off until an operator sets `Setting.post_draft_sync = true`. Administrators are then admitted. Any other account is admitted only when its user id is listed in `Setting.post_draft_sync_testers`. An empty list does not admit ordinary users. Staff who are not administrators are not admitted unless listed.

The public API still requires `read:post_drafts` and `write:post_drafts`. `read` and `write` do not include them, and this change does not add them to external applications or to tokens those applications already hold. A new WebUI session for an admitted user is minted with `read write follow read:post_drafts write:post_drafts`. A session created earlier keeps `read write follow` until the next full page load. That load replaces only the token on that browser session and embeds the replacement. Other browser sessions are updated when they load a page. A revoked web token is not replaced; that browser signs in again. While the flag is off, or the user is not admitted, the WebUI does not open the draft database for sync and does not call the draft API. The localStorage recovery switch still works on its own and still does not call the API.

IndexedDB remains the recovery copy. `client_uuid` identifies the draft. The IndexedDB `revision`, the page epoch, and the monotonic sync generation are separate. The page epoch starts again on each load. A new page identity is newer than the resumed generation, so one new character still syncs. The server id and the acknowledged server revision live in a separate `sync` store. A draft is `synced` only when that acknowledgement matches the edit that is current now, including text typed during the local debounce and not yet written. A response for an older edit stays unsent.

Local edits wait 300ms before IndexedDB and 2s before the server. One request is in flight per draft, and two requests are in flight across drafts. A newer edit replaces the body that has not been sent. Network failures, timeouts, and 5xx responses retry up to five times, backing off from 1s to 16s. Going offline waits without calling the draft `synced`. Coming online retries. 401, 403, 413, and 422 (including the 100-draft limit and the 256KiB payload cap) do not retry. The local copy stays.

POST is idempotent on `client_uuid`. A timed-out create is sent again with the same body. The same body returns the existing row. A different body returns 409 and is not written over the server row. A timed-out PATCH stays unresolved and is retried as that same intent. It is not treated as success because a later GET shows the same hash. A 409 is a conflict, including when the server has the same text at another revision. The other device's revision is remembered separately and is not used as the next PATCH or DELETE base. Conflict stays in place across further edits, reload, going online, and discard. Nothing is deleted or unlinked. The local text, settings, and media references stay.

A conflict is not copied onto a second server draft. One media id can belong to only one server draft. Copying later means a new `client_uuid` for the text and settings, then attaching the files again.

An explicit discard writes the tombstone in the same storage step that removes the local row, then deletes the server row only at the revision this client acknowledged. A successful response is adopted only when its hash is the hash that was sent. A 409 or an unknown response does not delete the other revision. A create whose response was lost is looked up by `client_uuid`. It is deleted only when the stored hash is the hash that was sent. Otherwise the server row stays and the delete stays unknown or blocked, including after reload. A conflict is discarded locally and is not deleted on the server. Publishing a post does not delete the server draft. If the create has not started, it is cancelled. If the server row already exists, it stays until draft publication is accepted. Sending a post does not remove the media guard and does not treat deletion of a text draft as a successful publish.

A web token that already has the draft scopes keeps them when the flag is turned off or the user leaves the tester list. The page flag is what stops the WebUI. A tab that is already open keeps the flag it loaded until the next full reload. This change does not push a live kill switch. The API still accepts those scopes. External OAuth tokens are not rewritten. While the flag is off, a page load does not lock the session row. Two page loads of an admitted session take a row lock and rotate that token once. A failed rotation leaves the previous web token in place. An expired or revoked web token is not replaced.

A send intent is one operation: an id, the page that owns it, the draft id, the base revision, the hash, and the expected revision. Those fields stay fixed. A ledger commit accepts the operation only when that base is still the stored acknowledgement. Another tab's newer acknowledgement is kept, and it is not used as this operation's PATCH or DELETE revision. The same operation may retry. A different edit, or another page's operation with the same text, does not replace it and does not clear it.

A lost response stays an explicit hold. The later draft UI has to offer an explicit resume or discard before a different body is sent. This foundation does not send that different body and does not delete the server row while the hold remains. A definite refusal, where the API did not keep the write (401, 403, 413, and 422, including the draft limit and the size limit), clears that operation and keeps the local text. A later edit can try again. A timeout or a 5xx response stays held.

A discard records the revision this page observed at that moment. It deletes the server row only when that pinned revision is still the stored acknowledgement and no operation is unresolved. A discard does not borrow a revision another tab acknowledged later. A deleted cursor stays deleted.

Coming back online continues the retry budget and does not reset an exhausted one. A failed ledger write stops network use until the stored cursor has been read again. Typing more text does not clear that stop. A conflict that cannot be written stops further network use. A discard that starts before the cursor has been read waits, then commits, and only then may call the server.

`persistence.status` is still the local IndexedDB result. The server state is `sync` on the same recovery view: `local` (saved on this device, waiting), `syncing`, `synced`, `failed`, `conflict`, `held` (publish left the server row in place), or `deleted`. The list, restore, and bulk-delete UI are not part of this change.
