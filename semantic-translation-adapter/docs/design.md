# Semantic Translation Adapter — A1 design

## 境界

```text
semantic_translation/
  api/            HTTP schema と FastAPI。domain model をそのまま返さない
  core/           DOM、unit、placeholder、validation。FastAPI を import しない
  policies/       HTML の意味。A1 は mastodon-v1
  backends/       unit の入出力だけ。HTML を import しない
```

backend の契約は次だけです。

```python
translate(
    units: list[TranslationUnit],
    source_language: str | None,
    target_language: str,
) -> list[TranslatedUnit]
```

`TranslationUnit` は `id` と `text` だけを持ちます。text に入るのは自然言語と placeholder です。

## なぜ HTML を backend に渡さないか

復元の責任は Adapter にあります。元 DOM は policy が保持し、backend の文字列は既存の text node にだけ書き戻します。属性は読みもしなければ書きもしません。`href`、`src`、`class`、`rel`、`data-*`、`lang`、`dir`、`title`、`alt`、その他すべての既存属性は不変です。一時的な metadata 属性は DOM に付けません。

## protected literal

保護は要素だけではありません。text node 内の次も protected literal です。

- plain URL text。絶対 `http://` と `https://`。Mastodon が anchor にしなかった URL と、remote HTML の平文 URL の両方が対象です。末尾の文の句読点は URL から外します。対応の取れた括弧は URL に残します。
- Unicode emoji sequence。`regex` の `\X` で grapheme cluster に分け、各 cluster を `emoji.is_emoji` で判定します。ZWJ、variation selector、skin tone、regional indicator、keycap は一つの literal です。

URL の中にある emoji は URL literal の一部としてまとめて保護します。

## Placeholder

`PlaceholderCodec` version 1 が token を発行します。初期の綴りは `{{MSTDN_P_0000}}` です。policy と validation はこの綴りを解釈せず、codec の `issue` / `find_tokens` / `strip_tokens` / `collides` だけを使います。

token には二種類あります。

- literal placeholder。URL と emoji。text node の中に残り、復元時に元の文字列へ戻します。
- anchor placeholder。保護要素、コメント、inline 境界。text node には書き戻しません。隣の text node を切り分けるためだけに unit 文字列へ入ります。

入力の text、コメント、属性値に予約 prefix `{{MSTDN_P_` が既にある文書は `placeholder_collision` で拒否します。別の token へ黙って逃げることはしません。

## translation unit の block 境界

text node を一つずつ backend に渡しません。一つの unit は、block container の中の inline の並びです。

block container:

- fragment root
- `p`
- `blockquote`
- `li`
- その他 `_BLOCK_TAGS`（`div`、見出し、`ul` / `ol`、table cell など）
- 自分は block でなくても、子に block を含む要素

`<br>` は unit を分割します。inline 要素の中の `<br>` も分割します。

保護要素は一つの anchor になり、中へ降りません。

透明な inline（`em`、`strong`、`a`、`span`、`b`、`i` など）のテキストは親 unit に残します。隣接する text node のあいだには構造用 placeholder を置きます。これは A1 の明示的な inline 境界であり、一般的な HTML inline code モデルではありません。

## mastodon-v1 が保護する要素

- `translate="no"` の要素と、その全子孫。入力の `translate="no"` は著者の指定です。Adapter は自分では `translate` を書きません。子孫の `translate="yes"` で翻訳を再開することは、A1 ではしません。
- `script`、`style`、`code`、`pre`、`kbd`、`samp`、`textarea`、`svg`、`math`
- `h-card`、`mention`、`hashtag`
- `invisible`、`ellipsis`
- class `emojione` または `custom-emoji` を持つ要素
- それらの class を持つ `img` だけを含む `picture`
- 既知の inline / block 一覧に無い要素。要素ごと保護し、中のテキストは翻訳しません

class は空白区切りの token で比較します。`not-invisible` は保護しません。

## Validation

失敗したら HTML を生成しません。判定順は次です。

| code | 条件 |
| --- | --- |
| `invalid_backend_response` | 応答が `TranslatedUnit` の list ではない。anchor の分割が崩れている。空だった gap に文字が入った |
| `duplicate_translation_unit` | unit id が重複 |
| `unknown_translation_unit` | 未知の unit id |
| `missing_translation_unit` | unit id が欠けている |
| `duplicate_placeholder` | 同一 token が複数回出現 |
| `unknown_placeholder` | 発行していない token。別の token への改変はここに入る |
| `missing_placeholder` | 必要な token が無い。認識できない壊れた token もここ |
| `placeholder_order_mismatch` | token の集合は同じだが順序が違う |

順序を見るのは、空の gap と text node の対応を崩さずに復元するためです。個数だけ合っていても、順序が変わった unit は復元しません。

このほか、prepare 段階で次を返します。

| code | 条件 |
| --- | --- |
| `placeholder_collision` | 入力が予約 prefix を含む |
| `unsupported_structure` | ネストが深すぎる、または inline 走査と block 判定が矛盾する |
| `unparseable_html` | parser が失敗した |
| `input_too_large` | UTF-8 バイト長が上限を超えた |
| `unknown_backend` / `unknown_policy` | 名前が A1 の登録に無い |

## Backend capability

`DirectTranslationBackend` は unit の text を不透明な文字列として翻訳します。DeepL、LibreTranslate、直接の TranslateGemma 呼び出しはこちらです。構造の決定はすべて Adapter が行います。

`StructuredLLMBackend` は unit の JSON リストを受け渡しでき、placeholder を不変にする指示も持てます。それでも HTML は受け取りません。DOM の再構築も許可しません。placeholder の validation は direct と同じです。

A1 が実装しているのは `IdentityBackend` だけです。これは direct 側のテスト用 backend で、unit text をそのまま返します。次段階で TranslateGemma を `DirectTranslationBackend` として追加します。

## Parser

lxml の HTML parser を使います。`no_network=True`、`huge_tree=False`、`recover=True` です。外部 entity は解決せず、`src` や `href` は取得しません。

投稿 HTML は fragment として読み、合成した親 `div` は出力しません。先頭が `<!DOCTYPE` または `<html` の入力は document として読みます。`<!DOCTYPE>` は要素木に残らないため、出力へは再掲しません。内部 subset を出力へ戻すと entity 宣言を保持してしまうためです。

libxml2 の HTML parser はネストがおよそ 254 を超えるとテキストを黙って落とします。A1 は raw markup の開始タグ深さが 128 を超えたら `unsupported_structure` で拒否します。

## セグメント計数

- `segments_total`: backend に送った unit 数。空白と placeholder だけの run は送りません。
- `segments_translated`: 検証を通過して復元した unit 数。成功時は total と同じです。
- `segments_skipped`: 保護した fragment 数。要素、コメント、URL literal、emoji literal です。構造用の boundary placeholder は数えません。

## A1 で明示している境界

安全に「壊れたまま翻訳を続ける」ことはしません。次は仕様として固定しています。

- 未知要素は翻訳せず、要素ごと残します。`marquee` のようなタグの内側は backend に渡りません。
- `ruby` / `rt` / `rp` は翻訳しません。
- `alt` と `title` を含む属性は翻訳しません。
- `:shortcode:` という平文は protected literal ではありません。custom emoji は `img` と `picture` の構造で保護します。
- `mailto:`、`xmpp:`、`www.` だけの表記、メールアドレスは A1 の protected literal ではありません。
- placeholder の並べ替えと、隣接 placeholder のあいだへの文字挿入は拒否します。
- 深いネストは拒否します。parser が落としたテキストを翻訳結果にしません。

IdentityBackend による往復は、byte 列の一致ではなく、parse 後の要素階層、順序、タグ名、属性、テキストが一致することです。
