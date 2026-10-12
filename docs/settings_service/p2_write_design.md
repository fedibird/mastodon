# Settings Service P2-0 書き込み契約

この文書は P2-1 以降の Writer を分割するための実装契約である。本番の Controller、`UserSettingsDecorator`、`Settings::ScopedSettings`、DB、キャッシュ、ActivityPub はこの PR では変えない。

この契約を書いた時点の PR base は `f2893228e6cc14a52e03d1ac8fb8d918b5fd7d2b`（#420 の squash merge）である。その後 `origin/fedibird` は `8186cf1e480fd065171904694a4236fb823d09e4`（#415）まで進んだ。#415 は `show_composer_posting_style_selector` を足しているが、P1-0 カタログには無い。その監査追従は別 PR とし、この PR ではカタログを再生成しない。production はカタログを読まない。P1 の Reader、Schema、読み取り API を前提にする。

D1 から D5 は変えない。User 設定はユーザーに 1 組である。Web::Setting は別物のままである。revision と `preferences_changed` は後続 PR である。

## 1. 現行の書き込み経路

User の `settings` 行を本番コードが書く箇所は `UserSettingsDecorator` だけである。`app/` に `user.settings[...] =` を直接書く箇所は decorator 以外にない。過去の migration と spec は別である。`AccountSettings` の `settings` は `accounts` の JSON であり、`settings` テーブルではない。

保存行は `settings.thing_type = User`、`thing_id = users.id`、`var`、YAML の `value` である。一意制約は `(thing_type, thing_id, var)` である。`users.locale`、`users.time_zone`、`users.chosen_languages` はこの行ではない。

### 1.1 Rails の preferences 更新

`Settings::PreferencesController#update` を、appearance、notifications、safety、other が継承する。認証はセッションの `authenticate_user!` と、サインイン済みなら `require_functional!` である。CSRF は Rails のフォームトークンである。OAuth スコープはない。

処理順は次のとおりである。

1. `UserSettingsDecorator#update(user_settings_params.to_h)` を実行する。
2. 戻り値が真のときだけ `ActivityPub::UpdateDistributionWorker.perform_async` を呼ぶ。戻り値は保存の成否ではなく、送信パラメータに profile キーが含まれるかである。
3. その後に `current_user.update(user_params)` で `locale`、`time_zone`、`chosen_languages` を更新する。
4. User 更新が成功したときだけ `I18n.locale` をそのユーザーの locale にし、リダイレクトする。失敗したら `:show` を描き直す。

設定の保存と User 列の更新は同じトランザクションに入っていない。設定の途中失敗は例外になり、User 列の更新には進まない。そこまでに `[]=` が成功した設定行は残る。User 列の検証失敗では、すでに書いた設定と、すでに積んだ ActivityPub ジョブは戻らない。

`user_settings_params` は 4 画面が同じ許可リストを使う。実際に届くキーは、その画面のフォームに出ている項目である。other 画面には `setting_noindex`、`setting_hide_network`、件数非表示、`setting_enable_reaction` がある。これらが profile キーなので、other の保存は値の変化に関係なく配送を積む。appearance の文字サイズや翻訳バーだけでは profile キーに当たらない。

### 1.2 UserSettingsDecorator

`update` は `process_update` のあと `profile_change?` を返す。`profile_change?` は次のキーがパラメータに含まれるときだけ真である。

- `setting_noindex`
- `setting_hide_network`
- `setting_hide_statuses_count`
- `setting_hide_following_count`
- `setting_hide_followers_count`
- `setting_enable_reaction`

値の差分は見ない。含まれていれば配送対象である。

`process_update` の順は固定である。

1. `notification_emails` と `interactions` を、既存ハッシュへ merge してすぐ書く。
2. `STRING_KEYS` を配列順に書く。この配列では `show_translation_bar` が `new_features_policy` より前にある。
3. `BOOLEAN_KEYS` を書く。

`change?` は `!settings[key].nil?` である。キーが無いことと、値が `nil` であることはどちらも書き込まない。行は削除しない。`false` と `""` は nil ではないので書く。

文字列の正規化は書く直前に行う。

- `translation_preferred_mode` は `TranslationPreferences.normalize_preferred_mode` を通す。`translated`、`bilingual`、`both` 以外は `translated` として保存する。`original` も保存時に `translated` へ変わる。
- `show_translation_bar` は `TranslationPreferences.normalize_visibility(value, user.setting_new_features_policy)` を通す。`true` は `always`、`false` は `never`、`always` / `target` / `never` はそのまま、それ以外はポリシーの既定へ正規化して保存する。ポリシーは `conservative` なら `never`、`tester` なら `always`、それ以外は `target` である。
- 同じリクエストに新しい `new_features_policy` があっても、バーの正規化はまだ保存されていない古い `setting_new_features_policy` を見る。古い値が `default` で入力が `nope`、同時にポリシーを `conservative` へ変えると、保存されるバーは `target` であり `never` ではない。

boolean は `ActiveModel::Type::Boolean` でキャストしてから保存する。`"0"` と `"false"` は `false`、`"1"` と `"true"` は `true` になる。キャスト結果が `nil` のときも、`change?` が真なら `nil` の行を書く。空文字の boolean 入力はここに当たる。

文字サイズは `STRING_KEYS` であり `INTEGER_KEYS` は空である。フォームの range は文字列のまま保存する。10 から 20 の範囲検査は保存処理にない。

`default_privacy` と `default_language` も文字列のまま保存する。公開範囲の選択肢検査も、言語コードの検査も decorator にはない。

### 1.3 ScopedSettings#[]=

1 キーごとに次を行う。外側のトランザクションはない。

1. `Setting.unscoped` で `(thing_type, thing_id, var)` を `find_or_initialize_by` する。
2. `update!` で YAML 化した `value` をコミットする。
3. その後に `Rails.cache.write(Setting.cache_key(var, user), value)` する。

キャッシュキーは `rails_settings_cached/<起動時の defaults MD5>/User-<id>/<var>` である。`User#settings` は `ScopedSettings` オブジェクトを `@settings` にメモするだけで、値はメモしない。9 キーの `setting_*` にインスタンス変数のメモは無い。`noindex?` のような別キーだけが `@noindex` を持つ。

読み取りは `Rails.cache.fetch` である。未保存なら YAML 既定を返す。`theme` と `noindex` だけは未保存時にサイト全体の `Setting[var]` を見る。9 キーはこの例外に入らない。ハッシュ既定のキーは `fetch` ブロック内の `return` でキャッシュに載らない。9 キーはスカラーなのでこの抜け方はしない。

`update!` のあとキャッシュ書き込みが失敗すると、DB は新しい値、キャッシュは古い値のまま残る。Reader は DB を読む。従来 getter はキャッシュを読む。P1 で観察した差はこの順で起きる。読み取りは行を作らない。

### 1.4 Credentials の PATCH

`Api::V1::Accounts::CredentialsController#update` の認可は `write` または `write:accounts` である。`read:preferences` は書いていないし、この契約でも足さない。

処理順は次のとおりである。

1. `UpdateAccountService` が `accounts` の列と、アカウント JSON の付随項目を `update!` する。失敗するとここで終わる。
2. `source` が blank でなければ decorator で 3 キーを書く。`{}` は blank なので設定を触らない。
3. 成功すると、設定が変わっていなくても `ActivityPub::UpdateDistributionWorker` を積む。

`source` の 3 キーは次の `fetch` で埋める。

- キーが無いときは、いまの getter を入れる。`privacy` は `setting_default_privacy`、`sensitive` は `setting_default_sensitive`、`language` は `setting_default_language` である。
- キーがあり値が `nil` のときは `nil` を入れる。decorator はそれをスキップするので、既存行は残る。

このため、`source` に `language` だけを置く PATCH は、未保存の privacy を locked なら `private`、そうでなければ `public` として新規保存し、未保存の sensitive を `false` として新規保存する。有効値を保存値に変える。新 Writer はこの補完をしない。Credentials を Writer に載せるまでは、この補完を残す。

GET の認可は `profile`、`read`、`read:accounts` のままである。

### 1.5 UpdateAccountService

アカウント属性の `update` または `update!` だけを行う。User の `settings` 行は書かない。成功時に、locked が外れたらフォローリクエストの承認を積み、リンク検証とハッシュタグ抽出を行う。設定の 9 キーとはトランザクションを共有しない。

### 1.6 locale と派生言語

`users.locale` は preferences の `user_params` だけが更新する。`default_language` 行は変わらない。`preferred_posting_language` は `valid_locale_cascade(default_language, locale, I18n.locale)` であり、保存しない。locale の更新に成功したリクエストだけが、リダイレクト用に `I18n.locale` を変える。失敗した描き直しでは、設定行だけ先に残ることがある。

新 Writer は locale を書かない。派生言語も書かない。

### 1.7 ActivityPub

`ActivityPub::UpdateDistributionWorker` はプロフィール更新の配送である。Sidekiq の `lock: :until_executed` で、実行中の重複は捨てる。配送の outbox は無い。enqueue が DB コミットの前に失敗すればリクエストは失敗し、その時点までの `[]=` は残る。コミット後の enqueue 失敗は、呼び出し元が例外を返す。設定は残る。ジョブは残らない。クライアントが同じ PATCH を再送すれば、もう一度積む。

9 キーは profile キーではない。appearance 画面の保存だけでは配送しない。other 画面は profile キーを含むので配送する。Credentials はアカウント更新のたびに配送する。

## 2. 最初の Writer が受けるキー

Reader の 10 キーから、派生の `preferred_posting_language` を除いた 9 キーだけを候補にする。カタログ上はどれも `candidate_general` である。D2 の高リスク例（禁止操作、禁止公開範囲、`unlocked_for_official_app`、`noindex`、件数非表示、`enable_reaction`、`interactions`）は含めない。

| キー | 保存 | フォームの入力 | 新 API が書く値 |
| --- | --- | --- | --- |
| `default_privacy` | 文字列または行なし | `Status.selectable_visibilities`（`public`、`unlisted`、`private`） | 同じ 3 つだけ |
| `default_sensitive` | boolean。未保存の有効値は `false` | チェックボックスの `"0"` / `"1"` | JSON の `true` / `false` だけ |
| `default_language` | 文字列、`nil`、`""`、行なし | 言語一覧と検出用の nil | `valid_locale?` の言語コードだけ |
| `show_translation_bar` | `always` / `target` / `never`、および古い `true` / `false` / `nil` / 未知文字列 | 3 つのラジオ | 3 つの文字列だけ |
| `translation_preferred_mode` | 3 モード。未知は読むとき `translated` | `translated` / `bilingual` / `both`。`original` は選択肢に無い | 同じ 3 つだけ |
| `new_features_policy` | `conservative` / `default` / `tester`。未保存の有効値は `default` | 同じ 3 つのラジオ | 同じ 3 つだけ |
| `content_font_size` | 整数、数値文字列、それ以外の文字列。YAML 既定は 15 | range 10〜20 の文字列 | 整数 10〜20 だけ |
| `info_font_size` | 上と同じ | 上と同じ | 上と同じ |
| `reduce_motion` | boolean。未保存の有効値は `false` | チェックボックス | JSON の `true` / `false` だけ |

許可リストは `UserPreferences::WriteContract::KEYS` にこの 9 つを固定する。Schema の `write_policy: :general` だけを見て受け付けない。Schema に一般キーが増えても、この定数を変える PR まで Writer は受け取らない。`preferred_posting_language` は `write_policy: :read_only` であり、定数にも入れない。

高リスク設定の Writer は作らない。Rails フォームと Credentials は、この許可リストへ自動では載せない。

## 3. PATCH と null と reset

一般 API の PATCH は、ボディに存在するキーだけを更新する。存在しないキーは読まないし、保存もしない。Credentials が今やっている getter 補完は、一般 API では行わない。

| 入力 | DB | 一般 API |
| --- | --- | --- |
| キーが無い | 行もキャッシュも触らない | 同じ |
| JSON `null` | 現行 decorator はスキップする。行削除ではない | 422 で拒否する。`nil` 行も作らない |
| `false` | boolean なら `false` の行を書く。未保存とは別である | boolean キーだけ受け、`false` の行を書く |
| `""` | 文字列キーなら空文字列の行を書く。`\|\|` では未保存にならない | 拒否する。privacy の空文字列と language の空文字列は、既存行として読み続ける |
| 明示的な既定値 | フォームは `"public"` や `"default"` や `"15"` を普通の値として保存する | 同じく普通の値として保存する。既定値だから行を消す、とはしない |
| 未保存へ戻す | 現行 API には無い | PATCH とは別の reset で行を削除する |

`null` と行削除は同じ意味にしない。保存済みの `nil`（state `:nil`）と行が無いこと（state `:absent`）も Reader が区別している。reset は行削除であり、`value` を YAML の nil にすることではない。

reset の候補は次の POST である。PATCH の値マップには混ぜない。

```json
{ "reset": ["user.default_privacy", "user.default_language"] }
```

キー名は P1-3 の `api_key_candidate` と揃える。実装は P2-3 まで行わない。P2-2 の PATCH は `reset` フィールドを知らない。

no-op は、すでに保存行があり、その保存値が再送した値と等しいときだけである。`updated_at` も動かさない。

未保存（state `:absent`）のキーへ明示的な既定値を送ったときは、YAML 既定や有効値と一致していても行を新規作成する。例として、行が無い `default_sensitive` に `false` を送ると `false` の行ができる。これは no-op ではない。

state は混ぜない。

- `:absent` は行が無い。
- `:nil` は行があり、YAML の値が nil である。
- `:present` は行があり、値が nil ではない。`false` と `""` は `:present` である。

reset は行削除であり、nil の保存でも既定値の書き込みでもない。すでに `:absent` のキーへの reset は削除する行が無いので no-op である。`:nil` の行への reset は行を消す変更であり、nil のまま残すことではない。

## 4. 読める値と書ける値

古い行は Reader が今までどおり読む。Writer はそれを修復しない。次の値は読んでよいが、一般 API からは書けない。

- `default_privacy` の `direct`、`limited`、空文字列、未知文字列。フォームの選択肢は `direct` と `limited` を除く。Credentials は検査せず保存できる。その差は Credentials を Writer に載せるときに別 PR で決める。
- `default_language` の `nil`、`""`、`ja-JP`、`invalid`。`ja-JP` は `valid_locale?` が偽である。`zh-CN` のように `SUPPORTED_LOCALES` にある地域付きコードは、下の許可集合に入り、ここでは拒否しない。派生言語だけが地域を剥がす。`source.language` は保存値のままである。
- `show_translation_bar` の `true`、`false`、`nil`、未知文字列。有効値は読むときに正規化する。保存し直さない。
- `translation_preferred_mode` の `original` と未知文字列。有効値は `translated` になる。保存し直さない。
- 文字サイズの `"18"`、`"invalid"`、範囲外の整数。`public_value` は `\A-?\d+\z` の文字列だけを整数にする。互換 JSON は `effective` を使い、文字列の `"18"` を整数にしない。

新しい一般 API の検査は次のとおりである。

- privacy は `Status.selectable_visibilities` の要素だけである。locked による補完は書き込まない。
- language は、送信された文字列そのものに対する `LanguagesHelper#valid_locale?` が真のときだけ保存する。`valid_locale_or_nil` は使わない。あれは `ja-JP` を `ja` に剥がし、`zh-CN` も `zh` に落とす読み取り用である。Writer は地域を剥がさないし、ハイフンを補わないし、大小文字も変えない。検出へ戻すのは reset である。根拠は `LanguagesHelper::SUPPORTED_LOCALES`（`ISO_639_1`、`ISO_639_1_REGIONAL`、`ISO_639_3`）である。フォームの `filterable_languages` は表示用の部分集合であり、Writer の許可集合にはしない。

`default_language` の許否は次のとおりである。

| 入力 | 一般 API | 理由 |
| --- | --- | --- |
| `ja` | 許可 | `valid_locale?` が真 |
| `en` | 許可 | 同じ |
| `de` | 許可 | 同じ |
| `zh` | 許可 | `ISO_639_1` にある |
| `zh-CN` | 許可 | `ISO_639_1_REGIONAL` にあり、`valid_locale?` が真。文字列のまま保存する |
| `zh-TW` | 許可 | 同じ |
| `zh-HK` | 許可 | 同じ |
| `zh-YUE` | 許可 | 同じ。広東語として既存の対応ロケールである |
| `ja-JP` | 拒否 | `SUPPORTED_LOCALES` に無い。`ja` へは変えない |
| `invalid` | 拒否 | 対応ロケールではない |
| 空文字列 | 拒否 | 未保存への reset ではない |
| `null` | 拒否 | 行削除でも nil 保存でもない |
- translation bar は `always`、`target`、`never` だけである。boolean と未知文字列は拒否する。ポリシーから値を生成して保存しない。
- mode は `translated`、`bilingual`、`both` だけである。`original` は拒否する。
- policy は `conservative`、`default`、`tester` だけである。
- 文字サイズは Integer であり、10 以上 20 以下である。数値文字列は拒否する。UI の range と保存検査をここで一致させる。既存の文字列行は残す。フォームは range の文字列を decorator へ送り続ける。
- sensitive と reduce_motion は `true` か `false` だけである。`"true"`、`1`、`"0"` は拒否する。

依存の評価時点は、リクエスト適用後の保存値である。

- リクエストに含まれるキーは、そのリクエストの新しい保存値を使う。
- 含まれないキーは、いま DB にある保存値を使う。有効値や YAML 既定へ読み替えた結果は使わない。
- バーを未知の値から正規化して保存することはしない。したがって、ポリシーとバーを同時に送っても、バーは 3 つの文字列以外を受けない。ポリシーだけを変えてもバーの行は変えない。読むときの有効値は、従来どおりポリシーに従う。

現行 decorator は、同時更新でも古いポリシーでバーを正規化して保存する。その挙動は spec で固定し、この PR では変えない。

## 5. 同時更新

DB の行を正とする。キャッシュは配信の都合であり、正ではない。

Writer 同士は、対象 User 行の `lock!`（`SELECT ... FOR UPDATE`）で直列化する。設定行がまだ無くても、ロック対象は User 行なので競合を取りこぼさない。Writer 同士が同じ未保存キーを書くときは、後続がロック後に先の行を読む。二つの INSERT にはならない。

変更前の保存状態は、ロックを取ったあと、同じトランザクションの中で `Setting.unscoped` から読む。ロック前の Reader 結果や getter のキャッシュは変更前の値に使わない。

`WriteResult` はリクエストに含まれるキーについて、次を別々に持つ。

- `before`: ロック後に読んだ state と configured。`:absent`、`:nil`、`:present` を区別する。
- `after`: このトランザクションが残す state と configured。
- `changed_keys`: state または configured が変わったキー。未保存への明示的な既定値の INSERT はここである。
- `unchanged_keys`: すでにその保存結果になっているキー。既存行への同値再送と、すでに `:absent` の reset がここである。`updated_at` は動かさない。

期待結果は次のとおりである。

| 状況 | 結果 |
| --- | --- |
| 別キーを二つの Writer が同時に書く | 両方の行が残る。後からロックを取った側は、先にコミットした相手のキーを読んでも上書きしない |
| 同じキーを二つの Writer が違う値で書く | 後からロックを取りコミットした値が残る |
| 同じ未保存キーを二つの Writer が INSERT する | 先にコミットした行を、後続がロック後に読む。同値なら no-op、違う値なら UPDATE である。二つの INSERT にはしない |
| 既存行へ同じ値を再送する | `unchanged_keys`。行も `updated_at` も変わらない |
| 未保存キーへ、有効値と同じ既定値を送る | `changed_keys`。行を作る |
| 既存の `:nil` 行へ値を書く | `changed_keys`。`:absent` とは扱わない |
| 既存行の reset | `changed_keys`。行は消える。nil は残さない |
| 行が無いキーの reset | `unchanged_keys` |

ポリシーとバーを同じリクエストで書くときは、節 4 の適用後の値で検査する。バーをポリシーから生成して保存しない。

移行期間の制約として、`UserSettingsDecorator` と `ScopedSettings#[]=` はこの User 行ロックを取らない。P2-1 で decorator にロックを足さない。P2-6 で同じロックに乗せるまでは、この差を残す。

Decorator は 1 キーずつ `update!` する。同じ未保存キーを Decorator と Writer が同時に INSERT すると、一意制約 `(thing_type, thing_id, var)` に当たることがある。PostgreSQL はそのトランザクションを失敗状態にする。P2-1 は、開いたトランザクションの中で `ActiveRecord::RecordNotUnique` を rescue して続きの SQL を実行しない。例外は `transaction` ブロックの外まで出し、そのトランザクションを完全に ROLLBACK してから、Writer 全体をやり直す。やり直しは最初の失敗のあと 2 回まで（合計 3 回）である。各回は新しいトランザクションで、禁止判定、User 行ロック、ロック後の読み直しから始める。先に入った行が見えれば INSERT ではなく UPDATE か no-op になる。

3 回とも一意制約で失敗したら `UserPreferences::Conflict` を上げる。これは P2-2 が HTTP 409 に変換するドメインエラーである。P2-1 は HTTP にしない。生の PostgreSQL 例外をそのまま呼び出し元の契約にしない。

そのほかの境界は次のとおりである。

1. 複数キーの途中失敗は、現行では先行キーが残る。Writer は検査を全部終えてから 1 トランザクションで書き、失敗したら全部戻す。
2. 9 キーの Writer は User 列を書かない。locale の失敗で設定が残る現行の preferences 画面は、そのままである。
3. 9 キーの成功では ActivityPub を積まない。
4. DB コミットのあとキャッシュ削除が失敗しても、DB は戻さない。節 6 のとおりである。

## 6. キャッシュ

比較した方式は次のとおりである。

| 方式 | 判断 |
| --- | --- |
| コミット後に `Rails.cache.write` で新しい値を入れる | 採らない。遅いリクエストの write が、後からコミットした新しいキャッシュを古い値で上書きできる |
| コミット後に触ったキーだけ `delete` する | P2-1 の暫定である。delete のあと古い write が走る穴は残る。Reader は DB なので読み取り API は正しい |
| revision をキーに含める | 後続 PR で getter まで揃える本方式である。古い write は古い revision のキーに当たり、読み手は見ない |
| Reader の DB 直接参照を続ける | 続ける。キャッシュを修復するために Reader へ write を入れない |

### 6.1 Rails 6.1 のコミット後処理

このアプリの Rails は 6.1.7 である。`ActiveRecord.after_all_transactions_commit` は無い。キャッシュ削除は、`transaction` ブロックの次の行に書かない。ブロックが戻った時点は、外側の COMMIT より前であることがある。

P2-1 は、`before_committed!`、`committed!(should_run_callbacks:)`、`rolledback!(force_restore_state:, should_run_callbacks:)`、`trigger_transactional_callbacks?` を実装したオブジェクトを、Writer 自身のトランザクションへ `User.connection.add_transaction_record` で登録する。

`committed!` は `should_run_callbacks` が真のときだけ cache.delete する。偽のときは何もしない。Rails 6.1 の `commit_records` は、callback を親へ繰り延べるときと、`ensure` の掃除のときに `committed!(should_run_callbacks: false)` を呼ぶ。ここで delete すると、SAVEPOINT の帳簿上の呼び出しや二重削除になる。`rolledback!` は `should_run_callbacks` の真偽にかかわらず cache.delete しない。

本番の成功経路は、開いたトランザクションが無い状態で始めた `RealTransaction` だけである。その `commit` は PostgreSQL の COMMIT であり、そのあと `commit_records` が `committed!(should_run_callbacks: true)` を呼ぶ。delete はこの呼び出しだけが行う。

`TransactionManager#begin_transaction` は `run_commit_callbacks = !current_transaction.joinable?` である。親が joinable な savepoint の `commit` は `RELEASE SAVEPOINT` であり、callback は親へ移る。親が joinable ではない savepoint は、`RELEASE SAVEPOINT` の時点で `committed!(should_run_callbacks: true)` が走り得る。これは PostgreSQL の COMMIT ではない。本番の Writer は、どちらの外側トランザクションにも入らない。節 6.2 が先に拒否する。

### 6.2 開いたトランザクションは joinable を問わず拒否する

本番の Writer は、`User.connection.transaction_open?` が真なら、joinable の真偽を見ずに `UserPreferences::OpenTransaction` を上げる。判定は `lock!` より前であり、設定行の SELECT や INSERT より前である。キーワード引数、環境名の分岐、非 joinable だけを許す条件は本番クラスに置かない。呼び出し側は `ActiveRecord::Base.transaction` で Writer を包めない。

RSpec の transactional fixtures は `begin_transaction joinable: false` でトランザクションを開く。この中で本番の判定をそのまま使うと Writer は必ず拒否される。fixture を開いたまま Writer の保存例を書くときだけ、`spec/` に置いたモジュールの prepend で判定を空にしてよい。そのモジュールを `app/` から参照しない。本番の呼び出しが同じ抜け道を引数や設定で使えるようにしない。

PostgreSQL の COMMIT と cache.delete の前後は、`use_transactional_tests = false` の例だけで検証する。この例は prepend を使わない。Writer が戻ったとき、別コネクションから行が見えることと、delete がその可視状態より前に呼ばれていないことを見る。fixture の savepoint 解放で delete が走ったことは、COMMIT の証拠にしない。

### 6.3 delete の失敗

COMMIT より後の cache.delete 失敗では DB を戻さない。戻しようが無く、例外をリクエストへ返すとクライアントの再送が別の更新とぶつかる。

callback の中で例外を握る。1 キーあたり 3 回まで delete を試し、各失敗は warn で user id、var、例外クラスとメッセージを残す。3 回とも失敗したら error で残し、それ以上は投げない。`WriteResult` のそのキーは `cache_deleted: false` である。成功したキーは `true` である。HTTP は成功のままである。no-op で行を触っていないキーは delete しない。

P2-1 の保証は次のとおりである。

- 正は DB の保存値である。
- ROLLBACK ではキャッシュを消さない。`committed!(should_run_callbacks: false)` でも消さない。
- Writer は `ScopedSettings#[]=` を呼ばない。`[]=` は `update!` の直後に `Rails.cache.write` する。
- リクエストに無いキーの行もキャッシュも触らない。
- 読み取りは保存状態を変えない。
- キャッシュが一致しているとき、既存 getter と Reader の有効値は P1 と同じである。一致していないとき、getter はキャッシュ、Reader は DB である。P2-1 はこの差を自動修復しない。
- revision はキャッシュキーと変更通知の同じ番号にする。P2-1 では列も番号も増えない。delete は revision までの暫定であり、delete のあと古い `[]=` が write する穴は残る。

### 6.4 P2-1 の RSpec

- `committed!(should_run_callbacks: false)` は cache.delete を呼ばない。`rolledback!` も cache.delete を呼ばない。
- 成功時、cache.delete は `committed!(should_run_callbacks: true)` の中だけで呼ばれる。トランザクションの途中では呼ばれない。
- Writer のトランザクションが例外で戻ると、cache.delete は呼ばれず、書いた行も残らない。
- 開いたトランザクションの中では、joinable が真でも偽でも、prepend 無しなら `OpenTransaction` になる。行も delete も無い。判定が `lock!` より前であることも固定する。
- `use_transactional_tests = false` で、別コネクションが行を見えた時点より前に delete が無く、Writer が戻ったあと無関係な ROLLBACK をしても行が残る。これが PostgreSQL COMMIT と delete の前後の検証である。
- fixture を開いた保存例は、`spec/` の prepend を付けたときだけ書く。本番クラスに同じ分岐が無いことを、ソースに引数も `Rails.env` も無いことで固定する。
- cache.delete が 2 回失敗して 3 回目に成功すると、行は残り、warn が 2 回残り、`cache_deleted` は true である。
- 3 回とも失敗すると、例外は呼び出し元へ出ず、行は残り、`cache_deleted` は false で、error ログが残る。
- ROLLBACK の例では delete の失敗ログは出ない。delete 自体を呼ばないためである。
- Decorator と同時の未保存 INSERT で一意制約に当たったとき、失敗したトランザクションの行は残らず、ROLLBACK のあと別トランザクションでやり直す。トランザクションの中で rescue して続行しない。3 回失敗すると `UserPreferences::Conflict` になり、部分行は残らない。

## 7. 副作用の境界

9 キーの適用ヒントは Schema の `reinitialize` または `reload` である。ActivityPub の対象ではない。

- ActivityPub は、この Writer からは積まない。other 画面と Credentials の現行配送は残す。
- 新しい WebUI への反映と、他端末への通知は D4 の後続である。P2-1 は結果オブジェクトに変更前後の保存値を載せるところまでである。配送はしない。
- メール、通知フィルタ、投稿制限は 9 キーの外である。将来それらの Writer を作るときも、ジョブはコミット後に限る。保証が必要なら、同じトランザクションの outbox 行と、それを送るプロセスをセットで設計する。9 キーには outbox を足さない。

副作用はコミット前に発火させない。`after_commit` より前にキャッシュ delete も Worker も呼ばない。

## 8. クラスの分割

書き込みメソッドを Reader と Schema に足さない。Schema は検査の材料として読む。Reader は変更前の保存状態を読む。

| クラス | 責務 |
| --- | --- |
| `UserPreferences::WriteContract` | 9 キーの定数、型、選択肢、範囲。未知キーと派生キーを拒否する |
| `UserPreferences::ChangeSet` | 省略、値の設定、reset を操作に分ける。変更前はロック後の configured state である |
| `UserPreferences::Writer` | 開いたトランザクションを joinable を問わず拒否し、User 行をロックし、1 トランザクションで UPSERT または DELETE し、`committed!(should_run_callbacks: true)` だけで cache delete する |
| `UserPreferences::Conflict` | 一意制約のやり直し上限を超えたドメインエラー。HTTP への変換は P2-2 |
| `UserPreferences::OpenTransaction` | 開いたトランザクションを拒否したドメインエラー |
| `UserPreferences::WriteResult` | `before`、`after`、`changed_keys`、`unchanged_keys`、キーごとの `cache_deleted`。HTTP の形にはしない |

DB 更新は `Setting.unscoped` をこのトランザクションの中で使う。`ScopedSettings#[]=` は使わない。

API コントローラ、OAuth、revision 列、Streaming は Writer の外である。Mastodon 互換の preferences と Credentials は、切り替え PR まで decorator のままである。

`WriteResult` の保存値は、API が後で `configured` と `effective` を組み立てる材料である。`public_value` は互換 JSON に使わない。一般 API の応答形は P2-2 で、P1-3 の読み取り文書に合わせる。

## 9. PR の分割とテスト

各 PR は単独でマージできる。前の PR の本番挙動を、次の PR が黙って広げない。

### P2-1 Writer

HTTP もフォームも変えない。節 8 のクラスと spec だけを足す。

- 9 キー以外、派生キー、Schema では general だが定数に無いキーを拒否する。
- 省略は無変更、`null` は拒否、`false` と空文字列と明示的既定値と reset を区別する。
- 節 4 の言語表を固定する。`ja-JP` は拒否し、`zh-CN`、`zh-TW`、`zh-HK`、`zh-YUE` は文字列のまま許可する。`valid_locale_or_nil` で地域を剥がさない。
- 未保存への既定値は INSERT する。既存行への同値再送だけを no-op にする。`:absent`、`:nil`、`:present` を取り違えない。
- 節 5 の User 行ロック、Decorator との一意制約、完全な ROLLBACK のあと最大 2 回のやり直し、上限超過の `Conflict` を固定する。
- 節 6.4 の、開いたトランザクションの拒否、`should_run_callbacks: false` で副作用が無いこと、transactional fixtures を切った COMMIT と delete の前後、delete 失敗を固定する。
- ポリシーだけの更新がバー行を変えない。同時更新でもバーをポリシーから生成しない。
- 2 キーの途中失敗で両方戻る。キャッシュ write が無く、delete は COMMIT 後の callback だけである。
- リクエスト外のキーが残る。decorator はロックしないままである。
- Reader と getter は、キャッシュが一致するとき P1 と同じである。DB だけ変えた差は残す。
- ActivityPub を積まない。`users.locale` を変えない。

### P2-2 一般設定 PATCH

`PATCH /api/v1/fedibird/preferences` を足す。スコープは `write:preferences` だけとする。`write`、`write:accounts`、`read`、`read:preferences` では書けない。`read:preferences` を Credentials や Mastodon の preferences に足さない。

ボディは P1-3 のキー名だけを受ける。省略、拒否、保存の spec をコントローラで繰り返す。`UserPreferences::Conflict` は 409 にする。`OpenTransaction` はコントローラが Writer をトランザクションで包まないことで本番には出さない。応答は変更後の読み取り文書である。キャッシュは `private, no-store` とする。既存 GET の JSON を回帰する。

### P2-3 reset

節 3 の POST で行を削除する。`null` の PATCH は 422 のままである。削除後の state は `:absent` であり、`:nil` ではない。

### P2-4 revision

P2-4A は `user_preference_revisions` に Writer の変更回数だけを記録する。行が無いユーザーは 0 である。設定行と同じトランザクションで 1 増やす。Decorator、フォーム、Credentials、既存 getter のキャッシュキーはこの番号を動かさない。HTTP 公開、ETag、If-Match、revision 付きキャッシュは後続である。詳細は `p2_4a_revision.md` に書く。

### P2-5 変更通知

コミット後に、revision と変更キーを載せる。9 キー以外と ActivityPub は混ぜない。enqueue 失敗を失いたくなった時点で outbox を別 PR にする。P2-5 の最初の実装は、コミット後の best-effort でよい。設定の正はすでに DB にある。

### P2-6 既存経路の移行

Rails フォームと Credentials を Writer に載せる専用 PR とする。載せる前に、次の挙動差を明示して承認する。

- 未知のバーと mode を保存時に正規化しなくなる。
- Credentials が省略キーを getter で埋めなくなる。
- 文字サイズの新規保存が整数だけになる。既存の文字列は残る。
- `direct` を Credentials から書けるかどうか。

承認前に切り替えない。

既存 GET の回帰は各 PR で回す。対象は Preferences serializer、Credentials の GET、Fedibird の読み取り API、InitialState、Reader、Schema である。P1-0 のカタログチェッカーも回す。カタログの項目追加は、経路を移す PR で source_refs がずれたときだけである。

## 10. この PR で決めたことと、実装時に残すこと

決めたことは、9 キーの許可リスト、PATCH と `null` と reset と no-op の差、`valid_locale?` による言語の許可集合、User 行ロック、開いたトランザクションの拒否、`committed!(should_run_callbacks: false)` では副作用を実行しないこと、Decorator との一意制約は完全な ROLLBACK のあと限定回数だけやり直すこと、delete 失敗を DB へ戻さないこと、ActivityPub を 9 キーに付けないこと、節 9 の PR 順である。

#415 の `8186cf1e480fd065171904694a4236fb823d09e4` は `show_composer_posting_style_selector` を足している。最新の `origin/fedibird` で P1-0 チェッカーは失敗する。未登録キーと、delegate 追加でずれた `source_refs` がある。この差の修正はこの PR に入れない。監査追従は別 PR のままである。

実装時に残すのは次だけである。

- revision の列を `users` に置くか、1 行の別テーブルに置くか。意味は P2-4 で同じである。
- P2-5 の通知を、最初から outbox にするか、best-effort のあとで outbox に強化するか。9 キーの正には影響しない。
- Credentials とフォームを Writer に載せるときの、省略キー補完と `direct` の扱い。P2-6 の承認事項である。
