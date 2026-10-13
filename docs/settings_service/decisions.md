# Settings Service — 確定事項（D1〜D5）

P0 で承認済みの決定である。この監査は決定を再設計しない。カタログの `disposition` と `owner` は、次の決定を実装方針として参照するための分類である。

## D1. User 設定はユーザー共通設定として維持する

`User.settings` はユーザーに 1 組の設定である。端末ごと、ブラウザごとには分けない。

保存先は `settings` テーブルの `thing_type = User`、`thing_id = users.id`、`var` が設定名である。`users.locale`、`users.time_zone`、`users.chosen_languages` と `accounts` の列、`accounts.settings` JSON は、この共通設定には含まれない。カタログでは owner と storage を分けてある。

## D2. 外部 API の一般設定と高リスク設定を分離する

将来の外部向け Settings API では、表示や投稿の既定値と、安全・配送・公開範囲に効く設定を同じ書き込み口に載せない。

この監査での推奨分類は次のとおりである。承認済みの公開契約ではない。

- `candidate_general`: 外観、確認ダイアログ、タイムライン表示、投稿の既定、翻訳、通知メール
- `candidate_high_risk`: 操作の禁止、禁止語・禁止公開範囲、公式アプリ向け locked 表示の回避、ActivityPub 配送対象（`noindex`、件数非表示、`enable_reaction`）、ファンアウトやステータス取得を変える非表示、`interactions` の受信フィルタ
- `retained_inactive`: 保存や許可パラメータには残るが、機能として提供しない、または画面がない
- `excluded`: プロフィール、認証情報、認可、購読リソース、投稿アイデンティティ

既存の `GET /api/v1/preferences` と `source` 付き資格情報 API は、この分離より前の Mastodon 互換面として記録する。スコープは追加しない。

## D3. Web::Setting は当面維持する

`web_settings.data` は WebUI の Redux 状態である。`User.settings` に吸収しない。

`config/routes.rb` の `namespace :web` にある `resource :settings, only: [:update]` は、Rails の update として PUT と PATCH を同じアクションへ届ける。現行 WebUI は `app/javascript/mastodon/actions/settings.js` から `PUT /api/web/settings` を送る。セッショントークンと CSRF は変わらない。この監査はルートもクライアントも変えない。

InitialState の `settings` キーはこの JSON であり、ユーザー設定ではない。サーバーは形を検証しない。

## D4. 設定専用の変更通知・購読経路を提供する

設定変更を伝える専用の経路は、後続の実装で用意する。この PR では `preferences_changed`、revision 列、購読 API を追加しない。

カタログの `side_effects` は、その経路が後で区別すべき影響の一覧である。例として、プロフィール系キーの ActivityPub 配送、通知フィルタ、メール、ファンアウト、資格情報レスポンスの locked マスクがある。

## D5. Rails 設定画面を維持し、WebUI 埋め込みと外部ブラウザ呼び出しで再利用する

`/settings/preferences/*` と `/settings/profile` は残す。この PR では iframe 化も、React への設定フォーム移植もしない。

書き込みの現状は、4 つの preferences 更新が同じ `user_settings_params` を使い、プロフィールは `UpdateAccountService` を使う、という形である。将来の埋め込みは、この画面と許可パラメータを再利用する。

## この監査が変更しないもの

Reader、Schema API、書き込み API、OAuth スコープ、DB revision、イベント、画面の iframe 化、Redux の動的反映、設定値の移行、既存不具合の修正はスコープ外である。
