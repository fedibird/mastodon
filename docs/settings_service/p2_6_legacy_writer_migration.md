# Settings Service P2-6A レガシー保存の互換性契約

この文書は、Rails フォームと Mastodon Credentials API にある 9 キーの保存を `UserPreferences::Writer` へ移すときの互換性契約である。P2-4B（`p2_4b_cache_migration_design.md`、#432）は現行のキャッシュ境界を固定した。この PR は、移行後の保存動作、revision、通知、エラー、副作用の受け入れ条件を決める。本番の保存経路は切り替えない。

作業基点は `origin/fedibird` の `fcfccb2a4e669d864e1b6519abe83225ecd8bc7d` である。前提は次のとおり、いずれもこの基点に含まれている。

- #427 revision
- #431 `preferences_changed`
- #432 キャッシュ移行設計
- #434 preferences streaming
- #435 WebUI の受信

`p2_write_design.md` の P2-6 は、切替前に承認する差として「未知のバーと mode を正規化しなくなる」「Credentials の省略補完をやめる」「文字サイズの新規保存を整数だけにする」「`direct` を書くか」を挙げている。この契約は、初回移行ではその拒否側を採らない。公開 `WriteContract` は維持し、フォームと Credentials の既存スカラー入力は別の信頼済み経路で維持する。案Aを推奨する判断は維持する。初回移行で承認を取る保存動作の変更は、次の2つを並列に置く。

- 9 キーの同値再送を Writer の no-op に揃える。
- Credentials の非スカラー設定値を拒否する。

それ以外の従来スカラー互換性は維持する。この PR は本番の保存経路を実装しない。

## 1. 9 キーの移行契約

対象は次の 9 キーだけである。

```text
default_privacy
default_sensitive
default_language
show_translation_bar
translation_preferred_mode
new_features_policy
content_font_size
info_font_size
reduce_motion
```

`preferred_posting_language` は派生値である。行を持たない。書かない。`valid_locale_cascade(setting_default_language, users.locale, I18n.locale)` であり、`ja-JP` のような地域付き文字列は保存値のまま残り、派生 getter だけが地域を外して `ja` を返す。

保存の現状は P2-4B の節 1.4 のとおりである。フォーム 4 画面は `Settings::PreferencesController#update` を継承し、`UserSettingsDecorator#update` のあと、profile キーがパラメータに含まれるときだけ ActivityPub を積み、そのあと `current_user.update` で `users.locale`、`time_zone`、`chosen_languages` を書く。Credentials は `UpdateAccountService`、省略補完、Decorator、ActivityPub の順である。どちらも revision を動かさない。各 `Settings::ScopedSettings#[]=` が従来キーへ `cache.write` する。

移行後、この 9 キーの実変更は Writer が管理する。管理する、の意味は次のとおりである。

- User 行の `FOR UPDATE` と revision 更新が、そのキーの書き込みと同じトランザクションである。
- 実変更の COMMIT 後に、従来キーの cache delete と `preferences_changed` を出す。
- ROLLBACK した変更では通知しない。cache delete もしない。
- 公開 `Writer#apply` の入力検査は弱めない。レガシー入力は別の入口から、同じロックと revision と COMMIT 後フックを使う。

9 キー以外は Writer に通さない。高リスク設定（`noindex`、件数非表示、`enable_reaction`、`interactions`、禁止操作）は従来の `[]=` のままである。getter は P2-4C と P2-4D まで従来キーのままである。すべての保存経路の移行が終わるまで、revision 付き getter の読み取りを有効化しない。

## 2. 公開 API とレガシー入力の境界

公開の `PATCH /api/v1/fedibird/preferences` と reset は、今の `UserPreferences::WriteContract` のままである。`Writer#apply` は null を拒否し、`direct` と `""` と `ja-JP` と文字サイズの文字列と `"0"` / `"1"` と未知のバーと `original` を拒否する。この許可範囲を、フォームや Credentials の互換のために広げない。

フォームと Credentials には、公開 `apply` とは別の信頼済み入力経路を置く。この経路が行うのは、旧入力の型変換、保存直前の正規化、レガシー値の許容である。P2-6B が名前を決める。この文書が固定するのは境界である。

レガシー経路が守るもの:

- 受けるキーは上の 9 キーだけである。`preferred_posting_language` も、高リスク設定も、未知の `var` も受けない。
- `Hash`、`ActionController::Parameters`、`Array` を値として保存する汎用バイパスを設けない。今日の Decorator は、文字列キーに届いた `Hash` と `Array` を YAML のまま書く。Credentials は `source` の値を型検査せず Decorator へ渡す。JSON オブジェクトは未許可の `ActionController::Parameters` として保存され、JSON 配列は Ruby の `Array` として保存される。フォームの strong parameters はスカラー許可のキーに対する `Hash` を落とす。レガシー経路は Credentials のこの抜けを維持しない。
- 公開 `apply` が拒否するレガシーなスカラーは、この経路では維持する。節 3。
- null を公開 `apply` の許可値にはしない。空文字 boolean がキャストされた `nil` を保存する必要がある場合は、公開 `apply` を通さず、Writer の内部入口で 9 キーの nil 行だけを書く。節 4。
- 外側のトランザクションには入らない。`Writer` は開いたトランザクションを `OpenTransaction` で拒否する。`current_user.update` や `UpdateAccountService` と一つのトランザクションにまとめない。

レガシー経路をコントローラへ繋ぐのは P2-6C と P2-6D である。この PR では繋がない。

## 3. 入力値の決定表

二つの案を比べる。

- 厳格化: フォームと Credentials も公開 `WriteContract` の型と許可値だけを受け、外れた入力は拒否する。`p2_write_design.md` が切替前の承認項目として挙げた差は、こちらに近い。
- 互換維持: 既存のフォームと Credentials が今日受け入れているスカラーを、レガシー経路で同じ結果にする。公開 PATCH の許可範囲は変えない。

初回移行の推奨は互換維持である。既存クライアントの入力を、移行を理由に 422 にしない。

| キー | 今日の保存 | 厳格化すると拒否されるもの | 初回移行の推奨 |
| --- | --- | --- | --- |
| `default_privacy` | フォームも Credentials も検査しない。`direct` も `""` も保存できる。フォームの選択肢は `Status.selectable_visibilities`（`direct` と `limited` を除く）だが、コントローラはそれを再検査しない | `direct`、`limited`、`""`、非文字列 | フォームの文字列を維持する。Credentials の `direct` はレガシー経路で維持する。公開 PATCH は今どおり拒否する |
| `default_sensitive` | `ActiveModel::Type::Boolean`。`"0"` は `false`、`"1"` は `true` | `"0"`、`"1"`、空文字、null | 同じキャストを維持する |
| `default_language` | 検査しない。`ja-JP` も保存する。派生言語は別計算で、`ja-JP` の派生値は `ja` | `ja-JP`、`""`、`invalid`。`zh-CN` など `valid_locale?` が真の地域付きは公開契約にも含まれる | 保存済みの文字列と地域付き文字列をレガシー経路で維持する。派生キーは書かない |
| `show_translation_bar` | 書く直前に `TranslationPreferences.normalize_visibility`。参照するポリシーは、同じリクエストの新しいポリシーより前に getter が見る値 | `nope`、`true` / `false`、空文字。正規化結果ではなく入力そのものを検査する | 保存直前の正規化を維持する。節 5 の旧ポリシーを使う |
| `translation_preferred_mode` | 書く直前に `normalize_preferred_mode`。未知と `original` は `translated` として保存する | `original`、`nope` | 保存直前の正規化を維持する |
| `new_features_policy` | 文字列のまま。許可集合を検査しない。`nope` も保存される | `conservative` / `default` / `tester` 以外 | レガシーの文字列保存を維持する。公開 PATCH の 3 値制限は維持する |
| `content_font_size` | フォームの range は文字列を送る。Decorator は `STRING_KEYS` なので `"18"` のまま。範囲検査はない | 文字列、範囲外の整数、`18.0` | フォームからの文字列保存を維持する。公開 PATCH は整数 10..20 のまま |
| `info_font_size` | 上と同じ | 上と同じ | 上と同じ |
| `reduce_motion` | boolean キャスト | `"0"`、`"1"`、空文字、null | 既存の boolean キャストを維持する |

不正なスカラーをレガシー経路で受け入れても、公開 PATCH の許可範囲には加えない。`Hash`、未許可の `ActionController::Parameters`、`Array`、未知キーは互換入力として維持しない。今日それらを保存できるのは、Decorator が型を見ないからである。フォームの strong parameters は未知キーと、スカラー許可へ渡した `Hash` をすでに落とす。Credentials だけが非スカラーを Decorator まで届ける。P2-6D でこれを拒否する。拒否するのは公開 API の拡大ではない。

## 4. nil、空文字、同値再送

`UserSettingsDecorator#change?` は `!settings[key].nil?` である。キーが無いことと、値が `nil` であることは書かない。行は削除しない。`updated_at` も動かない。従来キーへの `cache.write` もしない。

boolean の空文字は別である。`""` は `nil` ではないので `change?` は真になる。そのあと `ActiveModel::Type::Boolean#cast` が空文字を `nil` にする（Rails 6.1 の `FALSE_VALUES` には空文字が無く、`cast_value` が `""` を `nil` にする）。その `nil` が `[]=` で保存される。行は残る。YAML は `"---\n"` で、読み出しは `nil` である。未保存時の `false` には戻らない。getter も `nil` を返す。

この差を固定する。HTML フォームの urlencoded では、コントローラへ渡した `nil` は空文字になる。privacy のその空文字は保存され、既存値を上書きする。JSON の null とは違う。画面の checkbox は Simple Form が `"0"` か `"1"` を送り、空文字そのものは送らない。空文字 boolean は、空文字が Decorator まで届いたときの結果として固定する。

| 入力 | 今日 | レガシー経路の推奨 |
| --- | --- | --- |
| 文字列キーの実際の `nil` | スキップ。既存行は残る。JSON の null はここへ届く | 同じ。公開 `apply` は `null_value` で拒否するので、そこに押し込まない |
| boolean キーの `nil` | スキップ | 同じ |
| boolean の `""` | `nil` 行を書く。既存の `true` も `nil` になる | 同じ結果を Writer の内部入口で書く。公開 `apply` は null のまま拒否する |
| boolean の `"0"` / `"1"` / `false` / `true` | `false` / `true` / `false` / `true` | 同じキャスト結果を書く |

空文字 boolean の `nil` 行は、reset ではない。reset は行を削除して state を `:absent` にする。空文字は state `:nil` の行を残す。Reader はこの二つを区別する。レガシー経路も区別する。

同値再送は、今日と Writer で違う。Credentials の非スカラー拒否と並べて、初回移行の承認事項にする。節 16。

今日の `ScopedSettings#[]=` は、値が同じでも `update!` と `Rails.cache.write` を呼ぶ。YAML が同一なら ActiveRecord は UPDATE を出さず、`settings.updated_at` は動かない。それでも Rails 6.1 の `_update_record` は、更新列が空のとき `_trigger_update_callback` を真にする。外側トランザクションが無い本番では、`update!` の COMMIT で `RailsSettings::Base.after_commit :rewrite_cache` が走り、従来キーへもう一度 `cache.write` する。`[]=` の 48 行目の `cache.write` はその直後にも走る。revision は動かない。`preferences_changed` は出ない。この `[]=` の即時 write は transactional test でも観測できる。`rewrite_cache` は実 COMMIT のあとなので、transactional test の ROLLBACK では走らない。

Writer の同値は no-op である。`Setting#save!` を呼ばないので、`rewrite_cache` も `CacheDeletion` も走らない。revision、`updated_at`、通知は動かない。事前に入っていた従来キーは残る。P2-6 後の 9 キーはこちらに揃える。高リスク設定の `[]=` は対象外なので、同値でも今の write のままである。

### Writer の実変更と Setting の after_commit

Writer 自身は値を `cache.write` しない。`insert_row` と `update_row` は `Setting#save!` を呼ぶ。`Setting` は `RailsSettings::Base` なので、固定 gem rails-settings-cached 0.6.6（revision `86328ef0bd04ce21cc0504ff5e334591e8c2ccab`）の `lib/rails-settings/railtie.rb` が create と update に登録した `after_commit :rewrite_cache` が走る。`lib/rails-settings/base.rb` の `rewrite_cache` は `Rails.cache.write(self.class.cache_key(var, thing), value)` である。`delete_row` は `delete_all` であり、destroy の `expire_cache` は走らない。

これは `ScopedSettings#[]=` の即時 write とは別である。Writer のトランザクション内の INSERT / UPDATE と、COMMIT 後のモデルコールバックを分けて扱う。

`spec/lib/user_preferences/writer_setting_commit_cache_spec.rb` は `use_transactional_tests = false` で SQL の `COMMIT` を記録した。作成した User と Setting と revision だけを削除する。

| 操作 | SQL COMMIT のあと | `apply` 終了時の従来キー | Reader |
| --- | --- | --- | --- |
| 新規 `Setting#save!` | `rewrite_cache` が新しい値を write し、その次に `CacheDeletion` が同じ従来キーを delete する。どちらも COMMIT より前には走らない | 残っていない | DB の新しい値 |
| 既存行の `Setting#save!` | 上と同じ。write する値は更新後の値であり、削除前に入っていた古いキャッシュではない | 残っていない | DB の新しい値 |
| 同値 no-op | 対象キーの write も delete も無い。`save!` が無いのでモデルコールバックも無い。User トランザクションの COMMIT 自体はある | 呼び出し前の値が残る | DB の既存値 |
| reset（`delete_all`） | `CacheDeletion` の delete だけ。`rewrite_cache` も `expire_cache` も無い | 残っていない | state `:absent` |

観測した順は write、その次に delete である。逆順は出ていない。逆順になると delete の直後に `rewrite_cache` が値を書き戻し、終了時に従来キーが残る。今の登録順は `save!` がモデルを先に積み、Writer が後から `CacheDeletion` を積むので、write が先になる。この PR はその登録順を変えない。

P2-6B は `rewrite_cache` を抑止しない。`RailsSettings::Base` 全体のコールバックも変えない。両方成功したあとの従来キーは delete 済みである。write する値は新しい値なので、delete の前に落ちるとキャッシュには新しい値が残る。Writer のコード自体は値を write しない。モデルコールバックを含めると、COMMIT 後に write してから delete する。

Reader は DB を読む。getter は従来キーを読むので、終了時にキーが無いことは P2-4B の delete 契約と一致する。write と delete のあいだだけ、従来キーに新しい値が入る。

## 5. 案Aと案B

今日のフォームは 1 キーずつコミットする。Decorator の順は次である。

1. `NESTED_KEYS`: `notification_emails`、`interactions`。9 キーではない。
2. `STRING_KEYS` の配列順。9 キーでは `default_privacy`、`default_language`、`translation_preferred_mode`、`show_translation_bar`、`new_features_policy`、`content_font_size`、`info_font_size`。
3. `BOOLEAN_KEYS` の配列順。9 キーでは `default_sensitive` が `reduce_motion` より前。`noindex` や `enable_reaction` や `disable_post` は、この boolean 列の中で 9 キーと混ざる。

`content_font_size` で例外になると、それより前の `default_privacy` と `default_language` は残り、`info_font_size` と `reduce_motion` と、それより後ろの `noindex` は保存されない。例外は `current_user.update` と ActivityPub に届く前に出る。`users.locale` は変わらない。配送も積まれない。

### 案A: 旧部分保存を維持する

Decorator の既存キー順のまま処理する。9 キーだけを、1 キーにつき Writer のトランザクション 1 回で書く。高リスク設定とネストした設定は、今の位置で `[]=` のままである。

- 実変更 1 キーにつき revision が 1 進む。
- 実変更 1 キーにつき、その COMMIT のあと `preferences_changed` が 1 回出る。
- 同値の 9 キーは no-op で、revision も通知も cache delete も動かない。
- 途中失敗では、成功した先行キーが残る。失敗したキーのトランザクションは ROLLBACK し、そのキーの通知は出ない。後続キーは呼ばれない。
- User 行ロックを持っているのは、各キーの BEGIN から COMMIT までである。キーとキーのあいだはロックしない。今日と同様、別リクエストがその隙間に入れる。
- 9 キーの正規化は、そのキーを書く直前に行う。`show_translation_bar` は `new_features_policy` より前なので、正規化が読むポリシーは古い getter のままである。

利点は、保存順、部分保存、副作用の位置を維持しやすいことである。欠点は、複数キーのフォームが複数 revision と複数通知になることと、User 行ロックと SQL の回数がキー数だけ増えることである。#435 の WebUI は通知のたびに再取得する。案Aでは、一つのフォームが変えたキーの数だけ再取得が走る。これを 1 回にまとめるのは案Bであり、初回移行の黙認変更にはしない。

### 案B: 9 キーをまとめて Writer へ渡す

フォーム入力から 9 キーを抽出し、型変換と互換正規化のあと、1 トランザクションで保存する。高リスク設定は別の保存処理のままである。比較のための具体的な順は次のとおりである。

1. 書き始める前の `setting_new_features_policy` をスナップショットする。
2. 9 キーをそのスナップショットで正規化し、1 回の Writer トランザクションで書く。
3. そのあと、9 キー以外を今の Decorator 経路で書く。

結果は次のように変わる。

- 実変更が一つでもあれば revision は 1 だけ増える。通知も 1 回である。
- 9 キーの途中失敗は、9 キー全部を ROLLBACK する。先行キーは残らない。通知は出ない。
- 9 キーの失敗では、後ろに回した高リスク設定も保存されない。今日、ネストした `interactions` は文字列キーより前にコミットするので、この境界は変わる。
- 9 キーがコミットしたあとに高リスク設定が失敗すると、9 キーは残り、高リスクだけが欠ける。今日は文字列の失敗で、まだ書いていない boolean の高リスクが欠ける。
- 正規化にリクエスト内の新しいポリシーを使うと、節 6 の結果が `target` から `never` に変わる。案Bを採る場合も、スナップショットは書く前のポリシーにする。この正規化の変更は案Bに含まれない。別の仕様変更である。

利点は、設定変更を一括して反映でき、revision と通知が少ないことである。欠点は、旧 Decorator の保存順と部分保存が変わることである。

### 件数の比較

一つのリクエストが 9 キーをすべて別の値へ変え、加えて `noindex` を含む場合。

|  | 今日 | 案A | 案B |
| --- | --- | --- | --- |
| 9 キーの revision | 0 のまま | +9 | +1 |
| `preferences_changed` | 出ない | 9 回。各 COMMIT のあと | 1 回 |
| 同値だけの再送 | `[]=` が即時 `cache.write`。本番では `rewrite_cache` も走る。`updated_at` は動かない | no-op。revision も通知も cache delete も無い | 同じ no-op |
| `noindex` | `[]=`。revision 無し | 同じ。9 キーの Writer には通さない | 同じ |
| ActivityPub | profile キーがパラメータにあれば 1 回。値の変化は見ない | 同じ。9 キーの no-op では消さない | 同じにするなら、9 キーの成否と高リスクの順を決めたあとに、今日と同じ「profile キーの有無」で積む |
| `content_font_size` で失敗 | privacy と language は残る。font 以降と `noindex` は無い。locale は変わらない。配送は無い | privacy と language は各自の revision と通知を残す。font は ROLLBACK。以降は呼ばれない。配送は無い | 9 キーは全部 ROLLBACK。通知は無い。高リスクを後ろに回すなら `noindex` も無い |

### 推奨

初回移行は案Aを推奨する。既存の保存順、部分保存、旧ポリシーでの正規化、profile キーによる配送判定を、Writer のロックと revision と COMMIT 後フックに載せる最小の変更だからである。

この推奨は P2-6B の実装前にレビューする。レビューが案Bを採る場合、P2-6B のアダプタは 1 トランザクションに作り直し、上の部分保存と revision 件数と通知件数の変化をその PR の承認事項にする。正規化に新しいポリシーを使う変更は、案Bを選んでも勝手に入れない。

## 6. 翻訳バーとポリシーの順序

`show_translation_bar` は `new_features_policy` より前に処理される。両方を同じリクエストで変えるとき、バーの正規化は古いポリシーを使う。

- 旧ポリシー: `default`（未保存の有効値も `default`）
- 新ポリシー: `conservative`
- バー入力: `nope`

保存されるバーは `target` である。`never` ではない。そのあとポリシー行は `conservative` になる。

移行後もこの結果を維持する。複数キーを Writer へまとめる実装が、正規化の時点で新しいポリシーを読むように黙って変えない。案Aはキー順を保てばこの結果になる。案Bは、書く前の getter をスナップショットした場合だけ同じ結果になる。

読み取り側の `User#setting_show_translation_bar` は、保存済みの未知値をメモリ上で正規化するだけで、行を書き戻さない。これは P2-4B の節 4.9 のとおりであり、保存時の正規化とは別である。P2-6 で変えない。

## 7. フォーム 4 画面の順序

4 画面は同じ `Settings::PreferencesController#update` と、同じ `user_settings_params` を使う。サブクラスが変えるのは成功時のリダイレクト先だけである。

| 画面 | コントローラ | 成功時の遷移 | 画面上の 9 キー |
| --- | --- | --- | --- |
| appearance | `Settings::Preferences::AppearanceController` | `settings_preferences_appearance_path` | `content_font_size`、`info_font_size`、`reduce_motion`、`show_translation_bar`、`translation_preferred_mode` |
| other | `Settings::Preferences::OtherController` | `settings_preferences_other_path` | `default_privacy`、`default_language`、`default_sensitive`、`new_features_policy` |
| notifications | `Settings::Preferences::NotificationsController` | `settings_preferences_notifications_path` | 入力は無い。`notification_emails` と `interactions` |
| safety | `Settings::Preferences::SafetyController` | `settings_preferences_safety_path` | 入力は無い。禁止操作などの高リスク |

許可リストは 4 画面で共通である。safety へ `setting_content_font_size` を送っても文字列のまま保存される。移行は画面テンプレート単位ではなく、この共通アクションで行う。appearance と other だけを Writer にすると、notifications と safety に送られた 9 キーが `[]=` のまま残る。

画面に出てくる profile キーは other にある。`profile_change?` が見るのは値の変化ではなく、送信ハッシュのキーである。

```text
setting_noindex
setting_hide_network
setting_hide_statuses_count
setting_hide_following_count
setting_hide_followers_count
setting_enable_reaction
```

other が `setting_noindex` を含めば、値が既定のままでも ActivityPub を 1 回積む。9 キーだけでは積まない。appearance の 9 キーだけでも積まない。積む位置は、Decorator が例外なく返ったあと、`current_user.update` より前である。

`current_user.update` が失敗しても、すでに積んだ配送は取り消されない。失敗時はリダイレクトせず `:show` を描く。`users.locale` は保存されない。設定行は残る。`locale`、`time_zone`、`chosen_languages` の不正値は `sanitize_*` が `nil` にするので、それだけでは検証失敗にならない。失敗し得るのは、設定保存のあとに走る User 検証である。今日それは `setting_max_frequently_used_emojis` の数値検証で再現できる。レガシー経路を `current_user.update` と同じトランザクションに入れると、この「設定は残り、User 列は残らない」が変わる。入れない。

## 8. Credentials の副作用と順序

現行の順は次のとおりである。初回移行でもこの順を維持する。

1. `UpdateAccountService` が `accounts` を `update!` する。成功時に、locked が外れていればフォローリクエスト承認を `AuthorizeFollowWorker.push_bulk` で積み、`VerifyAccountLinksWorker` を積み、ハッシュタグ抽出を行う。User の settings 行は書かない。
2. `source` が blank でなければ、省略キーをその時点の getter で補完する。
3. `UserSettingsDecorator` が 3 キーを書く。
4. ここまで例外が無ければ `ActivityPub::UpdateDistributionWorker` を積む。設定が無変更でも積む。
5. `REST::CredentialAccountSerializer` がレスポンスを描く。`source` の 3 キーは Reader が DB から読む。

対象は次の 3 キーだけである。

```text
source.privacy   -> default_privacy
source.sensitive -> default_sensitive
source.language  -> default_language
```

補完は `fetch` である。キーが無ければ今の getter を入れる。キーがあり値が `nil` なら `nil` を入れ、Decorator はそれをスキップする。

`{"source":{"language":"de"}}` で privacy と sensitive が未保存なら、privacy は locked なら `private`、そうでなければ `public` を新規保存し、sensitive は `false` を新規保存する。language の getter が `nil` のとき、省略された language は行を作らない。`nil` スキップだからである。

補完が読む getter は、`UpdateAccountService` のあとである。同じ PATCH で locked を外すと、未保存 privacy の補完値は `private` ではなく `public` になる。移行で補完をアカウント更新の前に移すと、この結果が変わる。移さない。

`source.privacy = null` は保存済みの privacy を変えない。省略された sensitive は、未保存なら `false` を明示的に書く。null と省略は違う。

`source.privacy = "direct"` は Credentials では保存できる。公開 Preferences PATCH は拒否する。レガシー経路でも保存でき、公開 `apply` では拒否したままにする。

認可は `write` または `write:accounts` のままである。`write:preferences` だけでは 403 であり、アカウントも設定も書かない。Credentials 更新に `write:preferences` を新たに要求しない。

設定保存が `UpdateAccountService` のあとで失敗した場合、アカウント列の変更、フォローリクエスト承認の enqueue、リンク検証の enqueue はすでに終わっている。設定行は、失敗したキー以降が残らない。ActivityPub は積まれない。これを一つのトランザクションにまとめてアカウント更新まで戻すのは、この契約の変更である。やらない。

省略補完をやめ、PATCH に無いキーを無変更にする案は、公開 Preferences API の省略に合わせる別の仕様変更である。初回移行には入れない。補完はコントローラに残し、レガシー経路は補完済みの値を受け取る。経路の中で再度 getter 補完しない。

## 9. revision と通知

今日、フォームと Credentials は revision を増やさない。#431 の `preferences_changed` も出ない。P2-4B の節 3.1 のとおり、revision は Writer がコミットした変更回数だけを表す。

案Aを採ったあと、フォームと Credentials の 9 キーの実変更もこの回数に入る。「Decorator は数えない」は、その経路が Writer に載った時点で終わる。高リスク設定は数えないままである。

| 出来事 | revision | 通知 | キャッシュ |
| --- | --- | --- | --- |
| 9 キーの実変更 1 件（案A） | +1 | COMMIT 後に 1 回。changed key はその 1 キー | SQL COMMIT のあと、`rewrite_cache` が従来キーへ新しい値を write し、次に `CacheDeletion` が delete する。終了時はキーが残らない |
| 同じリクエストの実変更 N 件（案A） | +N | N 回 | 各キーの save が write し、そのあと変更キーを delete する。終了時はそれらのキーが残らない |
| 同値、nil スキップ、空の source | 動かない | 出ない | 9 キーの Writer は write も delete もしない。高リスクの `[]=` は今どおり write し得る |
| 入力エラーでそのキーのトランザクションが ROLLBACK | 動かない | 出ない | delete しない |
| 先行キーがコミットしたあとの後続失敗（案A） | 先行分だけ残る | 先行分はすでに出ている。失敗キーと後続は出ない | 先行キーだけ delete 済み |
| 公開 `apply` の複数キー | 今どおり +1 | 1 回 | 変更した行ごとに `rewrite_cache` が write し、そのあと `CacheDeletion` が変更キーを delete する。終了時はキーが残らない |

通知の payload はこの契約では変えない。件数だけが案Aで増える。payload をまとめる、または WebUI の再取得を間引くのは別承認である。

空文字 boolean の `nil` 行を新規に書く、または `true` から `nil` へ変えるのは実変更である。案Aでは revision と通知の対象になる。すでに `nil` の行へ同じ `nil` を書くのは同値 no-op である。

## 10. 途中失敗と切り戻し

今日の失敗位置は節 5 のとおりである。案Aは、失敗した 9 キーだけを Writer の ROLLBACK にし、先行キーのコミットを残す。先行キーの通知は戻さない。後続は実行しない。`current_user.update` と ActivityPub には進まない。

案Bは 9 キーをまとめて戻す。この差が、案Bを初回に採らない理由の一つである。

この PR の切り戻しは、文書と characterization を戻すだけである。本番の保存は変わっていない。

P2-6C 以降の切り戻し:

- フォームまたは Credentials の配線を、Decorator の `[]=` に戻す。戻した経路は再び revision を増やさない。
- すでに増えた `user_preference_revisions` は消さない。0 に戻すと、通知の購読者が番号の後退を見る。P2-4B の節 8 と同じである。
- 設定行は戻さない。部分保存で残った値も、成功した Writer の値も、データ修正の対象にしない。
- revision 付き getter を、切り戻しや移行の途中で有効にしない。

Writer を外側トランザクションに入れて失敗ごと全部戻す実装は、`OpenTransaction` で拒否される。その拒否を外して原子性を足すのは、案Aの部分保存を捨てる変更である。この契約ではやらない。

## 11. ActivityPub と User 列

移行で変えない。

- フォームの配送判定は、profile キーが入力に含まれるかである。9 キーの値や、User 列の成否では判定しない。
- Credentials は、アカウント更新と設定保存が両方成功したあとで配送する。設定保存の失敗では積まない。アカウント更新の中で積んだフォローリクエスト承認とリンク検証は、その失敗では戻さない。
- `users.locale`、`time_zone`、`chosen_languages` の保存位置は、設定保存のあとである。Writer をこの `update` と同じトランザクションに入れない。
- アカウントの locked が外れたときのフォローリクエスト承認は、`UpdateAccountService` の中のままである。
- リンク検証とハッシュタグ抽出は、`UpdateAccountService` の中のままである。
- 高リスク設定の保存処理は `[]=` のままである。

将来、案Bや省略補完の廃止で部分保存や配送順が変わる場合は、その PR で節 5 と節 8 のどの行が変わるかを書いて承認を取る。キャッシュ移行や revision 付き getter を理由に、この順を変えない。

## 12. P2-6B〜6E の実装とテストの分割

各 PR は単独で戻せる。公開 `Writer#apply` を弱めない。getter の読み取りは従来キーのままである。

| PR | 内容 | 本番の保存 |
| --- | --- | --- |
| P2-6A（この PR） | この契約と、現行挙動の characterization | Decorator と `[]=` のまま |
| P2-6B | 案Aのレガシー入口。9 キーだけ、1 キーずつ、節 3 と節 4 の変換で Writer のロックと revision と COMMIT 後フックを使う。コントローラには繋がない。公開 `apply` は変えない | 変わらない |
| P2-6C | 4 画面の共通 `update` で、9 キーだけを P2-6B の入口へ切り替える。高リスクとネストは `[]=` のまま。配送判定と `current_user.update` の位置は維持する | フォームの 9 キーが Writer |
| P2-6D | Credentials の 3 キーを同じ入口へ切り替える。省略補完、null スキップ、`direct`、`write` / `write:accounts`、アカウント更新との順は維持する | Credentials の 3 キーが Writer |
| P2-6E | 本番の 9 キーに対する直接の `[]=` を消す。Decorator の 9 キー分岐を削除する。safety と notifications を含む共通アクションに経路が残っていないことを確認する | 9 キーの本番保存は Writer だけ |

P2-6B が実装する境界は次のとおりである。

- 入口は公開 `apply` ではない。`apply` の `validate!` はレガシー値を拒否するため、そこにキャスト前のフォーム値を渡さない。
- キーの許可リストは 9 キーだけである。余分なキー、`Hash`、未許可の `ActionController::Parameters`、`Array` は、1 キーも書かずに拒否する。
- `nil` 入力は Writer を呼ばずスキップする。空文字 boolean はキャスト後の `nil` を、公開契約を緩めるのではなく内部入口で保存する。
- バーの正規化は、そのリクエストで 9 キーを書き始める前のポリシー getter を使う。
- 1 キーごとに、開いたトランザクションを拒否し、User 行をロックし、実変更だけ revision を進め、COMMIT 後に cache delete と `preferences_changed` を出す。
- 同値は ChangeSet の no-op に任せる。`save!` が無いので `cache.write` も `rewrite_cache` も走らない。
- 実変更の `Setting#save!` が出す `rewrite_cache` は抑止しない。SQL COMMIT のあと write、その次に delete、その次に `preferences_changed` である。`RailsSettings::Base` 全体のコールバックは変えない。
- 入口は `UserPreferences::LegacyWriter#update` である。1 呼び出しが 1 キーで 1 トランザクションである。
- コントローラ、Redis のキー形、ストリーミング、WebUI は P2-6B では変えない。P2-6C でフォームだけがこの入口を使う。

P2-6B のテストは、この入口を直接呼ぶ。実 COMMIT の cache delete と通知は `use_transactional_tests = false` で確認する。transactional test の中で「通知が無い」ことを、ROLLBACK される外側トランザクションだけで証明しない。

P2-6C はフォームの 9 キーをこの入口へ移した。Credentials の characterization は旧経路のままである。

## P2-6C の実装

フォームの 9 キーは Writer へ移行済みである。`Settings::PreferencesController#user_settings` が、1 回の update につき `LegacyWriter` を 1 つ作る。初期化時にポリシー getter を 1 回固定する。4 画面はこのメソッドを共有する。`UserSettingsDecorator.new(user)` のままでは従来の `[]=` である。Credentials はこちらを使うので、P2-6D まで revision は増えない。

Decorator の `NESTED_KEYS`、`STRING_KEYS`、`BOOLEAN_KEYS` の順は変えていない。ループの中で 9 キーだけを `LegacyWriter#update` へ渡す。文字列はキャスト前の入力、boolean もキャスト前の入力である。翻訳バーは Decorator で正規化せず、LegacyWriter がスナップショットした旧ポリシーで正規化する。`default` のあいだに `nope` と `conservative` を同時に送ると、バーは `target`、ポリシーは `conservative` である。ポリシー行が nil でも、その nil がスナップショットになる。

9 キーの実変更は revision と `preferences_changed` の対象である。1 フォームで複数キーが変わると、案Aのとおりキーごとに revision が進み、通知もキーごとに COMMIT 後へ出る。通知は ActivityPub より先になることがあり、まとめない。同値再送は `save!` を呼ばない。`updated_at`、revision、cache write/delete、通知は動かない。この no-op は 9 キーだけである。高リスク設定とネストした設定の同値保存は従来の `[]=` のままである。

`content_font_size` で失敗したとき、それより前の `default_privacy` と `default_language` は残り、それぞれの revision と通知も残る。失敗キーは ROLLBACK し、通知しない。`info_font_size`、`reduce_motion`、`noindex` は実行されない。`users.locale` は更新されない。ActivityPub は積まない。`InvalidInput` だけをフォームが捕捉し、422 で再表示する。先行キーは戻さない。DB 例外や `OpenTransaction` は入力エラーにしない。

profile 配送は、値の変化ではなく PROFILE_KEYS がパラメータにあるかで決まる。9 キーの revision では配送しない。profile キーが同値でも配送する。位置は Decorator の成功後、`current_user.update` の前である。

P2-6D に残るもの: Credentials の省略補完、null スキップ、`direct`、非スカラーの現在の保存、`write` / `write:accounts`、アカウント更新後の配送、revision が増えないこと。

## 13. P2-4C の開始条件

P2-4B の節 6 と節 7 と節 10 を変えない。対応は次のとおりである。

- 段階 D（revision 付き getter の読み取り、P2-4D）は、9 キーの本番保存が Writer だけになり、そのコードが全 Puma worker と Sidekiq に出たあとにしか始められない。それが P2-6E の完了と、P2-4B の確認 C である。
- P2-4C（段階 B。COMMIT 後に接尾辞キーも delete し、値は write しない。読み取りは従来キー）のコードを P2-6 より前に置いても、Decorator が番号を動かさないあいだは段階 D の許可にならない。P2-4B がすでにそう書いている。
- 段階 B を「完了」と呼んでよいのは、P2-6E が全プロセスに入り、9 キーの直接 `[]=` が残っていないときである。それより前に段階 D のプロセスを出さない。
- P2-6 の間、getter は従来キーのままである。P2-4C も従来キーを読む。読み替えは P2-4D だけが行う。
- P2-6 が Decorator の遅い `cache.write` を 9 キーから外しても、P2-4B の節 4.10 の cache-aside 再充填は残る。それを消すのは段階 D である。

## 14. P2-6B〜6E の受け入れ条件

次を満たすことを必須とする。

- 公開 `Writer#apply` の厳格な契約を弱めない。
- レガシー 9 キーの実変更は必ず Writer が管理する。
- User 行ロックと revision 更新が同じトランザクションである。
- cache delete と `preferences_changed` は COMMIT 後である。
- ROLLBACK した変更では通知しない。
- 既存フォームと Credentials の権限を増やさない。`write:preferences` を Credentials に要求しない。
- 9 キー以外の保存処理を Writer へ誤って通さない。
- Writer を外側トランザクションへ入れない。
- 9 キーへの直接 `ScopedSettings` 書き込みが、P2-6E の時点で本番から消える。
- getter は P2-4C / P2-4D まで従来キーを維持する。すべての保存経路の移行が終わるまで、revision 付き getter の読み取りを有効化しない。

加えて、案Aを採る場合は次も維持する。

- 節 3 のスカラー結果。`direct`、`""`、`ja-JP`、文字サイズの文字列、boolean キャスト、ポリシーの任意文字列。
- 空文字 boolean の `nil` 行と、`nil` 入力のスキップ。
- バーは古いポリシーで正規化する。例の結果は `target` である。
- mode の未知値は `translated` として保存する。
- 部分失敗で先行キーが残り、後続キーは保存されない。
- Credentials の省略補完と、アカウント更新のあとに getter を読むこと。
- profile キーの有無による配送と、Credentials の配送位置。
- 設定保存のあとに User 列の更新が失敗しても、設定は残り、配送は profile キーがあればすでに積まれている。

## 15. この PR の characterization

本番コードを変えずに固定できるものだけを、`spec/lib/user_preferences/legacy_writer_migration_boundary_spec.rb` に置いた。P2-4B の `cache_migration_boundary_spec.rb` がすでに見ている「9 キーを保存しても revision が 0」の単純な繰り返しは置いていない。

固定した現行挙動は次のとおりである。

1. フォームの文字サイズは文字列で保存される。公開契約は文字列を `invalid_type` にする。
2. `"0"` と `"1"` は `false` と `true` になる。
3. boolean の空文字は `nil` 行になる。getter も `nil` である。
4. `nil` 入力は保存しない。`updated_at` も cache.write も動かない。兄弟キーは保存される。
5. バーの `nope` は、同時に送った `conservative` ではなく、保存前の `default` で `target` になる。
6. mode の `original` は `translated` として保存される。
7. privacy の `direct` と `""` は保存される。getter もその値である。公開契約は `invalid_value` にする。
8. `ja-JP` は保存される。派生 getter は `ja` である。派生キーの行は無い。
9. 同値再送は `updated_at` を動かさず、従来キーへ `cache.write` する。
10. `content_font_size` の失敗で、先行の privacy と language は残る。
11. 同じ失敗で、後続の font、`reduce_motion`、`noindex` は保存されない。locale も変わらず、配送も積まれない。
12. appearance の 9 キーだけでは profile 配送が起きない。
13. other の profile キーは、値が変わらなくても配送を積む。9 キーだけでは積まない。
14. 設定保存のあと User 列の更新が失敗すると、設定と、profile キーがあれば配送は残り、locale は変わらず、応答はリダイレクトではない。
15. Credentials の language だけの PATCH は、未保存の privacy と sensitive を有効値で保存する。
16. 同じ PATCH で locked を外した場合、補完される privacy は更新後の `public` である。
17. `source.privacy = null` は保存済み privacy を変えない。省略された sensitive は `false` で保存される。
18. Credentials は `direct` を保存する。公開契約は拒否する。
19. アカウント更新のあと設定保存が失敗すると、表示名と locked とフォローリクエスト承認とリンク検証は残り、設定は保存されず、ActivityPub は積まれない。
20. `write` と `write:accounts` は source を保存できる。`write` は `write:preferences` を含まなくてよい。`write:preferences` だけは 403 で、設定もアカウントも書かない。
21. 高リスク設定と `interactions` は保存され、revision は 0 のままである。公開契約は `unknown_key` にする。safety の共通アクションも、送られた文字サイズを文字列で保存する。
22. フォームは非スカラーの privacy と未知キーを保存しない。Credentials は今日、privacy の JSON オブジェクトを未許可の `ActionController::Parameters` として、language の JSON 配列を `Array` として保存する。後者は P2-6D で拒否する対象であり、公開契約はすでに `invalid_type` である。フォームの urlencoded で privacy に `nil` を渡すと空文字として保存される。JSON の null とは違う。

未保証の並行順序は成功条件にしていない。失敗位置は Decorator の配列順であり、競合の勝ち負けではない。Writer の create、update、no-op、reset が SQL COMMIT の前後でキャッシュをどう触るかは、`spec/lib/user_preferences/writer_setting_commit_cache_spec.rb` が実 COMMIT で固定した。

## 16. 追加承認が必要な仕様変更

この PR では本番を変えない。案Aを推奨する判断は変えない。否決して案Bを採る場合だけ、節 5 の revision 件数、通知件数、部分失敗、高リスクとの境界を別途承認する。

初回移行の承認事項は次の2つで、並列である。どちらか一方だけを黙って外さない。

- 9 キーの同値再送を Writer の no-op に揃える。今日の `[]=` は同値でも即時 `cache.write` し、実 COMMIT では `rewrite_cache` も走る。Writer の no-op は `save!` を呼ばないので、その write も delete も無い。
- Credentials の非スカラー設定値を拒否する。今日は JSON オブジェクトが未許可の `ActionController::Parameters`、JSON 配列が `Array` として保存される。フォームの strong parameters はスカラー許可の `Hash` をすでに落とす。レガシー経路は `Hash`、`ActionController::Parameters`、`Array` を保存しない。

それ以外の従来スカラー互換性は維持する。`direct`、空文字、`ja-JP`、文字サイズの文字列、boolean キャスト、古いポリシーでの翻訳正規化、省略補完を含む。

推奨に入れないもの。やるなら別の仕様変更である。

- 未知のバーと mode を保存時に正規化しなくなること。
- バーの正規化に、同じリクエストの新しいポリシーを使うこと。
- Credentials の省略補完をやめること。補完をアカウント更新の前に移すこと。
- 文字サイズの新規保存を整数だけにすること。`ja-JP` やポリシーの任意文字列や `direct` や `""` をレガシー経路で拒否すること。
- 公開 `apply` に、上記のレガシー値や null を許可すること。
- Credentials に `write:preferences` を要求すること。
- Writer を `current_user.update` や `UpdateAccountService` と同じトランザクションに入れること。
- 9 キー以外を Writer に通すこと。
- 移行の完了前に revision 付き getter を読むこと。
- 通知 payload を変えること。案Aの複数通知を 1 回にまとめること。

## 17. スコープ外

この PR は次を変えない。

- `UserPreferences::Writer`、`WriteContract`、`ChangeSet`
- `UserSettingsDecorator`、`ScopedSettings`
- Rails フォームのコントローラ、`CredentialsController`
- Redis、Revision、`CacheDeletion`、`ChangeNotification`
- Streaming、WebUI
- GET / PATCH / reset のレスポンス
- migration、ActivityPub
