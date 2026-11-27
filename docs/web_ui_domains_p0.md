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

初回レビュー（PR #867）を受けて、推奨は次に更新した。実装は採用を待ってから行う。比較が要る項目は本文の該当節に表がある。

1. **公開ゲート。** P1 から P5 のマージでは本番の入口を開かない。検証環境だけで全経路を開き、P6 の総合検証のあと、運営者が明示した本番公開で初めて DNS、edge、アプリが揃って開く。`WEB_UI_DOMAINS` を書いただけでは開かない。詳細は「公開ゲート」。
2. **登録できるホスト。** 既存の WebAuthn RP ID と一致するホストか、そのサブドメインだけを許可する。別の registrable domain と、RP ID の兄弟名は起動時に拒否する。RP ID を親ドメインへ広げない。この初期範囲は既存キーとの互換を優先する。
3. **`ALTERNATE_DOMAINS` との重複。** 同じホストが両方に入っていたら起動時に拒否する。ゲートの開閉は `ALTERNATE_DOMAINS` の WebFinger を変えない。
4. **Streaming。** 厳密モードは追加入口だけである。正規ホスト、`LOCAL_DOMAIN`、`ALTERNATE_DOMAINS` は、公開後も今の `STREAMING_API_BASE_URL`（専用ホストを含む）のままにする。未設定時は挙動を変えない。追加入口のブラウザだけが同一 Origin の `wss`／`ws` を使う。`/api/v1/instance` の広告値は変えない。
5. **メディアと静的ファイル。** 一律のストレージ例外にはしない。インスタンス入口（`LOCAL_DOMAIN`、`WEB_DOMAIN`、他の `WEB_UI_DOMAINS`）への自動アクセスは 0 にする。専用ストレージ／CDN を例外にする案と、入口の固定パスで配信する案は「アセットとメディア」で分けて書く。推奨は、計算したホストがインスタンス入口なら同一 Origin、それ以外の専用ホストだけ例外。
6. **外部認証。** 初期範囲では、SAML、CAS、`OAUTH_REDIRECT_AT_SIGN_IN` のいずれかが必須のサーバでは追加入口を公開しない。パスワード、OTP、WebAuthn で入れるサーバを先行する。IdP 対応は別設計である。必須でないサーバでも、追加入口から正規 callback へ黙って遷移しない。
7. **Cookie。** 正規ホストと `ALTERNATE_DOMAINS` の Cookie 名は変えない。新しい UI 入口だけ `__Host-` 名を使う。旧形式の署名付き `_session_id` を新しい入口では受けない。比較は「セッション」。
8. **入口の選択 UI。** P1 から P5 では作らない。ユーザーは入口の URL を開く。
9. **連合。** 新しい UI 入口では、HTML と同一 Origin の API／Streaming／アセットを返す。ActivityPub の表現、inbox、WebFinger、host-meta、NodeInfo、インスタンス Actor は拒否し、正規 URL を案内する。`/api/*` の REST JSON は 406 にしない。判定表は「連合境界」。
10. **内部リンク。** 同一インスタンスのリンクは、左クリック、Ctrl／Cmd、中クリック、コンテキストメニューの「リンクを開く」も現在の入口を開く。正規 URL を出すのは、明示した「投稿 URL をコピー」「共有」「正規 URL で開く」だけである。

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

`config.hosts` へ入れる文字列は、ブラウザが送る Host ヘッダと一致する正規化後のホスト名である。入口判定は raw Host だけでは終わらない。Rails の `request.host`、`request.url`、`redirect_to` は、信頼済みプロキシ経由のとき `X-Forwarded-Host` と `X-Forwarded-Proto` を実効 Origin に使う。設計は「転送ヘッダ」。

## リクエスト境界

グローバルな `config.x.web_domain` と `ActionMailer::Base.default_url_options` はリクエストごとに変えない。

入口判定はリクエストローカルなオブジェクトに閉じ込める。

- ゲートが閉じている: すべてのホストで今の挙動。追加入口は開かない。
- 公開後の正規ホスト、`LOCAL_DOMAIN`、`ALTERNATE_DOMAINS`: レガシーモード。Streaming、Cookie 名、WebAuthn のグローバル設定は今のまま。
- 公開後の追加入口: 厳密モード。同一 Origin の自動通信、`__Host-` Cookie、発行 Origin に束縛したトークン。
- それ以外: 今どおり Host Authorization が拒否する。テスト環境は `config/initializers/1_hosts.rb` が `config.hosts` を設定しない。本番の許可リストは、テストで `config.hosts` を明示した request spec で見る。

Rails の URL ヘルパは二系統ある。

- `RoutingHelper#default_url_options` はメーラー設定を返す。ここを include する serializer、`TagManager`、`ActivityPub::TagManager`、WebFinger、host-meta、メディアプロキシは **WEB_DOMAIN** を出す。正規 ID はこちらに残す。
- `ApplicationController` は `default_url_options` を上書きしない。API コントローラの `*_url`（Link ヘッダ）と、通常の HTML の `url_for(only_path: false)` は **そのリクエストの Host** を使う。ゲートが閉じている間の `og:url` はこの形である。

Link ヘッダを WEB_DOMAIN に寄せる変更も、serializer の `url` を入口ホストへ寄せる変更もしない。公開後の追加入口で `og:url` と `rel=canonical` だけ正規 URL にする例外は「内部リンクと公開メタデータ」に書く。保存値の一括置換ではない。

## 転送ヘッダ

入口の実効 Origin は、正規化後の raw `Host` と、Rails／Streaming が使う `request.host` およびスキームが一致したときだけ成立する。

例示の `dist/nginx.conf` は `Host $host` と `X-Forwarded-Proto $scheme` を上書きし、`X-Forwarded-Host` は付けない。`server_name` に無い名前でも、nginx の default server が受け得る。参考設定では、知らない Host と SNI の不一致を default server で拒否する。静的ファイル、Streaming、`/ns` を含む全 location で、`Forwarded` と `X-Forwarded-*` を消してから edge が上書きする。本番のプロキシ構成はリポジトリに無い。

`request.host` が信頼済みプロキシの `X-Forwarded-Host` だけを見る、とは仮定しない。`TRUSTED_PROXY_IP` と `remote_ip_extensions.rb` は接続元 IP の検査であり、Host の信頼とは別である。アプリは raw `Host` と、Cookie と Origin に使うホストが一致しなければ拒否する。

公開後の edge は、クライアントが送った値を連結しない。

- `Host` は、edge が証明書と server_name で受けたホストのまま上流へ渡す。
- `X-Forwarded-Host` は消すか、その同じホストで上書きする。クライアントの値は捨てる。
- `X-Forwarded-Proto` は edge が終端したスキームで上書きする。
- `Forwarded` は消す。

Rails と Node Streaming は、正規化後の raw `Host` と実効ホストが違うリクエストを拒否する。両方とも許可リストに入っていても拒否する。例: `Host: 1.fedibird.com` かつ `X-Forwarded-Host: fedibird.com`、およびその逆。信頼済みでない接続元からの `X-Forwarded-For` は、今の `remote_ip_extensions.rb` が拒否する。この機能のために `CF-Connecting-IP` は足さない。

`dist/nginx.conf` の静的ファイル、`/api/v1/streaming`、`/ns` は Rails の Host Authorization を通らない。これらの経路の Host 許可は edge の server_name が担う。アプリに届いたリクエストの拒否は Rails と Streaming が担う。責任の分割は「公開ゲート」。

## WebUI の自動通信

axios（`app/javascript/mastodon/api.js`）は `baseURL` を持たず、相対パスでページの Origin へ送る。インスタンスは `Authorization: Bearer` と `X-CSRF-Token` を同時に付ける。送出前の共通ガードが、この二つのヘッダ、WebSocket のサブプロトコル、EventSource の `access_token` クエリを同じ判定にかける。

ガードは `new URL(input, document.baseURI)` で分解する。次をすべて満たすときだけ自動リクエストを送る。

- スキームがページと同じ `http` または `https`（Streaming は同じホストの `ws` または `wss`）
- ホストが punycode でページと一致
- ポートが一致
- ユーザー情報が無い
- network-path（`//host/...`）をページ以外のホストへ解決しない

不一致かパース不能なら、その URL では通信を開始しない。Bearer や CSRF を外して送り直すことはしない。文字列の `startsWith` や `split('/')` は使わない。`public_quote_navigation.js` の `url.split('/')[2]` は、通信を始める前のこの判定へ置き換える。

ブラウザの XHR と EventSource は、リダイレクトを追う前に `Location` を渡せない。axios の `maxRedirects` もブラウザの XHR では効かない。追跡後の `responseURL` 検査は、別入口への通信が起きたあとである。厳密モードの保証は、応答を出す側にある。

- 追加入口の API、Streaming、メディアは、別 Origin の `Location`、`Refresh`、meta refresh を出さない。返すなら同一入口の相対パスだけにする。Rails の Streaming 301 は、追加入口では出さない。
- こちらが `fetch` を呼ぶ箇所（Service Worker の通知 API を含む）は `redirect: 'error'` にする。`redirect: 'manual'` の opaque redirect は成功として読まない。
- WebSocket はページが `https` なら `wss`、`http` なら `ws` だけを、同一ホストで開く。ダウングレードした URL はコンストラクタを呼ばない。クエリの `access_token` と `Sec-WebSocket-Protocol` は、その判定のあとでだけ付ける。試験は、不一致のときにハンドシェイクも EventSource も発生しないことである。
- CSP の `connect-src` は、追加入口の文書では `:self` と、インスタンス入口ではない M2 ホストだけにする。CSP は二段目であり、これだけで 0 件を保証したことにはしない。

相対パスはページ Origin への解決後に同じ判定を通す。明示した外部リンクは別関数で、API クライアントを使わず、CSRF も Bearer も付けない。

Streaming のモードは次のとおりである。未設定と公開前は、どの行も「今の挙動」である。

| 公開 | クライアント | ページまたは API のホスト | WebUI / クライアントの Streaming |
| --- | --- | --- | --- |
| 閉 | ブラウザもネイティブも | 正規、`LOCAL_DOMAIN`、`ALTERNATE_DOMAINS` | 今の `STREAMING_API_BASE_URL`。専用ホストを含む |
| 閉 | どれでも | 追加入口 | 開かない |
| 開 | ブラウザ | 正規、`LOCAL_DOMAIN`、`ALTERNATE_DOMAINS` | レガシーモード。専用 Streaming も今のまま。厳密モードには入れない |
| 開 | ブラウザ | 追加入口 | 厳密モード。同一 Origin の `wss` または `ws` だけ。専用ホストへは繋がない |
| 開 | ネイティブ | 正規ホストと、インスタンス API が広告する Streaming | `/api/v1/instance` の値は変えない。未束縛トークンは今の経路 |
| 開 | ネイティブまたは未束縛トークン | 追加入口 | 拒否する |

正規ホストの WebUI も厳密モードにする変更は、この初期範囲に入れない。行うなら別の移行として仕様を書く。

ページネーションは二種類ある。

- タイムラインの追加読み込みは、最後の ID から相対パスを組む。この形を維持する。
- `scheduled_statuses` など一部は Link の絶対 URL を `api.get` に渡す。ガードを通った同一 Origin だけを追う。それ以外はページ送りを止める。

`Api::V1::StreamingController#index` は、リクエスト Host が Streaming 基底と違うと 301 する。`same_host?` はポート省略時に 80 と比較するので、`wss://` の 443 とは一致しない。公開後の UI 入口では別入口へ 301 しない。Node は `streaming/index.js` でトークンを `Authorization`、クエリ `access_token`、`Sec-WebSocket-Protocol` から取る。Host は見ていない。WebUI 用トークンとネイティブトークンの差は「セッション」に書く。

## 内部リンクと公開メタデータ

同一インスタンスへのリンクは、現在の入口の絶対 URL を `href` にする。SPA の `to` も同じパスである。左クリック、Ctrl／Cmd、中クリック、コンテキストメニューの「リンクを開く」は、ブラウザがその `href` を開くので現在の入口に留まる。

| 操作 | URL |
| --- | --- |
| アプリ内遷移、新規タブ、リンクのアドレスをコピー | 現在の入口。`href` がそうであるため |
| 「投稿 URL をコピー」「共有」「正規 URL で開く」 | API が返す正規 URL。`href` とは別の値 |

ブラウザの「リンクのアドレスをコピー」は `href` をコピーする。正規の共有 URL が欲しい操作は、画面上の共有アクションが正規フィールドを読む。この差を UI の文言で示す。ActivityPub の保存 HTML は正規 `href` のままである。WebUI が描画するときだけ、同一インスタンスの `href` を現在の入口へ投影する。`packs/public.js` の `.webapp-btn` と引用クリック（`public_quote_navigation.js`）もこの投影後の URL を開く。

未ログインの `/web/statuses/:id` を `ActivityPub::TagManager#url_for`（WEB_DOMAIN）へ飛ばす `HomeController` のリダイレクトは、公開後の HTML 入口では現在の入口の短絡パスにする。正規 URL の生成関数は変えない。

`og:url` と `rel=canonical` は、追加入口では正規 URL を出す。共有カードと検索が第二のインスタンス識別を作らないようにするためである。ゲートが閉じている間は、今の `url_for(only_path: false)` と `about_url`（リクエスト Host）を維持する。

## アセットとメディア

REST と ActivityPub の保存値には入口ホストを書かない。ブラウザが自動で読む URL と、302 の `Location` は次の二つの提案で分類する。インスタンス入口とは `LOCAL_DOMAIN`、`WEB_DOMAIN`、および他の `WEB_UI_DOMAINS` のホストである。

**提案 M1（推奨の第一段）。** 計算した配信ホストがインスタンス入口なら、現在の入口の固定パスで配信する。対象パスは既存の `/packs`、`/emoji`、`/system`、`/media_proxy`、`/headers`、アバターとヘッダのアプリ配下である。`MediaProxyController#show` は `RoutingHelper#full_asset_url` を `Location` にする。ローカルディスクではこれが `root_url`（WEB_DOMAIN）の絶対 URL になる。ブラウザの `src` を投影しても、302 が正規ホストへ戻す。公開後は、この `Location` も現在の入口の同一 Origin にする。認可、許可 variant、サイズ、キャッシュ、Range の扱いは維持する。Range はアプリが処理せず、最終の配信先に依存する。

**提案 M2（専用ホストだけの例外）。** `S3_ALIAS_HOST`、`S3_CLOUDFRONT_HOST`、Swift のオブジェクトホスト、`CDN_HOST` がインスタンス入口のどれでもないときだけ、その専用ホストへの自動リクエストを許す。Paperclip は別名ホストを `S3_HOSTNAME` より優先し、`CDN_HOST` では書き換えない。メール CSS（`PremailerWebpackStrategy`）は `CDN_HOST`、無ければ `WEB_DOMAIN`、それも無ければ `LOCAL_DOMAIN` を今どおり使う。メールはブラウザの入口通信ではない。

優先順位:

1. 配信ホストがインスタンス入口なら M1。別の入口や正規ホストへは自動で取りにいかない。
2. それ以外で専用ストレージまたは CDN が設定されていれば M2。
3. どちらも無ければ現在の入口の相対パス。

インスタンス入口には `ALTERNATE_DOMAINS` も含める。厳密モードのブラウザは、そこへも自動では取りにいかない。`ALTERNATE_DOMAINS` 自身のレガシーモード（WebFinger と署名付き GET／POST）は変えない。

署名付き URL はホストを書き換えると署名が壊れる。ホストが M2 の専用ホストなら、クエリを保ったままそのホストへ出す。ホストがインスタンス入口で、バイトを入口のパスから出せない構成は公開しない。公開前の検査は `CDN_HOST`、`S3_ALIAS_HOST`、`S3_HOSTNAME`、Swift のホストを列挙し、入口から配信できないものを公開不可にする。M2 が親 Issue の「選択した入口への一本化」から外れる範囲は、専用ホストに限る未決の例外として残す。

リモートの第三者がホストする画像は外部 URL である。任意 URL を入口経由で取得するオープンプロキシは足さない。既存の添付 ID プロキシは M1／M2 の `Location` 規則に従う。Service Worker の通知クリックと、`fetch` の `redirect: 'error'` もこの分類に含める。

Service Worker の通知はクリック先と API だけでなく画像も絶対 URL を使う。`web_push_notifications.js` は `avatar_static` を `icon`、先頭添付の `preview_url` を `image` と `hiddenImage`、失敗時はペイロードの `icon` をそのまま `showNotification` に渡す。`badge` の `/badge.png` とクリック先の `/web/...` は `self.location` 基準で同一 Origin である。公開後は、通知を出す前に `icon`、`image`、`hiddenImage`、ペイロード `icon` を M1／M2 で投影する。インスタンス入口のホストは `self.location` 上の URL にする。専用ストレージは M2 のまま残す。これらの画像取得にアクセストークンは付けない。

### CSP

CSP は全通信を止めない。現行の `content_security_policy.rb` は次のとおりである。

- `connect-src` は `:self`、`assets_host`、`media_host`、`streaming_api_base_url`
- `img-src` と `media-src` は `:https` を含む
- `frame-src` は `:https` を含む
- `script-src` は `:self` と `assets_host`

`:https` があるので、画像・音声・動画・フレームは CSP だけでは他の入口も正規ホストも止まらない。`assets_host` や Streaming 基底が正規ホストや別入口だと、`connect-src` がそのホストを明示的に許す。

公開後、UI 入口の HTML では文書ごとに CSP を組む。

- `connect-src` と `script-src` から、インスタンス入口であるホストを外す。同一 Origin は `:self` が担う。`:self` が同一ホストの `wss` を含むかはブラウザ差がある。対応ブラウザの確認項目にし、足りないブラウザには現在の入口の `wss` Origin だけを足す。兄弟入口の `wss` は足さない。
- `img-src`、`media-src`、`frame-src` の `:https` は、外部メディアのために残し得る。ここは CSP が入口間の画像を止めるとは書かない。入口間の画像は M1 の URL 生成と 302 が止める。
- `form-action` は `:self` のまま。
- ゲートが閉じている間の CSP は今の初期化子のまま回帰する。

CORS は `/api/*` を `origins '*'`、`credentials: false` のまま維持する。ネイティブアプリはこの形で Bearer を送る。WebUI の自動通信はクライアントのガードが同一 Origin 以外を送らない。

## セッション、Cookie、信頼境界

今の Cookie は Domain 属性を持たない。ブラウザはそれを他の Host へは送らない。これは、兄弟サブドメインが `Domain=親` の同名 Cookie を作れないという意味ではない。`__Host-` が付かない名前は、親ドメインを Domain にした Cookie として送られ得る。SameSite=Lax は、同じ registrable domain のサブドメイン間の POST を止めない。サブドメインは same-site である。

| Cookie | 設定箇所 | 今の属性 |
| --- | --- | --- |
| `_mastodon_session` | `session_store.rb` | SameSite=Lax。本番または `LOCAL_HTTPS` で Secure。Rails セッション。未認証の 2FA（`attempt_user_id`）と WebAuthn チャレンジと CSRF が入る |
| `_session_id` | `devise.rb` の Warden | 署名付き文字列の session id。HttpOnly。SameSite=Lax。1 年 |
| `remember_user_token` | Devise。`on_authentication_success` が常に `remember_me` を呼ぶ。`rememberable_options` は `secure: true` のみ | Domain 無し。SameSite の明示は初期化子に無い |

読み書きは一箇所に揃える。今は次が別々に Cookie を見ている。

- `Warden::Manager.after_set_user` と `after_fetch` は `cookies.signed['_session_id']` を見て、空なら `warden.raw_session['auth_id']` に落ちる。`auth_id` への代入はこのリポジトリの Ruby には無い。fallback は残っている。
- `before_logout` は `cookies.signed['_session_id']` だけを `SessionActivation.deactivate` に渡す。
- `ApplicationController#current_session` は署名付き `_session_id` だけで `SessionActivation.find_by` する。`render_initial_state` はそのトークンと Push 購読を HTML に埋める。

公開後の新しい UI 入口では、旧形式の文字列 `_session_id` も `auth_id` も受けない。発行 Host が記録されていない Cookie を、新しい入口の認証にしてはならない。

### Cookie 名の比較

| 案 | 既存ログイン | 新しい入口への tossing | 正規ホストへの tossing | ロールバック |
| --- | --- | --- | --- | --- |
| A. 全入口で旧名のまま、文字列 Cookie をどこでも受ける | 継続する | コピーや `Domain=親` の同名 Cookie を新しい入口が受ける | 残る | 容易 |
| B. 全ホストを `__Host-` に改名する | 既存 Cookie を読めず、一斉にログアウトする | ブラウザが Domain 付き `__Host-` を拒否する | 同じ | 旧 Cookie へ戻すと再びログアウトし得る |
| C. 推奨。新しい UI 入口だけ `__Host-`。正規ホストと `ALTERNATE_DOMAINS` は旧名のまま | 正規ホストのログインは継続する | `__Host-` は Domain を付けられず、他 Host の旧名 Cookie は読まない | 旧名の tossing は残る。重複した同名 Cookie は全ホストで拒否する | 公開を閉じると新しい入口の Cookie は使われなくなる。正規ホストの Cookie はそのまま |

推奨は C である。三つの Cookie は同じ中身ではない。

| Cookie | 中身 | 新しい入口の名前 | レガシー入口の名前 |
| --- | --- | --- | --- |
| Rails の暗号化 Cookie Store | CSRF、flash、未認証の `attempt_user_id`、WebAuthn の nonce 識別子。認証済み tuple ではない | `__Host-mastodon_session` | `_mastodon_session` |
| activation | 署名付きの session id。発行 Origin の正本はサーバ行 | `__Host-session_id` | `_session_id` |
| remember | Devise の remember。初期範囲の新しい入口では発行しない | 出さない | `remember_user_token` |

グローバルな `config.session_store` の key は `_mastodon_session` のまま、リクエストの途中で代入しない。実装候補は、セッションミドルウェアが読む前に、そのリクエストの `env['rack.session.options'][:key]` だけを入口用の名前へ差し替えることである。暗号目的（Cookie Store の暗号化と、activation の署名）は名前ごとに分ける。

初期範囲の新しい入口では remember を無効にする。`on_authentication_success` は、厳密モードのリクエストでは `remember_me` を呼ばない。期限切れや remember だけの Cookie ではログインを確立しない。レガシー入口の remember は今の期限（1 年）と失効のままにする。

状態は次の順だけ進む。

1. 未認証の GET。Cookie Store は CSRF のためにあってもよい。activation は無い。API の認証なし GET は公開のままにし、Cookie からユーザーを足さない。
2. パスワード成功かつ 2FA が要る。`attempt_user_id` を Cookie Store に置く。activation はまだ作らない。
3. パスワード、または OTP／WebAuthn／リカバリーコードの成功。`SessionActivation` とトークンを作り、activation Cookie を書く。
4. 以後の復元は、activation Cookie からサーバ行を引く。ユーザーが一致しない行は捨てる。
5. ログアウトはその行とトークンだけを破棄し、Streaming の既存の token kill でその接続を切る。パスワードリセットは今どおり全行を破棄する。

レガシー入口（正規ホストと `ALTERNATE_DOMAINS`）は今の名前と、文字列の `_session_id` を受け続ける。`auth_id` fallback もレガシー入口だけに残し、解決した activation のユーザーが、そのリクエストで認証されたユーザーと一致するときだけ使う。新しい入口へはこの fallback をコピーしない。

同一リクエストに同じ Cookie 名が複数あるときは、どちらの入口でもそのリクエストを拒否する。どれが host-only でどれが `Domain=親` かをサーバは区別できないためである。

正規ホストの旧名を後から `__Host-` へ移す作業は、この公開とは別の変更にする。そのときも、既存の host-only Cookie を読む期間を置き、一斉失効を公開の前提にしない。

### 解決の手順

ログイン確立、リクエストごとの復元、`current_session`、初期状態、Push、ログアウトは同じ解決関数を使う。

1. 転送ヘッダの検査を通過した実効 Origin を取る。
2. 新しい UI 入口では `__Host-` の三つだけを読む。署名を検証し、`host` が実効ホストと一致し、`user_id` が認証済みユーザーと一致し、そのユーザーの `SessionActivation` が存在し、紐づくトークンが失効していないことを確認する。一つでも欠ければ未認証にする。別ユーザーの activation は読み込まない。
3. レガシー入口では旧名を読む。文字列の session id は、その activation のユーザーが認証済みユーザーと一致するときだけ採用する。
4. 新しい入口では remember Cookie を発行せず、remember だけではセッションを作らない。レガシー入口の remember は今のまま読む。
5. ログアウトは、この関数が解決した activation だけを破棄する。破棄はそのトークンも消す（`dependent: :destroy`）。他入口の activation は残る。Cookie 削除はその入口の名前だけである。
6. パスワードリセットは、今どおり全セッションと全トークンを無効にする。
7. 未認証の 2FA 状態（`session[:attempt_user_id]`、`attempt_user_updated_at`、`webauthn_challenge`）は、その入口のセッション Cookie にだけ置く。新しい入口では `__Host-mastodon_session` である。

同時ログインは `MAX_SESSION_ACTIVATIONS`（既定 10）を消費する。検証で入口数とこの上限を見る。

### トークンの正本

Cookie の中身だけでは、Cookie を持たない Bearer API と Node Streaming は発行 Origin を検証できない。正本は `SessionActivation` に足す nullable の `issued_origin` である。既存行は NULL のままにし、全件 backfill はしない。NULL はレガシーの未束縛を意味する。索引は既存の `access_token_id` から activation を引く形で足りる。列の追加はこの P0 では行わない。

Node は今、`oauth_access_tokens` だけを見る（`streaming/index.js`）。公開後は token id から activation の `issued_origin` を同じ規則で見る。判定を `superapp` フラグだけにしない。

| 種類 | 作り方 | `issued_origin` | 受理する経路 |
| --- | --- | --- | --- |
| レガシー Web セッション | 公開前、またはレガシー入口で作った activation | NULL | 正規ホスト、`ALTERNATE_DOMAINS`、専用 Streaming。追加入口では拒否 |
| 追加入口の Web セッション | 厳密モードのログインで作った activation | その Origin | その Origin の Rails と Node だけ。正規、レガシー、他の入口では拒否 |
| Push の fallback | `Web::PushSubscription#find_or_create_access_token`。`access_token_id` が空のとき、superapp で scope に `push` を含むトークンを作り、activation には紐づけない | 行が無いので未束縛 | レガシー経路だけ。追加入口の購読はこの fallback を使わず、その activation のトークンだけを使う |
| 通常の OAuth | セッション行を持たないアプリのトークン | 行が無い | 今の API と専用 Streaming。追加入口では拒否 |

公開を閉じる、入口を消す、旧コードへ戻すときは、`issued_origin` が NULL でないトークンを先に revoke し、その token id の Streaming 接続を kill する。旧コードは列を見ないので、残ったトークンを通常の Bearer として受けてしまう。revoke のあとで列を戻す。

`Api::BaseController#current_user` は `current_resource_owner || super` であり、`:null_session` は Cookie 認証の停止を保証しない。厳密モードと、束縛トークンを提示したリクエストでは次で失敗させる。

- Bearer がある: 主体はそのトークンのユーザーだけにする。無効、失効、別 Origin の束縛なら 401 とし、Cookie の `super` へ落ちない。
- Bearer が無い API: Cookie からユーザーを採らない。`Api::Web` だけが、解決関数の Cookie セッションを使う。
- Cookie のユーザーと Bearer のユーザーが両方あり、一致しない: 401。初期状態にも `current_session` のトークンを埋めない。
- 認証なしの公開 GET: ユーザーを足さない。

試験には、追加入口のトークンを正規ホスト、他の入口、専用 Streaming へ持っていく場合と、公開を閉じたあと、入口削除のあと、旧コードへ戻したあとに同じトークンが 401 であることを含める。

### CSRF

Cookie を認証に使う書込は、POST、PUT、PATCH、DELETE のすべてで、`Origin` が実効 Origin と完全一致することを要求する。`Origin` が無いときは `Referer` の Origin を見る。どちらも無ければ拒否する。対象はログイン、ログアウト、設定、`Api::Web`（`protect_from_forgery with: :exception`）、その他セッション Cookie で状態が変わる経路である。

対象にしないもの:

- 署名付きの ActivityPub POST
- Bearer だけで、セッション Cookie を認証に使わない API
- 外部 IdP の callback。これは「外部認証」のとおり、同じ Origin で開始していないセレモニーを成功させない

SameSite=Lax や CSRF トークンの一致だけをもって、別ユーザーの Cookie の組合せを正当化しない。主体の一致は解決関数が行う。

### レートとキャッシュ

Host を Rack::Attack のキーに足さない。足すと入口の数だけ枠が増える。

基点の実装では、認証済み API の throttle（`throttle_authenticated_api`、メディア投稿、ページング、削除）は `authenticated_user_id`（`resource_owner_id`）である。同じユーザーのセッションが増えても、この枠は増えない。`authenticated_token_id` は定義されているが、throttle のキーには使っていない。トークン id をキーにするとセッション数だけ枠が増えるので、使わない。

未認証とログイン試行は IP（IPv6 は /64）またはメールである。入口が違っても同じ IP の枠は共有される。2FA の Redis キーは `2fa_auth_attempts:{user_id}:{hour}` で、入口では分かれない。

`CacheConcern#enforce_cache_control!` は、Vary に Cookie、Authorization、Signature のいずれかがあり、そのヘッダがリクエストに付いているときだけ `private, no-store` にする。これだけで認証済み応答の非キャッシュは保証されない。edge は次を保存せず、保存済みの応答を返さない。

- `Set-Cookie` がある応答
- Cookie または Authorization が付いたリクエストへの HTML、初期状態を含む文書、認証 API、認証付きリダイレクト

公開アセットをキャッシュするキーは `$scheme$host$request_uri` を含める。例示の `dist/nginx.conf` は `proxy_cache_key` を書いていない。nginx の既定は上流ホストであり、クライアントの Host ではない。`/ns` は語彙文書の静的バイトで、中の IRI は `http://fedibird.com/ns#` のままである。ホストごとに同じバイトをキャッシュしてよい。本番 nginx はこのリポジトリに無い。

## 認証（webauthn 3.5.1）

前提は #865 の単一 Origin である。`config/initializers/webauthn.rb` の `allowed_origins` は `WEB_DOMAIN` の Origin 一つだけである。`rp_id` は設定しない。`spec/initializers/webauthn_spec.rb` は `rp_id` が `nil` であることを固定している。

gem 3.5.1 の挙動は、タグ `v3.5.1` の `authenticator_response.rb` で確認した（この環境の bundle パスは使っていない）。

- `relying_party.id` が nil で、`allowed_origins` が一つだけのとき、検証時の RP ID はその Origin のホストである（`URI.parse(expected_origin.first).host`。ポートは含まない）。
- `allowed_origins` が複数で `id` が nil のとき、`rp_id_from_origin` は nil を返し、`valid_rp_id?` は失敗する。グローバルな許可 Origin に入口を足すと、正規ホストの既存検証も壊れる。
- 登録オプションは `rp.id` が nil なら id を埋めない。ブラウザは呼び出し元 Origin のホストを rpId にする。正規ホストで登録した既存キーの rpId は、`WEB_DOMAIN` のホストである。

正規ホストの登録と検証は、今の `WebAuthn.configuration` をそのまま呼ぶ。グローバルな `allowed_origins` に入口を足さない。

新しい UI 入口の `options_for_create`、`options_for_get`、`from_create`、`from_get`、`verify` は、同じリクエストスコープの `WebAuthn::RelyingParty` を通す。

- `id` は既存の実効 RP ID。今の単一許可 Origin のホストである。親ドメインへ広げない。
- `allowed_origins` は、転送ヘッダ検査を通過したそのリクエストの Origin 一つだけである。正規 Origin は足さない。入口で発行したチャレンジに、正規 Origin の assertion や attestation が通る余地を残さない。
- `name` は `Mastodon`、`credential_options_timeout` は 120_000、アルゴリズムは gem の既定（ES256、PS256、RS256）、attestation と cross-origin の検証フラグは今の既定のままコピーする。グローバル設定オブジェクトは書き換えない。
- 入口の Origin が RP ID の接尾辞条件を満たさなければ、セレモニーを開始しない。

セッションは `:cookie_store` なので、Cookie 内のレコードを消しても、古い暗号化 Cookie の再送でチャレンジが戻る。追加入口の一度限りは Redis を正本にする。Cookie Store には nonce だけを置く。

- キーは用途、ユーザー、nonce。値は Origin、試行またはセッションの識別子、challenge 本体。TTL は 120 秒。
- 発行は、同じユーザーと用途の前のキーを消してから新しいキーを作る。
- 検証は compare-and-delete で一度だけ成功する。並行の二つ目、再送、期限切れは失敗する。
- Redis が使えないときはセレモニーを開始せず、検証も失敗させる。
- ログイン試行の破棄とログアウトは、そのユーザーの未消費キーを消す。

正規ホストの既存セレモニーは、`session[:webauthn_challenge]` の文字列のままにする。この互換を Redis へ移さない。新しい入口は文字列チャレンジを受けない。

同じクレデンシャルへの並行検証で `sign_count` が戻らないように、P4 は `verify` のあと `sign_count` が前進するときだけ更新する比較を検討する。認証全体の刷新には広げない。

検証項目は、Origin 不一致、既存キー、入口で作った新しいキー、OTP、リカバリーコード、二つの入口に同じユーザー、二つの入口に別のユーザー、options の並行発行である。

WebAuthn の仕様では、RP ID は Origin の実効ドメインそのものか、その registrable domain の接尾辞でなければならない。`WEB_DOMAIN` が `fedibird.com` なら、`https://1.fedibird.com` は rpId `fedibird.com` を使える。登録オプションに rpId を明示しないと、ブラウザは `1.fedibird.com` を rpId にし、既存キーを見つけない。入口では rpId を明示する。

OTP、リカバリーコード、既存の `webauthn_credentials` 行は Origin に縛られていない。入口が違っても同じユーザーの第二要素として使える。サインカウンタはクレデンシャルごとに一つで、どの入口で使っても同じ行を更新する。

## 外部認証

callback を正規ホストに固定し、開始時の Cookie、state、PKCE が別 Origin にあると、セレモニーは一致しない。新しい入口から正規ホストへ黙って遷移させて完了扱いにしない。

推奨は、新しい UI 入口では SAML、CAS、OmniAuth、ATProto を開始しないことである。画面は正規入口でのログインを案内し、自動リダイレクトはしない。ATProto の client id、redirect、jwks は `ExternalBridge::Atproto::ClientDocument` が `WEB_DOMAIN` 固定である。入口ごとに client id を複製しない。SAML の `SAML_ACS_URL` と CAS の `CAS_CALLBACK_URL` も、登録済みの正規 URL のままにする。

同じ Origin で開始から callback まで通すには、その Origin を IdP に登録する必要がある。ATProto は client id が正規ホストの URL なので、追加入口ではこの形にできない。

初期範囲の推奨は、提案 6 のとおり、外部認証が必須のサーバでは追加入口を公開しないことである。IdP に入口の callback を登録する設計は、この範囲の外である。

Doorkeeper の `redirect_uri` はクライアント登録値のまま検証する。入口ホストを許可リダイレクトへ自動追加しない。メールのリンクは `WEB_DOMAIN` のままである。クリックした人は正規ホストにセッションを作る。新しい入口のセッションは別 Cookie なので残る。メール内リンクを入口へ戻す処理は、この範囲に入れない。

## PWA、Push、ブラウザ保存

Service Worker はページの Origin に登録され、スコープは `/`（`config/webpack/production.js` の OfflinePlugin、`publicPath`）である。入口ごとに別の登録になる。Push 購読は `Web::PushSubscription` が `SessionActivation` に紐づく。入口ごとのセッションが、それぞれの購読とトークンを持つ。同じアカウントの通知設定（サーバ保存）は共通である。

クリック先は `web_push_notifications.js` が `new URL(path, self.location)` で組む。Service Worker の Origin に留まる。通知の `icon`、`image`、`hiddenImage`、ペイロードの `icon` は「アセットとメディア」の M1／M2 で投影する。購読ペイロードの `access_token` は、そのセッションの superapp トークンである。画像取得には付けない。他入口の SW からは読めない。

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

拒否は route と action で行う。`Accept` が JSON であることだけでは拒否しない。`/api/*` の REST、manifest、WebUI の設定 JSON は対象外である。HTML と ActivityPub は、同じパスでも Accept と format で分かれる（`mime_types.rb` が `application/activity+json` を `:json` に登録、`routes.rb` の HTML 制約）。

| リクエスト | 正規ホストと `ALTERNATE_DOMAINS` | 新しい UI 入口 |
| --- | --- | --- |
| HTML の Accept、format 無し | 今の HTML | その入口の HTML |
| `application/activity+json`、`ld+json`、`jrd+json` | 今の ActivityPub と WebFinger | 406。`Link` で正規 URL |
| Actor パスの `?format=json` または `.json` | 今の Actor JSON | 406。`Link` で正規 URL |
| `/api/*` の REST、manifest | 今の API と manifest | REST と manifest を返す。406 にしない。束縛トークンは発行 Origin だけ。未束縛トークンは追加入口では拒否 |
| inbox、outbox、コレクションへの連合 POST／GET | 今のとおり | POST は 404。連合 GET は 406 と正規 URL |
| WebFinger、host-meta、NodeInfo、`/actor` | 今のとおり | 拒否し、正規 URL を案内 |
| `/ns`、`/ns/group/v1` | 例示 nginx が静的 JSON-LD を返す。IRI は `http://fedibird.com/ns#` | 公開前は edge が server_name に含めない。公開後に同じバイトを返しても、語彙の識別子は正規 IRI のまま |

`ALTERNATE_DOMAINS` はこの表の右列に入れない。

## 公開ゲート

P1 から P5 のコードを本番にマージしても、入口は開かない。公開フラグは `RAILS_ENV` では分けない。`RAILS_ENV=production` の検証環境でも、ネットワークを検証者に限ったうえで同じフラグを使える。インターネットに公開した本番では、P6 のあと運営者が明示するまでフラグを立てない。

本番公開は P6 の総合検証が終わったあと、運営者が別に行う。アプリの公開フラグ、edge の server_name、証明書、DNS が揃ったときだけ開く。アプリのフラグだけでは、nginx の静的ファイル、`/api/v1/streaming`、`/ns` は Rails の Host Authorization を通らない。edge が server_name に入れていなければ、それらの経路は開かない。入れてしまった設定ミスはアプリでは閉じられない。公開チェックリストに edge の allowlist を含める。

| 層 | 閉じる責任 | 開いたあとの責任 |
| --- | --- | --- |
| DNS と CDN | 検証が終わるまで新しい名前を向けない | 選んだ入口へだけ向ける |
| edge | server_name、上流、Streaming、静的ファイル、`/ns` を新しい名前で受けない | Host と転送ヘッダの上書き、キャッシュキー、認証応答の非キャッシュ |
| Rails | 本番では `config.hosts` に足さない。届いた不正 Host は拒否 | セッション解決、CSRF、WebAuthn、連合の拒否、302 の入口維持 |
| Node Streaming | 新しい名前を受けない | `issued_origin` が NULL でないトークンは発行 Origin だけ。公開を閉じるときは先に revoke して接続を切る |
| ブラウザ | 公開前は入口が無い | 自動通信の同一 Origin ガード |

ゲートを閉じる、入口を消す、旧コードへ戻すときは、`issued_origin` が NULL でないトークンを revoke し、Streaming を切ってから列を戻す。正規ホストの Cookie と `ALTERNATE_DOMAINS` の WebFinger は維持する。再開は同じ公開手順を最初から行う。公開フラグだけを戻しても、edge が開いたままであれば静的経路は残る。edge とアプリを同じ手順で閉じる。外部認証が必須のサーバは、初期範囲ではこの公開をしない。

## 実装の順序

各 PR はテストできる単位にする。本番の入口はこの表のあいだ開かない。

| 段階 | 中身 | 本番 |
| --- | --- | --- |
| P1 基盤 | 正規化、拒否規則、転送ヘッダの一致検査、リクエストローカルな判定。`config.hosts` は変えない | 閉 |
| P2 API / Streaming / 遷移 | 送出前ガード、公開後モードの同一 Origin Streaming、内部リンクの `href`、Link の拒否。serializer の正規 URL は不変。ゲート閉鎖時の `STREAMING_API_BASE_URL` は回帰 | 閉。テストは Host を直接渡す |
| P3 アセット / メディア | M1 の 302 と `src`、M2 の専用ホスト、入口 HTML の CSP。CSP が全通信を止めるとは扱わない | 閉 |
| P4 認証 / セッション / 連合 | `__Host-` は新しい入口だけ、解決関数、同一 Origin の CSRF、リクエストスコープの RelyingParty、連合の判定表 | 閉。テスト環境のフラグだけで有効 |
| P5 PWA / Push | manifest、SW、通知画像の投影 | 閉 |
| P6 検証環境 | 上のすべてと edge を検証環境だけで開く | 本番は閉 |
| 本番公開 | P6 のあと、運営者が edge とアプリを同時に開く | 明示したときだけ |

## 検証

ここは手順である。この P0 ではアプリを起動して実行していない。

比較の軸は、未設定、設定済みで正規ホストが `LOCAL_DOMAIN` と一致、`LOCAL_DOMAIN != WEB_DOMAIN`、既存の `ALTERNATE_DOMAINS` を維持、の四つである。

正規 URL は、同じステータスとアカウントについて、変更前後と各 Host で ActivityPub JSON、WebFinger subject、署名対象の inbox URL を比較する。違ってよいのは、公開後の入口における HTML、同一 Origin の自動リクエスト、内部リンクの `href` だけである。

生の HAR は共有しない。初期状態のトークン、`Authorization`、`Cookie`、`Set-Cookie`、`Sec-WebSocket-Protocol`、クエリの `access_token`、フォームの password と OTP、WebAuthn のチャレンジと attestation、非公開投稿の本文が入り得る。証跡は、抽出した host、path、status、リダイレクト先の host、リソース種別だけにする。

自動リクエストが選択中の入口以外のインスタンス入口へ 0 件であることを、この証跡で見る。対象はリダイレクト、WebSocket、EventSource、ページ送り、動的 import、メディア、通知の画像、Push のクリックである。意図した例外は、外部リンク、明示した正規 URL の共有、M2 の専用ストレージ、ゲート閉鎖時の専用 `STREAMING_API_BASE_URL`、メールである。外部認証は新しい入口では開始しない。

シナリオは次を含む。

- 3 入口 × 3 アカウント。投稿、リアクション、通知、設定、下書き、ログアウト、再読込、期限切れ、再ログイン
- 同一アカウントの複数入口。片方のログアウトが他方を残す。パスワードリセットは両方を無効にする
- WebAuthn の既存キー、入口の新しいキー、OTP、リカバリーコード、二つの入口で同一ユーザーと別ユーザー、options の並行発行
- 否定: 有効な旧 `_session_id` を新しい入口へ渡す、別ユーザーの Cookie の組合せ、remember だけ、`auth_id` fallback、兄弟からの Cookie tossing、同名 Cookie の重複、両方許可済みの Host と `X-Forwarded-Host` の不一致、別 Origin への自動 API、オープンリダイレクト、same-site サブドメインからの Cookie 付き POST、認証済み応答の共有キャッシュ、Host をキーにしたレート制限の増加

## 調査の範囲と未確認

基点 `54bd41378f` を読み、ripgrep で検索した。`vendor`、`node_modules`、`tmp`、`log`、ロケール YAML の翻訳文は対象外にした。二回目のレビュー対応では、ドメイン名の検索に加えて次も実行した。

```sh
git grep -n -E 'request\.(url|base_url|host)|default_url_options|_url\b|url_for|redirect_to' -- app config '*.rb' '*.haml'
git grep -n -E 'href=|src=|srcset=|url\(' -- app/javascript app/views '*.scss' '*.css'
git grep -n -E 'fetch\(|axios\.|EventSource|WebSocket|new URL\(|window\.location' -- app/javascript streaming
git grep -n -E 'publicPath|avatar_static|preview_url|hiddenImage' -- app/javascript config/webpack
git grep -n -E 'auth_id|remember_me|oauth.*state|redirect_uri|SAML_ACS|CAS_CALLBACK' -- app config '*.rb'
```

ヒットは監査表の機構へ対応づけた。行単位の全 `*_url` は列挙していない。実装 PR は同じ検索を差分に対してやり直す。

未確認:

- Rails は起動していない。`og:url` がゲート閉鎖時にリクエスト Host になる判断は、`ApplicationController` が `default_url_options` を上書きしないことから導いた。
- webauthn 3.5.1 の RP ID 導出は GitHub の `cedarcode/webauthn-ruby` タグ `v3.5.1` を読んだ。ローカルの `bundle show` は使っていない。
- 本番の nginx、CDN、証明書、Cloudflare の実設定はこのリポジトリに無い。
- `remember_user_token` の SameSite は初期化子に明示が無い。
- メディアの Range は最終配信先に依存し、エッジの対応は未確認である。
- `:self` が同一ホストの `wss` を含むブラウザの範囲は未確認である。
- 複数 Origin で同一 VAPID 鍵を使えることは P5 で確認する。
- `auth_id` を書くコードは、このリポジトリの Ruby 検索では見つかっていない。読む fallback だけがある。
