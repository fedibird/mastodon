# Feed delivery reason rollout — PR #710

更新: 2026-11-23 JST。対象: [PR #710](https://github.com/fedibird/mastodon/pull/710)（マージ済み）、[Issue #707](https://github.com/fedibird/mastodon/issues/707)、親 [#706](https://github.com/fedibird/mastodon/issues/706)。本書と補助スクリプトは計測の準備であり、機能を本番有効化する承認ではない。

## 目的と範囲

キーワード購読の候補理由を `FeedInsertWorker` に渡して再照合を省略できるか、list挿入時の二重評価を減らせるか検証する。最初の全購読走査 O(S) は #710 では解消しない。証跡は配送候補の理由であって、閲覧・Block/Mute・DomainBlock・言語・リスト設定の許可ではない。

`FEED_DELIVERY_REASON_MODE` は未設定/`off`（従来どおり）、`shadow`（旧判定を適用しつつ比較を記録）、`enforce`（新しい有効証跡で一部の再照合を省略）。未知値は警告して `off` に戻る。`PriorityFeedInsertWorker` も同じ意味論。

**スクリプトは本番フラグを設定せず、プロセスを再起動せず、Redis/DBのカウンタを削除しない。** 本番の shadow/enforce 切替・再起動・ロールバック・デプロイ・マージには運営者の明示承認が必要。

## 提供ツール

- `script/feed_delivery_reason_rollout.rb process-modes`: 指定 Linux PID / systemd unit の機能フラグだけを `/proc/<pid>/environ` から確認。その他の環境変数（秘密を含む）は出力しない。unit は MainPID のみなので他のunit/子プロセス/ホストも別途確認
- `... snapshot`: アプリと同じRedis接続を使い、既知の時間別 `feed_delivery_reason:v1:YYYYMMDDHH` ハッシュを HGETALL pipeline で読み、JSON保存。既定48時間（最大72時間）。出力は0600、上書き禁止
- `... compare`: 同じフェーズの2枚からUTC時間境界をまたぐ差分を計算。`BLOCKED` / `INSUFFICIENT` / `REVIEW_REQUIRED` を表示、JSON出力可能。`--strict` はBLOCKED/INSUFFICIENT時に終了コード3を返す。**REVIEW_REQUIREDはGO判定ではない**
- `script/feed_delivery_reason_pg_baseline.sql`: 読取専用のPostgreSQL累積統計スナップショット。統計リセット/EXPLAIN ANALYZEなし
- 既存の `spec/lib/feed_delivery_cost_spec.rb`: 1 / 100 / 1000宛先のSQL・オブジェクト割当・Redis flushをテストDBで計測（本番DBに対しては実行禁止）

**注意:** off はfeature counterを発行しない。shadow の agree/disagree は判定条件が実際に評価されたときだけ増える。enforceのevidence/reuse件数だけでは配送結果の互換性は証明できない。PG/Sidekiq/Redisの全体統計には他機能の負荷も含まれる。

## 一括観測（フラグ変更なし・単一ホスト）

同じコマンドの繰り返しを避ける場合は `script/feed_delivery_reason_observe.sh` を利用する。指定unitの MainPID でモードを前後確認し、指定秒数を挟んでRedisスナップショット2枚と差分判定を生成する。`--pg` はread-only SQLを前後に実行するオプション。既存の監視によるSidekiq/p95等は別途収集する。

```sh
# 本番サービス名は現地に合わせて置換。実測開始前に別途設定承認が必要。
bash script/feed_delivery_reason_observe.sh \
  --phase off --seconds 900 \
  --out-dir "$HOME/feed-delivery-710-off-$(date -u +%Y%m%dT%H%M%SZ)" \
  --unit mastodon-web.service --unit mastodon-sidekiq.service --pg

# shadow/enforceは切替済みかつ別承認がある場合だけ、--phaseを置換して実行。
# ステージングでは必要に応じて RAILS_ENV を明示する。
```

出力ディレクトリは新規パス必須（0600/0700）、同じ名前を上書きしない。`--unit` を省略すると警告し、プロセスモードの保証はしない。複数ホストや複数Sidekiq unitはそれぞれ確認する。`--seconds` は30〜86400（既定600）。`BLOCKED`/`INSUFFICIENT` は非ゼロ終了コードになり、計測データは残る。**スクリプトはモード変更も再起動も行わない。**

## 0. 開発／ステージングのチェック

```sh
ruby -c script/feed_delivery_reason_rollout.rb
RAILS_ENV=test bundle exec rspec \
  spec/lib/feed_delivery_reason_rollout_spec.rb \
  spec/lib/feed_delivery_spec.rb \
  spec/workers/feed_insert_worker_delivery_reason_spec.rb \
  spec/services/fan_out_on_write_service_delivery_reason_spec.rb
bundle exec rubocop script/feed_delivery_reason_rollout.rb \
  spec/lib/feed_delivery_reason_rollout_spec.rb

# 重い1/100/1000件ベンチ。fixtureを作成/削除するのでテストDBだけで実行。
RUN=/tmp/feed-delivery-reason-bench-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$RUN"
RAILS_ENV=test FEED_DELIVERY_COST=1 FEED_DELIVERY_COST_LOG="$RUN/cost.log" \
  bundle exec rspec spec/lib/feed_delivery_cost_spec.rb > "$RUN/rspec.log" 2>&1
```

ステージングの代表試験: 通常公開投稿、他者宛返信（キーワード一致）、Home/List、DomainBlock+ignore_block、通常Block/Muteの非回避、複数理由で同一宛先、購読編集・無効化・削除、投稿編集（update/unpush）、旧ジョブ・不正ジョブ、Priority worker、通知の重複防止。offと結果を比較し、未検証ケースを記録する。

## 1. off の本番事前確認・ベースライン（モード変更なし）

配備版がPR #710を含むかコミットSHAで確認。対象ホスト、すべてのSidekiq/Web関連unitとプロセス数、キュー長、PostgreSQLのstats_reset、Redis接続先、通常トラフィック、配送・通知障害の有無を記録。`rails runner` 自身のモードでは実稼働Sidekiqの状態を証明できない。

以下のunit名は例。実環境に合わせて置換する。`/proc` 読取権限のあるユーザー（通常は対象サービスユーザー）で実行する。

```sh
systemctl list-units --type=service 'mastodon*'
cd /home/mastodon/live
ruby script/feed_delivery_reason_rollout.rb process-modes \
  --unit mastodon-web.service --unit mastodon-sidekiq.service --expect off

umask 077
RUN="$HOME/feed-delivery-710-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN"

# 連続サンプルの開始。利用中のpsql認証/接続方法を適用する。
RAILS_ENV=production bundle exec ruby script/feed_delivery_reason_rollout.rb \
  snapshot --phase off --out "$RUN/off-start.json"
psql -X -v ON_ERROR_STOP=1 -f script/feed_delivery_reason_pg_baseline.sql \
  > "$RUN/off-pg-start.txt"

# 同程度の通常トラフィック期間を置く。Sidekiq/SQL/Redisの既存監視も記録。
RAILS_ENV=production bundle exec ruby script/feed_delivery_reason_rollout.rb \
  snapshot --phase off --out "$RUN/off-end.json"
psql -X -v ON_ERROR_STOP=1 -f script/feed_delivery_reason_pg_baseline.sql \
  > "$RUN/off-pg-end.txt"
ruby script/feed_delivery_reason_rollout.rb compare \
  --before "$RUN/off-start.json" --after "$RUN/off-end.json" \
  --out "$RUN/off-report.json"
```

offは配送feature counterがゼロなので、比較可能なSidekiq処理数・失敗数・queue latency/p50/p95、PostgreSQL処理/索引統計、Redis全体の操作数と負荷を外部監視で別に保存する。PG統計はstats_resetからの累積値なのでリセット有無を確認し同種負荷の期間同士で比較する。`pg_stat_statements` が既存有効なら queryid単位のcalls/total_exec_timeを見る（無断で拡張を追加しない）。

## 2. shadow（本番変更は別途承認）

まずステージングで起動時環境変数をshadowに設定し、ワーカーのモードを揃えて検証する。実行中のRails/Sidekiqは環境ファイル変更だけでは更新されない。再起動が必要な場合はSidekiq quiet/drain、再試行安全性、キュー遅延を検討し、運営者の許可後に実施する。旧offと新shadowが混在した期間の数字はフェーズ純度が低いとして区別する。

```sh
ruby script/feed_delivery_reason_rollout.rb process-modes \
  --unit mastodon-web.service --unit mastodon-sidekiq.service --expect shadow
RAILS_ENV=production bundle exec ruby script/feed_delivery_reason_rollout.rb \
  snapshot --phase shadow --out "$RUN/shadow-start.json"

# 実配送と監視。5秒のflush遅延とキュー遅延を考慮し終了値を記録。
RAILS_ENV=production bundle exec ruby script/feed_delivery_reason_rollout.rb \
  snapshot --phase shadow --out "$RUN/shadow-end.json"
ruby script/feed_delivery_reason_rollout.rb compare \
  --before "$RUN/shadow-start.json" --after "$RUN/shadow-end.json" \
  --min-jobs 100 --min-compared 10 --strict \
  --out "$RUN/shadow-report.json"
```

ステージングでは少なくとも「replyの資格判定」「ignore_block」「list二重判定」が発生するよう代表ケースを実行する。shadowの最低ゲート: `reply_disagree=0`、`ignore_block_disagree=0`、`list_disagree=0`、`persist_failures=0`、`recovery_attempts=0`。有効な比較サンプルとキーワードジョブが不足すればINSUFFICIENT。fallbackは失効等で想定されうるため、割合と理由を見て判断。SQL/正規表現回数、Sidekiq p50/p95、Redis総負荷、配送・通知・update/unpushに回帰がないことも確認する。数値だけで自動昇格はしない。

## 3. enforce（shadow合格後、別途明示承認）

まずステージング。次に本番を検討する場合は、停止条件・監視担当・切戻し方法を事前決定し、関連プロセスのモードを揃える。既存のキューに旧形式や失効証跡のジョブが残ってもfallbackする設計だが、実配送・通知結果を必ず確認する。

```sh
ruby script/feed_delivery_reason_rollout.rb process-modes \
  --unit mastodon-web.service --unit mastodon-sidekiq.service --expect enforce
RAILS_ENV=production bundle exec ruby script/feed_delivery_reason_rollout.rb \
  snapshot --phase enforce --out "$RUN/enforce-start.json"

# 同条件で監視・実配送チェック。
RAILS_ENV=production bundle exec ruby script/feed_delivery_reason_rollout.rb \
  snapshot --phase enforce --out "$RUN/enforce-end.json"
ruby script/feed_delivery_reason_rollout.rb compare \
  --before "$RUN/enforce-start.json" --after "$RUN/enforce-end.json" \
  --min-jobs 100 --strict --out "$RUN/enforce-report.json"
```

enforceでは `kw|...|result=evidence` と `list|result=reuse` が省略実施回数。`fallback` は証跡が使えず旧評価に戻った回数。**enforce自身はshadowの一致比較を出さない**。必ず従来との配送・通知・Block/Mute/DomainBlock安全性とSQL/Redis/Sidekiq実測を確認し、節約がない、過負荷、配送異常なら中止。

## 4. 停止・ロールバック

停止条件: shadowのdisagree、listの不整合、Redis persist失敗、可視性/Block/Mute違反、通知・配送の欠落や重複、DB/Redis/Sidekiqの負荷急増・キュー悪化。運営者の既定手順で全対象プロセスをoffへ戻し、必要な安全な再起動後 `process-modes --expect off` を全unit/ホストで確認。Sidekiqのキューを破棄しない。Redisのkey削除/統計リセット/DB変更はしない。コードのロールバックは別途判断。

## 5. 記録と判断

コミットSHA・配備版、対象ホストと全unit、各モード反映時刻（JST/UTC）、サンプル開始/終了、トラフィック/キュー、DB統計のstats_reset、外部指標、各JSONレポート、配送/通知の代表テスト、未検証項目を保存する。個人ID、投稿本文、購読キーワード、資格情報を記録しない。実測していない削減率は主張しない。

**例外:** 72時間を超える比較、Redis keyの失効（8日保持）、Redis再起動・カウンタ巻戻し、workerモード混在では差分の信頼性が落ちる。比較ツールは時間キー不足/負差分/フェーズ相違を拒否するが、稼働全プロセスのモード混在は自動検出できない。最後の判断は運営者のレビューで行う。
