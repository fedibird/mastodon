# グループ作成申請の承認（P2-A）

状態: P2-A。管理者の明示的な承認と却下を内部サービスで行う。User を持たないローカル Group を、検索・フォロー・Announce が扱えるようにする。申請画面の追加、審査画面、招待 URLは作らない。初代 owner の自動 Follow は承認トランザクションには入れず、P2-C がコミット後に一度だけ行う。

親は [#674](https://github.com/fedibird/mastodon/issues/674) と [#675](https://github.com/fedibird/mastodon/issues/675)。保存モデルは [group_management_p0.md](group_management_p0.md)。非公開アイコンは [group_management_p1.md](group_management_p1.md)。

`Setting.group_creation_requests` の初期値は false のままである。承認サービスもこの値が true のときだけ成功する。管理画面の項目にはしていない。

## 承認

`GroupCreationRequests::ApproveService.call(request:, reviewer_account:)` が一つのトランザクションで次を書く。

1. 申請行を `lock!` し、pending、機能フラグ、`GroupManagement.server_administrator?`、申請者が有効なローカル個人、アイコンの再検証、`username_available_for_approval?` を確認する。
2. ローカル `Account`（`actor_type: Group`、ログイン User なし、鍵あり、`discoverable: true`）と `account_stat`。
3. `ManagedGroup`（`approved_request`）。
4. 申請者本人の有効な owner 1件。
5. `GroupRegistrationInvitePolicy` に、その時点のサイト初期値をコピーする。
6. `record_approval!` と `GroupCreationDecision`。

失敗は `GroupCreationRequests::DecisionResult#code` で返す。`not_pending`、`not_authorized`、`username_taken`、`invalid_requester`、`icon_missing`、`invalid_icon`、`storage_unavailable`、`feature_disabled`、`conflict` である。pending は残し、別名の付与や自動却下はしない。途中の例外はトランザクションごと戻る。

却下は `RejectService.call(request:, reviewer_account:, decision_note:)`。理由は空白を除いて空なら `decision_note_blank`。Group は作らない。取消は申請者の既存 `record_cancellation!` であり、同じ行のロックで一方だけが確定する。

Action Review には登録しない。グループの owner 権限では承認できない。

## 登録招待ポリシー

`group_registration_invite_policies` は Group ごとに1件。発行可否、共有人数枠、共有枠の無制限、リンクごとの最大人数、人数無制限、期限秒数、無期限を持つ。初期コピーは発行不可、共有枠 0、リンク人数 1、期限 604800 秒、無制限はどちらも false。負数、無制限と上限の併記、無期限と秒数の併記はモデルと check が拒否する。

サイト初期値をあとから変えても、コピー済みの行は変わらない。既存 Group への backfill はしない。招待 URL の発行と枠の消費は P5 である。P5 は `lock_version` のあるこの行をロックして `shared_registration_quota` を減らす。この段階では減らさない。

## アイコン

アイコンが無い申請はワーカーを積まない。ある場合は承認トランザクションの中で非公開ストレージから読み、バイト数、MIME、画像実体を再検証する。失敗なら pending のまま承認しない。公開 avatar にはまだ書かない。

コミット後に `GroupCreationIcons::HandoffWorker` が `GroupCreationIcons::Copy` を実行する。`icon_handoff_source_digest` と avatar のファイル名が揃ってから `icon_handoff_copied_at` を入れる。同じ digest の再実行は avatar を上書きしない。`icon_handoff_copied_at` のあとだけ `Handoff.release_after_copy!` が非公開の元を消す。失敗は `icon_handoff_error` と `icon_handoff_attempts` と `icon_handoff_failed_at` に残り、元画像は消さない。コピーは 8 回で毎時の自動再試行を止める。止まった行は `rake group_creation_icons:resume` が試行回数を戻してから1回だけ再実行する。元の削除はコピー成功後、成功するまで毎時の `Scheduler::GroupCreationIconsScheduler` が続ける。承認後のアイコン列更新は、審査者が今も管理者か、申請者が今も有効か、現在の owner が初代のままかには依存しない。Paperclip がトランザクションの外へ書いたファイルは、その avatar 保存が戻ったとき消す。

## User なし Group

Group 用の User は作らない。`Account.without_unapproved` は、リモート、確認済みかつ承認済みのローカル User、または `managed_groups` があるローカル Group を含む。未承認の個人は入らない。管理行の無いローカル Group は、従来どおり User があるときだけ入る。

Bot からロックされていない Group へのフォローは成立する。ロックされた Group は承認待ちになる。Person の `setting_confirm_follow_from_bot` は変えない。ローカル投稿の `ProcessMentionsService` と、リモート投稿の `ActivityPub::GroupDistributionWorker` は同じ `ActivityPub::GroupAnnounce.announce?` を使う。`Mention.active` の明示メンションに加え、成立済みの Follow があり、原投稿が public または unlisted のときだけ1回 Announce する。silent な宛先は掲載しない。フォロー申請中、private、direct、limited、personal などの原投稿は掲載しない。User 付きの既存 Group は、その User の既定公開範囲を下限にする。User なしの新しい Group の下限は public である。リモート Group はローカルでは Announce せず、従来の配送のままである。元投稿は消さない。

承認コミットのあとに Sidekiq へアイコンジョブを積む。enqueue が失敗しても承認結果は成功のまま返し、`icon_handoff_error` に `enqueue_failed` を残す。毎時の復旧がコピーする。画像が無い申請は積まない。公開ファイルの実体が無いときは、ファイル名だけを根拠にコピー済みにせず、非公開の元は消さない。

## この段階でやらないこと

- 審査画面、一般向けの新しい書込 API、招待 URL、枠の消費
- 初代 owner の自動 Follow。P2-A の承認トランザクションでは作らない。P2-C が承認コミットのあと、一度だけ非同期で行う（[group_management_p2c.md](group_management_p2c.md)）
- 機能フラグを true にすること、本番 migration、本番デプロイ
