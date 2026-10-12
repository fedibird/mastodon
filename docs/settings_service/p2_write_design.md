# Settings Service P2-0 書き込み契約

この文書は P2-1 以降の Writer を分割するための実装契約である。本番の Controller、`UserSettingsDecorator`、`Settings::ScopedSettings`、DB、キャッシュ、ActivityPub はこの PR では変えない。

基準は `origin/fedibird` の `f2893228e6cc14a52e03d1ac8fb8d918b5fd7d2b`（#420 の squash merge）である。P1 の Reader、Schema、読み取り API を前提にする。`docs/settings_service/catalog.yml` は再生成しない。production はカタログを読まない。

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

同じ値をもう一度 PATCH することは成功である。保存値がすでにその値なら行を更新しない。`updated_at` も動かさない。再送で副作用を増やさないためである。

## 4. 読める値と書ける値

古い行は Reader が今までどおり読む。Writer はそれを修復しない。次の値は読んでよいが、一般 API からは書けない。

- `default_privacy` の `direct`、`limited`、空文字列、未知文字列。フォームの選択肢は `direct` と `limited` を除く。Credentials は検査せず保存できる。その差は Credentials を Writer に載せるときに別 PR で決める。
- `default_language` の `nil`、`""`、`ja-JP`、`invalid`。派生言語だけが地域と無効値を落とす。`source.language` は保存値のままである。
- `show_translation_bar` の `true`、`false`、`nil`、未知文字列。有効値は読むときに正規化する。保存し直さない。
- `translation_preferred_mode` の `original` と未知文字列。有効値は `translated` になる。保存し直さない。
- 文字サイズの `"18"`、`"invalid"`、範囲外の整数。`public_value` は `\A-?\d+\z` の文字列だけを整数にする。互換 JSON は `effective` を使い、文字列の `"18"` を整数にしない。

新しい一般 API の検査は次のとおりである。

- privacy は `Status.selectable_visibilities` の要素だけである。locked による補完は書き込まない。
- language は `valid_locale?` が真のコードだけである。地域タグは拒否する。検出へ戻すのは reset である。
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

1. 同じキーを二つのクライアントが書くと、後からコミットした行が残る。楽観ロックは P2-1 には無い。失ったクライアントは、次の GET で Reader の値を見る。revision を入れる PR で、`If-Match` による拒否を足せる。
2. 別のキーは別の行である。Writer はリクエストに含まれるキーだけを更新する。もう一方のキーは失わない。Credentials の省略キー補完は、並行した privacy の更新を上書きし得る。一般 API はその補完をしない。
3. ポリシーとバーを同じリクエストで書くときは、節 4 の適用後の値で検査する。バーをポリシーから生成して保存しない。
4. Rails フォームと一般 API が同じキーを書くと、後からコミットした方が残る。フォームは decorator の正規化のままである。同じ PR でフォームを Writer に切り替えない。
5. DB コミットのあとキャッシュ操作が失敗しても、DB は戻さない。Reader は新しい値を返す。getter は古いキャッシュを返すことがある。
6. 複数キーの途中失敗は、現行では先行キーが残る。Writer は検査を全部終えてから 1 トランザクションで書き、失敗したら全部戻す。
7. 9 キーの Writer は User 列を書かない。locale の失敗で設定が残る現行の preferences 画面は、そのままである。
8. 9 キーの成功では ActivityPub を積まない。積まないので、enqueue 失敗で設定だけ残る、という形にはならない。

未保存キーへの同時 INSERT は一意制約に当たることがある。そのときはトランザクション全体を 1 回だけやり直す。2 回目も失敗したら 409 とする。値の再送で保存値がすでに一致するときは更新しないので、やり直し後もべき等である。

## 6. キャッシュ

比較した方式は次のとおりである。

| 方式 | 判断 |
| --- | --- |
| コミット後に `Rails.cache.write` で新しい値を入れる | 採らない。遅いリクエストの write が、後からコミットした新しいキャッシュを古い値で上書きできる |
| コミット後に触ったキーだけ `delete` する | P2-1 の暫定である。delete のあと古い write が走る穴は残る。Reader は DB なので読み取り API は正しい |
| revision をキーに含める | 後続 PR で getter まで揃える本方式である。古い write は古い revision のキーに当たり、読み手は見ない |
| Reader の DB 直接参照を続ける | 続ける。キャッシュを修復するために Reader へ write を入れない |

P2-1 の保証は次のとおりである。

- 正は DB の保存値である。
- トランザクションが戻った値はキャッシュへ書かない。キャッシュ操作は `after_commit` だけである。現行の `[]=` は 1 文ごとの `update!` の直後に write するので、複数キーの外側トランザクションに入れるとコミット前にキャッシュがdirtyになる。Writer は `[]=` を呼ばない。
- リクエストに無いキーの行もキャッシュも触らない。
- 読み取りは保存状態を変えない。GET は今までどおりである。
- キャッシュが一致しているとき、既存 getter と Reader の有効値は P1 と同じである。一致していないとき、getter はキャッシュ、Reader は DB である。P2-1 はこの差を自動修復しない。
- revision はキャッシュキーと変更通知の同じ番号にする。P2-1 では列も番号も増やす。delete は、revision が入るまでの暫定である。

コミット後の delete に失敗しても HTTP は成功のままにする。DB はすでに正であり、クライアントに再送させると別の更新とぶつかる。失敗はログに残し、短い回数だけ delete をやり直す。それでも残る getter の古さは、revision 方式で閉じる。

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
| `UserPreferences::ChangeSet` | 省略、値の設定、reset を操作に分ける。変更前は Reader の configured state を使う |
| `UserPreferences::Writer` | 検査、1 トランザクションの UPSERT または DELETE、`after_commit` の cache delete、結果を返す |
| `UserPreferences::WriteResult` | 変更したキー、変更前後の保存値、状態。HTTP の形にはしない |

DB 更新は `Setting.unscoped` をこのトランザクションの中で使う。`ScopedSettings#[]=` は使わない。

API コントローラ、OAuth、revision 列、Streaming は Writer の外である。Mastodon 互換の preferences と Credentials は、切り替え PR まで decorator のままである。

`WriteResult` の保存値は、API が後で `configured` と `effective` を組み立てる材料である。`public_value` は互換 JSON に使わない。一般 API の応答形は P2-2 で、P1-3 の読み取り文書に合わせる。

## 9. PR の分割とテスト

各 PR は単独でマージできる。前の PR の本番挙動を、次の PR が黙って広げない。

### P2-1 Writer

HTTP もフォームも変えない。節 8 の 4 クラスと spec だけを足す。

- 9 キー以外、派生キー、Schema では general だが定数に無いキーを拒否する。
- 省略は無変更、`null` は拒否、`false` と空文字列と明示的既定値と reset を区別する。
- 節 4 の拒否と、古い行を修復しないことを固定する。
- ポリシーだけの更新がバー行を変えない。同時更新でもバーをポリシーから生成しない。
- 2 キーの途中失敗で両方戻る。キャッシュ write が無く、delete は commit 後だけである。
- 戻したトランザクションはキャッシュを触らない。
- 同じ値の再送は行を更新しない。同時 INSERT の一意制約は 1 回やり直す。
- リクエスト外のキーが残る。
- Reader と getter は、キャッシュが一致するとき P1 と同じである。DB だけ変えた差は残す。
- ActivityPub を積まない。`users.locale` を変えない。

### P2-2 一般設定 PATCH

`PATCH /api/v1/fedibird/preferences` を足す。スコープは `write:preferences` だけとする。`write`、`write:accounts`、`read`、`read:preferences` では書けない。`read:preferences` を Credentials や Mastodon の preferences に足さない。

ボディは P1-3 のキー名だけを受ける。省略、拒否、保存の spec をコントローラで繰り返す。応答は変更後の読み取り文書である。キャッシュは `private, no-store` とする。既存 GET の JSON を回帰する。

### P2-3 reset

節 3 の POST で行を削除する。`null` の PATCH は 422 のままである。削除後の state は `:absent` であり、`:nil` ではない。

### P2-4 revision

User に単調増加の整数を 1 つ足す案をこの契約の前提にする。設定行と同じトランザクションで増やす。キャッシュキーにその番号を含める。getter をその番号経由に変えるかどうかは、その PR の中で互換を見て決める。`If-Match` が無い書き込みは、今までどおり後勝ちである。

列を `users` に足すか専用の 1 行テーブルにするかは、P2-4 の実装時にマイグレーションの都合で選ぶ。番号の意味は同じである。

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

決めたことは、9 キーの許可リスト、PATCH と `null` と reset の差、書ける値と読めるだけの値、DB を正とすること、`[]=` を使わないこと、コミット後の delete を暫定とすること、ActivityPub を 9 キーに付けないこと、節 9 の PR 順である。

実装時に残すのは次だけである。

- revision の列を `users` に置くか、1 行の別テーブルに置くか。意味は P2-4 で同じである。
- P2-5 の通知を、最初から outbox にするか、best-effort のあとで outbox に強化するか。9 キーの正には影響しない。
- Credentials とフォームを Writer に載せるときの、省略キー補完と `direct` の扱い。P2-6 の承認事項である。
