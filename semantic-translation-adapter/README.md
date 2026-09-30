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

## backends

`IdentityBackend` は入力 unit をそのまま返します。構造が保たれることのテストに使います。

`TranslateGemmaBackend` は local vLLM へ HTTP で unit を送ります。モデルは Adapter の process には載せません。GPU、torch、transformers、CUDA は Adapter の依存ではありません。

```text
Mastodon / caller
  → Semantic Translation Adapter
  → TranslateGemmaBackend
  → HTTP
  → local vLLM
  → google/translategemma-12b-it
```

`backend` に `translategemma` を指定します。`source` は必須です。`null` は自動検出ではなく、`source_language_required` で拒否します。

```json
{
  "html": "<p>Hello <span translate=\"no\">@alice@example.com</span></p>",
  "source": "en",
  "target": "ja",
  "backend": "translategemma",
  "policy": "mastodon-v1"
}
```

endpoint が未設定でも API process は起動します。その backend を使った request が `backend_not_configured` になります。

| 環境変数 | 意味 |
| --- | --- |
| `TRANSLATEGEMMA_ENDPOINT` | vLLM の origin。例: `http://127.0.0.1:8001`。path は付けません |
| `TRANSLATEGEMMA_MODEL` | 既定値 `google/translategemma-12b-it` |
| `TRANSLATEGEMMA_TIMEOUT` | 秒。既定値 120 |
| `TRANSLATEGEMMA_MAX_TOKENS` | 生成上限。既定値 1024 |

caller が request ごとに URL を指定することはできません。redirect は追いません。

## vLLM

TranslateGemma 12B の structured chat content は vLLM `0.26.0` 以降です。A2 の再現 version は **`0.30.0`** です。改変された `vllm-translategemma-*` は使いません。公式 model card の total input context は 2K tokens なので、server も 2K で起動します。

```bash
vllm serve google/translategemma-12b-it \
  --host 127.0.0.1 \
  --port 8001 \
  --chat-template-content-format openai \
  --max-model-len 2048
```

対応する container image は `vllm/vllm-openai:v0.30.0` です。CUDA 13.0 がその image の既定です。実際に評価した GPU、dtype、追加引数は evaluation report に記録します。

`google/translategemma-12b-it` は Hugging Face の gated model です。利用者は Google / Gemma の利用条件を確認し、自分の環境で model access を用意します。weight と token はこの repository に含まれません。

評価は固定文だけを、起動中の endpoint に流します。

```bash
cd semantic-translation-adapter
TRANSLATEGEMMA_ENDPOINT=http://127.0.0.1:8001 \
  python3.12 scripts/evaluate_translategemma.py \
  --output translategemma-eval.jsonl \
  --gpu "not recorded" \
  --cuda "not recorded" \
  --dtype "not recorded"
```

server に届かないときは翻訳結果を作らず終了します。placeholder の順序規則はこの測定では変えません。

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

実行時の依存は FastAPI、Pydantic、lxml、regex、emoji、httpx です。core domain は FastAPI に依存しません。httpx は vLLM への HTTP と API テストに使います。torch と transformers は依存に入っていません。

設計の詳細は [docs/design.md](docs/design.md) です。
