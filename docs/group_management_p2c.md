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
3. ワーカーは短いトランザクションで `processing`、`claim_token`、`claim_expires_at` を書く。セッション advisory lock は使わない。PgBouncer の transaction pooling では、次の文が別の PostgreSQL backend に当たることがあり、セッションロックの取得と解放が同じ backend に届かない。
4. Follow を作るトランザクションは、もう一度行を `lock!` し、自分の `claim_token` がまだ有効な lease のときだけ `FollowService` を呼ぶ。lease が切れたあとに別ワーカーが claim していると、古いワーカーは Follow を作らない。Follow の挿入と `relationship_recorded_at` は同じトランザクションである。そのコミット前に落ちた場合は両方戻る。この時点では Follow は他の接続から見えず、Sidekiq も通知も Redis もまだ動かない。
5. `FollowService` は `defer_distribution: true` で呼ぶ。権限判定と Follow / FollowRequest の作成、フォロー数、フォローインポートの台帳、モデレーションの interaction はトランザクション内の DB 書き込みである。レート制限の Redis は作成時に増え、ロールバックの `after_rollback` で戻る。DB の外に出るのは `LocalNotificationWorker`、`MergeWorker`、`UnmergeWorker`、`ActivityPub::DeliveryWorker`、`NotifyService`、活動カウンタ、ホームが空の印、shadow のフォローゲートだけである。初期 Follow はインポートではないので、インポート用の配送追跡は積まない。`flush_distribution!` は各段階が成功したあとだけ進み、同じインスタンスでの再呼び出しは残りだけ送る。
6. ユーザーから Follow が見えるのは、discharge を含むトランザクションのコミット後である。配送はそのあと、行ロックで lease を取ったワーカーが1つだけ行う。`distribution_enqueued_at` は送信が成功したあと、その claim_token のまま書く。別ワーカーは有効な lease かこの時刻を見たら送らない。解除されて作成した Follow 行が無いときは時刻だけ書いて通知しない。ジョブ投入と `distribution_enqueued_at` は原子的ではないため、投入直後のクラッシュでは再配信し得る（at-least-once）。lease の有効期間中は他ワーカーが処理しないが、失効後の再投入に対する外部副作用全体の exactly-once は保証できない。`followed` 通知は既存の同一 Follow の通知行があれば同じ行のPush/メール配送を再試行し、重複するDB通知行の作成を抑える。ただし通知行保存のあとPush前に停止したケースを救うため、既存行があっても配送そのものはスキップしない。DB上の確認と作成に厳密な排他制約はなく、Pushやメールは障害時に重複する可能性がある。LocalNotificationWorker や MergeWorker は同じ Follow ID で再実行され得る。活動カウンタとshadow観測は障害時に重複計上し得る。プロセスをまたぐ再開は `distribute_persisted!` を使う。初回の Follow/FollowRequest 作成前に必要だったホーム再生成ヒントを `home_feed_partial_required` として discharge と同時に保存し、復旧時にも MergeWorker 投入 **前** に設定する（MergeWorker は完了後にヒントを削除する）。shadow 観測は試行時の有効状態とロック状態を `shadow_observation_required` / `shadow_target_locked` として記録し、復旧時は `relationship_recorded_at` を試行時刻として再投入する。ただし現時点でshadow機能がOFFなら、管理者の無効化指示を尊重して投入しない。すでに本人が解除して Follow/FollowRequest が無ければ、いずれの副作用も送らない。
7. `release_claim!`、恒久失敗、再試行可能失敗は、行ロックの下で自分の `claim_token` のときだけ書く。discharge 後と、別ワーカーの token には触れない。`succeeded` または `completed` は配送の記録後に書く。既にある Follow / FollowRequest は `FollowService` を呼ばずに `completed` にする。ロック、サイレンス、ブロック、停止は `FollowService` の判定を使う。ロックまたはサイレンスは Follow 申請で終わり、こちらから承認しない。ブロックは恒久失敗であり、あとでブロックを外してもワーカー再実行では Follow しない。管理者が再試行したときだけ、未実施なら試す。

## やらないこと

- 既存ローカル Group や、この migration より前に承認された申請への Follow の遡及。migration は行を INSERT も UPDATE もしない。`follows` への外部キーは張らない。
- 招待 URL の発行と消費。
- `Setting.group_creation_requests` を true にすること、本番 migration、本番デプロイ、Draft の解除。

enqueue に失敗した行と、lease が切れた `processing` は `Scheduler::GroupInitialFollowsScheduler`（5分、最大20行）が同じワーカーを積み直す。行が無い Group は見ない。

管理画面の申請詳細に状態が出る。discharge 済みの再試行ボタンは出さない。POST しても `already_done` で、Follow は戻らない。恒久失敗と enqueue 失敗は、サーバー管理者が再試行できる。`GroupInitialFollows::Retry` は `GroupManagement.server_administrator?` を自分で見る。一般利用者、Moderator、グループの owner からの直接呼び出しは `not_authorized` で、Follow を作らない。再試行は監査ログ `retry_initial_follow` にコードだけを残す。

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

ロールバックは、その環境にこの変更以外の未適用 migration が無いときだけ、`bin/rails db:rollback STEP=2` で claim 列と `group_initial_follows` をこの順に落とす。Follow 行は消えない。承認済み Group も残る。再度上げるときは `bin/rails db:migrate`。既に承認済みの Group へ Follow 行は戻さない。本番の migration とデプロイは、この手順の対象外である。
