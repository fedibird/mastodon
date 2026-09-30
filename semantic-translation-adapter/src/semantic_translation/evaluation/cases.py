"""Fixed evaluation sentences.

These strings are part of the adapter test suite. The harness must not be
pointed at live user posts.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class EvalCase:
    name: str
    html: str
    source: str
    target: str
    groups: tuple[str, ...]
    expected_placeholders: int


_MENTION = (
    '<span class="h-card" translate="no">'
    '<a href="https://example.com/@ada" class="u-url mention">@<span>ada</span></a>'
    "</span>"
)
_HASHTAG = (
    '<a href="https://example.com/tags/mastodon" class="mention hashtag" rel="tag">'
    "#<span>mastodon</span></a>"
)

EVAL_CASES: tuple[EvalCase, ...] = (
    EvalCase(
        "en_ja_plain",
        "<p>Good morning.</p>",
        "en",
        "ja",
        ("language:en-ja", "placeholders:none", "style:short_conversation", "style:en_to_ja"),
        0,
    ),
    EvalCase(
        "en_ja_one_placeholder",
        '<p>Hello <span translate="no">Ada</span> today.</p>',
        "en",
        "ja",
        ("language:en-ja", "placeholders:one"),
        1,
    ),
    EvalCase(
        "en_ja_two_placeholders",
        '<p>Hello <span translate="no">Ada</span> and <span translate="no">Bea</span>.</p>',
        "en",
        "ja",
        ("language:en-ja", "placeholders:two"),
        2,
    ),
    EvalCase(
        "en_ja_three_placeholders",
        '<p>See <span translate="no">Ada</span> <span translate="no">Bea</span> <span translate="no">Cy</span> now.</p>',
        "en",
        "ja",
        ("language:en-ja", "placeholders:three"),
        3,
    ),
    EvalCase(
        "en_ja_adjacent_placeholders",
        '<p>Go <span translate="no">Ada</span><span translate="no">Bea</span> now.</p>',
        "en",
        "ja",
        ("language:en-ja", "placeholders:adjacent"),
        2,
    ),
    EvalCase(
        "en_ja_url",
        "<p>See https://example.com/a for details.</p>",
        "en",
        "ja",
        ("language:en-ja", "placeholders:url"),
        1,
    ),
    EvalCase(
        "en_ja_emoji",
        "<p>I \U0001f44d this.</p>",
        "en",
        "ja",
        ("language:en-ja", "placeholders:emoji"),
        1,
    ),
    EvalCase(
        "en_ja_mention",
        f"<p>Hello {_MENTION} today.</p>",
        "en",
        "ja",
        ("language:en-ja", "placeholders:mention"),
        1,
    ),
    EvalCase(
        "en_ja_hashtag",
        f"<p>Talk about {_HASHTAG} today.</p>",
        "en",
        "ja",
        ("language:en-ja", "placeholders:hashtag"),
        1,
    ),
    EvalCase(
        "en_ja_inline_boundary",
        "<p>Hello <em>world</em>!</p>",
        "en",
        "ja",
        ("language:en-ja", "placeholders:inline"),
        2,
    ),
    EvalCase(
        "en_ja_mixed",
        f"<p>Hey {_MENTION} see https://example.com/a \U0001f44d</p>",
        "en",
        "ja",
        ("language:en-ja", "placeholders:mixed"),
        3,
    ),
    EvalCase(
        "en_ja_sns",
        "<p>lol this timeline is unhinged today.</p>",
        "en",
        "ja",
        ("language:en-ja", "style:sns", "style:en_to_ja"),
        0,
    ),
    EvalCase(
        "en_ja_technical",
        "<p>The adapter restores translated text onto the original DOM after validation.</p>",
        "en",
        "ja",
        ("language:en-ja", "style:technical", "style:en_to_ja"),
        0,
    ),
    EvalCase(
        "en_ja_long_paragraph",
        (
            "<p>Yesterday I rewrote the small service that sits in front of the translator. "
            "It still sends only the sentence, then checks that every marker came back unchanged. "
            "If a marker moves, the whole reply is discarded and the original post stays as it was. "
            "That is slower than trusting the model, and it is the behavior we want.</p>"
        ),
        "en",
        "ja",
        ("language:en-ja", "style:long_paragraph", "style:en_to_ja"),
        0,
    ),
    EvalCase(
        "ja_en_polite",
        "<p>本日はご確認いただきありがとうございます。</p>",
        "ja",
        "en",
        ("language:ja-en", "style:polite", "style:ja_to_en"),
        0,
    ),
    EvalCase(
        "ja_en_casual",
        "<p>ちょっとそれ、いま無理かも。</p>",
        "ja",
        "en",
        ("language:ja-en", "style:casual", "style:ja_to_en"),
        0,
    ),
    EvalCase(
        "ja_en_elliptical",
        "<p>わかった。あとで送る。</p>",
        "ja",
        "en",
        ("language:ja-en", "style:elliptical", "style:ja_to_en"),
        0,
    ),
    EvalCase(
        "ja_en_one_placeholder",
        '<p>明日<span translate="no">Ada</span>に渡す。</p>',
        "ja",
        "en",
        ("language:ja-en", "placeholders:one", "style:ja_to_en"),
        1,
    ),
    EvalCase(
        "zh_ja_plain",
        "<p>今天天气很好。</p>",
        "zh",
        "ja",
        ("language:zh-ja", "script:zh"),
        0,
    ),
    EvalCase(
        "zh_ja_one_placeholder",
        '<p>请看<span translate="no">Ada</span>。</p>',
        "zh",
        "ja",
        ("language:zh-ja", "placeholders:one"),
        1,
    ),
    EvalCase(
        "zh_tw_ja_probe",
        "<p>今天天气很好。</p>",
        "zh-TW",
        "ja",
        ("script:zh-TW",),
        0,
    ),
    EvalCase(
        "zh_hans_ja_probe",
        "<p>今天天气很好。</p>",
        "zh-Hans",
        "ja",
        ("script:zh-Hans",),
        0,
    ),
    EvalCase(
        "zh_hant_ja_probe",
        "<p>今天天气很好。</p>",
        "zh-Hant",
        "ja",
        ("script:zh-Hant",),
        0,
    ),
    EvalCase(
        "ko_ja_plain",
        "<p>오늘 날씨가 좋네요.</p>",
        "ko",
        "ja",
        ("language:ko-ja",),
        0,
    ),
    EvalCase(
        "ko_ja_one_placeholder",
        '<p>내일 <span translate="no">Ada</span>에게 전달합니다.</p>',
        "ko",
        "ja",
        ("language:ko-ja", "placeholders:one"),
        1,
    ),
)

REQUIRED_GROUPS: frozenset[str] = frozenset(
    {
        "language:en-ja",
        "language:ja-en",
        "language:zh-ja",
        "language:ko-ja",
        "script:zh",
        "script:zh-TW",
        "script:zh-Hans",
        "script:zh-Hant",
        "placeholders:none",
        "placeholders:one",
        "placeholders:two",
        "placeholders:three",
        "placeholders:adjacent",
        "placeholders:url",
        "placeholders:emoji",
        "placeholders:mention",
        "placeholders:hashtag",
        "placeholders:inline",
        "placeholders:mixed",
        "style:short_conversation",
        "style:sns",
        "style:technical",
        "style:long_paragraph",
        "style:polite",
        "style:casual",
        "style:elliptical",
        "style:ja_to_en",
        "style:en_to_ja",
    }
)
