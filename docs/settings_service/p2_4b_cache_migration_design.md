# Settings Service P2-4B キャッシュ移行設計

この文書は、P2-4A の `user_preference_revisions` を将来の revision 付きキャッシュで安全に使うための契約である。この PR は設計と、現行挙動を固定する RSpec だけを置く。revision 付き getter キャッシュは有効にしない。Rails フォーム、Credentials、`UserSettingsDecorator`、`Settings::ScopedSettings` の本番保存処理は変えない。

前提の #427 は squash merge 済みである。merge commit は `4e5d01cad28a8277bca8506f0fa7c3c4995456fc`。承認対象として指定された `65414341f747957f62f7d80e20794c0f06a4aee3` は squash 前の PR 枝の祖先であり、`user_preferences` の revision 実装は squash 結果と一致する。この設計の作業基点は、その merge commit を含む `origin/fedibird` の `8c15d2b048e237b40435d7ab77af99adf79709af` である。先端には #431（`preferences_changed`）が含まれる。通知の実装はこの PR では変えない。

P2-4A の「変わったキーだけを落とす」「短い期限の専用キャッシュ」「プロセス内の世代番号」は、この文書の節 3 で訂正する。訂正文は `p2_4a_revision.md` の末尾にも置いた。

## 1. 現在の全経路一覧

### 1.1 共通の保存とキャッシュ

User 設定の行は `settings.thing_type = User`、`thing_id = users.id`、`var`、YAML の `value` である。一意制約は `(thing_type, thing_id, var)` である。`users.locale`、`users.time_zone`、`users.chosen_languages`、`accounts` の列、`web_settings` はこの行ではない。

`User` は `Settings::Extend` を include する。`User#settings` は `Settings::ScopedSettings` を `@settings` にメモする。値そのものはメモしない。

`Setting.cache_key(var, user)` は rails-settings-cached 0.6.6 の実装のままである。

```text
rails_settings_cached/<起動時の defaults MD5>/User-<id>/<var>
```

MD5 は `RailsSettings::Default.instance` の文字列から、プロセスが最初にキーを作るときに一度だけ計算する。同じ `config/settings.yml` のプロセスは同じ接頭辞になる。defaults が変わったあとのローリング中は、新旧プロセスの接頭辞が違う。これは revision とは別の既存挙動である。

`Settings::ScopedSettings#[]=` は、複数キーを包む外側のトランザクションを持たない。キーごとに次を行う。

1. `Setting.unscoped` で `(thing_type, thing_id, var)` を `find_or_initialize_by` する。
2. `update!` で YAML 化した値をコミットする。
3. その直後に `Rails.cache.write(Setting.cache_key(var, user), value)` する。書く値は Ruby オブジェクトであり、有効値へ正規化した結果ではない。

`Settings::ScopedSettings#[]` は `Rails.cache.fetch` である。ミスならその 1 キーだけを SELECT し、行があれば YAML の値、無ければ `ScopedSettings.default_settings` をキャッシュする。ハッシュ既定のキーは `fetch` ブロック内の `return` でキャッシュに載らない。9 キーはスカラーなのでこの抜け方はしない。`theme` と `noindex` だけが未保存時にサイト全体の `Setting[var]` を見る。9 キーはこの例外に入らない。

production / development の `Rails.cache` は `redis_cache_store` であり、`REDIS_CACHE_PARAMS` の `expires_in` は 10 分である。`[]=` の `write` は期限を上書きしないので、設定エントリも 10 分で消える。namespace は `cache:7.1`、または `REDIS_NAMESPACE` があるときは `<namespace>_cache:7.1` である。URL は `CACHE_REDIS_URL` であり、Sidekiq の Redis とは別にできる。test は `memory_store` である。

`REDIS_CACHE_PARAMS` は `error_handler` を渡さない。activesupport 6.1.7.10 の `ActiveSupport::Cache::RedisCacheStore` は、そのとき `DEFAULT_ERROR_HANDLER` を使う。このハンドラは `RedisCacheStore: <method> failed, returned <returning>` をログし、例外を再送出しない。`read_entry`、`write_entry`、`delete_entry` は `failsafe` の中にある。`failsafe` が握るのは `Redis::BaseError` だけである。読取は `nil`（キャッシュミス）、書込は `false`、delete は `false` を返す。この三つの失敗は呼び出し元へ例外として出ない。`Redis::BaseError` 以外は握らない。キャッシュプールの `ConnectionPool::TimeoutError` は呼び出し元へ出る。`delete_multi_entries` は `failsafe` を通らない。現行の `CacheDeletion` が呼ぶのは単キーの `Rails.cache.delete` であり、こちらは `delete_entry` を通る。

Puma は `preload_app!`、既定 `WEB_CONCURRENCY` 2、`MAX_THREADS` 5 である。Sidekiq は別プロセスである。Web の全ホストと Sidekiq が同じ `CACHE_REDIS_URL` を使うとき、設定キャッシュはプロセスとホストをまたいで共有される。revision 行は PostgreSQL にあり、Redis がホストごとに分かれていても同じ行を指す。

`UserPreferences::Reader` は `Setting.unscoped` を 9 つの storage key について 1 回 SELECT し、インスタンス内にメモする。`Rails.cache` は読まない。書かない。revision も読まない。不正値を保存し直さない。

`UserPreferences::Writer` は開いたトランザクションを拒否し、`users` 行を `FOR UPDATE` し、変更したキーだけを同じトランザクションで書き、変更が残ったときだけ revision を 1 進める。Writer 自身のコードは値を `cache.write` しない。`CacheDeletion` は SQL COMMIT のあと従来キーを `delete` する。ただし `Setting` は `RailsSettings::Base` であり、rails-settings-cached 0.6.6（`86328ef0bd04ce21cc0504ff5e334591e8c2ccab`）の Railtie が create と update に `after_commit :rewrite_cache` を付けている。Writer の `Setting#save!` もこのコールバックを出す。実 COMMIT では `rewrite_cache` の write の次に `CacheDeletion` の delete が走り、`apply` が戻ったとき従来キーは残っていない。節 2.3。#431 の `ChangeNotification` は、その delete 登録のあとに同じ COMMIT 後フックとして Redis へ `preferences_changed` を出す。失敗は各自が飲み、DB は戻さない。

現行の `CacheDeletion` は、この PR では変えない。例外が出た delete は、同じキーを最大 3 回まで試す。1 回目と 2 回目の例外は warn のあと再試行し、3 回目の例外は error を残してそのキーを `false` にする。例外を呼び出し元へは出さない。`RedisCacheStore` が失敗を戻り値 `false` で返した場合、例外は無いので再試行せず、戻り値も見ない。`Rails.cache.delete` が戻っただけで `cache_deleted[key] = true` にする。Redis の DEL が 0（キーが元から無い）でも true になる。したがって `true` は、Redis 上でそのキーを削除したことを保証しない。読み取り障害（ミスと同じ `nil`）、書き込み障害（`false`）、キーが元から無いことを、この `true` は区別しない。この区別と、`false` を成功にしない修正は、後続実装の確認事項である。この PR の RSpec には足さない。

`UserPreferences::Revision.current` は `user_preference_revisions` を 1 行 SELECT する。行が無ければ 0 であり、行は作らない。

### 1.2 9 キー

| var | フォームの画面 | Decorator の型 | getter | 未保存の有効値 | Reader |
| --- | --- | --- | --- | --- | --- |
| `default_privacy` | other | STRING。検査なし。`direct` も保存できる | `User#setting_default_privacy`。キャッシュの生値のあと、`nil` と `false` だけを locked なら `private`、それ以外は `public` にする。`""` はそのまま | 行が無いときと同じ補完。YAML 既定は無い | state を維持し、有効値は getter と同じ |
| `default_sensitive` | other | BOOLEAN。`"0"` / `"1"` をキャスト | delegate `setting_default_sensitive` | `false` | 同じ |
| `default_language` | other | STRING。検査なし | delegate `setting_default_language` | `nil` | 保存値を維持。派生言語だけが別キー |
| `show_translation_bar` | appearance | STRING。書く直前に `normalize_visibility`。参照するポリシーは、同じリクエストの新値より前の getter | `User#setting_show_translation_bar`。生値を読み、メモリ上で正規化する | ポリシーに従う。未保存ポリシーは `default` なので `target` | 保存値は修復しない |
| `translation_preferred_mode` | appearance | STRING。書く直前に `normalize_preferred_mode`。未知と `original` は `translated` として保存 | `User#setting_translation_preferred_mode` | `translated` | 保存値は修復しない |
| `new_features_policy` | other | STRING。検査なし | delegate `setting_new_features_policy` | `default` | 同じ |
| `content_font_size` | appearance | STRING。range の文字列のまま。範囲検査なし | delegate `setting_content_font_size` | YAML の整数 15 | 文字列を維持。`public_value` だけが整数になる場合がある |
| `info_font_size` | appearance | 上と同じ | delegate `setting_info_font_size` | 整数 15 | 上と同じ |
| `reduce_motion` | appearance | BOOLEAN | delegate `setting_reduce_motion` | `false` | 同じ |

`preferred_posting_language` は 10 個目の読み取りキーであり、行を持たない。`valid_locale_cascade(default_language, users.locale, I18n.locale)` である。キャッシュキーは無い。revision の対象にしない。

delegate は `User` の `delegate ..., to: :settings, prefix: :setting` である。`setting_default_privacy`、`setting_show_translation_bar`、`setting_translation_preferred_mode` だけが delegate を上書きする。上書き後も生値は `settings.<var>` 経由で従来キャッシュキーを読む。9 キーにインスタンス変数のメモは無い。

### 1.3 読み取り経路

| 経路 | 正 | キャッシュ | revision SELECT |
| --- | --- | --- | --- |
| `ScopedSettings#[]` と delegate getter | ヒット時は Redis。ミス時は DB | 従来キーを `fetch`。ミス時に生値を書く | しない |
| 上書き getter 3 つ | 生値の取得は上と同じ。補完と正規化はメモリ上 | 有効値はキャッシュしない | しない |
| `UserPreferences::Reader` と `PreferenceDocument` | DB | 使わない | しない |
| `InitialStateSerializer` の 9 キー | Reader | 使わない | しない |
| `REST::PreferencesSerializer`（`GET /api/v1/preferences`） | Reader | 使わない | しない |
| `REST::CredentialAccountSerializer` の `source` | Reader | 使わない | しない |
| Fedibird preferences の GET | Reader | 使わない | しない |
| Rails フォームの再表示 | getter | 従来キー | しない |
| `ApplicationHelper#body_classes` の `reduce_motion` | getter | 従来キー | しない |
| `ApplicationHelper#render_initial_state` の共有画面の公開範囲 | getter の `setting_default_privacy` | 従来キー | しない |
| `AccountsHelper#account_theme_valiables` の文字サイズ | getter | 従来キー | しない |
| `PostStatusService`、`ReblogService`、`PostingIdentity::DelegatedTextPost` | 投稿者の getter | 従来キー | しない |
| `ProcessMentionsService` と `ActivityPub::GroupDistributionWorker` | グループの user の getter を 1 回 | 従来キー | しない |
| `UserPostingContext::Preview` | getter | 従来キー | しない |
| Credentials の PATCH が省略キーを埋めるとき | getter。その結果を保存し得る | 従来キー | しない |

同じ HTML 応答でも、InitialState の 9 キーは Reader、`body_classes` と文字サイズと共有画面の公開範囲は getter である。キャッシュが DB と違うとき、この二つは同じ応答の中で違う値になる。P1 からある差であり、この PR では残す。

投稿とグループ配送が読むのは、その投稿者またはグループの user の 1 回である。フォロワーごとの getter ではない。

### 1.4 書き込み経路

| 経路 | 9 キーでの動き | revision | キャッシュ |
| --- | --- | --- | --- |
| `Settings::PreferencesController#update`。appearance / notifications / safety / other が継承 | `UserSettingsDecorator#update` のあと、profile キーがパラメータに含まれるときだけ ActivityPub を積み、そのあと `users.locale` などを `current_user.update` | 動かない | 各 `[]=` が write |
| appearance の画面 | 文字サイズ 2 つ、`reduce_motion`、翻訳バー、翻訳モード | 動かない | 同上 |
| other の画面 | privacy、language、sensitive、policy | 動かない | 同上 |
| notifications と safety の画面 | 9 キーの入力は無い。許可リストは 4 画面で共通なので、送られた 9 キーは保存される | 動かない | 同上 |
| `Api::V1::Accounts::CredentialsController#update` | 先に `UpdateAccountService`。`source` が blank でなければ decorator で 3 キー。そのあと ActivityPub | 動かない | 同上 |
| `PATCH /api/v1/fedibird/preferences` と reset | `UserPreferences::Writer` | 変更が残ったとき +1 | COMMIT 後に従来キーを delete |
| `app/` から `user.settings[...] =` を直接呼ぶ本番コード | decorator 以外には無い | 動かない | `[]=` の write |

Decorator の `process_update` は次の順である。

1. `notification_emails` と `interactions` を merge して書く。9 キーではない。
2. `STRING_KEYS` の配列順。9 キーでは `default_privacy`、`default_language`、`translation_preferred_mode`、`show_translation_bar`、`new_features_policy`、`content_font_size`、`info_font_size`。
3. `BOOLEAN_KEYS`。9 キーでは `default_sensitive`、`reduce_motion`。

`show_translation_bar` は `new_features_policy` より前に書く。正規化が読む `user.setting_new_features_policy` は、同じリクエストの新しいポリシーではなく、すでに見える古い値である。古いポリシーが未保存（有効値 `default`）で入力が `nope`、同時にポリシーを `conservative` へ変えると、保存されるバーは `target` である。`never` にはならない。

`change?` は `!settings[key].nil?` である。キーが無いことと、値が `nil` であることは書かない。行は削除しない。

Credentials の 3 キーは `fetch` で埋める。キーが無ければ今の getter を入れる。キーがあり値が `nil` なら `nil` を入れ、decorator はそれをスキップする。`source` に `language` だけがある PATCH は、未保存の privacy を locked なら `private`、そうでなければ `public` として新規保存し、未保存の sensitive を `false` として新規保存する。

Writer の許可リストは `UserPreferences::WriteContract::KEYS` の 9 キーだけである。高リスク設定（`noindex`、件数非表示、`enable_reaction`、`interactions`、禁止操作）は通らない。それらも同じ `[]=` と従来キャッシュキーを使う。この revision をそのキャッシュキーへ付けない。

### 1.5 キャッシュ更新の対応

| 出来事 | 従来キー |
| --- | --- |
| `[]=` の `update!` 成功 | そのキーへ `write` |
| `[]=` の `update!` 失敗 | そのキーは write しない。先行キーの write は残る |
| Writer の変更コミット | 変更キーだけ `delete`。無変更キーは触らない |
| Writer の ROLLBACK、空 PATCH、同値再送、入力エラー | delete しない。revision も進まない |
| Reader と getter のミス | `fetch` が生値を write する。Reader はしない |
| 読み取り | 行を作らない。不正値を修復しない |

`CacheDeletion` が例外を 3 回受けて `false` にしたとき、行と revision は残り、従来キーは古いまま残ることがある。HTTP は成功である。Reader は DB を見る。getter は残ったキャッシュを見る。`Redis::BaseError` は `failsafe` が `false` を返すだけで例外にならないので、この 3 回には入らない。そのとき `cache_deleted` は `true` のままで、キーが残っていることがある。節 1.1。

## 2. 更新と読み取りのシーケンス

### 2.1 フォームと Decorator

`Settings::Preferences::AppearanceController` または `OtherController` の `update` は、外側のトランザクションを持たない。

1. `UserSettingsDecorator#update` が、送られたキーを節 1.4 の順で `user.settings[var] =` する。
2. 各代入は `update!` でそのキーだけをコミットし、従来キーへ `cache.write` する。
3. `profile_change?` が真なら `ActivityPub::UpdateDistributionWorker.perform_async` を積む。9 キーは profile キーではない。appearance の 9 キーだけでは積まない。other は profile キーを含むため、値の変化に関係なく積む。
4. `current_user.update` で `locale`、`time_zone`、`chosen_languages` を書く。
5. User 更新が成功したときだけ `I18n.locale` を変えてリダイレクトする。失敗したら `:show` を描き直す。

revision 行は SELECT しない。

### 2.2 Credentials

1. `UpdateAccountService` が `accounts` を `update!` する。成功時に、locked が外れていればフォローリクエスト承認を積み、リンク検証とハッシュタグ抽出を行う。User の settings 行は書かない。
2. `source` が blank でなければ、省略キーを getter で埋めてから decorator が 3 キーを書く。
3. ここまで例外が無ければ ActivityPub を積む。設定が無変更でも積む。
4. 資格情報 JSON の `source` は Reader が DB から読む。

### 2.3 Writer

1. 開いたトランザクションがあれば、ロックの前に `OpenTransaction`。
2. `BEGIN`。
3. `SELECT users ... FOR UPDATE`。
4. `SELECT user_preference_revisions ... FOR UPDATE`。無ければ 0。
5. リクエストに含まれるキーだけを `Setting.unscoped` から読む。
6. 変わったキーだけを INSERT / UPDATE / DELETE する。
7. 変更が残っていれば revision を +1。無ければ番号も `updated_at` も動かさない。
8. `CacheDeletion` と `ChangeNotification` をトランザクションレコードとして登録する。`Setting#save!` はそれより前に、自分を同じトランザクションのコールバックへ登録している。
9. `COMMIT`。
10. `Setting` の `after_commit :rewrite_cache` が従来キーへ新しい値を `cache.write` する。これは Writer のコードではない。rails-settings-cached 0.6.6 の `lib/rails-settings/railtie.rb` が `RailsSettings::Base` に付けた create / update のコールバックで、`lib/rails-settings/base.rb` の `rewrite_cache` が `Rails.cache.write(cache_key, value)` する。キーは `Setting.cache_key(var, thing)` で、従来キーと一致する。
11. `CacheDeletion#committed!` が同じ従来キーを `delete` する。
12. `ChangeNotification#committed!` が Redis へ通知する。

`delete_row` は `delete_all` である。destroy ではないので、reset では `expire_cache` も `rewrite_cache` も走らない。delete だけが残る。

同値 no-op は `Setting#save!` を呼ばない。`rewrite_cache` も `CacheDeletion` も走らない。事前に入っていた従来キーは残る。User 行のトランザクション自体は COMMIT される。

`spec/lib/user_preferences/writer_setting_commit_cache_spec.rb` は `use_transactional_tests = false` で、SQL の `COMMIT` とキャッシュ操作の順を記録した。新規作成と既存行の更新はどちらも、SQL COMMIT のあと `rewrite_cache` の write、その次に `CacheDeletion` の delete である。どちらも `transaction_open?` はすでに false である。Rails は SQL COMMIT の前にトランザクションスタックを外すので、この false は「まだ COMMIT していない」という意味ではない。境界は SQL の `COMMIT` である。`Writer#apply` が戻ったとき従来キーは無く、Reader は DB の新しい値を返す。reset は COMMIT のあと delete だけである。no-op は対象キーの write も delete も無い。

delete のあとに write する経路は、この測定では出ていない。その順になると、`CacheDeletion` が消した直後に `rewrite_cache` が値を戻し、処理終了時に従来キーが残る。今の登録順は、`save!` がモデルを先に登録し、Writer がそのあと `CacheDeletion` を登録するので、write が先になる。この順を入れ替える本番変更は、この PR ではしない。コールバックを Writer の保存だけ止めるか、write の次の delete を許容するかは、`p2_6_legacy_writer_migration.md` の P2-6B の判断として残す。

User 行ロックを持っているのは 3 から 9 までである。Redis の delete、`rewrite_cache` の write、通知はロックの外である。

### 2.4 読み取り

getter は従来キーを `fetch` する。ヒットなら SQL は無い。ミスならその var の SELECT が 1 回である。`show_translation_bar` の getter はバーとポリシーの 2 キーを読む。

Reader は最初の `get` で storage 9 キーを 1 回 SELECT し、同じインスタンスでは追加の settings SELECT をしない。revision は読まない。

## 3. revision とキャッシュキーの関係

### 3.1 この番号の意味

P2-4B でも、revision は Writer がコミットした変更回数だけを表す。1 リクエストで複数キーが変わっても増分は 1 である。同値再送、すでに absent の reset、空の PATCH、空の reset、入力エラー、ROLLBACK では増えない。行が無いユーザーは 0 であり、行は作らない。

Decorator、`ScopedSettings#[]=`、Rails フォーム、Credentials の保存はこの番号を増やさない。したがって、この番号は User.settings 全体の変更回数ではない。#431 の `preferences_changed` が運ぶ revision も同じ境界である。通知の payload はこの PR では変えない。

ユーザー単位の単一 revision を 9 キーすべてのキャッシュキーに使う場合、1 キーの Writer 変更で 9 キーすべての世代が進む。変わったキーだけを失効させたいなら、別の世代管理が要る。

### 3.2 世代方式の比較

| 観点 | 単一 revision を 9 キーへ使う | キーごとの世代 |
| --- | --- | --- |
| 整合性 | 読み手は 1 つの番号だけを見る。バーとポリシーを別世代のキャッシュから混ぜない。同じ番号のあいだに Decorator が書いても世代は進まないので、その変更は新しいキーへ反映されない。これは方式の欠陥ではなく、節 3.1 の境界である | 同時に変えた複数キーは、同じトランザクションで関係する世代をすべて進める必要がある。片方だけ進むと、バーの生値とポリシーが別世代になる。フォームの途中失敗では、成功したキーだけ世代が進み、「このユーザーの世代」は一つにならない |
| DB 負荷 | 既存の 1 行。読み取りは処理単位あたり 1 SELECT。追加 migration は無い | 9 個のカウンタか、1 行のマップ。SELECT 回数は 1 行にまとめれば同じ。P2-4A の表とは別物になる |
| キャッシュ命中率 | 1 キーの変更で、そのユーザーの 9 キーが次の読み取りでミスする。変更はユーザー単位であり、全ユーザーのキーは落ちない。10 分 TTL の全失効より範囲は狭い。変わった 1 キーだけの失効よりは悪い | 変わったキーだけがミスする。命中率はこちらが良い |
| 実装複雑度 | 低い。既存の番号と #431 の payload をそのまま世代にできる | 高い。新しい保存、通知の単一番号との分岐、ローリング時のキー形、部分保存との対応が要る。DB migration はこの PR の対象外であり、この方式を採るなら別承認が要る |

推奨は単一 revision である。

根拠は次のとおりである。

- P2-4A がすでにこの番号を PostgreSQL に書いており、#431 が同じ番号を通知している。キャッシュ世代を別カウンタにすると、通知の revision とキャッシュの世代が別の意味になる。
- 9 キーの有効値は、バーとポリシー、privacy と locked、派生言語のように複数キーを読む。世代は一つである方が、読み手が混ぜる番号を間違えない。
- 設定変更は読み取りより稀である。1 回の変更で同じユーザーの残り 8 キーが 1 回ずつミスするコストは、キーごとの世代の migration とローリング契約より小さい。
- ミス時の SQL が重いと測れた場合は、世代を割る前に、ミスした 9 キーの充填を 1 回の SELECT にまとめる。それは世代方式を増やさない。

採らないもの: `Setting.cache_key` の実装自体を変え、全設定 var の末尾にこの revision を足すこと。高リスク設定や通知メールは 9 キーの Writer では変わらない。そのキャッシュまで世代が進むと、進まない保存経路の値が新しいキーから見えなくなる。接尾辞は 9 キーの getter 専用にする。

将来のキー形は次である。`Setting.cache_key` の戻り値は変えない。

```text
<Setting.cache_key(var, user)>/rev/<整数>
```

行が無いユーザーは `/rev/0` である。revision はキーの一部であり、キャッシュされた値の中には入れない。値から現在の revision を復元しない。Redis 上のキーを走査して最大の番号を探さない。

キャッシュするのは `ScopedSettings#[]` が今キャッシュしている生値である。privacy の locked 補完、翻訳バーの正規化、翻訳モードの正規化、文字サイズの `public_value` はキャッシュしない。それらをキーへ入れると、Reader の configured と getter の生値が分岐する。

### 3.3 revision の取得方式

満たす条件は次のとおりである。

1. revision の正は PostgreSQL である。
2. 古い設定キャッシュから revision を取得しない。
3. 複数ホストが同じ番号を共有できる。
4. リクエスト中の重複 SELECT を抑えられる。
5. ジョブなど HTTP 以外が、処理をまたいで古い revision を持ち続けない。
6. revision のキャッシュが失効しても、消えても、安全に回復する。
7. 旧キャッシュキーへのフォールバックで古い値が復活しない。

| 方式 | 判断 |
| --- | --- |
| getter のたびに `user_preference_revisions` を SELECT する | 正しくはある。9 キーを読む画面では最大 9 回になる。`show_translation_bar` はポリシーと合わせてさらに増える。採らない |
| 設定値のキャッシュエントリに revision を同梱し、そこから現在の番号を決める | 条件 2 に反する。古い値の中の番号を現在の番号として使うと、新しい世代へ進まない。採らない |
| プロセスメモリの世代番号を正にする | ホスト間で共有されない。Puma のスレッドと Sidekiq のジョブが古い番号を持ち続ける。条件 3 と 5 に反する。採らない |
| revision だけを短い TTL で Redis に置く | ホスト間では共有できる。TTL のあいだ、COMMIT 済みの新しい番号を見ない。delete に失敗すると、期限まで古い番号の値キーを読み続ける。「短時間キャッシュした」だけでは即時整合性にならない。正としては採らない。信頼する高速経路としても採らない |
| COMMIT 時に revision 用 Redis キーを上書きする | Redis 更新が失敗したホストは古い番号のままである。条件 1 と 6 を、Redis が PostgreSQL に追いついている前提に変えてしまう。採らない |
| 処理単位のはじめに PostgreSQL を 1 回読み、その単位の中だけメモする | 採る |

推奨は、処理単位ごとの PostgreSQL 読み取りとメモである。

- HTTP リクエストでは、そのリクエストで最初に 9 キーの getter が revision を必要としたとき 1 回 SELECT する。同じリクエストの残りの getter はメモを使う。
- メモの置き場は、リクエストとジョブの終わりに必ず捨てるものにする。`Setting` や `User` のクラス変数には置かない。Puma はスレッドを使い回す。捨てないと次のリクエストが前のユーザーの番号を使う。
- Sidekiq はジョブごとに捨てる。前のジョブの番号を次のジョブが使わないことを、同じスレッドで二つのジョブを流すテストで固定する。Rails の executor が `CurrentAttributes` を捨てることに依存するなら、その捨てる動作自体をテストで固定する。暗黙の捨てに任せきりにしない。
- 同じ処理単位の中で Writer が新しい番号をコミットしたら、メモをその `after_revision` へ更新する。更新前の番号のまま残り getter を読まない。
- メモが空なら、また PostgreSQL を読む。行が無ければ 0。これは条件 6 の回復である。Redis に revision が無くても同じである。
- PostgreSQL が revision を返せないときは、番号を推測しない。旧キーも、プロセス内の古い番号も読まない。getter は失敗する。
- Reader にはこの SELECT を足さない。Reader は設定行の DB が正であり、世代キャッシュを通らない。

このメモは世代の正を複製しない。正は毎回 PostgreSQL であり、メモは同じ処理単位の重複 SELECT を消すだけである。

### 3.4 値キャッシュの読み方

段階 D 以降の 9 キー getter は次だけを行う。

1. 節 3.3 の番号 R を得る。
2. `<従来キー>/rev/<R>` を `fetch` する。
3. ミスなら、その var の設定行を DB から読み、生値をそのキーへ書く。write に失敗しても、その場の戻り値は DB の生値である。
4. 従来キーは読まない。ミスを従来キーで埋めない。

従来キーへのフォールバックは、`[]=` の遅い `cache.write` が残した古い値を、新しい世代のミスのあとで復活させる。条件 7 のため、段階 D 以降は禁止する。

段階 D の Redis 障害は、ストアがミスとして処理する場合と、例外が呼び出し元へ出る場合に分ける。従来キーへのフォールバックは、どちらの場合もしない。

`Redis::BaseError` は、節 1.1 のとおり `failsafe` が読み取りを `nil` にする。`fetch` は例外を見ない。ミスとしてブロックへ進み、DB を読む。書き込みと delete は `false` が返る。段階 D の getter が `fetch` を使うなら、この経路では追加の rescue 無しに DB の生値へ進む。この `nil` は、キーが元から無いミスと同じである。失敗した読み取りのあと、ブロックが読んだ古い生値を新しい revision のキーへ書かないこと、および `false` を成功と扱わないことは、P2-4D の確認事項である。`write` が `false` でも、上の 3 のとおり、その場の戻り値は DB の生値である。

`Redis::BaseError` 以外で呼び出し元へ出る例外は、今日の `fetch` でも呼び出し元へ出る。キャッシュプールの `ConnectionPool::TimeoutError` がそれである。段階 D でこの例外を DB 読み取りへ落とす rescue は、段階 D の実装 PR の本番変更であり、この PR では入れない。rescue するにしても従来キーは読まない。DB も失敗したら例外を返す。番号を推測して古い revision キーを読まない。

## 4. レース条件と解決方法

解決の順序は固定である。getter を revision キーへ切り替えるのは、9 キーを保存するすべての本番経路が、同じトランザクションで revision を進めるようになったあとである。今日それは Writer だけである。Decorator が従来キーへ `cache.write` しているあいだに読み手だけを切り替えると、Decorator の COMMIT が DB と従来キーを更新し、revision キーは最大 10 分、古い生値を出し続ける。Reader だけが新しい値を見る。これは今日の `cache.write` より悪い。

### 4.1 フォームで 9 キーを保存する

4 画面は一度に 9 キーを出さない。許可リストは共通なので、一つの POST が 9 キーを全部含むことはできる。そのとき Decorator は節 1.4 の順で 9 回 `update!` し、成功のたびに従来キーを write する。revision は 0 のままである。途中の getter は、すでに write されたキーだけ新しい値を見る。Reader は、自分の SELECT より前にコミットされたキーだけを見る。

この POST を一つの revision にまとめるには、9 回の `update!` を一つのトランザクションへ入れる必要がある。それは途中失敗で先行キーを残す現行の部分保存を変える。この PR ではやらない。P2-6 の承認事項である。

### 4.2 Credentials の 3 キー

`source` があると、privacy、language、sensitive の順で保存する。省略キーは保存前の getter で埋める。getter のキャッシュが古いと、古い privacy や sensitive を新しい行として保存する。revision は進まない。資格情報 JSON は Reader なので、応答の `source` は DB と一致し、埋めた値がキャッシュと違っても応答は DB を見る。

### 4.3 フォームの途中失敗

例として、文字列キーの途中で `content_font_size` の `update!` が例外になる。

- それより前の `default_privacy`、`default_language`、`translation_preferred_mode`、`show_translation_bar`、`new_features_policy` は、送られていればコミット済みであり、従来キーも write 済みである。
- `info_font_size` と二つの boolean は未到達である。
- `current_user.update` には進まない。`locale` は変わらない。
- profile キーを含まない appearance 相当の POST なら ActivityPub はまだ積んでいない。other 相当で profile キーが先に保存されていれば、例外の位置によってはすでに積んでいる。
- revision は変わらない。
- 例外は Rails の 500 になる。部分行は残る。

revision をキーごとに足すと、失敗時点の番号が「全キーが新しい」を意味してしまう。一つの番号にまとめると、部分保存を戻すトランザクションが要る。どちらもこの PR ではやらない。

### 4.4 アカウント更新の成功後に設定保存が失敗する

Credentials では `UpdateAccountService` が先にコミットする。locked 解除の承認ジョブとリンク検証は、その成功時にすでに積んであることがある。そのあと decorator が 2 キー目で失敗すると、1 キー目の設定と従来キーの write は残り、3 キー目は無く、ActivityPub のプロフィール配送は `perform_async` の前なので積まない。revision は変わらない。アカウント列は戻らない。

設定の revision はアカウント更新を数えない。この順序をキャッシュ対応のために入れ替えない。

### 4.5 Writer と Decorator が同じキーを並行変更する

Decorator は User 行をロックしない。Writer はロックする。

- Decorator の `update!` が Writer のロック後読み取りより前にコミットすると、Writer はその値を見てから自分の値を書く。revision は Writer の変更が残ったときだけ進む。
- Writer が先にコミットして従来キーを delete したあと、Decorator の遅い `cache.write` が古い値を従来キーへ戻す。DB は Decorator の値、revision は Writer の番号、getter は古いキャッシュ、という並びが今日残る。P2-0 が残した穴である。
- 同じ未保存キーの二重 INSERT は一意制約に当たる。Writer はトランザクション全体を戻して最大 3 回試す。Decorator はやり直さない。
- revision キーの読み取りを先に有効にすると、Decorator が DB を上書きしても世代が進まず、すでに充填された revision キーが残る。段階 D の前に、この経路を Writer へ乗せる。

### 4.6 Writer と Decorator が別キーを並行変更する

設定行は衝突しない。Decorator は User 行ロックを待たない。両方の行が残る。revision は Writer のキーだけを反映する。Writer の delete は自分の変更キーだけである。Decorator のキーは従来キーへの write だけが getter を更新する。

単一 revision の読み取りをここへ先に適用すると、Decorator のキーも世代は Writer 側の番号のままなので、充填済みの revision キーが Decorator の新しい DB 値を隠す。別キーであっても、Decorator が番号を動かさない限り段階 D は始められない。

### 4.7 COMMIT 後の遅い cache.write

`[]=` は DB の COMMIT のあとで write する。次の順で従来キーが古い値に戻る。

1. リクエスト A が v1 をコミットし、write がまだ終わっていない。
2. リクエスト B が v2 をコミットし、従来キーを delete するか v2 を write する。
3. A の write が v1 を従来キーへ置く。

Writer は値を write せず delete する。それでも、A が Decorator なら 3 が delete のあとに起きる。revision キーは、A が書き始める前に見た番号のキーへ A が write する場合に限って、この上書きを読み手から隠せる。A が write の直前に番号を読み直すと、B の新しい番号のキーへ v1 を書く。したがって、revision キーへ値を write してよいのは、その番号を値の COMMIT と同じトランザクションで確保した保存だけである。Decorator は今日それをしない。段階 D の保存側は値を write せず、番号を進めて delete し、充填は読み手のミスに任せる。

### 4.8 設定変更中の Reader と getter

- getter はキーごとに従来キーを見る。ヒットは SQL を発行しない。`update!` と `cache.write` のあいだは、ヒットが古い値、ミスと Reader が新しい DB 値である。
- Reader は最初の SELECT をインスタンスにメモする。そのあと別プロセスがコミットしても、同じ Reader インスタンスは見ない。次の Reader は見る。
- 将来の revision メモも同じ境界にする。処理単位の途中の他プロセスの COMMIT は、次の処理単位まで見えない。同じ処理単位の Writer だけは、節 3.3 のとおりメモを更新する。
- メモをプロセス寿命やクラス変数にすると、ジョブが古い番号を持ち続ける。採らない。

### 4.9 保存済みの nil と不正文字列

読み取りは修復しない。次は行の `value` と `updated_at` を変えず、従来キーには生値を載せる。

| 保存値 | getter の有効値 | Reader |
| --- | --- | --- |
| privacy の `nil` | locked なら `private`、そうでなければ `public`。行は増えない | state `:nil`。有効値は getter と同じ |
| privacy の `""` | `""`。`\|\|` で置き換わらない | configured `""` |
| privacy の `direct` | `direct` | configured `direct` |
| language の `invalid` や `ja-JP` | そのまま。派生言語だけが別計算 | configured は保存値のまま |
| バーの `nil` や `nope` | メモリ上でポリシーに従う | configured は `nil` または `nope` |
| mode の `original` | 有効値は `translated` | configured は `original` |
| 文字サイズの `"18"` や `"invalid"` | そのまま | configured は文字列。`"18"` の `public_value` だけ整数 |

Decorator の書き込みは別である。バーの `nope` や mode の `original` をフォームが送ると、保存前に正規化した値を書く。これは読み取り修復ではない。P2-6 まで残す。

段階 D の値キャッシュが有効値を入れると、この表が崩れる。生値だけをキャッシュする。

### 4.10 段階 B の cache-aside 再充填

Writer が COMMIT したあと従来キーを delete しても、その delete より前に DB から旧値を読んだ別リクエストの `fetch` が、delete のあとで旧値を同じ従来キーへ write することがある。

1. リクエスト R が従来キーをミスし、DB から旧値 v1 を読む。write はまだである。
2. Writer が v2 を COMMIT し、従来キーを delete する。
3. R の `fetch` が v1 を従来キーへ write する。

段階 B の getter は従来キーを読む。このあと TTL のあいだ v1 を返すことが残る。DB と Reader は v2 である。

P2-6 で Decorator を Writer へ移すと、節 4.7 の Decorator による遅い `cache.write` は無くなる。Writer の `Setting#save!` は節 2.3 のとおり、SQL COMMIT のあと `rewrite_cache` で従来キーへ新しい値を write し、その次に delete する。終了時の従来キーは delete 済みである。節 4.10 の再充填は、その delete のあとでも残る。delete より前に旧値を読んだ `fetch` が、delete のあと従来キーを埋め直す経路は消えない。

段階 D は、値キーを `<従来キー>/rev/<R>` に分けることで解消する。旧値を読んだ `fetch` が write するのは、その読み取りが確保した古い番号のキーである。新しい番号の読み取りは別キーであり、その再充填を見ない。write の直前に番号を読み直して、新しいキーへ旧値を書く実装は採らない。節 4.7 と同じ制約である。

段階 B と段階 D が同時にいるローリング期間では、段階 D の getter はこの分離で再充填を見ない。段階 B の getter は従来キーのままなので、上の競合が残る。

## 5. 既存フォームの互換性

次は P2-6 で個別に承認するまで変えない。revision 付きキャッシュを理由に、この PR でも後続のキャッシュ PR でも無断で変えない。

- フォームの文字列と boolean キャスト。文字サイズは文字列のまま。boolean は `ActiveModel::Type::Boolean`。空文字の boolean は `nil` 行になり得る。
- 翻訳バーは、同じリクエストの新しいポリシーではなく、保存時点で getter が見る古いポリシーで正規化して保存する。
- 保存途中の失敗は、成功したキーだけを残す。
- Credentials は省略キーを getter で補完して保存する。
- Credentials は `direct` を検査せず保存できる。Writer の一般 API は `Status.selectable_visibilities` 以外を拒否する。
- ActivityPub は、フォームでは profile キーがパラメータに含まれたとき、Credentials ではアカウント更新の成功後、9 キーの Writer では積まない。この順序を変えない。
- `users.locale` などは設定行と同じトランザクションに入っていない。設定が残って User 列の検証が失敗することがある。
- 高リスク設定は 9 キーの Writer と revision に載せない。フォームの `[]=` のままである。

## 6. P2-6 との依存関係

P2-6 は Rails フォームと Credentials を Writer に載せる、別承認の移行である。この設計はそれを実装しない。互換性の決定表、案Aと案B、移行後の受け入れ条件は [p2_6_legacy_writer_migration.md](p2_6_legacy_writer_migration.md) に分けた。段階 D を P2-6 の完了前に始めない、というこの節の依存は変えない。

段階 D（revision キーの読み取り）は、P2-6 が全ホストの全プロセスへ出たあとにしか始められない。理由は節 4 である。Decorator が番号を動かさないあいだは、単一 revision の値キャッシュは Decorator の保存を隠す。

P2-6 より前に番号だけを Decorator へ足す案は採らない。

- キーごとに `[]=` の直後へ +1 すると、9 キーのフォームが 9 つの番号を作り、途中失敗の番号が部分状態を「最新」にする。#431 の通知をそこへ付けると、部分状態を `preferences_changed` として出すことになる。通知の範囲拡大は P2-5 の再承認が要る。
- フォーム全体を 1 トランザクションと 1 増分にすると、節 5 の部分保存が変わる。原子性の変更はこの PR の対象外である。
- 番号の意味が「Writer の変更回数」から「Decorator を含む変更回数」へ変わる。P2-4A と #431 の契約変更であり、キャッシュ PR に混ぜない。

したがって、キャッシュ世代を読み始める前提は「9 キーの本番保存が Writer だけになり、その COMMIT が revision を進める」である。それが P2-6 の完了である。P2-6 自体は従来キーの delete のままでよく、revision キーの読み取りを同時に有効にしない。P2-6 が Decorator を Writer へ移しても、節 4.10 の cache-aside 再充填は残る。それを消すのは段階 D である。

P2-6 が承認されないあいだ、本番は段階 A に留まる。revision 行は Writer と通知だけが使う。getter は従来キーのままである。

## 7. ローリングデプロイの段階

対象プロセスは、9 キーを読むか書くすべての Rails プロセスである。Puma worker、Sidekiq、同じコードを読むその他のプロセスを含む。streaming ディレクトリは 9 キーを読まない。

### A. 現行キャッシュキーを維持し、revision 更新を準備する

現状が段階 A である。P2-4A の revision と、Writer の従来キー delete と、#431 の通知がある。getter と `[]=` は従来キーだけを使う。

- 旧コード: 従来キーを読み書きできる。revision 行を知らなくても getter は動く。
- 新コード: 段階 A のままなら旧コードと同じキーを使う。
- 新方式の読み取りは無効のままである。
- 切り戻し: getter が番号を見ていないので、revision 行が残っていても値の読み取りは変わらない。行を消す必要は無い。消すと Writer の次の変更が再び 1 から始まる。通知の購読者が番号の後退を見る。行は残す。

### B. revision を進めるすべての保存経路が、新キーを理解する

始められるのは P2-6 が入り、9 キーの本番保存が Writer だけになってからである。この段階のコードは次を行う。

- 9 キーの変更 COMMIT と同じトランザクションで、今までどおり revision を 1 進める。
- COMMIT 後に、変更キーの従来キーを delete する。
- COMMIT 後に、コミットした番号の `<従来キー>/rev/<R>` も delete する。値は write しない。
- getter はまだ従来キーだけを読む。節 4.10 のとおり、delete より前に旧値を読んだ `fetch` が delete のあと従来キーを再充填すると、TTL のあいだその getter は旧値を返すことが残る。

旧プロセスが段階 A の Writer（従来キーだけ delete、revision は進める）で、新プロセスが段階 B でも、読み手が従来キーであるあいだは両方とも読める。段階 A の Decorator がまだ 1 プロセスでも残っているなら、段階 B の完了とは言わない。Decorator は番号を進めず、従来キーへ write する。

新方式の読み取りは、まだ有効にしない。

切り戻し: 段階 B から A へ戻すと、接尾辞キーの delete が止まるだけである。読み手は従来キーのままなので、値は DB のミス充填に戻る。接尾辞キーは誰も読まない。TTL 10 分で消える。

### C. 全ホストと全プロセスが B であることを確認する

コード PR ではない。デプロイの確認である。

- Puma の各 worker、Sidekiq、ジョブを実行するホストに、段階 A や Decorator 保存が残っていない。
- 9 キーの保存が Writer だけである。
- 読み手はまだ従来キーである。

ここを確認する前に段階 D のプロセスを 1 台でも出すと、残った Decorator の write が revision キーから見えない。

切り戻し: 段階 D を出していなければ、B のまま維持するか A へ戻せる。値の正は DB のままである。

### D. 新しいキャッシュキーの読み取りを有効にする

全プロセスが B であるデプロイの、次のデプロイで読み取りを切り替える。ローリングの途中で段階 B と段階 D が同時にいる。

- 段階 D の getter は節 3.4 だけを行う。従来キーは読まない。
- 段階 B の getter は従来キーを読む。delete のあとに DB を読んだミスは、新しい値を充填する。delete より前に旧値を読んだ `fetch` が delete のあと従来キーを再充填する競合は、節 4.10 のとおり、このローリング期間も段階 B の getter に残る。段階 D の getter は、古い番号のキーへの再充填を読まない。
- 段階 D の Writer は従来キーと新しいキーの両方を delete する。段階 B の読み手が delete のあとでミスすれば DB を見る。delete より前の再充填は、直前の箇条のとおり段階 B の getter に残る。
- 段階 A の Decorator がこの時間に残っていると、正しくない。C がそれを禁止する。

有効化してよい時点は、C の確認が終わったあとの、このデプロイだけである。環境変数を古いプロセスが無視する形では有効化しない。古いプロセスは読み取りコードを持たないからである。

切り戻し: 節 8。

### E. 旧キャッシュキーの互換処理を終える

段階 D が全プロセスへ行き、従来キーの TTL である 10 分を超えて待ち、従来キーを読むプロセスが残っていないことを確認してから行う。

- 変更後の delete は、新しいキーだけにする。
- 従来キーを読むコードを消す。
- 従来キーへのフォールバックは足さない。

待ち時間より前に E を出すと、まだ従来キーを読む段階 D 未満のプロセスが、delete されなくなった古い値を読む。

切り戻し: 従来キーの読み取りへは戻さない。戻すと、残っていた遅い write が復活する。戻す先は段階 D の読み取りである。従来キーは空でも、ミスが DB を読むので値は正しい。

## 8. 運用上の切り戻し

| いる段階 | 戻し先 | 値の動き |
| --- | --- | --- |
| A | A の前 | getter は元から従来キーである。revision 行は残す |
| B | A | 読み手は従来キーのまま。接尾辞 delete が無くなるだけ |
| C | B または A | 読み取りはまだ従来キー |
| D | B | 新しいプロセスは従来キーを読む。段階 B と D の Writer が従来キーを delete しているので、ミスが DB を充填する。接尾辞キーは読まなくなる。フォールバックはしない |
| E | D | 新しいキーの読み取りを戻す。従来キーの読み取りは戻さない |

どの段階でも、切り戻しのために設定行や revision 行を書き換えない。番号を 0 に戻すと、購読者の revision が後退し、古い `/rev/0` がまだ残っていれば古い値を指す。

Redis を全消しする場合も、充填は DB から行う。従来キーが先に再充填されても、段階 D と E の読み手はそれを見ない。

PostgreSQL の revision 行が読めないとき、段階 D と E は従来キーへ逃げない。その getter は失敗する。これは今日のキャッシュヒットが PostgreSQL 停止中も値を返すことと比べて、9 キーの getter だけ可用性を下げる。条件 1 と 7 を優先する。Reader は元から PostgreSQL が要る。API と InitialState は Reader なので、この可用性の差は getter 経路に限る。

## 9. DB と性能

見積もりは段階 D 以降の読み取りである。今日の本番は revision SELECT を getter に足さない。

| 状況 | SQL |
| --- | --- |
| 9 キーの getter がすべて従来キーにヒット。今日 | settings 0、revision 0 |
| 同じリクエストで 9 キーの getter。段階 D、値キャッシュはヒット | revision 1、settings 0 |
| Writer が 1 キーを変えた直後の、9 キー getter。段階 D | revision 1。世代が 9 キーとも進むので、各キーのミスで settings SELECT が最大 9。2 回目のリクエストは revision 1 と settings 0 |
| Reader の `read`。今日も段階 D も | settings 1。revision は足さない |
| Writer の変更 1 回 | `users` の `FOR UPDATE` 1、revision の `FOR UPDATE` 1、対象キーの settings SELECT 1、変更行の書き込み、revision の UPDATE または INSERT。Redis は COMMIT のあと |
| Decorator の 1 キー。P2-6 まで | settings の読み書き 1。revision 0。User 行ロック 0 |

User 行ロックを持っている時間は、Writer の BEGIN から COMMIT までである。Redis の delete と `preferences_changed` はロックの外であり、この設計でも外に置く。ロック時間を延ばす SELECT やキャッシュ操作をトランザクションへ足さない。

複数設定の同時更新は、Writer 同士なら User 行ロックで直列になる。Decorator が残っているあいだは、別キーも同じキーもロックの外で並行する。P2-6 のあと、9 キーは Writer の直列化だけになる。高リスク設定の `[]=` はロックしないままである。

多数のアカウントが関係する処理では、フォロワーごとの revision SELECT を新たに始めない。今日の投稿とグループ配送は、対象 user の getter を 1 回呼ぶ。段階 D でも対象 user あたり revision SELECT は 1 である。ループの中で getter を呼ぶ処理を見つけた場合は、user id ごとのメモをそのジョブの中だけ使い、ジョブを越えて持たない。

計測方法は次のとおりである。本番実装の PR で、この回数を assertion にする。

- リクエストまたはサービスの例で `sql.active_record` を購読し、`user_preference_revisions` と `settings` を数える。9 回の getter で revision の SQL が 1 であり、値キャッシュのヒット中は settings の SQL が 0 であることを見る。
- 1 キーを Writer で変えた直後の 9 getter で、settings の SQL がキーあたり 1 回を超えないことを見る。まとめ SELECT を後で入れる場合は、その PR で上限を 1 へ下げる。
- Writer のトランザクションの外でだけ `Rails.cache.delete` と Redis publish が呼ばれることを、既存の `use_transactional_tests = false` の例で維持する。
- ロック待ちは、既存の Writer 並行例と同じく、先にロックを持った側が終わるまで後続の適用が終わらないことで見る。段階 D はロック区間へ Redis を足さないので、この前後関係は変わらない。
- 多数アカウントは、`PostStatusService` とグループ配送の例で revision SQL の本数を数える。対象 user の本数を超えないことを見る。
- Rails.cache の障害は二つに分ける。`Redis::BaseError` はストアが読み取りをミスとして返すので、`fetch` のブロックが DB の生値を返し、従来キーを読まないことを見る。`Redis::BaseError` 以外で呼び出し元へ出る例外のスタブでも、従来キーを読まず、DB が成功すれば生値を返し、DB も失敗すれば例外が残ることを見る。
- PostgreSQL の障害は、revision SELECT が例外を上げるスタブで、従来キーに新しい値があっても getter がそれを返さないことを見る。

毎 getter の個別 revision SELECT は、上の最初の計測で不合格にする。

## 10. 実装 PR の分割

各 PR は単独で戻せる。前の段階の読み取りを、次の PR が黙って有効にしない。

| PR | 内容 | 本番の読み取り |
| --- | --- | --- |
| P2-4B（この PR） | この設計、P2-4A の命中率の訂正、現状固定の RSpec | 従来キーのまま |
| P2-6 | フォームと Credentials を Writer へ載せる。節 5 の差を承認してから | 従来キーのまま。revision は Writer の変更だけが進む、という今日の意味が、移行後はフォームと Credentials にも適用される。その意味の変化は P2-6 の承認に含める |
| P2-4C | 段階 B。9 キーの Writer が COMMIT 後に接尾辞キーも delete する。値は write しない。読み取りヘルパは getter から呼ばない | 従来キーのまま |
| 確認 C | デプロイ確認。PR ではない | 従来キーのまま |
| P2-4D | 段階 D。9 キーの getter だけが節 3.3 と 3.4 を使う。Reader は DB のまま。従来キーへフォールバックしない | 新しいキー |
| P2-4E | 段階 E。従来キーの delete と読み取りコードを消す。D が全プロセスへ出てから 10 分を超えて待つ | 新しいキー |

P2-4C を P2-6 より前に出しても、Decorator が番号を動かさないので段階 D の許可にはならない。P2-4D を P2-4C と同じデプロイにまとめない。まとめると、旧プロセスが接尾辞を delete しない時間と、新プロセスが接尾辞を読む時間が重なる。番号が進む Writer 同士だけならミスが DB を読むので値は合うが、Decorator が 1 台でも残ると合わない。間に確認 C を置く。

この分割に入れないもの: Decorator の先行移行、フォームの原子性変更、ETag、If-Match、DB migration、ActivityPub の変更、Web::Setting、P2-5 の payload 変更、revision 付きキャッシュの先行有効化。

## 11. 各段階の受け入れテスト

### この PR で固定するもの

本番コードを変えずに固定できるものだけを RSpec にする。

- Decorator が 9 キーを保存しても revision 行は増えず、0 のままである。
- `ScopedSettings#[]=` が保存しても revision は増えない。write するキーは `Setting.cache_key` である。
- 既存 getter が `fetch` するキーは `Setting.cache_key` であり、`/rev/` を含まない。Writer が番号を進めたあとも同じである。
- Writer の保存だけが revision を進める。P2-4C の実装後、delete は従来キーと `/rev/<after_revision>` の両方である。下の「P2-4C の実装」を参照する。
- Reader は、従来キーを別の値で上書きしても DB の保存値を返す。
- `nil`、空文字、`direct`、未知のバー、`original`、不正な言語、文字サイズの文字列を読んでも、行の値と `updated_at` は変わらない。

### この PR では書かないテスト

次は本番の読み取りか保存を変えないと意味を持たない。実装 PR の受け入れテストとして残す。

- 段階 D で、9 回の getter が revision SELECT を 1 回だけ発行する。
- 値キャッシュがヒットしているあいだ、getter が settings を SELECT しない。
- revision キーのミスが従来キーを読まない。
- `Redis::BaseError` の読み取りはストアがミスとして処理し、getter が DB の生値を返し、従来キーを読まない。呼び出し元へ出る例外でも従来キーを読まない。DB も失敗すれば例外が残る。
- 節 4.10 の再充填を、段階 D では古い revision のキーへの write が新しい revision の読み取りに見えないことで確認する。段階 B の getter では TTL 中に旧値が残ることを、実装前の受け入れ条件として残す。
- `CacheDeletion` の確認。例外が出た delete は最大 3 回まで試し、3 回目で `false` にする。`Rails.cache.delete` の false は、P2-4C で未確認として扱う。`cache_deleted` の true は従来キーの delete が true を返したことだけを意味する。false の戻りと例外の失敗はログで区別する。詳細は「P2-4C の実装」。
- revision SELECT の例外が、従来キーに値があってもそれを返さない。
- 同じスレッドの次の Sidekiq ジョブが、前のジョブの revision メモを見ない。
- 同じリクエストの Writer のあと、メモが `after_revision` になっている。
- キャッシュするのは生値であり、privacy の補完とバーの正規化結果ではない。
- 段階 B の Writer が、従来キーと `/rev/<after_revision>` の両方を COMMIT 後に delete し、値を write しない。
- 段階 D のフラグが無効のプロセスは、番号が進んでいても従来キーだけを読む。
- P2-6 の互換性一覧。バーの旧ポリシー、Credentials の省略補完、`direct`、部分保存、locale とのトランザクション、ActivityPub の順序。現行挙動の固定は `p2_6_legacy_writer_migration.md` と、その characterization RSpec に移した。

## 12. 追加承認が必要な仕様変更

この PR では承認を求めない。後続で必要になるものだけを分ける。

- P2-6: 節 5 の互換性差を、フォームと Credentials を Writer へ載せるときに承認する。載ったあとの revision は、その保存も数える。今日の「Decorator は数えない」はそこで終わる。
- 段階 D: 9 キーの getter が PostgreSQL を読めないとき失敗する、という可用性の変更。節 8。
- 単一 revision により、1 キーの変更で 9 キーの値キャッシュが同時にミスする、という命中率。この設計の推奨としてここに書いた。実装は P2-4D である。
- キーごとの世代、revision の Redis キャッシュ、`Setting.cache_key` への全体接尾辞、フォームの原子性変更、通知 payload の変更は、この推奨に含めない。やるなら別の設計承認が要る。

## P2-4C の実装

段階 B の delete は実装済みである。getter は従来キーのままである。revision 付きキーの読み取りは有効にしていない。

キーは `UserPreferences::CacheKey.for_revision(key, user, revision)` が作る。中身は `#{Setting.cache_key(key, user)}/rev/#{revision}` だけである。DB も Redis も読まない。`Setting.cache_key` 自体は変えていない。番号はユーザー単位の一つで、キーごとの世代はない。

`Writer#register_after_commit` は、トランザクション内で決めた `after_revision` を `CacheDeletion.new(..., revision:)` に渡す。COMMIT 後に `Revision.current` を読み直さない。

変更キーごとに、従来キーを delete してから `/rev/<after_revision>` を delete する。どちらも SQL COMMIT のあとである。未変更キーは消さない。公開 Writer の複数キーは同じ `after_revision` を使う。LegacyWriter は 1 キー 1 COMMIT なので、各キーはその COMMIT の番号を使う。

`Rails.cache.delete` が true のときだけ、その世代の削除を確認できたものとする。false は未確認であり、成功の証明にはしない。false ではリトライせず、error ログも出さない。DB の保存と revision と通知は戻さない。例外は従来どおり最大 3 回で、失敗したキャッシュキーだけをやり直す。1 回目と 2 回目は warning、3 回目は error である。ログは user_id、var、legacy / revision の区分、revision 側の番号、例外クラスである。設定値は出さない。従来キーの例外があっても revision キーを試し、その逆も、次の変更キーも試す。

`WriteResult#cache_deleted` は設定キーごとの Hash のままである。値は従来キーの結果だけである。true は従来キーの delete が true を返したことである。false は、false が返ったか、例外のリトライが尽きたかである。revision キーの結果は `CacheDeletion#revision_cache_deleted` に分け、この Hash にはキャッシュキー文字列を入れない。

同値、空 PATCH、空 reset、absent の reset、不正入力、ROLLBACK では、どちらのキーも delete しない。`RecordNotUnique` のリトライで残るのは、最後に成功した COMMIT の delete と通知だけである。

`rewrite_cache` は抑止していない。Writer は値を `Rails.cache.write` しない。reset では `rewrite_cache` は走らない。

段階 C はコードではなくデプロイ確認である。Puma の各 worker、Sidekiq、設定を読む他の Rails プロセスが段階 B になるまで、P2-4D の読み取りを出さない。旧プロセスが残るあいだは段階 C 未完了である。このデプロイだけでは getter を変えないので、従来キーの読み取りは維持される。

切り戻しは段階 B から A である。接尾辞キーの delete を止める。読み手は従来キーのままなので、接尾辞キーは誰も読まない。revision 行は消さない。

## P2-4D の実装

段階 D の読み取りは実装済みである。User に属する 9 キーの getter だけが `/rev/<revision>` を読む。従来キーへのフォールバックはない。P2-4C の二重 delete、通知、保存契約は変えていない。

### revision メモ

`UserPreferences::RevisionMemo` は `ActiveSupport::CurrentAttributes` である。保持するのは処理単位の `revisions` Hash と、入れ子の深さを数える `depth` だけである。User のインスタンス変数、クラス変数、グローバル変数には持たない。

`RevisionMemo.scope` が処理単位を開く。開始時の Hash は空である。同じ単位の同じ user id は、最初の参照だけ `UserPreferences::Revision.current` で PostgreSQL を読む。行が無ければ 0、あればその整数である。取得に成功した整数だけをメモする。例外はその場で伝播し、0 を推測してメモしない。別の user id は別の SELECT になる。

入れ子の `scope` は外側の Hash を共有し、`depth` だけを増やす。内側が終わっても外側のメモは残る。一番外側が終わるとき、正常終了でも例外でも `reset` して破棄する。次の処理単位へは持ち越さない。

`scope` の外、たとえば Rails console や Rake ではメモを作らない。参照のたびに PostgreSQL を読む。

### HTTP と Sidekiq

`Mastodon::RackMiddleware#call` は `@app.call` を `RevisionMemo.scope` で包む。`ensure` の `clean_up_sockets!` はそのままである。応答が例外でも、スコープの `ensure` がメモを破棄してからソケットを閉じる。Puma がスレッドを再利用しても、次のリクエストは空のメモから始まる。Rails の executor はリクエストの前後で `CurrentAttributes.reset_all` も呼ぶ。メモを作るのはその開始より後である。

`Mastodon::SidekiqMiddleware#call` は、既存の `Chewy.strategy` と `HostValidationError` の握りつぶし、Elasticsearch の後始末、例外の再送出を `RevisionMemo.scope` の中に置く。`ensure` の Redis と StatsD の掃除はスコープの外のままである。同じスレッドの次のジョブは、前のジョブの revision を見ない。

### getter

切り替え箇所は `Settings::ScopedSettings#[]` だけである。`@object` が User で、キーが `UserPreferences::WriteContract::KEYS` の 9 つであるときだけ、次の順で読む。

1. `RevisionMemo.revision_for(user.id)`
2. `UserPreferences::CacheKey.for_revision`
3. `Rails.cache.fetch`
4. ミスなら、その User とその var の Setting 行を 1 行だけ読む

返すのは、行があればその生値、無ければ従来の default である。nil 行も nil のまま返す。privacy の locked 補完、翻訳バーと翻訳モードの正規化、`preferred_posting_language`、公開 API 用の文字サイズ変換は、これまでどおり User と Reader の getter が生値のあとで行う。getter は行を修復せず、`updated_at` を変えない。

9 キー以外、User 以外、サイトの `Setting[]`、`Web::Setting` は従来キーのままである。ネストした Hash の default マージは、従来どおり `fetch` ブロックの中の `return` でメソッドから抜け、マージ結果をキャッシュしない。`Setting.cache_key` 自体は変えていない。`[]=` は従来キーへ write するままである。

`ScopedSettings#[]=` と `Setting#save!` は従来キーを更新するだけで、revision キーは消さない。revision キーが空なら getter は DB を読む。一度充填した revision キーは、Writer がその番号を delete するまで残る。`update_column` では消えない。本番の 9 キー保存は Writer なので、COMMIT 後の delete とメモ更新で次の getter は新しい番号のミスから DB を読む。

revision キーが無いとき、DB の生値を正とする。次はしない。

```ruby
Rails.cache.fetch(revision_key) { Rails.cache.fetch(legacy_key) { ... } }
```

revision SELECT が失敗しても、Redis が失敗しても、従来キーは読まない。

### キャッシュする値と障害

revision キーに入れるのは生値、または行が無いときの default である。補完後、正規化後の値は入れない。

`Redis::BaseError` は `RedisCacheStore` の failsafe が読み取りをミスとして扱う。`fetch` のブロックが DB の生値を返し、その戻り値が呼び出し元へ返る。`write` が false でも戻り値は DB の生値である。広範な `rescue` は足していない。`ConnectionPool::TimeoutError` のように呼び出し元へ出る例外は、従来キーへ切り替えずに伝播する。

### Writer のあと

`Writer#write_once` は、`User.transaction` が戻ったあと、実変更があるときだけ `RevisionMemo.remember!(user.id, after_revision)` を呼ぶ。SQL COMMIT、`rewrite_cache`、従来キーと revision キーの delete、`preferences_changed` より後である。COMMIT より前には更新しない。ROLLBACK、同値の no-op、`RecordNotUnique` で失敗した試行はメモしない。成功したリトライの `after_revision` だけをメモする。キャッシュ delete が失敗しても、COMMIT 済みならメモは新しい番号になる。別ユーザーのメモは変えない。`scope` の外では `remember!` は何もしない。LegacyWriter は Writer を使うので同じである。Writer から revision キーへ値を write する処理は足していない。

同じ処理単位のメモは、他プロセスの COMMIT を追いかけて読み直さない。その単位自身の Writer が COMMIT したときだけ、次の getter は新しい番号を読む。

### 並行再充填

節 4.10 を RSpec で固定した。revision 6 の getter が DB から v1 を読んだあと、キャッシュ write の前に Writer が v2 と revision 7 を COMMIT し、`/rev/7` を delete する。遅れて `/rev/6` へ v1 を書いても、次の処理単位は revision 7 を読み、v2 を得る。`/rev/6` の古い値は残ってよい。

### 性能

`sql.active_record` で数えた。

| 状況 | revision SELECT | settings SELECT |
| --- | --- | --- |
| 同じ scope で 9 キーを初回に読む。キャッシュは空 | 1 | 9 |
| 同じ scope の 2 回目の同じキー。revision キャッシュはヒット | 0 | 0 |
| Writer が 1 キーを変えた次の scope で 9 キーを読む | 1 | 9 |

revision 自体は Redis にキャッシュしない。プロセスをまたぐメモは作らない。9 キー分のまとめ SELECT は後続の最適化とする。

### ローリングデプロイと切り戻し

段階 C は、この変更を出す前に全 Rails プロセスが段階 B であり、キャッシュクリア済みである、という運用確認を前提にする。このリポジトリの変更では本番プロセスの確認はできない。段階 A のプロセスが残っている状態では出さない。

展開中は段階 B と D が混在する。B は従来キーを読む。D は revision キーを読む。Writer は両方を delete する。DB の revision は共通である。旧 Decorator による 9 キーの書き込みは残していない。

切り戻し先は段階 B である。設定行と revision 行は消さないし、番号も 0 に戻さない。D から B へ戻すと読み取りは従来キーになり、節 4.10 の cache-aside 再充填競合が再び残る。

### P2-4E へ残す作業

- 従来キーの delete をやめる。
- 9 キー以外に残る従来キーの読み取りと、`ScopedSettings#[]=` の従来キーへの write を、段階 E の条件が揃ってから消す。
- 従来キーへのフォールバックは足さない。
- 段階 D が全プロセスへ出てから、従来キーの TTL である 10 分を超えて待つ。
- revision の Redis キャッシュ、キーごとの世代、ミス時の 9 行まとめ SELECT は、この PR ではやらない。
