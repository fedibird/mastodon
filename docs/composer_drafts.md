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
| Completed media id, order, ALT, focus | | In-progress upload bytes and preview-only attachments |
| Managed hashtags and mentions, suppressions, context source id and revision | | Permission caches and `interactionCheck` |
| Selected posting style, revision, manual overrides, usage | | Display objects such as `reply_status` |
| Sender id and whether the choice was explicit | | Redraft and existing-post edit state |
| Surface kind and key, group destination account id | | |

Completed media is restored as an id plus ALT, order, and focus. The thumbnail URL is not part of the snapshot, and an upload that has not finished is not described as saved. The banner says when attachments were still uploading. Keeping those files across reloads belongs to P1-B.

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
