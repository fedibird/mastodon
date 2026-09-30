# Semantic Translation Adapter

Mastodon / Fedibird の投稿 HTML を、意味と構造を保ったまま翻訳するための独立サービスです。A1 は semantic core だけを実装します。

## 目的

投稿 HTML を一度 DOM として読み、翻訳してよい自然言語だけを translation unit に切り出します。翻訳 backend が返した文字列を検証したあと、元の DOM の text node に書き戻します。

```text
Mastodon HTML
  → parse
  → mastodon-v1 policy
  → translation units + protected placeholders
  → backend
  → strict validation
  → original DOM へ復元
  → translated HTML
```

## backend に HTML を渡さない

backend が変更できるのは、policy が翻訳対象にした自然言語だけです。タグ、属性、リンク、mention、hashtag、emoji、URL を backend に生成させ直すと、復元も検証もできなくなります。backend interface は unit の文字列だけを受け取り、DOM を知りません。

## policy と backend

`TranslationPolicy` が HTML を解釈します。A1 の policy は `mastodon-v1` です。`TranslationBackend` は unit を翻訳するだけです。policy を差し替えても backend の契約は変わりません。

## protected literal

DOM 要素だけでなく、text node の中の次の文字列も保護します。

- 絶対 `http://` / `https://` URL（anchor になっていない平文も含む）。URL の直前が CJK や emoji でも検出します。ASCII 英数字の直後のひらがなは URL に含めません
- URL そのものを表示している `a`（`Formatter#link_html` の短い URL を含む）。anchor 全体を一つの protected fragment にします。人間が読めるリンクラベルは翻訳対象です
- Unicode emoji sequence（grapheme cluster 単位）

保護した断片は backend に出さず、placeholder に置き換えます。

## validation は fail closed

backend の応答は信用しません。unit id の過不足と重複、placeholder の過不足、重複、改変、順序の変化、text node が無い位置への文字挿入は復元前に拒否します。失敗時は translated HTML を作りません。

## A1 の範囲

実装している backend は `IdentityBackend` だけです。入力 unit をそのまま返すので、prepare から restore までの構造が保たれることをテストします。

TranslateGemma、llama.cpp、Ollama、vLLM、LibreTranslate、DeepL は次段階です。TranslateGemma は、HTML を見ない `DirectTranslationBackend` として追加する想定です。

## API

- `GET /healthz`
- `POST /v1/translate/html`

```json
{
  "html": "<p>Hello <span translate=\"no\">@alice@example.com</span></p>",
  "source": "en",
  "target": "ja",
  "backend": "identity",
  "policy": "mastodon-v1"
}
```

入力サイズの上限は `SEMANTIC_TRANSLATION_MAX_HTML_BYTES` です。既定値は 100000 バイトです。リクエスト本文はログに残しません。エラー応答に原文 HTML は含めません。

## 開発

Python 3.12。

```bash
cd semantic-translation-adapter
python3.12 -m pip install -e '.[dev]'
python3.12 -m pytest
```

実行時の依存は FastAPI、Pydantic、lxml、regex、emoji です。core domain は FastAPI に依存しません。httpx は API テスト用の開発依存で、A1 は外部の翻訳 API を呼びません。

設計の詳細は [docs/design.md](docs/design.md) です。
