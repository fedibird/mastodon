# WEB_UI_DOMAINS の監査と設計（P0）

状態: P0。設計、監査表、検証手順だけ。アプリ、設定、依存関係、DB migration、デプロイは変えない。この設計がレビューで承認されるまで P1 以降の実装に進まない。

親の要件は [#863](https://github.com/fedibird/mastodon/issues/863)。この段階の成果物は [#866](https://github.com/fedibird/mastodon/issues/866)。監査の行は `docs/web_ui_domains_p0_audit.md`。

基点コミット: `54bd41378f`（`fedibird`。[#865](https://github.com/fedibird/mastodon/pull/865) マージ済み、webauthn 3.5.1）。`WEB_UI_DOMAINS` という識別子はこの基点に無い。

## この P0 で固定する振る舞い

ユーザーが開いた入口の Origin で、WebUI から Fedibird への自動通信を完結する。同じブラウザで、入口ごとに別のアカウントへ同時ログインできる。

正規のインスタンス識別は今のままにする。

| 設定 | 今の意味 | この設計での扱い |
| --- | --- | --- |
| `LOCAL_DOMAIN` | acct のドメイン。`config.x.local_domain` | 変えない |
| `WEB_DOMAIN` | 正規の Actor/Object/HTTP URL のホスト。未設定時は `LOCAL_DOMAIN`。`config.x.web_domain` | 変えない。URL 生成の正本 |
| `ALTERNATE_DOMAINS` | WebFinger の acct 別名。`config.hosts` にも入る | 変えない。UI 入口とは別 |
| `WEB_UI_DOMAINS` | 無い | 追加の WebUI 入口。カンマ区切りのホスト名。例: `cf.fedibird.com,cdn.fedibird.com,1.fedibird.com,2.fedibird.com` |

`WEB_UI_DOMAINS` が空、または後述の有効化ゲートが閉じている間は、今の単一 Origin の挙動にする。DNS と CDN の選択は管理者が入口の外で行う。アプリは与えられた Host を許可リストと照合するだけにする。

発行する Actor/Object URI、ActivityPub、WebFinger、NodeInfo、HTTP 署名、REST のフィールド名と値、キャッシュ済み本文、Streaming イベントの意味は変えない。正規 URL の文字列一括置換と、プロセス全体の `default_url_options` の書き換えはしない。

## 三つの URL

| 種類 | 例 | 誰が使うか |
| --- | --- | --- |
| 正規 URL | `https://fedibird.com/users/alice`、`acct:alice@fedibird.com` | 連合、署名、共有、メール、ネイティブクライアント、REST/ActivityPub の保存値 |
| 入口 URL | `https://1.fedibird.com/web/timelines/home` | そのタブの WebUI。API、Streaming、アプリ自身の静的ファイル、アプリ自身が配信するメディア、ログイン |
| 外部 URL | 他サーバー、S3/Swift の別名ホスト、明示した CDN、OAuth の相手 | そのサービスのホストのまま。Fedibird が任意の外部サイトをプロキシすることはしない |

WebUI は正規 URL をデータとして保持する。画面遷移と、Fedibird 自身への自動リクエストに使うときだけ、許可済み入口へ投影する。投影はブラウザ側か、そのリクエストの応答組み立てで行い、保存済み文字列と他クライアント向け JSON は正規ホストのままにする。

## レビューで決める提案

実装はこれらの採用を待ってから行う。推奨を先に書く。

1. **有効化ゲート。** `WEB_UI_DOMAINS` を読んでも、`WEB_UI_DOMAINS_READY=true` かつ検証を通過するまで `config.hosts` にも WebAuthn にも反映しない。途中の PR をマージしても入口は開かない。推奨は二段階ゲート。
2. **登録できるホスト。** 既存の WebAuthn RP ID（下の「認証」）と一致するホストか、そのホストのサブドメインだけを許可する。別の registrable domain は起動時に拒否する。RP ID を親ドメインへ広げる変更は、登録済みキーの rpId ハッシュと一致しなくなるため行わない。`LOCAL_DOMAIN != WEB_DOMAIN` で正規ホストがすでにサブドメインのとき、その兄弟名（`cf.example.com` に対する RP ID `web.example.com`）は既存キーを使えない。その場合も拒否する。
3. **`ALTERNATE_DOMAINS` との重複。** 同じホストが両方に入っていたら起動時に拒否する。WebFinger 別名と UI 専用入口を一つの名前に重ねない。
4. **Streaming。** ゲートが開いている WebUI では、初期状態の Streaming URL をそのリクエストの Origin の `wss://`（開発時は `ws://`）にする。`STREAMING_API_BASE_URL` は `/api/v1/instance` と、UI 入口ではない専用 Streaming ホスト向けに残す。その値が別の `WEB_UI_DOMAINS` ホストを指すとき、WebUI はそれを使わず同一 Origin にする。
5. **アセット。** UI 入口の HTML から出す JS/CSS/フォント/アプリ配下のパスは同一 Origin の相対 URL にする。`CDN_HOST` が別の UI 入口でも、そこへ自動では取りにいかない。`S3_ALIAS_HOST` / `S3_CLOUDFRONT_HOST` / Swift のオブジェクトホストはストレージ例外として残す。REST JSON には入口ホストを書き込まない。
6. **メール、SAML、CAS、ATProto、外部 OAuth。** コールバックと本文リンクは `WEB_DOMAIN` のままにする。入口へ戻すワンタイムコードは、この一連の必須範囲に入れない。戻しを足すときは、トークンをクエリに載せず、許可した相対パスだけを返す。
7. **Cookie 名。** `__Host-` への改名は有効化リリースに入れない。既存セッションを一斉に落とさない。ホスト束縛は今の署名付き Cookie の値を二重読みする形で足す（「セッション」）。
8. **入口の選択 UI。** P1 から P5 では作らない。ユーザーは入口の URL を開く。入口をまたぐスイッチャは Cookie をコピーしない明示遷移として、別仕様にする。
9. **連合を別名入口で受けるか。** UI 入口では HTML の WebUI と、その UI が使う同一 Origin の API/Streaming/アセットを返す。ActivityPub の content negotiation、inbox/outbox、WebFinger、host-meta、NodeInfo、インスタンス Actor は拒否し、正規 URL を案内する。別名を新しい Actor や Node として広告しない。HTTP 301 で入口全体を正規ホストへ寄せることはしない。
10. **本文中の正規リンク。** 通常クリックはアプリ内ルートへ留める。新規タブ、コピー、共有は正規 URL のままにする。

## ホストの正規化

P1 のパーサは次を満たす。比較は許可リストとの完全一致で、サブドメインの一括信頼や文字列の前方一致は使わない。

- 前後の空白を除き、カンマで分割し、空要素を落とす。
- スキーム、パス、クエリ、フラグメント、ユーザー情報を拒否する。値はホスト名だけにする。
- 小文字化し、Addressable で IDN を ASCII ホストへ正規化する。
- ポート、ワイルドカード、IP リテラル、末尾ドット、空ラベルを拒否する。本番の Origin は `https://` と既定ポート 443 だけにする。
- 重複は拒否する。`WEB_DOMAIN` と `LOCAL_DOMAIN` のホスト自身がリストに入っていたら、その要素は追加入口ではないので拒否する（正規ホストはもともと入口である）。
- `ALTERNATE_DOMAINS` との積は拒否する（提案 3）。
- WebAuthn の接尾辞条件を満たさないホストは拒否する（提案 2）。
- 不正な値が一つでもあれば、リスト全体を無効にし、ゲートは開かない。一部だけ採用しない。

`config.hosts` へ入れる文字列は、ブラウザが送る Host ヘッダと一致する正規化後のホスト名である。`X-Forwarded-Host` は見ない。

## リクエスト境界

グローバルな `config.x.web_domain` と `ActionMailer::Base.default_url_options` はリクエストごとに変えない。

入口判定はリクエストローカルなオブジェクトに閉じ込める。

- ゲートが閉じている、または Host が正規ホストである: 今の挙動。
- Host が許可済み UI 入口である: WebUI 向けの投影と、連合エンドポイントの拒否をそのリクエストだけに適用する。
- それ以外: 今どおり Host Authorization が拒否する。テスト環境は `config/initializers/1_hosts.rb` が `config.hosts` を設定しない。本番の許可リストは、テストで `config.hosts` を明示した request spec で見る。

Rails の URL ヘルパは二系統ある。

- `RoutingHelper#default_url_options` はメーラー設定を返す。ここを include する serializer、`TagManager`、`ActivityPub::TagManager`、WebFinger、host-meta、メディアプロキシは **WEB_DOMAIN** を出す。正規 ID はこちらに残す。
- `ApplicationController` は `default_url_options` を上書きしない。API コントローラの `*_url`（Link ヘッダ）と、通常の HTML の `url_for(only_path: false)` は **そのリクエストの Host** を使う。`og:url` は `app/views/shared/_og.html.haml` がこの形である。

この分岐を崩さない。Link ヘッダを WEB_DOMAIN に寄せる変更も、serializer の `url` を入口ホストへ寄せる変更もしない。

## WebUI の自動通信

axios（`app/javascript/mastodon/api.js`）は `baseURL` を持たず、`/api/v1/...` のような相対パスでページの Origin へ送る。`Authorization: Bearer` は Redux `meta.access_token`、CSRF は `meta[name=csrf-token]` である。相対パスはこのままにする。

絶対 URL を自動リクエストに使う前に、`new URL` で分解し、次がすべて一致するときだけ同一 Origin とみなす。

- スキームがページと同じ `https` または `http`
- ホストが punycode で一致
- ポートが一致
- ユーザー情報が無い

一致しない絶対 URL には `Authorization` を付けない。`credentials` は付けない。EventSource の `access_token` クエリにも載せない。文字列の `startsWith(origin)` は使わない。`https://fedibird.com.evil.example`、ユーザー情報付き URL、バックスラッシュやエンコードでホストが変わる URLは、パーサが別 Origin と判定したものとしてトークンを付けない。

Fedibird 自身のアプリパス（API、Streaming、`/packs`、`/emoji`、`/system`、既存のメディアプロキシ配下）で、ホストが正規ホストか許可済み UI 入口のときは、パスとクエリを保ったままページ Origin の相対 URL へ投影してから送る。判定不能な URL はフェイルクローズで、自動リクエストしない。ユーザーが明示した外部リンクは、トークン無しの遷移として残す。

ページネーションは二種類ある。

- タイムラインの追加読み込みは、最後の ID から相対パスを組む。この形を維持する。
- `scheduled_statuses` など一部は Link の絶対 URL を `api.get` に渡す。サーバは API コントローラの `*_url` でリクエスト Host の絶対 URL を出す。クライアントは上記の同一 Origin 検査を通ったものだけを Bearer 付きで追う。検査に落ちたらそのページ送りを止める。

初期状態（`InitialStateSerializer#meta`）の `streaming_api_base_url` は、今は `config.x.streaming_api_base_url` 固定で、本番の既定は `wss://WEB_DOMAIN` である。ゲートが開いた WebUI では提案 4 のとおりリクエスト Origin にする。`/api/v1/instance` の `urls.streaming_api` はネイティブクライアント向けに今の設定値のままにする。

`app/controllers/api/v1/streaming_controller.rb` は、リクエスト Host が Streaming 基底と違うと 301 で基底ホストへ送る。`same_host?` はポート省略時に 80 と比較する。`wss://` の既定ポート 443 とは一致しない。例示の `dist/nginx.conf` は `/api/v1/streaming` を Rails の前で Streaming プロセスへ渡す。P2 では、UI 入口から Rails に届いた場合も別入口へ 301 しない。WebSocket のトークンは `@gamestdio/websocket` のプロトコル引数、EventSource はクエリの `access_token` である。HAR に残さない（「検証」）。

`HomeController#redirect_unauthenticated_to_permalinks!` は、未ログインの `/web/statuses/:id` と `/web/accounts/:id` を `ActivityPub::TagManager#url_for` へ送る。これは WEB_DOMAIN の絶対 URL である。HTML の入口では、同じパスをリクエスト Host 上の短絡パスへ戻す。連合用の正規 URL 生成は変えない。

`Permalink` は `href` に正規 URL を持ち、通常の左クリックは `to` のアプリ内ルートへ進む。Ctrl/中クリックは正規 URL を開く。提案 10 のとおり、通常クリックは入口に残し、新規タブとコピーは正規 URL とする。ステータス HTML 内のメンションとハッシュタグは `Formatter` が WEB_DOMAIN の `href` を出す。ActivityPub の `content` は正規のままキャッシュされる。WebUI の表示時だけ、同一インスタンスへの通常クリックをアプリ内遷移にする。

## アセットとメディア

優先順位は次のとおり。REST と共有 URL には入口ホストを混ぜない。

1. WebUI が読むアプリ自身のパスは、入口の相対 URL にする。選んだ入口の CDN がそれをキャッシュする。
2. Paperclip の S3/Swift URL はストレージホストのままにする。`S3_ALIAS_HOST` は `S3_HOSTNAME` より優先され、`CDN_HOST` では書き換えない（`config/initializers/paperclip.rb`）。
3. `CDN_HOST` は、UI 入口ではないアセットホスト、およびメール CSS（`PremailerWebpackStrategy`）に残す。UI 入口の HTML からは、別の UI 入口である `CDN_HOST` へ自動リクエストしない（提案 5）。
4. リモートの画像・動画・カード・絵文字は、今のメディアプロキシとリモート URL のままにする。許可していない URL を入口経由で取得するオープンプロキシは足さない。

`MediaProxyController` は添付 ID と許可した variant だけを受け、302 でストレージ URL へ返す。任意 URL のクエリは無い。再取得は `Remotable` と `Request` のプライベートアドレス検査を通る。Range はアプリ内では処理せず、302 先のストレージに依存する。入口化してもプロキシの許可パス、認可、サイズ、キャッシュは今の制約を維持する。署名付きストレージ URL のクエリは、投影しても改変しない。投影してよいのは「ホストが正規ホストまたは UI 入口で、パスがアプリ自身のもの」だけである。ストレージホストは投影しない。

CSP（`config/initializers/content_security_policy.rb`）は起動時に決まり、`connect-src` は `:self`、アセットホスト、メディアホスト、Streaming 基底を許す。UI 入口どうしを `connect-src` に足さない。バグで別入口へ繋いでも CSP が止める。`form-action` は `:self` のままにする。

CORS（`config/initializers/cors.rb`）は `/api/*` を `origins '*'`、`credentials: false` で開いている。ネイティブアプリと他サーバー向けのこの形は維持する。ブラウザの Cookie 付きクロス Origin はここで開かない。WebUI のトークン送出防止はクライアントの同一 Origin 検査が担う。

## セッション、Cookie、信頼境界

今の Cookie は Domain 属性を持たない。ホスト専用である。

| Cookie | 設定箇所 | 属性 |
| --- | --- | --- |
| `_mastodon_session` | `config/initializers/session_store.rb` | `same_site: :lax`。本番または `LOCAL_HTTPS` で `secure`。Domain 無し |
| `_session_id` | `config/initializers/devise.rb` の Warden フック | 署名付き。HttpOnly。`same_site: :lax`。1 年。Domain 無し。値は `SessionActivation.session_id` |
| `remember_user_token` | Devise `:rememberable`。`rememberable_options` は `secure: true` のみ | Domain 無し。SameSite の明示は初期化子に無い |

ホスト専用なので、入口 A の Cookie は入口 B へ送られない。同一アカウントのサーバデータは共通で、ログイン状態は入口ごとに別の `SessionActivation` になる。`SessionActivation` は作成時に専用の Doorkeeper トークンを作る（`assign_access_token`）。初期状態の `access_token` はそのトークンである。ログアウトは現在の `_session_id` の activation を破棄し、そのトークンも `dependent: :destroy` で破棄する。他入口の activation は残る。パスワードリセットは全セッションと全トークンを無効にする。この既存仕様を維持する。

同時ログインは `MAX_SESSION_ACTIVATIONS`（既定 10、`config/initializers/session_activations.rb`）の枠を消費する。古い activation から破棄される。検証では、入口数とこの上限の両方を見る。

有効化時に既存セッションを落とさないため、Cookie 名は変えない。P4 のホスト束縛は次の二重読みにする。

- 署名付き `_session_id` の値が従来の文字列なら、今どおり受け入れる。正規ホストの既存ログインは継続する。
- 新しく発行する値は、session id と発行ホストを一緒に署名する。検証時、ホストがリクエスト Host と一致するときだけ受け入れる。
- ゲートが閉じている間は従来の文字列だけを書く。

`__Host-` プレフィックスは、Secure、Path=/、Domain 無しをブラウザが強制する。改名は既存 Cookie を読めなくなる。提案 7 のとおり有効化には入れない。サブドメインからの Cookie tossing は、名前が `__Host-` でない限り残る。緩和はホスト専用のまま Domain を付けないこと、UI 入口を運営者の管理下だけにすること、P4 のホスト束縛で「コピーされた session id」を別 Host では拒否することである。許可リストに無いサブドメインをまとめて信用することはしない。

CSRF は HTML が `protect_from_forgery with: :exception`、API が `:null_session`、`Api::Web` は CSRF を要求する。SameSite=Lax のため、別入口からのクロスサイト POST にセッション Cookie は付かない。P4 で、Cookie を使うログインとセッション変更 POST は、`Origin`（無ければ `Referer`）がリクエストの Origin と一致することを追加で見る。欠ける場合は拒否する。ActivityPub inbox は署名で受け、この Origin 検査の対象にしない。

実 IP は `TRUSTED_PROXY_IP` の `config.action_dispatch.trusted_proxies` と、`lib/action_dispatch/remote_ip_extensions.rb` が担う。信頼済みプロキシ以外からの `X-Forwarded-For` / `Client-Ip` は `IpSpoofAttackError` になる。このリポジトリは `CF-Connecting-IP` を読まない。この機能のためにそのヘッダは足さない。Cloudflare を使う場合、オリジンが信頼してよいのは Cloudflare の接続元だけであり、その設定は運営者のプロキシ側で行う。アプリは今の X-Forwarded-For 経路を維持する。

Rack::Attack のキーはユーザー ID、トークン ID、IP であり、Host は含まない。Host をキーに足すと、入口の数だけ制限が緩む。足さない。

キャッシュは `CacheConcern#enforce_cache_control!` が、Vary に Cookie / Authorization / Signature があり、そのヘッダがリクエストに付いているとき `private, no-store` にする。認証済み応答を入口間で共有しない。公開 HTML をプロキシキャッシュするときは、キャッシュキーに `$host` を含める。例示の `dist/nginx.conf` は `proxy_cache_key` を書いておらず、nginx の既定は上流ホストであってクライアントの Host ではない。参考設定では `$scheme$host$request_uri` を提案する。本番の nginx はこのリポジトリに無いので、ここでは断定しない。

## 認証（webauthn 3.5.1）

前提は #865 の単一 Origin である。`config/initializers/webauthn.rb` の `allowed_origins` は `WEB_DOMAIN` の Origin 一つだけである。`rp_id` は設定しない。`spec/initializers/webauthn_spec.rb` は `rp_id` が `nil` であることを固定している。

gem 3.5.1 の挙動は、タグ `v3.5.1` の `authenticator_response.rb` で確認した（この環境の bundle パスは使っていない）。

- `relying_party.id` が nil で、`allowed_origins` が一つだけのとき、検証時の RP ID はその Origin のホストである（`URI.parse(expected_origin.first).host`。ポートは含まない）。
- `allowed_origins` が複数で `id` が nil のとき、`rp_id_from_origin` は nil を返し、`valid_rp_id?` は失敗する。グローバルな許可 Origin に入口を足すと、正規ホストの既存検証も壊れる。
- 登録オプションは `rp.id` が nil なら id を埋めない。ブラウザは呼び出し元 Origin のホストを rpId にする。正規ホストで登録した既存キーの rpId は、`WEB_DOMAIN` のホストである。

したがってグローバル設定は書き換えない。正規ホストの登録と検証は、今の `WebAuthn.configuration` をそのまま呼ぶ。

UI 入口のセレモニーだけ、リクエストスコープの `WebAuthn::RelyingParty.new` を使う。

- `id` は既存の実効 RP ID。つまり今の単一 `allowed_origins` のホスト。ここを親ドメインへ変えない。
- `allowed_origins` はそのリクエストの Origin 一つと、正規 Origin のうち、RP ID の接尾辞条件を満たすもの。入口の Origin が条件を満たさない場合はセレモニーを開始しない。
- チャレンジは今どおりセッションに置く。セッション Cookie がホスト専用なので、入口をまたいでは共有されない。加えて、発行 Origin と用途（登録かログインか）をセッションに結び、検証時にリクエストと一致しなければ捨てる。用途を分けるキーは、進行中のセレモニー以外の既存ログインを落とさない。

WebAuthn の仕様では、RP ID は Origin の実効ドメインそのものか、その registrable domain の接尾辞でなければならない。`WEB_DOMAIN` が `fedibird.com` なら、`https://1.fedibird.com` は rpId `fedibird.com` を使える。登録オプションに rpId を明示しないと、ブラウザは `1.fedibird.com` を rpId にし、既存キーを見つけない。入口では rpId を明示する。

OTP、リカバリーコード、既存の `webauthn_credentials` 行は Origin に縛られていない。入口が違っても同じユーザーの第二要素として使える。サインカウンタはクレデンシャルごとに一つで、どの入口で使っても同じ行を更新する。

外部認証の信頼境界は次のとおり。

- ATProto の client id、redirect、jwks は `ExternalBridge::Atproto::ClientDocument` が `WEB_DOMAIN` 固定である。入口へ複製しない。
- SAML は `SAML_ENABLED` と `SAML_ACS_URL` などの環境変数（`config/initializers/omniauth.rb`）。CAS は `CAS_CALLBACK_URL`。登録済み URL は正規ホストのままにする。
- Doorkeeper の認可は、リクエストが来たホストのセッションを見る。`redirect_uri` はクライアント登録値のまま検証する。入口ホストを許可リダイレクトへ自動追加しない。
- メールのリンクはメーラーの `default_url_options` により `WEB_DOMAIN` である。クリックした人は正規ホストにセッションを作る。別名入口のセッションは別 Cookie なので残る。

## PWA、Push、ブラウザ保存

Service Worker はページの Origin に登録され、スコープは `/`（`config/webpack/production.js` の OfflinePlugin、`publicPath`）である。入口ごとに別の登録になる。Push 購読は `Web::PushSubscription` が `SessionActivation` に紐づく。入口ごとのセッションが、それぞれの購読とトークンを持つ。同じアカウントの通知設定（サーバ保存）は共通である。

クリック先は `app/javascript/mastodon/service_worker/web_push_notifications.js` が `new URL(path, self.location)` で組む。Service Worker の Origin に留まる。この形を維持する。購読のペイロードに載る `access_token` は、そのセッションのトークンである。他入口の SW からは読めない。

`ManifestSerializer` は `RoutingHelper` を include する。`scope` とアイコン絶対 URL は `root_url` になり、今は WEB_DOMAIN である。別 Origin のページから見ると、manifest の scope がそのページの外に出る。P5 では、manifest を返すリクエストの Origin で `scope`、`start_url`、アイコン、`share_target` を組む。`id` は今の serializer に無い。入口ごとに別アプリとしてインストールできるよう、`id` をその Origin にするか、フィールドを付けない。複数入口で一つの `id` を共有しない。

`localStorage`（`settings.js`、絵文字セットの変更マーカー）と IndexedDB `mastodon` は Origin 専用である。サーバの下書きと設定はアカウントで共通、ブラウザ内の未送信バッファは入口で分かれる。ブラウザは Origin をまたいで localStorage を移せない。移すチャネルは作らない。同じアカウントが入口 A と B にログインしているとき、A の下書きバッファは B に出ない。投稿済みデータとサーバ保存の下書きは両方から見える。

BroadcastChannel の使用は、この監査の検索範囲では見つかっていない。絵文字の更新は `document` の CustomEvent である。

VAPID 鍵はインスタンスに一つである。既存購読を壊すローテは、この機能の範囲に入れない。複数 Origin で同じ VAPID 公開鍵を使えることの確認は P5 の検証項目にする。

## 連合境界

UI 入口の Host を `TagManager#local_url?`、`ActivityPub::TagManager#local_uri?`、`WebfingerResource#domain_matches_local?` に入れない。これらは今、WEB_DOMAIN と LOCAL_DOMAIN（`local_url?` は WEB_DOMAIN のみ）を見る。UI ホストを足すと、別名 URL がローカルオブジェクト ID として解釈される。

`alternate_domains` の参照は次だけである。

- `config/initializers/1_hosts.rb` の設定と `config.hosts`
- `WellKnown::WebfingerController#username_from_resource` の acct 書き換え。subject は常に `acct:user@LOCAL_DOMAIN`（`Account#to_webfinger_s`）
- `ExternalBridge::Rss::PlayerResolver#instance_host?`。ここはサブドメイン接尾辞も真にする。UI の許可判定には流用しない

署名検証（`SignatureVerification#build_signed_string`）は、リクエストの Host ヘッダとパスを見る。正規 URI のホストへ読み替えない。UI 入口で ActivityPub の GET/POST を拒否すれば、別名 Host 向けの署名を成功扱いにしてキャッシュさせる経路ができない。既存の正規ホストと `ALTERNATE_DOMAINS` への署名付き GET/POST は、今のコントローラのまま回帰させる。

HTML と ActivityPub は、同じパスでも Accept と format で分かれる（`config/initializers/mime_types.rb` が `application/activity+json` を `:json` に登録、`config/routes.rb` の HTML 制約）。UI 入口では JSON/ActivityPub 形式を 406 とし、`Link` で正規 URL を示す。inbox への POST は 404 とする。WebFinger、host-meta、NodeInfo、`/actor` も UI 入口では拒否し、正規 URL を案内する。`ALTERNATE_DOMAINS` のホストはこの拒否の対象にしない。

## 実装の順序

各 PR はテストできる単位にする。ゲートが閉じている限り、本番の Host 許可とセレモニーは増えない。

| 段階 | 中身 | ゲート |
| --- | --- | --- |
| P1 基盤 | 正規化、拒否規則、リクエストローカルな判定オブジェクト。`config.hosts` は変えない | 閉 |
| P2 API / Streaming / 遷移 | 同一 Origin 検査、初期状態の Streaming、未ログイン短絡リダイレクト、Link の検査。serializer の正規 URL は不変 | 閉。テストは Host を直接渡す |
| P3 アセット / メディア | ブラウザ投影、CSP に兄弟入口を足さない、ストレージ例外 | 閉 |
| P4 認証 / セッション / 連合境界 | ホスト束縛の二重読み、リクエストスコープの RelyingParty、UI 入口での連合拒否、Cookie POST の Origin 検査、`config.hosts` への追加 | この PR で `WEB_UI_DOMAINS_READY` を見て開く。P2 と P3 が無い状態では開かない |
| P5 PWA / Push | manifest をリクエスト Origin に合わせる。SW と Push は入口に留める | P4 の後 |
| P6 総合検証 | 下の手順。実ブラウザと CDN | 有効化のあと |

P4 より前に `config.hosts` へ入口を足すと、セッション分離と WebAuthn が未完了の Host が開く。追加は P4 にまとめる。

## 検証

ここは手順である。この P0 ではアプリを起動して実行していない。

比較の軸は四つである。

- `WEB_UI_DOMAINS` 未設定
- 設定済みで、正規ホストが `LOCAL_DOMAIN` と一致
- `LOCAL_DOMAIN != WEB_DOMAIN`
- 既存の `ALTERNATE_DOMAINS` を維持

正規 URL は、同じステータスとアカウントについて、変更前後と各 Host で ActivityPub JSON、WebFinger subject、署名対象の inbox URL を比較する。違ってよいのは UI 入口での HTML と、UI が組み立てる自動リクエストだけである。

ブラウザの Network/HAR では、選択した入口以外の Fedibird 入口への自動リクエストが 0 件であることを見る。対象はリダイレクト、WebSocket、EventSource、ページ送り、動的 import、メディア、Push のクリックである。意図した例外は、外部リンク、正規 URL の新規タブまたはコピー、ストレージホスト、UI 入口ではない `STREAMING_API_BASE_URL`、メールと外部認証の正規ホストである。例外は HAR に印を付けてレビューする。

HAR とサーバログにはトークンを残さない。

- 保存前に `Authorization`、`Cookie`、`Set-Cookie`、`X-CSRF-Token` を消す
- クエリの `access_token`、WebAuthn のチャレンジと attestation、remember Cookie を消す
- Streaming URL をコピーするときもクエリを落とす
- ログ採取はトークンと Cookie をマスクしたレベルで行う

シナリオは次を含む。

- 3 入口 × 3 アカウントの同時ログイン。投稿、リアクション、通知、設定、下書き、ログアウト、再読込、期限切れ、再ログインで他入口と混ざらない
- 同一アカウントの複数入口。片方のログアウトが他方のセッションと Push を残す。パスワードリセットは両方を無効にする
- WebAuthn の既存キー（正規ホストで #865 以前に登録したもの）、入口で新規登録したキー、OTP、リカバリーコード
- 直接接続と CDN 入口
- 否定: 未許可 Host、偽装した `X-Forwarded-Host`、信頼済みでない接続元からの `X-Forwarded-For`、別 Origin への Bearer、オープンリダイレクト、CSRF、兄弟サブドメインからの Cookie、アカウントの取り違え、認証済み応答の共有キャッシュ、Host を変えただけのレート制限回避

## 調査の範囲と未確認

基点 `54bd41378f` を読み、ripgrep で次を検索した。`vendor`、`node_modules`、`tmp`、`log`、ロケール YAML の翻訳文は対象外にした。WebAuthn の現行契約を固定している spec は読んだ。

```sh
git grep -n -E 'WEB_DOMAIN|LOCAL_DOMAIN|ALTERNATE_DOMAINS|alternate_domains|web_domain|local_domain' -- '*.rb' '*.js' '*.haml'
git grep -n -E 'local_url\?|local_uri\?|web_domain\?|local_domain\?' -- '*.rb'
git grep -n -E 'CDN_HOST|S3_ALIAS_HOST|S3_HOSTNAME|STREAMING_API_BASE_URL|asset_host' -- '*.rb' '*.js'
git grep -n -E 'streaming_api_base_url|access_token' -- app/javascript app/serializers/initial_state_serializer.rb
git grep -n -E '_session_id|_mastodon_session|rememberable_options|cookie_store' -- '*.rb'
git grep -n -E 'WebAuthn|allowed_origins|rp_id' -- '*.rb'
git grep -n -E 'config\.hosts|trusted_proxies|CF-Connecting-IP|X-Forwarded' -- '*.rb' '*.conf' '*.erb'
```

未確認のまま残しているもの:

- Rails は起動していない。`og:url` がリクエスト Host になるという判断は、`ApplicationController` が `default_url_options` を上書きしないことと、ビューが `url_for(only_path: false)` を呼ぶことから導いた。
- webauthn 3.5.1 の RP ID 導出は GitHub の `cedarcode/webauthn-ruby` タグ `v3.5.1` を読んだ。ローカルの `bundle show` は使っていない。
- 本番の nginx、CDN、証明書、Cloudflare の実設定はこのリポジトリに無い。`dist/nginx.conf` と `nanobox/*.conf` は例である。
- `remember_user_token` の SameSite は、この初期化子では明示されていない。
- メディアの Range は 302 先のストレージ依存で、エッジの対応は未確認である。
- 複数 Origin で同一 VAPID 鍵を使えることは P5 で確認する。
- `*_url` の全呼び出しを行単位では列挙していない。機構ごとに代表箇所を監査表へ書いた。実装 PR は上の検索をやり直して、新しい生成箇所が表に載っていることを確認する。
