# Settings Service P2-6E 残存書き込み監査

この文書は、`UserPreferences::WriteContract::KEYS` の 9 キーについて、本番で revision を進めずに保存する経路を閉じる前に走査した記録である。対象は User の Setting 行（`thing_type = User`、`thing_id = users.id`、`var` が 9 キー）だけである。高リスク設定、`notification_emails`、`interactions`、サイト Setting、`Web::Setting`、`preferred_posting_language`、読み取りは保存方式を変えていない。

作業基点は `origin/fedibird` の `8be47e70651152b30e302f3c43c64115e1a9ec17`（#443）である。

## 1. 走査範囲

ローカル作業ツリーの `app`、`lib`、`config`、`db`、`script`、`bin` を走査した。GitHub の検索結果は使っていない。

`script/audit_nine_key_writes.rb` が同じ範囲の Ruby / Haml / ERB と、拡張子のない `bin` スクリプトを読む。この作業での走査は 2337 ファイル、違反 0、許可リスト外の動的書き込み 0 である。キー名のリテラル検索に加え、次も見た。

- `UserSettingsDecorator.new`、`LegacyWriter.new`、`UserPreferences::Writer.new`
- `.settings[` と `.settings.name =`
- `ScopedSettings#[]=` と `method_missing` の代入
- `Setting.unscoped.new` / `delete_all` / `first_or_initialize(var:)`
- `insert_all` / `upsert_all` / `update_all`（settings 行には当たっていない）
- SQL の settings INSERT / UPDATE / DELETE（該当なし）
- `send` / `public_send` による設定代入（該当なし）
- migration、seed、Rake、bin

`User` の `delegate ..., to: :settings, prefix: :setting` は読み取りメソッドだけである。`setting_default_privacy=` は定義されていない。

## 2. 分類

| 区分 | 場所 | キー | 到達 | 方針 |
| --- | --- | --- | --- | --- |
| A | `Api::V1::Fedibird::PreferencesController#apply_writes` | 公開契約の 9 キー | PATCH / reset。外側トランザクションなし。`Writer#apply` | 移行済み。変更しない |
| A | `Settings::PreferencesController#user_settings` | フォームの 9 キー | 4 画面の update。`LegacyWriter` を 1 つ渡す | 移行済み。変更しない |
| A | `Api::V1::Accounts::CredentialsController#update` | privacy / language / sensitive | `UpdateAccountService` のあと。`LegacyWriter` を 1 つ渡す | 移行済み。変更しない |
| A | `UserPreferences::Writer#insert_row` / `update_row` / `delete_row` | 引数のキー | Writer と LegacyWriter だけが呼ぶ。1 キー 1 トランザクション | 許可する内部保存 |
| B | `UserSettingsDecorator#process_update` の `user.settings[key] =` | `STRING_KEYS` / `BOOLEAN_KEYS` のうち 9 キー | `legacy_writer` が無いときだけ。本番コントローラはすでに Writer を渡している | 書き込み開始前に拒否。9 キーの分岐は残す |
| C | 同じ Decorator の nested / 非 9 キー | `notification_emails`、`interactions`、高リスクを含む残り | フォームの strong parameters | 従来の `ScopedSettings#[]=` のまま |
| C | `Form::AdminSettings`、`Form::ActionReviewSettings` | サイト Setting の `var` | 管理画面 | 対象外 |
| C | `Web::Setting` | Web UI の別モデル | `Api::Web::SettingsController` | 対象外 |
| D | `UserPreferences::Reader`、User の getter、serializer、helper、fan-out の `Setting.unscoped.where` | 9 キーを含む読み取り | リクエストの描画と配送フィルタ | 変更しない |
| E | spec の `user.settings['default_privacy'] =` など | テストの初期行 | RSpec だけ | 本番経路ではない。`[]=` は閉じていない |
| F | `db/migrate` と `db/post_migrate` の `user.settings[...] =` | `advanced_layout`、auto play、theme など。9 キーではない | 適用済み migration | 変更しない |
| F | `db/migrate/20190314181829_migrate_open_registrations_setting.rb` | サイトの `registrations_mode` | 適用済み migration | 動的初期化として監査の許可リストに理由付きで残す |
| G | `Settings::ScopedSettings#[]=` と `method_missing` の代入 | 呼び出し元が渡した任意の var | Decorator の非 9 キー、テスト、歴史的 migration | 全体の転送や拒否はしない。構造上 9 キーも書ける |

分類 B の本番呼び出し元は、この基点では残っていなかった。`UserSettingsDecorator.new` の本番箇所はフォームと Credentials だけで、どちらも `legacy_writer:` を渡す。

## 3. 閉じた経路

`UserSettingsDecorator#process_update` は `NESTED_KEYS` の前に検査する。`legacy_writer` が無く、9 キーの非 nil 入力があるときは `UserSettingsDecorator::MissingLegacyWriter`（`ArgumentError`）を上げる。ログにはキー名と呼び出し元を残し、値は残さない。

この例外は `UserPreferences::InvalidInput` ではない。フォームも Credentials も 422 に変換しない。他のキーを保存したあとでは検出されない。nil の 9 キーは従来どおりスキップし、同時に渡した 9 キー以外は保存できる。`profile_change?` はキーの存在のままである。順序は NESTED、STRING、BOOLEAN のままである。9 キーの `LegacyWriter#update` 分岐は残している。

## 4. 移行しなかった直接書き込み

本番の 9 キー直接代入は見つからなかった。追加の呼び出し元を Writer に移す変更はない。

`ScopedSettings#[]=` は User 以外と 9 キー以外も書く。ここへ 9 キー専用の拒否を入れると、テストの初期化、歴史的 migration、高リスク設定の契約まで変わる。入れていない。新しい `user.settings['default_privacy'] =` や未許可の動的代入は `script/audit_nine_key_writes.rb` が失敗させる。許可リストはファイルパスと理由であり、行番号ではない。

## 5. P2-4C / P2-4D

次は満たしている。

- 本番の 9 キー保存経路は上表の A に尽きる
- Decorator を Writer なしで使うと、非 nil の 9 キーは保存前に拒否される
- 実変更は LegacyWriter / Writer が revision を進める
- 同値は no-op のまま
- 高リスクとネストは 9 キー Writer の対象外
- revision 付き getter は有効にしていない

次は、このリポジトリの変更だけでは確認できない。

- 古いプロセスがデプロイ完了前に、Writer なしの Decorator または `ScopedSettings#[]=` で 9 キーを書く可能性。ローリングデプロイの完了はここでは確認していない
- `ScopedSettings#[]=` 自体は 9 キーを受け付ける。現行の本番呼び出し元はない

そのため、P2-4C と P2-4D の開始条件を満たしたとは判定しない。既存 revision のリセットや一括変換はしていない。
