# 初代オーナーの一度だけのフォロー（P2-C）

状態: P2-C。承認済みの新規ローカル Group について、申請者本人を一度だけ Follow する。既存 Group への遡及、招待 URL、機能フラグの初期 ON はしない。

親は [#674](https://github.com/fedibird/mastodon/issues/674)。承認の本体は [group_management_p2a.md](group_management_p2a.md)。審査画面は P2-B。

`Setting.group_creation_requests` の初期値は false のままである。この文書の手順は staging でオペレーターが明示的に ON にした場合の確認用であり、本番では実行しない。

## 状態

`group_initial_follows` は承認1件につき1行。承認トランザクションが pending の行を作り、Follow は作らない。コミット後に `GroupInitialFollows::Worker` が動く。

| state | 意味 |
| --- | --- |
| pending | 未実行。enqueue に失敗したときは `last_error` が `enqueue_failed` |
| processing | ワーカーが確保中。Follow と discharge 時刻が既に入っていることがある |
| succeeded | このジョブが Follow または Follow 申請を作った |
| completed | 実行時点で Follow または Follow 申請が既にあった |
| retryable_failure | 関係は作っていない。再試行できる |
| permanent_failure | 停止。管理者が再試行するまで繰り返さない |

`relationship_recorded_at` が discharge（義務の終了）である。入ったあとは、Follow が消えていても作り直さない。owner 権限の正本は `GroupRoleAssignment`、メンバーの正本は通常の `Follow` で、互いを復元しない。

## トランザクション

1. 承認トランザクションは Group、ManagedGroup、owner、招待ポリシー、審査記録、pending の `group_initial_follows` だけを書く。
2. コミット後にワーカーを積む。Redis や Sidekiq が拒否しても承認結果は成功のまま、`last_error` に `enqueue_failed` を残す。
3. ワーカーは短いトランザクションで `processing` にする。
4. その次の savepoint で `FollowService` を呼ぶ。Follow または FollowRequest の挿入と、`relationship_recorded_at`、`outcome`、関係 id は同じ savepoint でコミットする。挿入のあと、discharge の更新前に落ちた場合は savepoint ごと戻る。ユーザーはその Follow を見られないので、解除との競合は起きない。再実行は最初の1回として Follow を作る。
5. `succeeded` または `completed` は、その savepoint のあとに別トランザクションで書く。この間に落ちると state は `processing` のまま、discharge 時刻は残る。再開は終端状態へ進めるだけで、Follow が既に解除されていても作り直さない。
6. 既にある Follow / FollowRequest は `FollowService` を呼ばずに `completed` にする。オプション変更や再配送をしない。
7. 通知、ホームへの merge、リモート配送は `FollowService` の既存実装に任せる。ロック、サイレンス、ブロック、停止は迂回しない。ロックまたはサイレンスのときは Follow ではなく Follow 申請で終わり、こちらから承認しない。

セッション単位の advisory lock で、同じ行のワーカーは同時に1つだけ中へ入る。ロックを取れない側は何もしない。クラッシュでセッションが終わるとロックは外れる。

## やらないこと

- 既存ローカル Group や、この migration より前に承認された申請への Follow の遡及。migration は行を INSERT も UPDATE もしない。`follows` への外部キーは張らない。
- 招待 URL の発行と消費。
- `Setting.group_creation_requests` を true にすること、本番 migration、本番デプロイ、Draft の解除。

enqueue に失敗した行と、lease が切れた `processing` は `Scheduler::GroupInitialFollowsScheduler`（5分、最大20行）が同じワーカーを積み直す。行が無い Group は見ない。

管理画面の申請詳細に状態が出る。discharge 済みの再試行ボタンは出さない。POST しても `already_done` で、Follow は戻らない。恒久失敗と enqueue 失敗は、管理者が再試行できる。再試行は監査ログ `retry_initial_follow` にコードだけを残す。

## Staging での確認

本番では実行しない。対象は使い捨てまたは staging の DB と Sidekiq である。作業前に DB のバックアップを取る。

1. フラグが OFF であることを確認する。`Setting.group_creation_requests` が false なら、承認は `feature_disabled` で pending のまま、Group も Follow も増えない。
2. staging の console だけで `Setting.group_creation_requests = true` にする。管理画面の設定項目からは ON にしない。
3. テスト用の個人アカウントで申請を1件出す。pending の間は Group、owner、`group_initial_follows`、Follow、公開アバターが無い。
4. サーバー管理者がその1件だけを承認する。承認応答の時点で Group と owner と pending または終端の `group_initial_follows` がある。Follow はワーカー完了後に1件である。Group に User は付かない。
5. 申請詳細で「初代オーナーのフォロー」が succeeded または completed になっていることを見る。
6. 本人がグループを解除する。Follow は0件に戻る。`relationship_recorded_at` は残る。
7. Sidekiq で `GroupInitialFollows::Worker` を同じ request id に再投入するか、lease 切れを待って scheduler を走らせる。Follow は戻らない。管理画面の再試行も `already_done` である。
8. 別のローカルアカウント、Bot、リモートアカウントからの通常 Follow は、この行とは独立に従来どおり動く。public または unlisted の明示メンションは、成立済み Follow があるときだけ Announce になる。
9. 確認が終わったら `Setting.group_creation_requests = false` に戻す。既にできた Group と Follow は消えない。フラグ OFF は新しい承認を止めるだけである。

ロールバックは、その環境にこの変更以外の未適用 migration が無いときだけ、`bin/rails db:rollback STEP=1` で `group_initial_follows` を落とす。Follow 行は消えない。承認済み Group も残る。再度上げるときは `bin/rails db:migrate`。既に承認済みの Group へ Follow 行は戻さない。本番の migration とデプロイは、この手順の対象外である。
