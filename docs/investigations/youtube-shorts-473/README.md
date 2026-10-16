# YouTube Shorts 黒画面のP1調査（#473）

調査日: 2026-10-17 JST（証拠ファイル内はUTC）。対象は `origin/fedibird` の
`b3c6e826fa54dd1f04f36aa84d10cd5e56d82d65`。

## 結論と未完了条件

**ユーザー報告の黒画面は再現できておらず、根本原因は未特定。P1の完了条件は未達。**
YouTubeへのHTTPS接続は実行環境のプロキシがCONNECT段階で403を返し、
oEmbed、視聴ページ、埋め込みページのいずれもYouTubeのHTTP応答に到達しなかった。
これはYouTubeの動画制限やプレーヤーエラーではない。

実施できたのは最新コードの確認、合成カードを使ったReact/Jestテスト6件、
Chromiumでの実コンポーネントとCSSの寸法測定12条件。
Shorts URLとwatch URLに同じカードデータを与えると同じiframeになった。
これは**実際のoEmbed応答・保存値が等しいことの証明ではない**。
本変更は調査記録とテストのみ。URL変換、レイアウト、権限設定等の製品コード変更はない。

次に必要なのは、障害の出た動画URL・ブラウザ・OSと、YouTubeへ到達できる環境での
同一動画のA/B/C比較。Firefox・モバイル・拡張機能ありの実測も未実施。
P1を閉じたり、根本修正をマージしたりする根拠はまだない。

## 外部取得の試行

[oembed.json](oembed.json) にURL、取得時刻、要求したエンドポイント、失敗を記録した。
HTTPステータス `null` は未到達を意味し、成功やYouTubeの403を意味しない。
動画自体はダウンロードしていない。

| 候補 | 動画ID | 入力形式 | oEmbedの実測 |
| --- | --- | --- | --- |
| Shorts候補（NASA） | `fUrlyCjL8JA` | shorts / watch / embed | 3件ともCONNECT 403、YouTube応答なし |
| Shorts候補（NASA） | `hZIJ2PyFHME` | shorts / watch / embed | 同上 |
| 通常動画候補（公式APIの例） | `M7lc1UVf-VE` | shorts / watch / embed | 同上 |
| 通常動画候補（Big Buck Bunny） | `aqz-KE-bpKQ` | shorts / watch / embed | 同上 |

候補の現在の公開状態・埋め込み可否は確認できていない。
通常動画に対するshorts形式も入力形式の対照であり、Shortsであるという主張ではない。
watch / embedの直接ナビゲーション8件もChromium
`154.0.8037.57` で `ERR_TUNNEL_CONNECTION_FAILED`。
[chromium-network.json](chromium-network.json) を参照。
取得ツール経由のoEmbedも `Online fetch throttled` となり、代替の実測値は得られなかった。

## 境界ごとの確認

| 境界 | ソースで確認した処理 | 実測・未測定 |
| --- | --- | --- |
| URL → oEmbed | `FetchLinkCardService::PRESET_ENDPOINTS` は `www.youtube.com` と `youtu.be` を同じoEmbedへ渡す。`FetchOEmbedService` はURLをテンプレート展開し、200応答のversion/typeを検証 | 上記12件は通信失敗。`type/html/width/height` は未取得 |
| oEmbed → PreviewCard | videoならwidth/heightを保存（欠損は0）、htmlを `MASTODON_OEMBED` でサニタイズし、thumbnailを取得。取得できなければHTML探索、Open Graph / `twitter:player` へ進む | 実動画の保存・フォールバック発生は未測定。Rails/Ruby実行環境がなくDB経路は実行できず |
| PreviewCard → REST | width/heightは属性出力、htmlをもう一度 `MASTODON_OEMBED` で処理 | 実REST値は未取得。合成カードはAPI出力の代用品であり実測ではない |
| REST → React iframe | `addAutoPlay` は最初のiframeに `autoplay=1&auto_play=1` を付加。Shorts分岐なし。親高さは実測幅×metadata height/width | JestとChromiumで合成値を検証。src・sandbox・サイズを記録 |

関連ソース:
`app/services/fetch_link_card_service.rb`, `app/services/fetch_oembed_service.rb`,
`app/models/preview_card.rb`, `app/serializers/rest/preview_card_serializer.rb`,
`lib/sanitize_ext/sanitize_config.rb`,
`app/javascript/mastodon/features/status/components/card.js`,
`app/javascript/styles/mastodon/components.scss`。

確認した差異:

- サニタイズ設定はiframeの `allowfullscreen/frameborder/height/scrolling/src/width`
  を許可し、sandboxを付加する。`allow` と `referrerpolicy` は許可しない。
  実際のYouTube応答にこれらの属性が含まれるかは未取得。
- `twitter:player` のフォールバックはoEmbedとは別のiframe生成経路。
  キャッシュ由来・新規oEmbed由来・フォールバック由来を混ぜて比較しない。
- `PreviewCard` はURL単位。既存カードは2週間閾値や画像欠損による再取得判定があり、
  投稿にカードが既に付いているとサービスは早期終了する。
  shorts/watchで別の時点に作成されたキャッシュを比較すると取得時刻差が混入する。
- `frame_src :self, :https` はHTTPS iframeを許可する。親の `connect_src/media_src`
  だけから別オリジンのYouTubeフレーム内部通信の失敗を断定できない。
- `HomeController` は `Referrer-Policy: origin` を設定する。
  カード外部リンクの `rel=noreferrer` を、埋め込みiframeのReferer欠落と混同しない。
  リバースプロキシやブラウザを含め、実際のリクエストヘッダーを確認する必要がある。

## DOM・サイズの実測（合成カード）

最新の `Card` をReactDOMでマウントし、実際の再生ボタンをクリックした。
`application.scss` 全体をSassでコンパイルして適用。
Intl・Icon・Blurhash・Thumbhash・initial_stateのみをスタブ化した独立ページであり、
ログイン済みFedibirdページ全体の実測ではない。
外部リクエストは意図的に中止し、レイアウト測定と再生の成否を分離した。
カードのID `abcdefghijk`、200×113 / 113×200のmetadataは合成値。

| 親幅 | metadata | iframe実寸（CSS px） | 同じwatchデータとの差 |
| --- | --- | --- | --- |
| 280 | 200×113 | 278×157.0625 | なし |
| 320 | 200×113 | 318×179.65625 | なし |
| 480 | 200×113 | 478×270.0625 | なし |
| 280 | 113×200 | 278×492.03125 | なし |
| 320 | 113×200 | 318×562.828125 | なし |
| 480 | 113×200 | 478×846.015625 | なし |

各iframeはwrapperと同じ実寸で、ゼロサイズやwrapperによる映像領域の切り取りは
この12条件では見られなかった。カード自体のoverflowはhidden。
挿入後srcは全件
`https://www.youtube.com/embed/abcdefghijk?feature=oembed&autoplay=1&auto_play=1`。
sandboxは保存され、allow/referrerpolicy属性は入力どおり存在しない。
[chromium-layout.json](chromium-layout.json) に矩形・属性を記録。

200×113を返すと仮定した場合、狭いカードではYouTubeの最小200×200 viewport要件を
下回る。ただし通常動画にも共通するサイズ上の懸念で、Shortsの黒画面の原因とは断定できない。
黒帯（アスペクト比の余白）・クリッピング・映像のデコード失敗は別々に記録する。

## 原因候補と次の判定

優先順は検証の効率によるもので、発生確率を実証した順位ではない。

| 優先 | 分類 | 証拠と判定条件 | 最小修正の候補（別途レビュー） |
| --- | --- | --- | --- |
| 1 | 個別動画／YouTube側 | APIエラー101/150なら埋め込み禁止、100なら削除・非公開等。現状はいずれも未観測。視聴ページ成功だけでは埋め込み可を証明しない | URL書き換えでは解消しない。P4の導線として別検討 |
| 2 | ブラウザ／Referer | 153はReferer等のクライアント識別欠落。実ヘッダー未測定。Fedibirdのorigin設定だけではプロキシ・拡張機能による変更を除外できない | 153が出る層に限定して対応。全iframeの無条件変更はしない |
| 3 | 権限／autoplay | サニタイズでallowが落ちることはソース上確実。手動クリックなら再生するのか、onAutoplayBlockedが出るのか未測定 | 権限不足が再現できた場合に限り、YouTubeに必要な権限の許可範囲を別PRで検討 |
| 4 | Fedibirdのカード寸法／キャッシュ／フォールバック | 合成カードのURL形式差はなし。狭い16:9カードの最小寸法不足は確認。実動画metadata・キャッシュ差は未取得 | 実測で問題が出た境界だけ修正。縦長レイアウトP3とは分離 |
| 5 | デコード・GPU・拡張機能 | 音声やUIだけ動く状況の実機証拠がない。エラー5、media診断、拡張なしプロファイルとの比較が必要 | 条件が絞れてから検討 |

総合判定: **未特定**。現段階で「Fedibirdのバグ」「Shorts一般の埋め込み不可」
「特定パラメーターが原因」のいずれにも確定できない。

## 到達可能な環境での再現手順

1. 障害動画のURLと、同じ環境で再生できる通常動画のURL、OS・ブラウザのバージョン、
   ログイン状態、拡張機能、画面幅を記録する。拡張なしの新規プロファイルでも比較する。
2. 各IDでshorts/watch/embed（必要ならyoutu.be）のoEmbedを同じ時刻に取得する。
   例: 次のコマンドはJSONとHTTPヘッダーを別々に残す。動画は取得しない。

   ```sh
   curl --get --max-time 30 --dump-header oembed.headers \
     --data-urlencode 'format=json' \
     --data-urlencode 'url=https://www.youtube.com/shorts/VIDEO_ID' \
     'https://www.youtube.com/oembed' --output oembed.json
   ```

3. HTTPコード、type、width/height、htmlの全属性、thumbnail_urlを比較する。
   iframe srcは同じIDでもクエリやホストが異なる可能性があるので省略しない。
4. Fedibirdでテスト投稿を作り、管理下の検証環境でPreviewCardの
   `url/redirected_url/type/html/width/height/created_at/updated_at` を読み取り、
   Networkのstatus API応答の `card` と比較する。
   既存キャッシュの削除や本番DBの書き換えは行わない。
   フォールバック判定には検証環境で `attempt_oembed` / `attempt_opengraph` の経路も記録する。
5. 同じ動画で(A)視聴ページ、(B)HTTP(S)で配信した独立HTMLのiframe、
   (C)Fedibirdのカードを比較する。Bは `file://` やembed URL直接表示にしない
   （Refererの条件が変わる）。まず640×360等の十分な大きさで手動再生する。

   ```html
   <!doctype html>
   <meta charset="utf-8">
   <meta name="referrer" content="strict-origin-when-cross-origin">
   <iframe width="640" height="360"
     src="https://www.youtube.com/embed/VIDEO_ID"
     allowfullscreen></iframe>
   ```

6. B/Cでsrcを無加工、`autoplay=1`、`autoplay=1&auto_play=1` と一つずつ比較する。
   oEmbed由来の既存クエリは維持し、autoplay失敗時は手動再生も試す。
   同時再生は避ける。最初は元のsandbox/allow/referrerpolicyを維持し、
   差が出た時だけ一属性ずつ変えた対照を追加する。
7. DevToolsのConsole / NetworkでiframeのHTTPリクエスト、実Referer、
   ページのReferrer-Policy / Permissions-Policy / CSP、失敗リクエストを記録する。
   必要なら独立ページにIFrame APIのonError / onAutoplayBlockedを追加する。
   `enablejsapi=1` やoriginの追加は条件変更なので、未加工iframeとは別の結果として扱う。
   通常のページJSから別オリジンiframeの内部DOMや映像ピクセルは読めない。
8. 再生ボタンを押した後、FedibirdページのConsoleで以下を実行し、
   src、属性、iframeとwrapperの実寸、親のoverflowを取得する。

   ```js
   [...document.querySelectorAll('.status-card-video iframe')].map(frame => {
     const rect = element => {
       const { x, y, width, height } = element.getBoundingClientRect();
       return { x, y, width, height };
     };
     return {
       src: frame.src,
       attributes: Object.fromEntries([...frame.attributes].map(a => [a.name, a.value])),
       iframe: rect(frame),
       wrapper: rect(frame.parentElement),
       parentOverflow: getComputedStyle(frame.parentElement.parentElement).overflow,
       metaReferrerPolicy: document.querySelector('meta[name="referrer"]')?.content || null,
     };
   });
   ```

   最後の値は補助情報。実際に送信されたRefererは必ずNetworkで確認する。
   640×360で失敗するか、幅を広げると映像が戻るか、UIだけか音声も動くかを別々に記録する。
   HARには認証や署名付きURLが含まれ得るため、公開時は関連値のみ抽出する。

## テストと追加方針

追加した `app/javascript/mastodon/features/status/components/__tests__/card-test.js`
は外部通信なしの6テスト。クリック前にはiframeがなく、クリック後に同一IDの
shorts/watchカードが同じiframeになること、既存クエリの保持、両autoplayパラメーター、
sandbox/fullscreen/寸法属性の保持、横長・縦長metadataからの親高さを検証する。
権限やパラメーターを最適と認定するテストではなく、現行の変換境界を固定したもの。

```sh
NODE_ENV=test node_modules/.bin/jest \
  app/javascript/mastodon/features/status/components/__tests__/card-test.js \
  --runInBand --coverage=false
node_modules/.bin/eslint app/javascript/mastodon/features/status/components/__tests__/card-test.js
```

Jest 6/6、ESLint、`git diff --check` は成功。
既存CardのReact lifecycle警告とBrowserslistの古いデータ警告は残る。
既存の `spec/services/fetch_oembed_service_spec.rb` と
`spec/services/fetch_link_card_service_spec.rb` は特定済みだが、Ruby不在のため実行していない。

次のサーバーテストは、実測した応答を取得してからオフラインfixtureで追加する:

- 同一IDのshorts/watch（通常動画を含む）で要求URLが保持され、成功応答が
  PreviewCardとRESTまで同じID・寸法・許可属性で渡ること。
- oEmbed 401/403/404、無効JSON、type/寸法欠損時のHTML探索・OG/twitter:player分岐。
- キャッシュの新旧・既存カード添付時の再取得条件。
- もしallow/referrerpolicyを変更するなら、サニタイズの許可範囲・二重処理・危険属性排除。

外部YouTube通信をCI必須にはしない。実プレーヤーの101/150/153、自動再生制限、
縦動画の実描画はブラウザで別途確認する。

## 一次資料

- [埋め込みURL・パラメーター・最小寸法](https://developers.google.com/youtube/player_parameters)
- [IFrame APIのエラーとautoplayイベント](https://developers.google.com/youtube/iframe_api_reference#Events)
- [Refererと埋め込みの要件](https://developers.google.com/youtube/terms/required-minimum-functionality)

資料は調査時に確認した。`auto_play` は公式パラメーター一覧に見当たらないが、
それだけで有害・黒画面の原因とは判定できない。
