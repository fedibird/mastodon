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
- `version_gap` がある、またはその確認に失敗した
- 検索のタイムアウト、接続失敗、壊れた応答
- 候補の走査が `GroupDirectory::CandidatePage::MAX_SCAN`（offset 上限 10000 に 2000 を足した件数）に達し、索引にまだ続きがある

不正な `q` / `software` / `language` / `scope` / `order` / `offset` は、Elasticsearch に触る前に **400** です。1文字の非ハンドル、正規化できないハンドル、匿名の `scope=following` は索引を見ずに空配列です。

候補 id は返す前に PostgreSQL で掲載条件、NodeInfo、PeerTube、停止、silence、移動、承認、ManagedGroup、Block、Blocked-by、Mute、ドメインブロック、following を現在の値で見ます。閲覧者のフォロー集合は Elasticsearch の terms にしません。フォローの有無は候補 id に対する1本の `IN` です。ログイン中のレスポンスでも、ディレクトリのシリアライザは `followed_message` が空ならフォローの存在確認をしません。メッセージがある行だけ、共通シリアライザと同じ確認をします。

offset と limit は、その確認で残った行に対して適用します。走査上限でページを埋められないときは、欠けた配列ではなく 503 です。

## ロールバック

1. Web の `GROUP_DIRECTORY_ES_SEARCH` を外す（または `false`）
2. Web を再起動する

API はすぐ SQL に戻ります。索引と `GROUP_DIRECTORY_INDEX` はそのままで構いません。検索の障害を、SQL の全文スキャンで肩代わりしないでください。

live sync も止めるときは、Web と Sidekiq の `GROUP_DIRECTORY_INDEX` を外して再起動します。索引を消す必要はありません。消す場合も `GroupDirectoryIndex` だけにし、accounts / tags / statuses は消さないでください。

## 計測

リクエストごとに `group_directory.elasticsearch_search`（`scanned` と `returned`）と、失敗時の `group_directory.search_unavailable`（`reason`）を出します。理由はログに残り、JSON には出しません。本番相当の p95 と比較は未計測です。
