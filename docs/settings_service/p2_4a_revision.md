# Settings Service P2-4A revision

Writer がコミットした設定変更の回数だけを、`user_preference_revisions` に記録する。行が無いユーザーは revision 0 である。初めて変更がコミットされたとき、revision 1 の行を作る。既存ユーザーへの事前作成はしない。

`users` に列を足す案は採らない。その列は既存の `users` 行を更新し、全件バックフィルかデフォルト値の書き換えを伴う。専用テーブルなら新しい空テーブルと、変更のあったユーザーだけの INSERT で済む。`user_id` を主キーにし、`users.id` への外部キーは `ON DELETE CASCADE` である。PostgreSQL の `bigint` 主キーと外部キーは、このアプリが既に使っている PostgreSQL 10 以降の機能だけであり、新しいテーブルへの外部キーは既存の `users` 全件更新をしない。

## この番号が数えるもの

一つの Writer リクエストで複数キーが変わっても、増分は 1 である。同値再送、absent への reset、空の PATCH、空の reset、入力エラー、ROLLBACK では増えない。ユーザーごとに独立し、時刻からは推定しない。

この番号は Writer 経由の変更だけを数える。`UserSettingsDecorator`、`Settings::ScopedSettings#[]=`、Rails の preferences フォーム、Credentials の PATCH は revision を増やさない。したがって、User.settings 全体の変更を完全に表す番号ではない。getter のキャッシュキーも、この PR では変えない。

`PreferenceDocument` の version 1 は文書の形である。revision とは別であり、この PR の HTTP 応答には出さない。ETag と If-Match もまだ無い。

## P2-4B / P2-4C で決めること

1. Decorator の `[]=` を revision に載せるなら、1 キーごとの `update!` の直後に番号を増やすのではなく、フォーム保存全体を一つのトランザクションと User 行ロックにまとめる必要がある。今のまま後付けすると、途中失敗で設定だけ残り revision がずれる。
2. 既存フォームは多数のキーを順に書く。原子性の単位を「リクエスト全体」にするのが Writer と揃う。1 キーずつを別 revision にすると、途中の番号を読んだクライアントが半分だけ新しい状態を見る。
3. キャッシュキーは `Setting.cache_key(var, user)` の末尾に revision を足す。古い write は古い番号のキーに残り、読み手は見ない。
4. getter が revision を古いキャッシュから読むと、設定が新しい番号へ進んでも古い値を読み続ける。revision の読み取りは設定値のキャッシュと分け、DB か短い期限の専用キーにする。設定値のキャッシュミスで revision を再取得してはならない。
5. 毎リクエストの revision SELECT は、User 行ロックの中では既に払っている。読み取り経路では、プロセス内の世代番号か、revision だけを持つキャッシュを先に見る。設定本文のキャッシュ命中率は、revision が変わったキーだけを落とすことで維持する。
6. 旧キーは、revision 付きキーを読み始めてから一定期間残し、その後削除する。読み取りを旧キーのままにすると、Writer の delete と Decorator の write が再び食い違う。
7. revision 行は PostgreSQL が正である。複数プロセス、複数ホストでも同じ行を読む。メモリ上の番号を正にしない。
8. Decorator がロックを取らない間、Decorator の保存は revision を動かさない。Writer の番号は「最後の Writer 成功」であり、その後のフォーム保存を含まない。P2-6 で同じロックに乗せるまで、この差を残す。
9. ローリングデプロイ中、旧プロセスは revision 行を知らない。新プロセスの Writer だけが行を作る。旧プロセスの getter は従来のキャッシュキーを読む。新プロセスが getter を revision 付きに変えるのは、旧プロセスが Writer の delete だけを見る状態が終わってからにする。
