# WEB_UI_DOMAINS URL 監査表（P0）

基点: `54bd41378f`（`fedibird`、webauthn 3.5.1）。設計の本文は `docs/web_ui_domains_p0.md`。この表は実装時の抜け確認用である。行は機構単位で、同じホスト選択をする呼び出しをまとめている。

分類:

| 分類 | 意味 |
| --- | --- |
| canonical-identity | acct、Actor/Object ID、鍵 ID |
| federation-transport | 配送、署名、WebFinger、NodeInfo |
| browser-navigation | 画面遷移、共有リンク、OGP |
| api-absolute | REST の絶対 URL。ネイティブクライアントも読む |
| streaming | WebSocket / EventSource |
| media-asset | 画像、動画、アバター、絵文字、カード |
| static-asset | JS / CSS / フォント / manifest の配信 |
| session | Cookie、CSRF、WebAuthn、OAuth |
| email | メール本文と Message-ID |
| external | 他サーバー、ストレージ、外部ログイン相手 |
| mixed | 一つの箇所が複数の役割を持つ |

方針:

| 方針 | 意味 |
| --- | --- |
| keep-canonical | 正規ホストのまま生成・保存する |
| project-at-browser | WebUI が読むときだけ入口 Origin へ投影する。保存値と他クライアント向け JSON は変えない |
| request-host | 今どおり、そのリクエストの Host を使う |
| same-origin-guard | 追加入口の厳密モードだけで、自動リクエストの前に URL パーサで Origin を検査し、不一致なら送信しない。レガシーモードの専用 Streaming は止めない |
| refuse-on-ui-host | UI 入口では拒否し、正規 URL を案内する |
| unchanged | この機能では挙動を変えない |
| gate | 有効化ゲートが開くまで本番の挙動を変えない |

フェーズは P1 基盤、P2 API/Streaming/遷移、P3 アセット、P4 認証/連合、P5 PWA、P6 検証環境、その後の明示的な本番公開である。P1 から P5 のマージでは本番の入口を開かない。設計文書の「公開ゲート」とこの表のフェーズは同じ意味である。

検索式と対象外は設計文書の「調査の範囲と未確認」。以下の行番号は基点のファイルを読んだ位置である。

## 1. 正規 URL の生成

| 箇所 | 用途 | 現行ホスト | 分類 | 方針 | フェーズ | 回帰 |
| --- | --- | --- | --- | --- | --- | --- |
| `config/initializers/1_hosts.rb` `local_domain` / `web_domain` / `alternate_domains` | 環境変数の読み込み。メーラー `default_url_options` は `web_host`。`config.hosts` は local、web、alternate。`/health` は Host 検査の対象外 | WEB_DOMAIN が URL 生成。LOCAL は acct。alternate は許可リスト | mixed | keep-canonical。追加入口の `config.hosts` 追加は P6 の検証のあと、明示した本番公開まで行わない | P1, P6 | 未設定時、`root_url` のホストは WEB_DOMAIN、インスタンスの domain 表示は LOCAL_DOMAIN |
| `RoutingHelper#default_url_options` | include 先の `*_url` をメーラー設定へ固定 | WEB_DOMAIN | canonical-identity | keep-canonical。リクエストごとの書き換え禁止 | P1 | LOCAL と WEB が違うとき、このモジュール経由の URL は WEB |
| `TagManager#web_domain?` / `#local_domain?` / `#local_url?` | メンションとローカル URL 判定。`local_url?` は WEB のみ。alternate も UI ホストも見ない | WEB または LOCAL | canonical-identity | unchanged。UI ホストを足さない | P4 | WEB 以外のホストは `local_url?` が偽 |
| `ActivityPub::TagManager#url_for` / `#uri_for` / `#key_uri_for` / コレクション URI | ローカル Actor、Note、絵文字、鍵の正規 URL | WEB_DOMAIN（RoutingHelper） | canonical-identity | keep-canonical | P4 | 入口で作った投稿の `id` と `url` が正規ホストのまま |
| `ActivityPub::TagManager#local_uri?` | ホストが LOCAL または WEB ならローカル URI | LOCAL または WEB | federation-transport | unchanged。UI ホストを足さない | P4 | UI ホストの URL は `local_uri?` が偽で、オブジェクト ID として解決しない |
| `OStatus::TagManager#unique_tag` | `atom_uri` の `tag:LOCAL_DOMAIN,...` | LOCAL_DOMAIN | federation-transport | keep-canonical | P4 | Note の `atomUri` が LOCAL、`id` が WEB |
| `Account#local_username_and_domain` / `#to_webfinger_s` | `acct:user@LOCAL_DOMAIN`。ローカル `acct` はドメイン無し | LOCAL_DOMAIN | canonical-identity | keep-canonical | P4 | WebFinger subject が入口ホストにならない |
| `WebfingerSerializer` | subject、aliases、profile/self/subscribe | subject は LOCAL。href は WEB | federation-transport | keep-canonical | P4 | alternate で引いても subject は LOCAL |
| `WellKnown::WebfingerController#username_from_resource` | alternate の acct を `user@LOCAL_DOMAIN` へ書き換えてから解決。インスタンス Actor は username が local または web のとき | alternate は引数の正規化だけ | federation-transport | unchanged。UI ホストはここへ足さない | P4 | 既存 `ALTERNATE_DOMAINS` の spec が通る。UI ホストの acct は 404 |
| `WebfingerResource#domain_matches_local?` | acct ドメインが LOCAL または WEB | LOCAL または WEB | federation-transport | unchanged | P4 | UI ホストだけではローカル acct にならない |
| `WellKnown::HostMetaController` と `show.xml.ruby` | XRD の WebFinger テンプレート | WEB_DOMAIN | federation-transport | keep-canonical。UI 入口では拒否 | P4 | 正規ホストの host-meta が今と同じ href |
| `Nodeinfo::DiscoverySerializer` | `/.well-known/nodeinfo` の schema リンク | WEB_DOMAIN | federation-transport | keep-canonical。UI 入口では拒否 | P4 | 正規ホストの href が WEB |
| ActivityPub actor/note serializer の `id`、`inbox`、`outbox`、`sharedInbox`、`publicKey.id` | 配送先と鍵 ID | WEB_DOMAIN | federation-transport | keep-canonical | P4 | 署名対象 URL のホストが変更前後で一致 |
| `Formatter` のメンション `href` とハッシュタグ `href` | ステータス HTML。ActivityPub `content` に入ってキャッシュされる | WEB_DOMAIN | mixed | keep-canonical（保存 HTML）。WebUI の通常クリックだけ project-at-browser | P2 | リモートから見える `content` の href が WEB のまま |
| `REST::AccountSerializer` / `REST::StatusSerializer` の `url` | クライアント向け正規 URL | WEB_DOMAIN | api-absolute | keep-canonical。WebUI の通常クリックはアプリ内ルート | P2 | ネイティブクライアントが受け取る `url` が WEB |
| `REST::V1::InstanceSerializer` の `uri` と `urls.streaming_api` | インスタンス識別子と Streaming 広告 | `uri` は LOCAL の文字列。Streaming は設定値 | api-absolute | unchanged。WebUI 初期状態とは別に扱う | P2 | `/api/v1/instance` が入口ホストを `uri` にしない |
| メーラーの `web_url` と `default_url_options` | 通知リンク | WEB_DOMAIN | email | keep-canonical | P4 | メールのリンクホストが WEB |
| `NotificationMailer` の Message-ID | スレッド識別 | LOCAL_DOMAIN | email | unchanged | P4 | Message-ID のドメインが LOCAL |
| `shared/_og.html.haml` の `og:url` | OGP。`url_for(only_path: false)` | リクエスト Host | browser-navigation | 未設定とレガシー入口は request-host。追加入口では正規 URL | P2 | 未設定時はリクエスト Host。追加入口の `og:url` は WEB。連合 JSON は WEB |
| `about/show.html.haml` の `rel=canonical` | `about_url`。`routes.default_url_options` は未設定 | リクエスト Host | browser-navigation | 未設定とレガシー入口は request-host。追加入口では正規 URL を明示して出す | P2 | 未設定時はリクエスト Host。追加入口の canonical は WEB |
| `Mastodon::Version.user_agent` | 送出 User-Agent の `+https://WEB_DOMAIN` | WEB_DOMAIN | federation-transport | unchanged | P4 | User-Agent の URL が WEB |
| `ExternalBridge::Atproto::ClientDocument.origin` | client id、redirect、jwks | WEB_DOMAIN。ポートとローカル名は拒否 | external | keep-canonical。追加入口では開始しない。外部認証必須のサーバは初期範囲で追加入口を公開しない | P4 | 未設定時の client id は WEB。追加入口に開始ボタンが無い |

## 2. 署名と配送

| 箇所 | 用途 | 現行ホスト | 分類 | 方針 | フェーズ | 回帰 |
| --- | --- | --- | --- | --- | --- | --- |
| `SignatureVerification#verify_signature_strength!` | GET は Host の署名を要求。POST は Digest | リクエストの Host ヘッダ | federation-transport | 正規ホストと alternate では unchanged。UI 入口では連合 GET/POST を拒否し、この検証を成功経路にしない | P4 | 正規ホストへの署名付き GET が今どおり成功 |
| `SignatureVerification#build_signed_string` | `(request-target)` はメソッドと `original_fullpath`。`host` は受信ヘッダ | リクエスト Host | federation-transport | 正規 URI への読み替えをしない | P4 | 署名文字列の Host が受信 Host と一致 |
| `Request#set_common_headers!` | 送出署名の Host | 配送先 URL のホスト（リモート inbox など） | federation-transport | unchanged。配送先 URL は正規の inbox のまま | P4 | 送出署名の Host が相手 inbox のホスト |

## 3. WebUI の API、Streaming、遷移

| 箇所 | 用途 | 現行ホスト | 分類 | 方針 | フェーズ | 回帰 |
| --- | --- | --- | --- | --- | --- | --- |
| `InitialStateSerializer#meta` | `streaming_api_base_url`、`access_token`、`domain` | Streaming は設定値（本番既定 `wss://WEB_DOMAIN`）。`domain` は LOCAL。トークンは `current_session.token` | streaming, session | 未設定とレガシー入口は今の Streaming URL。追加入口のブラウザだけ同一 Origin。`/api/v1/instance` は変えない | P2 | 未設定時と正規ホストの初期状態 Streaming が今の設定値 |
| `ApplicationHelper#render_initial_state` | `#initial-state` にセッショントークンを埋める | その HTML を出した Host のセッション | session | 入口の Cookie から引いた activation のトークンだけを埋める | P4 | 入口 A の HTML に入口 B のトークンが無い |
| `app/javascript/mastodon/api.js` | axios。`baseURL` 無し。Bearer と `X-CSRF-Token` | 相対パスならページ Origin | api-absolute | 相対パスは維持。絶対 URL は same-origin-guard | P2 | 相対 `/api/v1` に Bearer が付く。別 Origin には付かない |
| API `set_pagination_headers` と各 `next_path` の `*_url` | Link ヘッダ | API コントローラは RoutingHelper を include しないのでリクエスト Host | api-absolute | request-host。クライアントは same-origin-guard | P2 | 入口への API リクエストの Link がその入口。トークンは別 Host の Link へ出ない |
| タイムラインの追加読み込み（`max_id`） | 相対パスを再リクエスト | ページ Origin | api-absolute | unchanged | P2 | ホームのページ送りが同一 Origin |
| `scheduled_statuses` などの `api.get(nextUrl)` | Link の絶対 URL をそのまま GET | Link のホスト | api-absolute | same-origin-guard。不一致ならページ送りを止める | P2 | 不正な絶対 URL で Bearer が送られない |
| `app/javascript/mastodon/stream.js` `connectStream` | WebSocket は基底 URL とプロトコル引数のトークン。EventSource はクエリ `access_token` | `meta.streaming_api_base_url` | streaming | 追加入口だけ同一 Origin。レガシー入口の専用 Streaming は今の基底のまま | P2 | 未設定時と正規ホストの専用 Streaming が残る。追加入口から選択外の入口への WS/SSE が 0 |
| `Api::V1::StreamingController#index` | Host が Streaming 基底と違うと 301。ポート省略時は 80 と比較 | `STREAMING_API_BASE_URL` または `wss://WEB_DOMAIN` | streaming | レガシー入口の 301 は維持。追加入口では別 Origin の Location を出さない | P2 | 未設定時と正規ホストの専用 Streaming リダイレクトが残る。追加入口からはその Location が出ない |
| `HomeController#redirect_unauthenticated_to_permalinks!` | 未ログインの `/web/statuses/:id` を `TagManager#url_for` へ | WEB_DOMAIN | browser-navigation | HTML 入口ではリクエスト Host の短絡パス。正規 URL 生成は維持 | P2 | 入口の未ログイン状態遷移が正規ホストへ自動で飛ばない |
| `Permalink`、`packs/public.js` の `.webapp-btn`、`public_quote_navigation.js` | `href` または `dataurl` を開く。引用クリックは `url.split('/')[2]` でホストを見ている | `href` は API の正規 URL になり得る | browser-navigation | 同一インスタンスの `href` は現在の入口。正規 URL は共有アクションだけ。ホスト判定は `URL` パーサ | P2 | 中クリックと「リンクのアドレスをコピー」が現在の入口。共有ボタンだけが正規 URL |
| `main.js` の `/web` 付与 | `history.replaceState` | ページ Origin | browser-navigation | unchanged | P2 | 入口のパスが入口に残る |
| 設定画面・管理画面のフォーム | `form-action 'self'` | ページ Origin | browser-navigation | unchanged | P2 | ログイン POST がページ Origin |
| Doorkeeper 認可とトークン | セッションはリクエスト Host。`redirect_uri` はクライアント登録値。CORS は `/oauth/token` を資格情報無しで許可 | リクエスト Host と登録済み redirect | session | 入口を許可 redirect に自動追加しない。トークン応答は今の CORS | P4 | 既存アプリの redirect_uri が通る。オープンリダイレクトにならない |
| `config/initializers/omniauth.rb` の SAML / CAS | ACS と callback は環境変数 | 運営者が登録した URL | external | 追加入口では開始せず、正規 callback へ自動遷移しない。必須のサーバは追加入口を公開しない | P4 | レガシー入口の既存 IdP は今どおり。追加入口から ACS へ飛ばない |
| 外部ブリッジの WebUI（`external_feeds`、reading bookmarks、emoji mute） | 相対 `/api/v1/...` | ページ Origin | api-absolute | same-origin-guard の対象に含める | P2 | ブリッジ画面が別入口へ Bearer を送らない |

## 4. アセットとメディア

| 箇所 | 用途 | 現行ホスト | 分類 | 方針 | フェーズ | 回帰 |
| --- | --- | --- | --- | --- | --- | --- |
| `config/environments/production.rb` `asset_host` | `CDN_HOST` を Rails のアセットホストにする | CDN_HOST またはアプリホスト | static-asset | UI 入口の HTML では同一 Origin。CDN_HOST が UI 入口ではないときだけ例外 | P3 | ゲート閉鎖時の pack URL が今と同じ |
| `config/webpack/configuration.js` `publicPath` | `/packs/` | ページ Origin | static-asset | 相対のまま | P3 | 動的 import がページ Origin |
| `RoutingHelper#full_asset_url` | API と HTML の絶対アセット URL。S3/Swift のときは storage URL を `root_url` と結合 | WEB、またはストレージ URL | media-asset | REST には入口を書かない。WebUI はアプリパスだけ投影し、ストレージホストは残す | P3 | S3 の URL が REST に残り、ホスト部分を改変しない |
| `config/initializers/paperclip.rb` | `S3_ALIAS_HOST` または `S3_CLOUDFRONT_HOST` で `:s3_alias_url`。無ければ S3 ホスト名 | ストレージ | media-asset | unchanged。CDN_HOST よりこちらを優先 | P3 | 別名ホスト設定時の添付 URL が今と同じ |
| `content_security_policy.rb` | `connect-src` は `:self` と assets、media、streaming。`img-src` / `media-src` / `frame-src` は `:https` を含む | WEB、CDN、S3、Streaming、任意の https | static-asset | 入口 HTML では connect-src と script-src からインスタンス入口を外す。`:https` は外部メディア用に残り得る。CSP が全通信を止めるとは扱わない。画像の入口維持は M1 の URL と 302 | P3 | ゲート閉鎖時の CSP は今と同じ。公開後、connect-src に兄弟入口が無い |
| `config/initializers/cors.rb` | `/api/*` などを `origins '*'`、`credentials: false` | 任意 Origin。Cookie は送られない | api-absolute | unchanged。WebUI の Bearer 制限はクライアント側 | P2 | ネイティブアプリが別 Origin から Bearer で API を呼べる |
| `MediaProxyController#show` | 添付 ID と許可 variant。`full_asset_url` を `Location` にする。ローカルディスクでは WEB_DOMAIN の絶対 URL | WEB_DOMAIN、または S3/Swift | media-asset | インスタンス入口が配信ホストなら `Location` も現在の入口（M1）。専用ストレージだけ M2。認可、variant、キャッシュ、Range の依存先は維持 | P3 | ローカルディスクの 302 が別入口や正規ホストへ戻らない。許可外 variant は 404 |
| `MediaController#show` | ローカルメディアを Paperclip URL へリダイレクト | ストレージ | media-asset | unchanged | P3 | リダイレクト先ホストがストレージのまま |
| REST media / account avatar / custom emoji / preview card serializer | JSON に絶対 URL | ストレージまたは `full_asset_url` | media-asset | keep-canonical（JSON）。WebUI の `src` 組み立てで project-at-browser（アプリパスのみ） | P3 | リモートクライアントの JSON ホストが変わらない |
| `external_remote_media` と動画モーダル | `media.url` を `src` にする | JSON のホスト | media-asset | 投影レイヤをここへ通す。Range は 302 先依存（エッジは未確認） | P3 | ストレージ URL のクエリが落ちない |
| `PremailerWebpackStrategy` | メール CSS の取得ホスト | CDN_HOST または WEB | email | unchanged | P3 | メールの CSS 参照が今と同じ |
| `ApplicationHelper` の dns-prefetch | CDN とストレージを先読み | CDN / S3 | static-asset | UI 入口では、別 UI 入口を prefetch しない | P3 | 選択外入口への prefetch が 0 |

## 5. Host、Cookie、レート、キャッシュ

| 箇所 | 用途 | 現行ホスト | 分類 | 方針 | フェーズ | 回帰 |
| --- | --- | --- | --- | --- | --- | --- |
| `1_hosts.rb` の `config.hosts` と `dist/nginx.conf` | Host Authorization。テスト環境では未設定。例示 nginx に `default_server` と転送ヘッダの消去は無い | LOCAL、WEB、ALTERNATE | session | 追加入口は P6 以降の明示公開まで足さない。未知 Host の拒否と `Forwarded` の除去は、公開前に運営者が満たす条件であり、例示ファイルの現状ではない | P6 | 未設定時の許可リストは今と同じ。両方許可済みでも Host と X-Forwarded-Host の不一致は拒否 |
| `session_store.rb` `_mastodon_session` | Rails の暗号化 Cookie Store。CSRF、flash、未認証 2FA。認証 tuple ではない | Domain 無し、SameSite=Lax、本番で Secure | session | 共有の `@key` は書き換えない。actionpack 6.1.7.10 は `cookie_jar[@key]` を直接使う。追加入口は別 CookieStore かリクエストスコープの Store。旧名は読まない | P4 | 正規ホストの既存セッションが残る。入口 A と B の Cookie が混ざらない |
| `devise.rb` Warden `_session_id` と `auth_id` fallback、`ApplicationController#current_session`、`before_logout` | ログイン、復元、初期状態のトークン、ログアウトが別々に Cookie を読む | 旧名。文字列の session id。`auth_id` を書くコードは検索範囲に無い | session | 一つの解決関数。新しい入口は `__Host-` だけを読み、旧文字列と `auth_id` は拒否。レガシー入口は旧文字列を、ユーザー一致のときだけ受ける | P4 | 有効な旧 Cookie を新しい入口へ渡しても未認証。別入口のログアウトが他を消さない |
| `rememberable_options` と `on_authentication_success` の `remember_me` | レガシー入口は `remember_user_token`。追加入口では発行も復元もしない | Domain 無し。SameSite は初期化子に明示無し | session | レガシー入口の発行と復元は維持。追加入口は Devise の remember 戦略でもログインしない | P4 | 正規ホストの remember が継続する。追加入口へ remember Cookie を渡してもログインしない |
| `SessionActivation#assign_access_token` | セッションごとに Doorkeeper トークン | サーバ共有。Cookie はホスト専用 | session | 入口ごとに別 activation。ログアウトは現在の ID だけ破棄 | P4 | 入口 A のログアウト後、B のトークンが有効 |
| `User#reset_password!` | 全セッションと全トークンを無効化 | サーバ全体 | session | unchanged | P4 | パスワードリセットで全入口が落ちる |
| `session_activations.rb` `max_session_activations` | 既定 10。超過分は古い順に破棄 | ユーザー単位 | session | unchanged。検証で入口数との関係を見る | P6 | 11 個目のログインが最も古い activation を消す既存挙動 |
| `production.rb` `trusted_proxies` と `remote_ip_extensions.rb` | `TRUSTED_PROXY_IP` 以外の転送ヘッダを拒否 | 接続元 IP | session | unchanged。`CF-Connecting-IP` はアプリが読まないので足さない | P1 | 信頼済みでないピアの X-Forwarded-For が拒否される |
| `rack_attack.rb` | 認証済み API は `authenticated_user_id`。`authenticated_token_id` は未使用。未認証は IP | ユーザーまたは IP。Host は無い | session | Host もトークン id もキーにしない。セッションが増えてもユーザー枠は増えない | P4 | 同じユーザーの二つの入口が認証済み API の枠を共有する |
| `CacheConcern#enforce_cache_control!` | Cookie 等で Vary している認証応答を `no-store` | 応答ごと | session | 認証応答を入口間で共有しない | P4 | ログイン HTML が public キャッシュされない |
| `dist/nginx.conf` `@proxy` | `Host $host`、`X-Forwarded-Proto $scheme`、`X-Forwarded-For`。cache key は未指定 | 受信 Host を転送。キャッシュキーは nginx 既定 | mixed | 参考設定に `$scheme$host$request_uri` と、Cookie/Authorization のバイパスを書く。本番構成は推測しない | P6 | 例示ファイルだけの変更なら、アプリの既定挙動は不変 |

## 6. WebAuthn と第二要素

| 箇所 | 用途 | 現行ホスト | 分類 | 方針 | フェーズ | 回帰 |
| --- | --- | --- | --- | --- | --- | --- |
| `config/initializers/webauthn.rb` | `allowed_origins` は WEB の Origin 一つ。`rp_id` は nil。`rp_name` は Mastodon | WEB_DOMAIN | session | グローバルオブジェクトをリクエストで書き換えない | P4 | `webauthn_spec` の単一 Origin と `rp_id == nil` が維持される |
| webauthn 3.5.1 `AuthenticatorResponse#verify` と options／from_create／from_get | origin が一つで id が nil のとき、RP ID はその Origin のホスト。複数 Origin かつ id nil は検証失敗 | 単一許可 Origin のホスト | session | 入口の RelyingParty は id に既存 RP ID、`allowed_origins` はそのリクエスト Origin 一つ。正規 Origin は足さない。チャレンジはユーザー、用途、TTL、消費を持つ | P4 | 入口で発行したチャレンジを正規 Origin から渡すと失敗。正規ホストの既存キーは成功 |
| `WebauthnCredentialsController#options` / `#create` | 登録。チャレンジは `session[:webauthn_challenge]` | セッションのホスト | session | 正規ホストは今の呼び出し。入口はリクエストスコープの RelyingParty と、Origin・用途に束縛したチャレンジ | P4 | 既存クレデンシャル行を移行しない。入口で新規登録したキーは rpId が正規ホストと一致 |
| `Auth::SessionsController#webauthn_options` と `TwoFactorAuthenticationConcern#valid_webauthn_credential?` | ログイン検証 | グローバル設定とセッションチャレンジ | session | 入口では同じ RelyingParty を options と verify の両方に渡す | P4 | 不正 Origin（spec の `evil.example`）は拒否。OTP とリカバリーコードは入口でも使える |
| `webauthn_credentials` テーブル | `external_id`、公開鍵、sign_count | ユーザー単位。Origin 列は無い | session | unchanged | P4 | 二つの入口で同じキーを使うと sign_count が一つの行で進む |

## 7. PWA、Push、ブラウザ保存

| 箇所 | 用途 | 現行ホスト | 分類 | 方針 | フェーズ | 回帰 |
| --- | --- | --- | --- | --- | --- | --- |
| `ManifestSerializer#scope` / `#start_url` / `#share_target` | `scope` は `root_url`（RoutingHelper なので WEB）。`start_url` は相対パス。`id` は無い | WEB と相対パス | static-asset | レスポンス時のリクエスト Origin で scope とアイコンを組む。`id` は入口ごと。複数入口で共有しない | P5 | 正規ホストの manifest scope が正規 Origin |
| `config/webpack/production.js` OfflinePlugin | `sw.js` を `/` スコープで生成 | 配信された Origin | static-asset | スコープ `/` を維持。入口ごとに別 SW | P5 | 正規ホストの SW が今のスコープ |
| `service_worker/web_push_notifications.js` | クリックは `self.location`。`icon` は `avatar_static`、`image` と `hiddenImage` は `preview_url`、失敗時はペイロードの `icon` | クリックは SW の Origin。画像は JSON の絶対 URL | media-asset, session | クリックと API は同一 Origin。画像は M1／M2。トークンは画像に付けない | P5 | 通知の画像リクエストが他のインスタンス入口へ出ない |
| `Web::PushSubscription#associated_access_token` | `access_token_id` が空だと `find_or_create_access_token` が activation に紐づかない superapp トークンを作る | 未束縛の superapp | session | 追加入口ではこの fallback を使わない。購読はその activation の束縛トークンだけ | P5 | レガシーの fallback トークンは追加入口で拒否。ログアウトは自分の activation だけ |
| `settings.js` localStorage、`storage/db.js` IndexedDB `mastodon` | 表示設定とオフラインキャッシュ。絵文字セットのマーカーも localStorage | Origin ごと | session | 入口をまたいで複製しない | P5 | 入口 B に A の localStorage 下書きが出ない。サーバ保存の下書きは両方から見える |
| `service_worker/entry.js` の sign-out | その SW の IndexedDB を削除 | その Origin | session | unchanged | P5 | 他 Origin の DB が残る |

## 8. 連合を入口でどう扱うか

| 箇所 | 用途 | 現行ホスト | 分類 | 方針 | フェーズ | 回帰 |
| --- | --- | --- | --- | --- | --- | --- |
| `config/routes.rb` の HTML 制約と ActivityPub コントローラ | 同じパスで HTML と ActivityPub 表現を分ける。拒否は route と action | リクエスト Host。JSON の id は WEB | mixed | Actor 系の ActivityPub 表現だけ 406 と正規 URL。REST、manifest、WebUI JSON は 406 にしない | P4 | 正規ホストの content negotiation と `/api` が今どおり |
| `ActivityPub::InboxesController` | 共有 inbox とアカウント inbox。署名必須。Host の独自検査は無い | リクエスト Host | federation-transport | UI 入口の POST は 404。正規と alternate は unchanged | P4 | 正規 inbox の署名付き POST が 202 |
| `InstanceActorsController` `/actor` | インスタンス Actor JSON | リクエスト Host で JSON。id は WEB | federation-transport | UI 入口では拒否 | P4 | 正規 `/actor` の id が WEB |
| `ExternalBridge::Rss::PlayerResolver#instance_host?` | RSS プレイヤー用に web、local、alternate と、そのサブドメイン接尾辞を自インスタンスとみなす | 上記に加え接尾辞 | external | UI 許可リストには使わない。完全一致の別判定にする | P1 | このメソッドの真偽が UI 入口追加で変わらない |

## 9. 初回レビューで追った箇所

二回目の検索で、ドメイン名の一覧に無かった消費先を足した。方針の詳細は設計文書の対応する節である。

| 箇所 | 用途 | 現行ホスト | 分類 | 方針 | フェーズ | 回帰 |
| --- | --- | --- | --- | --- | --- | --- |
| `streaming/index.js` `accountFromRequest` | トークンを Bearer、クエリ、`Sec-WebSocket-Protocol` から取る。Host も `issued_origin` も見ない | トークンが有効ならどの Host でも可 | streaming | 正本は activation の nullable `issued_origin`。NULL はレガシー経路。非 NULL はその Origin だけ。閉鎖は発行停止のあと対象 Origin だけを失効する。superapp だけでは分類しない | P4 | 束縛トークンを正規ホストや専用 Streaming へ持っていくと 401。未束縛トークンはレガシー経路で今どおり、追加入口では拒否 |
| `dist/nginx.conf` の `/ns`、静的 `/packs`、`/api/v1/streaming` | Rails の Host Authorization を通らない | `server_name` の例は `example.com` | static-asset | 公開前は edge が新しい名前を受けない。公開後も転送ヘッダを上書きし、認証応答をキャッシュしない | P6 | アプリのフラグだけではこれらの経路が開かない |
| Rails `request.host` / `request.url` | `X-Forwarded-Host` を実効ホストに使うことがある。信頼済みプロキシのときだけ、とは仮定しない | raw Host と転送ヘッダは別 | session | raw Host と Cookie／Origin に使うホストが一致しなければ拒否。IP の `TRUSTED_PROXY_IP` とは別の検査 | P1 | `Host` と `X-Forwarded-Host` が別の許可済みホストなら拒否 |
| `on_authentication_success` の `remember_me` | ログイン成功のたびに remember Cookie を書く | `remember_user_token` | session | 追加入口では書かず、remember からの復元も拒否する。レガシー入口は今のまま | P4 | 追加入口に remember Cookie が出ず、既存の remember でもログインしない |
| `session[:attempt_user_id]` と `session[:webauthn_challenge]` | 未認証の 2FA は Cookie Store。追加入口のチャレンジ正本は Redis。Cookie には nonce だけ | 正規ホストは文字列チャレンジ | session | スコープは Origin、用途、ユーザー、試行または activation。別入口のチャレンジは消さない。正規ホストの文字列チャレンジは維持 | P4 | 古い Cookie の再送は失敗する。別入口の進行中チャレンジは残る |
| `CacheConcern#enforce_cache_control!` | Vary に Cookie 等があり、そのヘッダが付いているときだけ no-store | 応答ごと | session | edge は Set-Cookie、認証付き HTML、初期状態、認証 API、認証付きリダイレクトを保存しない | P6 | Cookie 付きリクエストに公開キャッシュを返さない |
| 連合の content negotiation | 拒否は Actor、inbox、WebFinger、NodeInfo、host-meta の route と action。JSON 一般ではない | リクエスト Host | federation-transport | REST、manifest、WebUI JSON は 406 にしない。表は設計文書 | P4 | 正規ホストの Actor JSON と `/api` が今どおり |
| `Api::BaseController#current_user` | `current_resource_owner \|\| super`。`:null_session` は Cookie fallback を止めない | Cookie セッションまたは Bearer | session | Bearer が無効または別 Origin の束縛なら 401。Cookie へ落ちない。主体が食い違うときも 401。公開 GET はユーザーを足さない | P4 | 追加入口のトークンを正規ホストへ持っていくと 401。ゲートを閉じたあとも revoke 済みで 401 |
| `SessionActivation` | 発行 Origin の列は無い。トークンは `access_token_id` | 未束縛 | session | nullable の `issued_origin` を正本にする。既存行は NULL。全件 backfill はしない | P4 | NULL のトークンはレガシー経路で使える。非 NULL は発行 Origin 以外で拒否 |

## 実装時に再実行する確認

新しい URL 生成を足した PR は、設計文書の `git grep` を基点との差分に対してやり直す。ヒットしたファイルが上の表の機構に入っていることを確認する。入っていなければ行を足してからマージする。

特に次は、ヒット数が増えたら個別に見る。

- `include RoutingHelper` が増えて、API の Link が WEB 固定になっていないか
- `window.location`、`fetch(`、`axios`、`new WebSocket`、`new EventSource` が絶対 URL をトークン付きで使っていないか
- `local_uri?` または `local_url?` の条件に UI ホストが混ざっていないか
- `WebAuthn.configuration.allowed_origins` への代入が初期化子以外に無いか
