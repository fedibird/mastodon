# Settings Service P1-0 棚卸し

監査日の基準コミットは `90ba4b16e175ff6fe413b94db218deefa83f6777` である。この文書は `catalog.yml` の読み方と、経路の対応、保留事項をまとめる。キーの全件はカタログが正である。カタログは実行時契約ではなく、production は読み込まない。

数値は `script/check_settings_service_catalog.rb` が `catalog.yml` の `meta.stats` とソース抽出を照合した結果に合わせてある。

| 区分 | 件数 |
| --- | ---: |
| カタログ項目 | 242 |
| `verified` | 216 |
| `inferred` | 23 |
| `unresolved` | 3 |
| 未決の open question | 6 |
| `candidate_general` | 119 |
| `candidate_high_risk` | 28 |
| `retained_inactive` | 6 |
| `excluded` | 28 |
| `site` | 34 |
| `client` | 21 |
| `derived` | 3 |
| `user_column` | 3 |

`user.*` のトップレベルは 133 件で、そのうち 3 件は `users` 列（locale、time_zone、chosen_languages）である。ネストしたメール通知と interactions は 20 件である。`inferred` 23 件は、Redux 初期状態のグループ 20 件と、参照が見つからない site キー 3 件（`disallowed_hashtags`、`enable_personal_account`、`min_invite_role`）である。否定検索なので verified にしていない。

## 1. 設定ストレージの全体構造

保存は次の層に分かれる。同じ名前でも層が違う。

1. **User.settings（RailsSettings のスコープ付き行）**  
   `User` は `Settings::Extend` で `settings` を持つ。実体は `Settings::ScopedSettings` である。`settings` テーブルに `thing_type=User`、`thing_id`、`var`、YAML 化した `value` が入る。未保存のときは `config/settings.yml` の `defaults` を返す。`theme` と `noindex` だけは、未保存時にサイト全体の `Setting[var]` を見る（`DEFAULTING_TO_UNSCOPED`）。

2. **getter の有効値**  
   ほとんどの `user.setting_*` は `settings` への delegate である。`setting_default_privacy`、`setting_show_translation_bar`、`setting_translation_preferred_mode` は User 側の上書きで、保存値そのものではない。`preferred_posting_language` は保存された `default_language` ですらない。

3. **サイト設定**  
   `thing_type` と `thing_id` が NULL の行と、同じ YAML のデフォルトである。管理画面の `Form::AdminSettings` が書く。ユーザーデフォルトと同じハッシュを共有するので、`user.settings.site_title` のように呼ぶと YAML デフォルトが返る。呼んでいないキーをユーザー設定とは数えない。

4. **users 列**  
   `locale`、`time_zone`、`chosen_languages`。preferences の `user_params` が `User#update` する。

5. **accounts 列と accounts.settings JSON**  
   プロフィール、`locked`、`searchability`、`followed_message`、誕生日、所在地。`UpdateAccountService` が書く。

6. **web_settings.data**  
   ユーザーあたり 1 行の JSON。WebUI の Redux `settings` である。

読み取りのキャッシュは `Setting.cache_key` 経由の `Rails.cache` である。`ScopedSettings#[]=` は `update!` のあとでキャッシュへ書く。トランザクションには入っていない。Hash の読み取りは `cache.fetch` のブロック内で `return` するため、ネスト設定の読み取り結果はキャッシュに載らない。P2 の検討事項であり、この PR では直さない。

`UserSettingsDecorator` の `INTEGER_KEYS` は空である。数値に見える文字サイズや絵文字倍率は `STRING_KEYS` で、フォームの文字列がそのまま YAML になる。YAML 上の初期値は数値である。

## 2. Rails フォーム別の入力項目数

パーサは `f.input` / `ff.input` / `fields_f.input` の行だけを数える。Haml コメントの行は commented である。条件付きは、その行より浅い `- if` / `- unless` が残っている場合である。条件付き件数は active に含まれる。

| 画面 | active | うち条件付き | commented |
| --- | ---: | ---: | ---: |
| preferences/appearance | 57 | 0 | 0 |
| preferences/notifications | 19 | 3 | 0 |
| preferences/safety | 11 | 0 | 0 |
| preferences/other | 63 | 2 | 1 |
| profiles | 16 | 1 | 0 |

通知の条件付き 3 件は `report`、`pending_account`（管理者）、`trends`（`manage_taxonomies`）である。other の条件付き 2 件は `enable_status_polling` と `enable_status_polling_intersection` で、`new_features_policy == tester` のときだけ描画される。コメントアウトは `setting_enable_local_timeline` の 1 件である。プロフィールの条件付きは `discoverable` で、`Setting.profile_directory` が真のときだけ出る。

4 つの preferences 更新は同じ `user_settings_params` を許可する。画面に出ていなくても、許可リストにあればその URL への POST で書ける。表示数と書き込み可能なキー数は一致しない。

## 3. User.settings とフォームの対応

書き込みは `UserSettingsDecorator#process_update` が行う。

- `notification_emails` と `interactions` は、送られたキーだけを Boolean 化して既存 Hash に merge する。送られないキーは残る。
- `STRING_KEYS` はそのまま保存する。例外は翻訳バーと翻訳モードの正規化である。
- `BOOLEAN_KEYS` は `ActiveModel::Type::Boolean` で保存する。Simple Form のチェックボックスは `"0"` / `"1"` になる。
- `PROFILE_KEYS`（`noindex`、`hide_network`、件数 3 種、`enable_reaction`）がパラメータに含まれると、値の変化に関係なく `profile_change?` が真になる。other 画面はこれらの入力を持つので、保存のたびに `ActivityPub::UpdateDistributionWorker` が積まれる。

フォームに無い、またはコメントアウトだが許可リストには残る例は `show_target` と `enable_local_timeline` である。

`default_privacy` のフォームは getter を表示する。未保存なら、アカウントが locked のとき `private`、そうでなければ `public` が見える。other を保存すると、その有効値が保存値になる。読み取りだけでは書き戻さない。

## 4. InitialState に出る設定

署名済みユーザーのユーザー設定は、主に `InitialStateSerializer#meta` に `user.setting_*` として入る。例外と別名は次のとおりである。

- `enable_local_timeline` は保存値を読まず、リテラル `false` である。
- `show_translation_bar` は meta キー `translation_bar_visibility` で、getter の正規化後の値である。
- `trends` / `show_trends` は `Setting.trends && user.setting_trends` である。
- `compose.default_privacy` は、共有 URL の `visibility` があればそれ、なければ `setting_default_privacy`（有効値）である。
- `compose.default_language` は `preferred_posting_language` である。
- `compose.default_sensitive` は `setting_default_sensitive` である。
- `compose.default_searchability` は **`accounts.searchability`** である。
- `search.default_searchability` は **`setting_default_search_searchability`** である。
- `compose.prohibited_words` は保存文字列をカンマ分割した配列である。保存形とは違う。
- 文字サイズの一部（`content_font_size` など）は meta にも入るが、JS の `initial_state.js` は export しない。表示は `account_theme_valiables` の CSS 変数である。`composer_font_size` と `composer_min_height` は InitialState に無く、CSS だけである。
- `translation_private_content_allowed` は翻訳バックエンドの能力で、設定ではない。

未ログイン時、meta に入る再生・メディア系はサイトの `Setting.*` である。`enable_local_timeline` は付かない。JS は欠落時に `?? true` するが、ログイン中のレスポンスは明示的な `false` なのでこのフォールバックは使われない。

InitialState の `settings` は `Web::Setting` の JSON に、about ページ用のサイトフラグ 4 つを足したものである。

## 5. 既存 API に公開されている設定

| 経路 | 認可 | 出る値 |
| --- | --- | --- |
| `GET /api/v1/preferences` | `read` または `read:accounts` | `posting:default:visibility`（有効な default_privacy）、`posting:default:sensitive`、`posting:default:language`（**preferred_posting_language**）、`reading:expand:media`（display_media の文字列）、`reading:expand:spoilers`、`reading:autoplay:gifs`（自動再生 4 フラグの AND） |
| `GET/PATCH /api/v1/accounts/verify_credentials` と update_credentials の `source` | 参照は `profile` / `read` / `read:accounts`、更新は `write` / `write:accounts` | `privacy`（有効値）、`sensitive`、`language`（**保存された default_language**。nil があり得る） |
| `PATCH /api/web/settings` | セッション + CSRF | `web_settings.data` 全体。スキーマなし |
| `api/v1/fedibird/*` | 各コントローラの既存スコープ | ユーザー設定の preference キーは読んでいない。翻訳言語、投稿アイデンティティ、投稿コンテキストである |

資格情報の `show` は、公式 iOS / Android かつ `unlocked_for_official_app` のとき、応答直前にメモリ上の `account.locked` を false にする。行は更新しない。`accounts#show` にも同じマスクがある。

## 6. React 内の静的参照と動的参照

`app/javascript/mastodon/initial_state.js` はモジュール評価時に `#initial-state` を読む。export された値は、その後 Redux が更新されても変わらない。

- **静的 import**: `getMeta(...)` の export を他ファイルが import しているもの。タイムラインスイッチ、ボタン非表示、翻訳バー、ポーリング reducer などがここである。`apply_hint` は `reinitialize`。
- **Redux meta**: hydrate で meta 全体が入る。スキャンした selector がユーザー設定キーを `state.meta` から読んでいない。値は既に meta にあるので、selector に切り替えれば追加改修で動的更新できる、という観察である。実行時に全参照を証明したわけではない。
- **Redux compose / search**: 投稿の既定公開範囲・言語・検索対象は hydrate で入る。ページ読み込み時のスナップショットである。
- **CSS 変数と body class**: 文字サイズ、絵文字倍率、システムフォント、アバター形状、テーマ。`apply_hint` は `reload`。
- **コンポーネント初期化時**: `columns_area` の `componentDidMount` が `enable_local_timeline` / `enable_federated_timeline` / `enable_limited_timeline` の静的値でカラムを消す。
- **クライアント独自**: Redux `settings`。`actions/settings.js` が debounce して `PUT /api/web/settings` する。`saved` は保存前に除く。`apply_hint` は `live`。`portableComposerDisplayMode` はコンポーザーごとの UI 状態であり、`translation_preferred_mode` ではない。翻訳の `original` はステータスごとの表示モードであり、保存される既定モードではない。
- **未使用 export**: `show_target` と `hidePersonalFromAccount` は export されるが、import が見つからなかった。後者の効果は `Api::V1::Accounts::StatusesController` が次のリクエストで読むことなので `live` とした。前者は UI もサーバー効果も見つかっていないので `unknown` である。

## 7. API 化候補と除外

候補はカタログの `disposition` が正である。除外したものもエントリとして残してある。

除外の理由は、単純な preference ではないからである。

- プロフィール一式（`account.*`）。`locked` は未設定の `default_privacy` の入力になる。`searchability` は compose の既定検索対象そのものである。
- OAuth アプリ、二要素、セッション、インポート、移行、削除、外部サービスの資格情報、購読、タグフォロー、投稿アイデンティティ、Web Push。
- サイト設定（`site.*`）。
- WebUI JSON（`client.web_settings`）。D3 により別ストアのまま。
- 派生値（`preferred_posting_language`、`reading:autoplay:gifs`、翻訳の private content 可否）。保存キーとして公開しない。

`enable_local_timeline` は設定行と許可パラメータが存在するが、Fedibird はローカルタイムラインを出さない。InitialState は false 固定で、フォームはコメントアウトである。利用可能・書き込み可能とは分類しない。`retained_inactive`、`write_policy: not_writable`（推奨）である。現状の許可リストはまだ受け付ける。

`show_target` と許可だけが残る `notification_emails.followed_message` も候補から外し、一覧には残す。

## 8. 副作用とアクセス権

推奨の `read_policy` / `write_policy` は D2 の分離案である。現行の OAuth 付与は `read_sources` / `write_sources` と notes に書いた。

高リスク推奨（28 件）の根拠はコード上の効果である。

- `disable_post` はステータス API と投稿アイデンティティが拒否する。
- `disable_follow` はフォロー API が新規フォローを拒否する。
- `prohibited_words` は投稿と更新が拒否する。
- `unlocked_for_official_app` は資格情報の locked をマスクする。
- `PROFILE_KEYS` は ActivityPub の Update 配送を起こす。
- `hide_direct_from_timeline` と `hide_personal_from_timeline` は自分へのファンアウトを変える。
- `hide_personal_from_account` はアカウントのステータス API から personal を外す。
- `interactions.*` は `NotifyService` が通知作成または DM を落とす。`must_be_dm_to_send_email` はメールだけを止める。

`disable_swiping`、`disable_joke_appearance`、`disable_relative_time`、`disable_reaction_streaming`、`disable_auto_focus_to_emoji_search` は名前が disable でも配送や拒否には使われていない。一般候補である。

通知メールは `notification.type` の文字列で Hash を引く。スタッフ向けキーはフォームが非表示でも、merge なので既存値は維持される。

## 9. 不一致、孤立キー、未使用キー

確認できた不一致:

- **default_language の 3 経路**。フォームと資格情報 `source.language` は保存値（nil があり得る）。Preferences API と compose は `preferred_posting_language`（保存値、users.locale、I18n.locale の順で、地域部分を落とした有効ロケール）。同義ではない。
- **default_privacy**。保存値が空なら getter は `account.locked` を見る。Preferences と compose と資格情報の `privacy` は有効値。資格情報の更新は有効値を書き戻し得る。
- **show_translation_bar**。保存は nil、旧 boolean、`always|target|never`、未知文字列があり得る。読み取りの正規化は保存しない。書き込みの未知値は、その時点の保存済み `new_features_policy` の既定へ置き換わる。STRING_KEYS の順で、同じリクエストの新しい policy より先に正規化する。JS の `normalizeTranslationBarVisibility` は未知値を null にする。InitialState は Ruby の有効値を渡すので、通常の画面では一致する。
- **translation_preferred_mode**。許容は `translated`、`bilingual`、`both`。それ以外の読み書きは `translated`。表示モード `original` は設定ではない。
- **検索対象が二つ**。ユーザー設定の既定は YAML 上 `public` で、検索 UI の `search.default_searchability` になる。アカウント列の既定は DB 上 `direct` で、コンポーザーの `compose.default_searchability` になる。コンポーザー reducer の hydrate 前初期値は `private` である。
- **notification_emails.followed**。YAML 既定 false、フォームあり、許可パラメータに無い。通知タイプ `:followed` のメール判定はこのキーを読む。チェックボックスは strong parameters で落ちる。
- **notification_emails.followed_message**。許可パラメータにだけある。YAML にもフォームにも無い。プロフィールの `followed_message` とは別物である。
- **hide_personal_from_account**。decorator、フォーム、delegate、InitialState にある。`settings.yml` に無い。未保存の getter は nil で、呼び出し側では偽として扱われる。
- **enable_local_timeline**。YAML 既定 true、フォームはコメント、InitialState は false、JS はログイン中にその false を使う。
- **enable_personal_account**。YAML にだけある。`enable_personal_timeline` とは別キーで、app 配下に `Setting.enable_personal_account` は見つからなかった。
- **disallowed_hashtags**。YAML に残る。`DisallowedHashtagsValidator` は `Setting.disallowed_hashtags` を読まず、`Tag#usable?` が偽のタグを拒否する。
- **min_invite_role**。管理フォームの KEYS から外れている。`db/legacy_role_setting_sync.rb` が招待権限を UserRole へ写すときに読む。
- **show_target**。YAML、delegate、許可、InitialState、未使用の JS export がある。フォームは無い。
- **数値**。YAML は integer / float、保存処理は文字列、CSS はどちらも埋め込む。`max_frequently_used_emojis` だけ JS が `Number()` する。
- **User delegate の重複**。`show_follow_button_on_timeline`、`show_subscribe_button_on_timeline`、`show_target` が `user.rb` の delegate に 2 回ある。動作は同じメソッドが 2 回列挙されているだけで、この PR では消さない。
- **preferences の autoplay 名**。`reading:autoplay:gifs` は 4 つの autoplay が全部真のときだけ真である。`reading:expand:media` は boolean ではなく `display_media` の enum 文字列である。

通知フォームは `notification_emails` の `simple_fields_for` を 2 回描画する。キーが違えば Rack が 1 つの Hash にまとめる、という実行はしていない。open question に残す。

## 10. P1-1 以降の注意と保留

P1-1 で再利用できるもの:

- `docs/settings_service/catalog.yml` のキー、storage、legacy_keys、raw/effective、source_refs、disposition。
- `script/check_settings_service_catalog.rb`。ソースの decorator、許可パラメータ、フォーム、InitialState、settings.yml との差分を、Rails を起動せずに見る。
- D1〜D5 を `decisions.md` に固定したこと。

実装時に守ること:

- Reader は保存値を書き換えない。とくに翻訳バーの nil と未知値、未設定の `default_privacy`、未設定の `default_language`。
- `configured` と `effective` を同じフィールドにまとめない。言語、公開範囲、翻訳バー、trends のサイト AND、ローカルタイムラインの false 固定、二つの searchability。
- 高リスク推奨の 28 件を一般の書き込み API に混ぜない。この分類は推奨であり、ここで新しいスコープは切っていない。
- `enable_local_timeline` を「設定があるので利用可能」にしない。
- Web::Setting を User.settings のスキーマに畳まない。JSON の葉は未完了である。
- 文字サイズは文字列として保存され得る。スキーマで整数へ移行するなら別 PR のマイグレーションであり、この監査は値を変えない。
- キャッシュと DB 更新のずれは P2。Reader を足すときも、この PR の範囲では `ScopedSettings` を直さない。
- `followed` の許可パラメータ不一致は不具合として見える。修正は別 PR にする。推奨は、フォームとメールが使う `followed` を許可し、通知 Hash の `followed_message` は許可しない、である。プロフィールの `followed_message` は触らない。

保留のままにしたこと:

- `show_target` を消すか、画面を戻すか。参照が export 以外に見つからない。動的参照の可能性は静的 import スキャンでは閉じられない。
- 本番 DB に nil、旧 boolean、未知の翻訳値が何件あるか。DB は読んでいない。
- 通知フォームの二重 `fields_for` が 1 リクエストで両方残るか。未実行。
- 一般候補の最終的な API キー名。カタログの `user.*` は候補名であり、公開契約ではない。
