# グループディレクトリの Elasticsearch 検索

`GET /api/v1/group_directory` の検索先を切り替える手順です。既定は PostgreSQL のままです。この文書の手順を、計測と検索範囲の差の承認が終わる前に本番で実行しないでください。

## フラグ

| 変数 | 既定 | 役割 |
|---|---|---|
| `ES_ENABLED` | 環境による | Elasticsearch 自体 |
| `GROUP_DIRECTORY_INDEX` | 未設定（オフ） | 索引の作成後に live sync する |
| `GROUP_DIRECTORY_ES_SEARCH` | 未設定（オフ） | API が索引を読む |

3つは別です。`GROUP_DIRECTORY_INDEX` だけをオンにしても API は SQL のままです。`GROUP_DIRECTORY_ES_SEARCH` だけをオンにしても、下の準備が揃っていなければ API は SQL へ戻らず **503** になります。

Web と Sidekiq は別プロセスです。live sync を使うときは両方に同じ `ES_ENABLED` と `GROUP_DIRECTORY_INDEX` を入れて再起動します。検索フラグは API を出す Web プロセスが読みます。

## オンにする前

1. `bin/tootctl search deploy --only group_directory`
2. Web と Sidekiq に `GROUP_DIRECTORY_INDEX=true` を入れて再起動する
3. `bin/tootctl search deploy --only group_directory --rebuild`
   完了すると Redis の `group_directory:index:backfill_complete` が付く。索引が存在するだけでは足りない。この印が無い、または再構築の途中で消えている間は検索フラグをオンにしても **503**。
4. Redis の `group_directory:index:version_gap` が空であること
5. 索引サイズ、投入速度、検索の p95、DB の問い合わせ数を本番相当のデータで測る

このリポジトリの実装時には、その本番相当の計測はしていません。

## 検索範囲の差（承認が必要）

SQL は `accounts.note` の全文を `ILIKE` します。索引は次だけを見ます。

- タグを除いた本文の先頭 2000 文字（`GroupDirectory::Document::NOTE_LIMIT`）
- 名前・ハンドル・ドメインと本文を足した先頭 2500 文字（`SEARCH_TEXT_LIMIT`）
- HTML タグの中だけにある文字列は、索引には残りません
- 検索側の正規化は小文字化、ASCII folding、CJK 幅の折りたたみに寄せています。SQL の `ILIKE` は全角やアクセントを同じようには畳みません

例: 説明の 2001 文字目以降にある語、`<b>` のようなタグ文字自体、全角ラテン文字と半角の対応は、フラグをオンにしたあと SQL と同じ結果になりません。この差を受け入れるまで `GROUP_DIRECTORY_ES_SEARCH` はオンにしません。

20文字を超える検索語は、20文字の窓を AND したあと、**今の**表示名・username・domain・説明・`username@domain` のどれか1つに、その語が連続して含まれることを Ruby で確認します。窓が別の場所や別のフィールドに散らばっただけのヒットは返しません。確認の対象は Elasticsearch が返した候補 id だけで、テーブル全体の `ILIKE` は使いません。

## 失敗したとき

フラグがオンで、次のどれかなら **503** `Group directory search is temporarily unavailable` です。SQL 検索には切り替えません。

- `ES_ENABLED` が true でない
- `GROUP_DIRECTORY_INDEX` が true でない
- 索引が無い、または存在確認に失敗した
- 再構築が終わっていない（`group_directory:index:backfill_complete` が無い）
- `version_gap` がある、またはその確認に失敗した
- 検索のタイムアウト、接続失敗、壊れた応答、point in time を開けない
- シャードの一部だけが応答した（`_shards.failed > 0`）。部分結果は返さない
- 候補の走査が `GroupDirectory::CandidatePage::MAX_SCAN` に達し、索引にまだ続きがある
- Elasticsearch 呼び出しが `GroupDirectory::SearchBudget::MAX_CALLS`（25）を超える、または開始から `MAX_ELAPSED`（5秒）を超える
- `scope=following` のグループフォローが `GroupDirectory::FollowingSearch::MAX_FOLLOW_IDS`（10000）を超える。Person のフォローはこの数に入れない

不正な `q` / `software` / `language` / `scope` / `order` / `offset` は、Elasticsearch に触る前に **400** です。1文字の非ハンドル、正規化できないハンドル、匿名の `scope=following` は索引を見ずに空配列です。

候補 id は返す前に PostgreSQL で掲載条件、NodeInfo、PeerTube、停止、silence、移動、承認、ManagedGroup、Block、Blocked-by、Mute、ドメインブロック、following、それにリクエスト中の software / language / `scope=local` を現在の値で見ます。ES に残った lemmy や ja では返しません。

`scope=following` は、閲覧者がフォローしている **Group** の id だけを、上限+1件まで PostgreSQL から読み、500件ずつ Elasticsearch の terms に分けて渡します。Person のフォローは数に入れません。1リクエストに全件は入れません。返した id は PostgreSQL でフォロー成立を再度確認します。

1回の API リクエストは、point in time を開く前から応答を返す直前までを見て、Elasticsearch 25回または 5秒で打ち切ります。最後の検索のあとのデータベース検査が 5秒を超えても、欠けた配列ではなく 503 です。`scope=following` はチャンクを順位でマージし、ページが埋まったら残りの可視性検査をしません。

検索の一連の `search_after` は同じ point in time の中で行います。応答が新しい pit id を返したら、次の検索と close はその id を使います。ページの途中で `last_status_at` が変わっても、そのリクエストの候補順は開き始めたときのままです。

mapping 変更で通常の `tootctl search deploy` がこの索引を purge するときは、purge の前に完了印を消します。`--min` や `--max` を付けた再投入は全件ではないので、成功しても印は戻しません。印が戻るのは `--min`/`--max` なしの成功した再投入か、`--rebuild` だけです。途中で失敗した索引は検索フラグがオンでも 503 です。

offset と limit は、その確認で残った行に対して適用します。走査上限でページを埋められないときは、欠けた配列ではなく 503 です。

## ロールバック

1. Web の `GROUP_DIRECTORY_ES_SEARCH` を外す（または `false`）
2. Web を再起動する

API はすぐ SQL に戻ります。索引と `GROUP_DIRECTORY_INDEX` はそのままで構いません。検索の障害を、SQL の全文スキャンで肩代わりしないでください。

live sync も止めるときは、Web と Sidekiq の `GROUP_DIRECTORY_INDEX` を外して再起動します。索引を消す必要はありません。消す場合も `GroupDirectoryIndex` だけにし、accounts / tags / statuses は消さないでください。

## 計測

リクエストごとに `group_directory.elasticsearch_search`（`scanned` と `returned`）と、失敗時の `group_directory.search_unavailable`（`reason`）を出します。理由はログに残り、JSON には出しません。本番相当の p95 と比較は未計測です。
