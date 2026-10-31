# グループ作成申請とローカル役職の永続化（P0）

状態: P0。モデル、migration、この文書だけ。申請画面、承認の実行、Group Account の作成、招待 URL、FEP、REST API は作らない。

親の制約は [#657](https://github.com/fedibird/mastodon/issues/657)。この段階の保存モデルは [#658](https://github.com/fedibird/mastodon/issues/658)。

## 何を正本にするか

| 正本 | テーブル | 役割 |
|---|---|---|
| 作成申請 | `group_creation_requests` | 個人による申請のスナップショットと審査結果 |
| ローカルグループの管理 | `managed_groups` | ローカル Group Account 1件に対する管理行 |
| ローカル役職 | `group_role_assignments` | そのグループの owner / moderator |

`GroupAffiliation` はリモート Group が公開した権限キャッシュのままにする。ローカル役職の読み書きには使わない。Follow はこれまで通りメンバー集合であり、役職を保存しない。通常メンバー用のテーブルは作らない。

`Account#user` はその Account のログインであり、グループの owner ではない。既存のローカル Group は、管理者が Account の `actor_type` を Group に変えた個人アカウントであることがある。その User を初代 owner だとは扱わない。

## 申請

`GroupCreationRequest` を保存しても `accounts` も `users` も増えない。owner 行も `managed_groups` も作らない。

保持するもの:

- 申請者 (`requester_account_id`)。ローカルで、`person_type?` かつ `User#functional?` の個人だけ。Group、Application、Service、リモート、未承認、未確認、停止、無効、memorial、移動済みは拒否する。
- 希望 username、表示名 (`display_name`)、説明 (`note`)。Account のローカル規則に合わせる。username は `[a-z0-9_]{1,30}` に正規化して保存する。表示名は `LocalDisplayNameValidator`（30書記素、カスタム絵文字は1文字）。説明は `NoteLengthValidator`（500書記素）。
- `requested_at`、状態、審査者、`reviewed_at`、`decision_note`、取消日時、承認後の Group Account、初代 owner。
- `previous_request_id`。同じ申請者の却下または取消済み申請を1件だけ指す。承認済みや審査中からは再申請できない。1件の申請に後継は高々1件（unique）。

状態は `pending / approved / rejected / cancelled`。DB の初期値は `pending`。作成時に他の状態では保存できない。

`pending` からだけ `approved`、`rejected`、`cancelled` へ進む。その先は終端である。username、表示名、説明、申請者、申請日時、`previous_request_id` は作成後に変更できない。審査者は申請の内容を書き換えて通さない。

審査者はサーバー管理者に限る。`GroupManagement.server_administrator?` は、ログインできるローカル個人で、ロールが `can?(:administrator)`（Owner）または `can?(:manage_settings)`（Admin ロール）を持つ人である。Moderator と、ロールを持たないレガシー `users.admin` だけでは足りない。却下には空でない理由が要る。取消は申請者側の操作であり、審査者を埋めない。取消と再申請の画面は P1 である。モデルの `record_cancellation!` と `record_rejection!` は、その画面と P2 が同じ不変条件を通るための入口である。

Action Review には登録しない。`off` も `always` もこの申請を自動承認しない。`ActionReview::OperationRegistry` にグループ作成を足してはいけない。

### username は申請中に予約しない

作成時に、ローカル Account との大小文字を無視した衝突と、予約 username を拒否する。これは案内であり、占有ではない。

- pending の username に unique index を置かない。同じ名前の pending を複数保存できる。
- `lower(username)` の index は検索用で、unique ではない。
- pending のあとでも、その username で Account を作れる。
- 名前が後から埋まっても、提出済みスナップショットは書き換わらない。却下と取消は引き続きできる。
- 承認する側は、Group Account を挿入する前に `username_available_for_approval?` を呼ぶ。このメソッドは自分の pending 行を予約として数えない。
- 同時承認の最終防止は、既存の `accounts` の username unique index である。P2 は `ActiveRecord::RecordNotUnique` を承認失敗として扱う。

## 承認トランザクション（P2。この PR では実行しない）

P0 の `record_approval!` は Account を作らない。すでに同じトランザクション内へ入っている Group Account、`ManagedGroup`、有効な owner 1件を見て、申請を `approved` にし、初代 owner を申請へ写すだけである。条件が欠けていれば保存しない。

P2 は次を1つのトランザクションで行う。外部配送、Webhook、タイムラインへの投入はコミット後にする。

```ruby
GroupCreationRequest.transaction do
  request.lock!
  raise unless request.pending?
  raise unless request.username_available_for_approval?

  group = Account.create!(
    username: request.username,
    display_name: request.display_name,
    note: request.note,
    actor_type: 'Group'
  )
  # アイコンの受渡しは下の「承認時の avatar」。ここで Account#avatar へコピーする。

  ManagedGroup.create!(
    account: group,
    origin: :approved_request,
    creation_request: request
  )
  GroupRoleAssignment.create!(
    group_account: group,
    member_account: initial_owner,
    role: :owner,
    granted_by_account: reviewer,
    granted_at: Time.current
  )
  request.record_approval!(reviewer_account: reviewer, group_account: group)
end
```

`initial_owner` は申請者と同じとは限らない。P2 の画面が決める。写した `initial_owner_account_id` は申請に固定し、後の移譲では変更しない。

`Account.create!` はローカルなら鍵を作り、`account_stat` を保存する。Group 用の User を作るかどうかは P2 が既存の投稿経路を見て決める。作る場合でも、その User を `GroupRoleAssignment` の owner にしてはいけない。

承認済みの新規グループは owner 不在を許さない。`record_approval!` が owner 1件と `initial_owner_account_id` の一致を要求する。DB は `state = approved` の行に `group_account_id` と `initial_owner_account_id` を要求する。有効な owner はグループあたり高々1件を partial unique index が保証する。承認後にその唯一の owner を `revoke!` するとモデルが拒否する。

P3 の移譲は、有効 owner を0件や2件にしない。推奨手順は、現在の owner 行の member を新しい個人へ置き換え、古い member は `revoked_at` 付きの履歴行として残すことである。partial unique index は `revoked_at IS NULL` だけを見る。移譲サービスはこの PR には無い。

## ローカル管理行

`ManagedGroup` はローカル `actor_type == 'Group'` の Account に一意である。

- `origin = approved_request` は作成申請を必須とし、Account の username は申請の username と一致する。申請が既に別の Group を指している場合は拒否する。
- `origin = legacy_unassigned` は P3 の明示的な移行用に check 制約へ入れてある。P0 のモデルはこの origin を保存できない。Account の作成や更新から自動では作らない。
- 既存 Group を読み込んでも `managed_groups` は増えない。owner も付かない。

管理行が無い Group は、今まで通り Follow と配送で動く。`GroupAffiliation`、GroupDelivery、ProcessMentions、PostingContext、Invite、ActivityPub Actor serializer はこの PR で変えない。

## 役職

`GroupRoleAssignment` は `owner` と `moderator` だけを持つ。

- 対象グループは、ローカル Group で、かつ `ManagedGroup` があるものだけ。
- 役職者はローカルの有効な個人 Account。Group 自身、ボット、リモート、機能していない User は拒否する。
- `member_account_id <> group_account_id` は DB の check である。
- 同じグループの有効な行は member ごとに1件。owner を moderator と重ねられない。解除したあとなら新しい行を足せる。
- 有効な owner は `role = 0 AND revoked_at IS NULL` の partial unique index でグループあたり1件。
- グループ、member、role、付与時刻、付与者は変更しない。変更は解除して新しい行を作る。
- リモートの人を member にする列制約は置いていない。今はモデルが拒否する。将来のリモート管理は、この拒否を外す変更で足せる。
- 保存しても Follow は増減しない。Follow を消しても役職は残る。

## アイコンの staging（P1/P2。P0 では列も Paperclip も足さない）

アイコンは申請の対象である。P0 は公開経路へ載せず、実装は次の段階へ残す。列を先に足すと、既存の Paperclip 初期化が公開ストレージへ書いてしまうためである。

現状の `AccountAvatar`:

- 許可タイプは `AccountAvatar::IMAGE_MIME_TYPES`（jpeg、png、gif、webp、bmp、ico）。HEIC/HEIF/AVIF は止めたまま。
- 大きさの上限は `AccountAvatar::LIMIT`（4MB）。
- スタイルは original（400x400）と tiny（120x120。gif 以外は webp）。gif は static も作る。
- `config/initializers/paperclip.rb` のファイル保存は `public/system` 配下で、URL は `/system/...`。S3 は `public-read` と `Cache-Control: public, max-age=315576000, immutable`。Swift は `fog_public: true`。
- `remotable_attachment :avatar` は `avatar_remote_url` から取得して同じ公開ファイルへ置く。

したがって、承認前に `Account#avatar` へ保存すること、`avatar_remote_url` をセットすること、申請モデルへデフォルト設定の `has_attached_file` を足すことは、いずれも未承認の画像を公開 Actor または公開 URL から届く状態にする。

P1 で足す staging:

- 申請行の非公開ファイル。パスは `public/` の外（例: `storage/group_creation_icons/:id/original`）。S3 を使う環境では別 prefix と private ACL。公開用バケットの `public-read` を継承しない。
- 審査前に作るのはオリジナルだけ。400x400 や tiny の公開派生物は承認時に Account の既存パイプラインへ任せる。
- タイプと上限は `AccountAvatar::IMAGE_MIME_TYPES` と `LIMIT` と同じ。
- 審査プレビューはサーバー管理者だけのコントローラが `send_file` / `send_data` する。`Cache-Control: private, no-store`。media proxy、`/system`、ActivityPub の icon には出さない。
- 却下、取消、申請行の削除では、コミット後に staging ファイルを消す。トランザクションが戻った場合は消さない。
- 未承認の間は Group Account が無いので、プロフィール URL も ActivityPub の icon も存在しない。

P2 の受渡し:

1. 上のトランザクションで Group Account を作ったあと、staging のオリジナルを `group.avatar` へコピーし、既存の Paperclip スタイルを作る。
2. コピーが成功しトランザクションがコミットしてから staging を消す。
3. Paperclip はコミット前に公開パスへ書く。ロールバックしたときは、その Account id 用に書いたファイルを消す。公開 URL が残っても、行が無ければ Actor としては配信しない。残ファイルの削除をロールバック処理に含める。
4. `avatar_remote_url` は申請アイコンに使わない。

## 既存 Group の移行（P3。この PR では行を作らない）

対象は、この機能より前からいるローカル Group である。リモート Group の権限は引き続き `GroupAffiliation` だけを見る。

P3 は管理者が対象を選んだときだけ行う。

1. モデルが今拒否している `legacy_unassigned` を、明示的な移行処理からだけ保存できるようにする。
2. `ManagedGroup` をその Group Account に1件作る。フォロワーはコピーしない。
3. owner は管理者が指定した別の個人 Account である。`Account#user` や最古の Follow から埋めない。
4. owner を割り当てるまで、そのグループは owner 不在のままでよい。承認済みの新規グループとは違い、移行中の不在は許す。
5. 移行が終わるまで配送、Follow、Announce、既存 API の意味は変えない。

## migration

`db/migrate/20261110120000_create_group_management_records.rb` は新しい3テーブル、外部キー、check、partial unique index だけを足す。`accounts` などの既存テーブルは更新しない。バックフィルしない。既存行が無いので、新しいテーブル上の index は同時作成を要しない。

外部キーは、審査記録が Account の削除で消えないよう `restrict` を基本にする。付与者だけは `nullify` する。申請者や承認済みグループを削除する手順は、この restrict を壊さない形で P3 以降が別途決める。P0 の時点では対象行が無く、既存 Account の削除経路は増えた行を持たない。

## この PR でやらないこと

- 申請フォーム、アイコンの HTTP アップロード、管理者の承認画面
- Group Account / Actor / User の作成と、鍵の配送、フォロー、Announce
- Action Review への操作登録
- 招待 URL、参加申請、モデレーションログ、FEP、REST
- 既存 Group への `ManagedGroup` や owner の自動作成
