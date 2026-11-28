# WEB_UI_DOMAINS の基盤（P1）

P0 の設計は [`docs/web_ui_domains_p0.md`](web_ui_domains_p0.md)、監査表は [`docs/web_ui_domains_p0_audit.md`](web_ui_domains_p0_audit.md)。この文書は P1 で実装した契約だけを書く。P2 以降（同一 Origin の API／Streaming／遷移、メディア、Cookie、WebAuthn のリクエストスコープ、連合の拒否、PWA）は実装しない。

公開ゲートは閉じたままである。`WEB_UI_DOMAINS` を書いても、追加入口は開かない。`WEB_UI_DOMAINS_READY` のような環境変数は読まない。リクエストヘッダでも開かない。

## 設定

`config/initializers/1_hosts.rb` が起動時に一度だけ `WebUiDomains::Configuration` を作る。結果は `Rails.configuration.x.web_ui_domains` に置き、凍結する。リクエストや worker の処理の中でこのオブジェクトを書き換えない。`config.x.local_domain`、`config.x.web_domain`、`config.x.alternate_domains`、メーラーの `default_url_options`、`config.hosts`、WebAuthn のグローバル設定は、この初期化子がこれまで書いていた値のままである。

`WEB_UI_DOMAINS` が未設定、空白、またはカンマだけのときは候補は空である。開発用の `localhost:3000` のような既存の `LOCAL_DOMAIN` は、この変数が空のあいだ新しい制約で拒否しない。

カンマで分割し、要素の前後の空白は捨て、空要素は捨てる。残った要素は次のとおり正規化する。

- 小文字化し、Addressable の IDNA で ASCII ホストにする。
- 比較は正規化後の完全一致だけである。ワイルドカードや「この親のサブドメイン全部」はない。
- スキーム、ユーザー情報、パス、クエリ、フラグメント、ポート、ワイルドカード、IP リテラル（`127.0.0.1`、`127.1`、`0x7f.0.0.1`、`0177.0.0.1`、十進整数、`[::1]` を含む）、末尾ドット、空ラベル、不正な DNS ラベル、空白、制御文字は拒否する。
- 重複は正規化後に見る。Unicode と対応する punycode も重複である。
- 正規化したホストが `LOCAL_DOMAIN`、`WEB_DOMAIN`、`ALTERNATE_DOMAINS` の正規化したホストと重なれば拒否する。既存の値そのものは変えない。ポート付きの既存設定は、ホスト部分だけを比較に使う。
- 追加入口は、現在の WebAuthn 実効 RP ID の本当のサブドメインだけを許す。実効 RP ID は、正規 `WEB_DOMAIN` の Origin のホストであり、ポートは含まない。グローバルな `rp_id` と `allowed_origins` は変えない。
- ラベル境界を要求する。`notfedibird.com` は `fedibird.com` のサブドメインではない。兄弟ホスト、別の registrable domain、public suffix そのもの（`co.uk`、`github.io`、`localhost`）を RP ID にした追加入口は拒否する。`foo.github.io` の子 `1.foo.github.io` は、registrable domain が同じなので候補にできる。`bar.github.io` はできない。

不正な要素が一つでもあればリスト全体を拒否し、正しい要素も採用しない。`WebUiDomains::Configuration.load!` が `WebUiDomains::ConfigurationError` を上げ、起動は止まる。メッセージに、採用しなかったことと各要素の理由を書く。

`Configuration#strict_mode_enabled?` は常に false である。候補が載っていることと、厳密モードが有効であることは別である。

`config.hosts` に入る名前は `WebUiDomains::HostAuthorizationList.legacy` の戻り値だけである。引数は `LOCAL_DOMAIN`、`WEB_DOMAIN`、`ALTERNATE_DOMAINS` だけで、追加入口は渡せない。テスト環境はこれまでどおり `config.hosts` を設定しない。`/health` を Host Authorization の対象外にする既存の proc も変えない。

## リクエストコンテキスト

`WebUiDomains::RequestContext.build` がリクエストローカルな凍結オブジェクトを返す。プロセス全体の config、`default_url_options`、セッション Cookie のキーは変えない。

分類は正規化した raw `Host` に対して行う。

| `host_roles` | 意味 |
| --- | --- |
| `:web_domain` | 正規 `WEB_DOMAIN` のホスト |
| `:local_domain` | `LOCAL_DOMAIN` のホスト。WEB と同じなら両方入る |
| `:alternate_domain` | `ALTERNATE_DOMAINS` のホスト。レガシー入口のまま |
| `:additional` | 採用済みの追加入口候補 |

| `mode` | 意味 |
| --- | --- |
| `:legacy` | 正規ホスト、`LOCAL_DOMAIN`、`ALTERNATE_DOMAINS`。厳密モードには入れない |
| `:additional_candidate` | 候補として整合しているが、ゲートは閉じている |
| `:strict` | テストがゲートを開いたときだけ。本番の呼び出しでは作らない |
| `:unrecognized` | どのリストにも無い。拒否そのものは既存の Host Authorization が行う |
| `:rejected` | 追加入口として厳密モードへ進めない。Host が壊れている場合も含む |

`canonical_origin` は起動時に固定した正規 Origin である。式は WebAuthn 初期化子と同じ `https://` または `http://` に、設定された `WEB_DOMAIN` 文字列を足したもので、ポートもそのまま残す。リクエストからは計算し直さない。

`access_origin` は `mode == :strict` のときだけ入る。それ以外は nil である。HTTP の `Origin` ヘッダは読まない。`X-Forwarded-Host` が別の許可済みホストでも、それをアクセス先に採用しない。

`observed_origin` は、raw `Host` と、下の規則で決めたスキームから見た値である。転送ヘッダがスキームを壊した場合は nil になり、転送先のホストへすり替わらない。

ゲートをテストで開く方法は `WebUiDomains::Gate.open_for_test` を `build` の `gate:` に渡すことだけである。`WebUiDomains::Middleware` は引数を渡さないので、常に `Gate.closed` である。HTTP のテスト用入口は作らない。追加入口の本番契約は HTTPS かつポート 443 であり、テストは Rack の env でその接続を表す。

## 転送ヘッダ

`request.host` と `request.ssl?` は、信頼済みプロキシかどうかに関係なく `X-Forwarded-Host` と `X-Forwarded-Proto` を実効値に使うことがある。P1 はそれを信用しない。

即時の接続元は `REMOTE_ADDR` だけを見る。`request.remote_ip` や `X-Forwarded-For` の中のアドレスは、プロキシ信頼の判定に使わない。信頼リストは `config.action_dispatch.trusted_proxies` であり、未設定時は Rack の既存フィルタである。テストは `trusted_proxies:` でリストを渡せる。

追加入口候補で次のいずれかなら `mode` は `:rejected` になり、ゲートを開いていても `:strict` にしない。

- raw `Host` が壊れている、複数値、IP、ユーザー情報、パスを含む
- `X-Forwarded-Host` が複数、不正、または raw `Host` とホストか実効ポートが違う。両方が許可済みでも不一致なら失敗する。`example.com` と `example.com:443` は HTTPS では同じ実効ポートとして一致する
- `X-Forwarded-Proto` が複数、`http`/`https` 以外、または `X-Forwarded-SSL` と矛盾する
- 信頼済みでないピアが、接続のスキームと違う `X-Forwarded-Proto` や `X-Forwarded-SSL: on` を送った。接続が HTTP なのにヘッダだけ HTTPS にする昇格は採用しない。Rails が `request.ssl?` を真にしても、こちらは真にしない
- 接続が HTTPS なのに転送スキームが HTTP。これはダウングレードとして失敗させる
- 信頼済みピアの TLS 終端は、接続が HTTP で、`X-Forwarded-Proto` が単一の `https` のときだけ外部スキームを HTTPS にする
- `X-Forwarded-Port` が複数、不正、または Host から決まる実効ポートと違う。ヘッダの値でポートを上書きしない
- `Forwarded` が残っている。中身は解釈しない
- 外部スキームが HTTPS でない、または実効ポートが 443 でない
- 上記を満たしたうえで、Rails の実効ホスト、スキーム、ポートが raw `Host` から決めた値と違う

レガシー入口では、同じ不一致を `forwarding_consistent?` と `forwarding_failure_code` に記録する。`mode` は `:legacy` のままで、`failure_code` は nil である。未設定時とレガシー入口の Host、転送、Streaming の応答は変えない。

## ミドルウェアの順序

`WebUiDomains::Middleware` は判定を `env['web_ui_domains.context']` に置き、必ず次のアプリを呼ぶ。P1 ではスタックへ挿入しない。挿入するときは `ActionDispatch::Cookies` の直前にする。Cookie ストアはその後なので、将来ゲートを開いたときに、セッションを読む前へ同じ判定を置ける。P1 のミドルウェアは失敗でも応答を変えない。未許可 Host の拒否は、これまでどおり Host Authorization と、公開前の edge の server_name が行う。

現在の本番順序の中では、次の位置である。

1. `ActionDispatch::HostAuthorization`
2. `ActionDispatch::RemoteIp`（クライアント IP。Host の信頼とは別）
3. 将来: `WebUiDomains::Middleware`（P1 では未挿入）
4. `ActionDispatch::Cookies`
5. cookie store（`_mastodon_session`）

## Node Streaming と edge

この PR は `streaming/index.js`、nginx、CDN、DNS を変えない。後続が Node と edge に同じ判定を置くときの契約は次である。

- 追加入口の外部スキームは HTTPS、ポートは 443。レガシー入口と未設定時の `STREAMING_API_BASE_URL` は今のままにする。
- raw `Host` と、Streaming が接続に使うホストが違えば、両方が許可済みでも拒否する。
- `Forwarded` は解釈しない。`X-Forwarded-Proto`、`X-Forwarded-Port`、`X-Forwarded-Host` の複数値や、信頼済みでないピアからの昇格は採用しない。
- プロキシ信頼は、Node へ接続してきた即時ピアで判断する。`X-Forwarded-For` のクライアントアドレスと混同しない。
- アクセス先 Origin を、HTTP の `Origin` ヘッダから採らない。
- ゲートが閉じているあいだ、Node は追加入口を受けない。アプリのフラグだけでは、edge が server_name に入れた静的ファイルや Streaming は閉じられない。公開は P6 のあと、運営者が別に行う。

## 失敗したときの扱い

| 状態 | P1 の結果 |
| --- | --- |
| 設定が不正 | 起動時に例外。候補は空。一部だけは残さない |
| 設定が空 | 今の単一 Origin。候補は空 |
| 候補が整合、ゲートは閉 | `:additional_candidate`。`access_origin` は nil。`config.hosts` には入っていないので、本番の Host Authorization は従来どおりこの Host を拒否する |
| 候補の検証に失敗 | `:rejected` と `failure_code`。厳密モードには進まない |
| レガシー入口 | `:legacy`。転送の不一致は記録するだけで、応答は変えない |
| どのリストにも無い | `:unrecognized`。Host Authorization の既存の拒否に任せる |

## テストから厳密モードを見る

本番の呼び出しは `RequestContext.build(request)` またはミドルウェアである。どちらもゲートを開かない。テストだけが次の形を使う。

```ruby
WebUiDomains::RequestContext.build(
  request,
  configuration: configuration,
  gate: WebUiDomains::Gate.open_for_test,
  trusted_proxies: [IPAddr.new('10.0.0.0/8')],
)
```

`trusted_proxies: :none` はどのピアも信頼しない。`:application` は起動中の Rails 設定を使う。このキーワードを環境変数へ繋がない。
