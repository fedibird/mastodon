# Status title and ActivityPub object type

Status of this change: stored data and internal guards only. Ordinary
posts remain Notes. Nothing in this change delivers a Page, exposes
`post_title` or `ap_object_type` on the REST API, adds a composer field,
or enables Lemmy or PieFed delegated posting.

## Data model

`statuses.post_title` is nullable text. `statuses.ap_object_type` is a
nullable string. Neither column has a database default, and this change
does not update existing rows.

NULL `ap_object_type` means `note`. New notes also store NULL, so old
and new notes are the same shape. The only stored value this release
can persist for the column is `page`, and only through a direct model
write. `PostStatusService` refuses `page` before it saves, schedules, or
delivers anything.

`Status#object_type` stays the URI discriminator: `:comment` for a reply
and `:note` otherwise. It is not the ActivityStreams type. A page still
returns `:note` from that method, so its object id does not move.

Rails enum is not used. An enum wants a stored value on every row and
would collide with the existing `object_type` method name if it were
given that name. Unknown values fail validation and the NOT VALID check
constraint. They are not rewritten to `page`.

## note and page

| `ap_object_type` | `post_title` | Meaning |
|---|---|---|
| NULL or `note` | NULL | Existing post |
| NULL or `note` | text | Internal note that has a title. Not exposed and not delivered as a Page |
| `page` | text | Future Page. Not created by the public post path |
| `page` | NULL | Invalid |

A remote Page, Article, or other converted type is still ingested as a
normal status. Its `name` is not copied into `post_title`, and
`ap_object_type` stays NULL. The existing converter may still fold a
remote Page name into the status body. That behavior is unchanged.

## Title and content warning

`post_title` is a separate string. It is not `spoiler_text`, and it is
not the first line of `text`.

Normalization:

- nil, `""`, and whitespace-only (Unicode `[[:space:]]`) become NULL
- a value that contains a control character (`\p{Cc}`), U+2028, or U+2029 is rejected, including when the only character is a line break
- surrounding whitespace is removed only after that rejection
- Unicode is stored as given, without NFC or NFKC folding
- the string is not parsed or sanitized as HTML

The length limit is 100 Unicode code points (`String#length`, PostgreSQL
`char_length`). That is the same count Lemmy uses when it truncates a
missing title (`chars().count()`, 200 scalar values) and the same count
as PieFed's `varchar(255)`. 100 is below both, so a title accepted here
does not need to be truncated for those receivers. Grapheme clusters are
not the limit: one ZWJ emoji is one grapheme and several code points, and
a 100-grapheme title could exceed Lemmy's 200. Over-long titles are
rejected, not truncated.

`StatusLengthValidator` still counts grapheme clusters of spoiler text
plus body only. The title is not added to that budget and cannot raise it.

## What this release refuses

Public `POST /api/v1/statuses` and `PUT /api/v1/statuses/:id` return 422
when the raw parameters include `post_title` or `ap_object_type`. The
parameters are not dropped quietly, because a client would otherwise
believe it had created a Page.

`PostStatusService` accepts `post_title` for an internal note. It raises
before save, schedule, or distribution when `ap_object_type` is `page`
or any other non-note value. Reply, quote, and boost of a stored page
also raise. A page cannot be a reply, boost, quote, poll, or remote row.

`UpdateStatusService` ignores those keys and refuses to edit a page, so
an update is not serialized as a Note. `ActivityPub::NoteSerializer`
raises `Status::UnreleasedActivityObject` for a page and still emits
`Note` or `Question` with no `name` for everything else. Distribution,
local fan-out, the public status permalink, the ActivityPub outbox, and
account backups skip pages. Local discard still runs, but a page does
not send Delete or Undo. REST responses do not grow new attributes.

A stored page is also withheld from readers. `StatusPolicy#show?` is
false for everyone, including the author, so single-status REST, HTML,
ActivityPub collections that authorize the status, and oEmbed return
404. Account status lists, profile HTML and RSS, the public and hashtag
database feeds, Redis feed hydration, and Explore trend queries add
`without_unreleased_pages` at those entrances only. `default_scope` is
unchanged. Search drops a page in `StatusFilter`, and Chewy does not
index one. Webhooks are not enqueued. The profile status counter does
not include a page.

`without_unreleased_pages` is `ap_object_type IS DISTINCT FROM 'page'`.
On a public or account timeline it is a residual check on the index
already chosen by visibility, deletion, and account predicates. It does
not add an index and does not scan the table by itself. Redis hydration
applies it only to the small id list already loaded from the feed.

## REST API later

M3-6b can add optional input and output:

- `post_title`
- `ap_object_type` with `note` and `page`

The server, not the client, decides whether a page is allowed. Sending
the fields must not bypass posting context, delegation, visibility, or
mention checks. A page still requires a normalized title. A note may
omit it. Clients that do not send the fields keep today's Note behavior.

`REST::StatusSerializer` stays unchanged until that release. Until then,
a stored title is invisible to existing clients.

## Serializer switch later

M3-6c should select the object serializer from `ap_page?`:

- page: a Page serializer whose `name` is `post_title` and whose `content` remains the status body
- anything else: the current `ActivityPub::NoteSerializer`, including `Question` for polls

`ActivityPub::ActivitySerializer` should keep using that choice for the
Create and Update object. Delete stays a Tombstone. The object id in all
three activities is `ActivityPub::TagManager.instance.uri_for(status)`,
which already uses `object_type` and must not grow a second path for pages.

## Composer later

The composer should grow an explicit title input for a page. It must not
fill that input from the first line, the content warning, or the whole
body. The delegated Lemmy and PieFed drafts already say that an explicit
title is required and they keep the draft. The non-delegated Lemmy hint
that the first line becomes a title belongs to the viewer's own identity
and is a separate path.

## Remote group adapters later

After a Page is delivered with a stable id, `lemmy_group` and
`piefed_group` can be considered again. They are still absent from
`PostingIdentity::RemoteGroupPost::ADAPTERS`. Enabling them also has to
keep the current contract checks: source id, key prefix, revision,
audience, visibility, and mention rules. PieFed `local_only` and
`restricted_to_mods` are per community and are not NodeInfo, so they
stay separate from the delegation grant.

## Migration and rollback

The migration adds two nullable columns and
`statuses_post_title_shape` with `validate: false`. Rolling the migration
back drops the constraint and the columns. PostgreSQL 11+ does that
without rewriting the table. Rows that stored a title or a page would
lose those values; this release has no public writer for them.

A later migration can `VALIDATE CONSTRAINT` once a scan is acceptable.
Do not backfill NULL to `note`. NULL already means note, and a table-wide
UPDATE would rewrite `statuses`.
