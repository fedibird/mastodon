# グループ作成申請の画面と非公開アイコン（P1）

状態: P1。一般ユーザーが申請を出し、自分の履歴を見て、審査中なら取り下げ、却下または取り下げのあと再申請できる。アイコンは非公開のオリジナルだけを保存する。

親は [#657](https://github.com/fedibird/mastodon/issues/657)。保存モデルは [#658](https://github.com/fedibird/mastodon/issues/658) と [group_management_p0.md](group_management_p0.md)。この段階の画面は [#660](https://github.com/fedibird/mastodon/issues/660)。

P1 は Group Account、`ManagedGroup`、owner 行、Follow、Announce を作らない。管理者の承認画面も作らない。

## 機能ゲート

`Setting.group_creation_requests` の初期値は `false` である。未設定はオフである。管理画面の項目にはしていない。開発で試すときはコンソールから次を実行する。

```ruby
Setting.group_creation_requests = true
```

オフのときはナビゲーションを出さない。加えて `/settings/group_creation_requests` の一覧、新規、確認、作成、詳細、取り下げ、アイコンプレビューはコントローラが 404 にする。ログインより前に拒む。UI を隠すだけでは通さない。

オンのときも、`GroupManagement.local_functional_person?` を満たすログイン済みの個人だけが使える。Group、リモート、停止、無効なユーザーは 403 である。サーバー管理者である必要はない。

## 画面

`/settings/group_creation_requests`

1. 新規フォームでユーザー名、表示名、説明、任意のアイコンを入れる。制約はフォームに書く。検証は `GroupCreationRequest` と `AccountAvatar` の上限に合わせる。
2. 「内容を確認する」はまだ行を作らない。アイコンがある場合だけ、非公開ストレージへオリジナルを書き、署名付きセッションにキーと本文を載せる。セッションに画像バイトや利用者のファイル名は入れない。
3. 確認画面に、正規化後の表示名、`@username@<このサーバーのドメイン>`、説明、アイコン（または既定アイコン）、申請者が初代オーナーになること、承認まで Group が存在しないこと、ユーザー名は予約されないこと、提出後は修正できないことを出す。
4. 確認チェックを付けた POST だけが `pending` の行を作る。`requester_account` は `current_account`、状態はモデルの初期値である。HTTP パラメータの申請者、状態、審査者、アイコンキーは読まない。
5. 詳細は本人の行だけ。却下理由も本人の詳細だけに出す。審査中だけ取り下げできる。`lock_version` が合わない、または pending でない取り下げは状態を壊さず失敗する。
6. 却下または取り下げで、まだ後継が無い行からだけ再申請できる。`previous_request_id` の自由入力欄は無い。他人の ID、審査中、承認済み、後継のある行は 404 である。過去の行は更新しない。

確認ドラフトの寿命は 30 分である。ドラフトには申請者の Account ID を文字列で入れ、確認・プレビュー・送信のたびに現在の Account と照合する。一致しなければドラフトと非公開ファイルを捨てる。`Auth::SessionsController` は既ログインの create を skip しているので、ログアウトでセッションが消えることには依存しない。二重送信は `submission_token` の部分ユニーク索引で 1 行に畳む。

## アイコンのバイト列

Paperclip の `has_attached_file` は使わない。`config/initializers/paperclip.rb` の初期値が `public/system`、S3 の `public-read`、Swift の `fog_public: true` だからである。`Account#avatar` と `avatar_remote_url` にも書かない。

許可タイプは `AccountAvatar::IMAGE_MIME_TYPES`（jpeg、png、gif、webp、bmp、ico）。HEIC、HEIF、AVIF、SVG は許可しない。上限は `AccountAvatar::LIMIT`（4 MiB 未満）。クライアントの Content-Type と拡張子は見ない。`FastImage` と `Marcel` の両方が同じ許可タイプを示し、寸法が読めて、一辺 8192 px 以下、総画素 8_294_400 以下であるものだけを受ける。PNG は IHDR、IDAT、IEND と CRC が揃っていること、それ以外の画像は ImageMagick の `identify` が制限付きで復号できることを追加で求める。ICO は各ディレクトリ要素のサイズとオフセットがファイル内に収まり、その実体が完全な PNG か BITMAPINFOHEADER であることまで見る。ヘッダだけの PNG と、画像実体の無い ICO は拒否する。オリジナルだけを保存し、400x400 や tiny は作らない。

保存キーは 64 文字の十六進であり、利用者のファイル名ではない。

### どの構成で書くか

`GroupCreationIcons::Storage` が選ぶ。公開ストレージへのフォールバックはしない。

| 条件 | 結果 |
|---|---|
| `GROUP_CREATION_ICON_STORAGE` 未設定、かつ S3 も Swift も無効 | `Rails.root/storage/group_creation_icons`（`GROUP_CREATION_ICON_ROOT` で変更可）。`public/` と Paperclip の公開ルートの中は拒否する |
| S3 または Swift が有効で、専用の保存先が未設定 | アイコンアップロードを拒否する。アイコン無しの申請はできる |
| `GROUP_CREATION_ICON_STORAGE=filesystem` | 上のディレクトリ。パスが公開配下なら拒否する。複数ホストで読むには、そのディレクトリを共有する必要がある。共有しないホストからはプレビューも P2 のコピーもできない |
| `GROUP_CREATION_ICON_STORAGE=s3` | `GROUP_CREATION_ICON_S3_BUCKET` が必須で、`S3_BUCKET` と同名は拒否する。書き込み前に Block Public Access の4つ（`BlockPublicAcls`、`IgnorePublicAcls`、`BlockPublicPolicy`、`RestrictPublicBuckets`）がすべて有効で、bucket policy が `Principal "*"` の `s3:GetObject` を許さず、`GetBucketPolicyStatus` が public でないことを確認する。確認できない、API が無い、policy が読めない場合は書かない。オブジェクト ACL は `private`。`GROUP_CREATION_ICON_S3_ALIAS_HOST` と `GROUP_CREATION_ICON_S3_CLOUDFRONT_HOST` があると拒否する。公開 URL と署名付き URL は作らない |
| `GROUP_CREATION_ICON_STORAGE=swift` | 専用コンテナが必須で、`SWIFT_CONTAINER` と同名は拒否する。fog-openstack 0.3.10 の `Directory` には `read_acl` が無く、`directories.get` はオブジェクト一覧を取る。ACL は `Fog::Storage#head_container` の `X-Container-Read` だけを見る。ヘッダが無ければ非公開。`.r:*` や `.rlistings`、HEAD 失敗、ヘッダが読めない場合は拒否する |

公開 URL を発行しないことと、匿名 GET が失敗することは別である。このコードはバケットまたはコンテナ自身の公開読み取り設定を見て、匿名 GET は実行しない。バケットの前段にある CloudFront などの配信は API からは見えない。運用者は、アイコンを有効にする前に、保存したオブジェクトの URL を認証なしで GET し、403 または 404 になることを確認する。その確認ができない構成では S3/Swift を使わない。

実 S3 バケットと実 Swift コンテナへの結合試験は未実施である。テストは、公開 bucket policy と公開 Swift ACL（`.r:*`、`.rlistings`、ACL 不明）を持つ別名の保存先で `put` が呼ばれないことまでを見る。

### プレビュー

`GET /settings/group_creation_requests/:id/icon` は、本人の申請で、アイコンが残っているときだけバイト列を返す。`GroupCreationRequests::Access.preview_allowed?` が門である。P1 の `reviewer?` は常に false である。P2 はここをサーバー管理者に広げる。URL を知っていても他人は 404 になる。

応答は `Cache-Control: private, no-store`、`X-Content-Type-Options: nosniff`、`Content-Disposition: inline; filename="icon.png"`（検出したタイプからの固定名）である。メディアプロキシ、`/system`、ActivityPub の icon には出さない。

### トランザクションとファイル

1. 確認 POST は、モデル検証と画像検証が通ってから非公開ストレージへ書く。検証に失敗したときは書かない。
2. 書いたあとでセッションの更新に失敗したら、そのキーを消す。
3. 作成 POST は、セッションのキーを読み直し、バイト列を再度検証してから `GroupCreationRequest` を挿入する。挿入が失敗してもファイルは残し、確認をやり直せる。挿入できたらセッションだけ消し、ファイルは行が参照する。
4. プロセスが「書いたあと、行を挿入する前」に死ぬと、未参照ファイルが残る。`Scheduler::GroupCreationIconsScheduler` が 1 時間ごとに、24 時間より古くどの行も参照しないキーを消す。確認ドラフトは 30 分なので、この猶予で消えない。同じジョブが、削除に失敗した却下・取り下げの再試行も行う。1 件のストレージ例外では残りの行を止めない。`rake group_creation_icons:sweep` と `rake group_creation_icons:purge_terminal` は手動の再実行用である。
5. 取り下げと却下は、状態変更のトランザクションがコミットしたあと `GroupCreationIcons::Purge` がファイルを消す。消してから `icon_purged_at` を入れる。AWS、Fog、OS の例外でも `icon_purged_at` は空のまま残し、次の定期実行で再試行する。オブジェクトが既に無い場合は完了として印を付ける。
6. 承認では消さない。トランザクションが戻った確認前のファイルも消さない。

## P2 への引き渡し

承認トランザクションの中で Group Account を作ったあと、コミット前に次でオリジナルを読む。

```ruby
file = GroupCreationIcons::Handoff.staged_original(request)
# file は Tempfile。P2 が close する。
# ここで group.avatar へコピーし、既存の Paperclip スタイルを作る。
# avatar_remote_url は使わない。
```

コピーと承認行のコミットが成功してから、公開ファイルを残したままステージングを消す。

```ruby
GroupCreationIcons::Handoff.release_after_copy!(request)
```

`release_after_copy!` は `approved` 以外では拒否する。P1 はこれを呼ばない。

`release_after_copy!` が失敗すると、承認済みの行は `Purge.purge_terminal` の対象ではなく、sweep も申請行がキーを参照しているので消さない。ステージングが残る。P2 は、`Account#avatar` へのコピーと承認トランザクションのコミットが成功したことを後から判定できる印を申請に残し、失敗したコピーを再試行できるようにする。P1 はその印も承認処理も足さない。

Paperclip はコミット前に公開パスへ書く。ロールバックしたときは、その Account id 用に書いた公開ファイルを P2 が消す。ステージング側は `release_after_copy!` を呼ばなければ残る。

P2 が審査者にプレビューを許すときは `GroupCreationRequests::Access.reviewer?` を、ログインできるサーバー管理者に限って true にする。コントローラの検索も、本人の `has_many` だけでは審査者の ID を見つけられないので、同じ門に合わせる。
