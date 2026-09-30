"""Fixed HTML and backend-behavior fixtures for the Mastodon v1 policy."""

from dataclasses import dataclass

THUMBS = "\U0001f44d"
THUMBS_TONE = "\U0001f44d\U0001f3fb"
HEART = "\u2764\ufe0f"
FAMILY = "\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466"
FLAG = "\U0001f1ef\U0001f1f5"
KEYCAP = "1\ufe0f\u20e3"


@dataclass(frozen=True)
class HtmlFixture:
    name: str
    html: str
    # When true, a text node itself contains angle brackets. The payload may
    # then contain "<" without that "<" being markup the adapter serialized.
    literal_angle_brackets: bool = False


HTML_FIXTURES: tuple[HtmlFixture, ...] = (
    HtmlFixture("plain_sentence", "<p>Hello world.</p>"),
    HtmlFixture(
        "multiple_paragraphs",
        "<p>First paragraph.</p><p>Second paragraph.</p>",
    ),
    HtmlFixture("br_break", "<p>Line one<br>Line two</p>"),
    HtmlFixture(
        "mention",
        (
            "<p>Hello "
            '<span class="h-card" translate="no">'
            '<a href="https://example.com/@alice" class="u-url mention account-url-link" '
            'data-account-id="1" data-account-actor-type="Person" '
            'data-account-acct="alice@example.com">@<span>alice</span></a>'
            "</span> today</p>"
        ),
    ),
    HtmlFixture(
        "hashtag",
        (
            "<p>Talk about "
            '<a href="https://example.com/tags/mastodon" class="mention hashtag" rel="tag">'
            "#<span>mastodon</span></a> today</p>"
        ),
    ),
    HtmlFixture(
        "custom_emoji",
        (
            "<p>Hello "
            '<img draggable="false" class="emojione custom-emoji" alt=":coolcat:" '
            'title=":coolcat:" src="https://cdn.example/emoji.png" '
            'data-original="https://cdn.example/emoji.png" '
            'data-static="https://cdn.example/static.png"> there</p>'
        ),
    ),
    HtmlFixture(
        "translate_no_nested",
        (
            "<p>Keep <span translate=\"no\">secret <b>nested</b> "
            '<a href="https://example.com/hidden">link</a></span> please</p>'
        ),
    ),
    HtmlFixture(
        "formatted_url",
        (
            "<p><a href=\"https://example.com/very/long/path\">"
            '<span class="invisible">https://</span>'
            '<span class="ellipsis">example.com/very/long</span>'
            '<span class="invisible">/path</span>'
            "</a></p>"
        ),
    ),
    HtmlFixture(
        "url_anchor_text",
        '<p><a href="https://example.com/foo">https://example.com/foo</a></p>',
    ),
    HtmlFixture(
        "plain_text_url",
        "<p>See https://example.com/a and http://example.com/b for details.</p>",
    ),
    HtmlFixture("url_only_line", "<p>https://example.com/only</p>"),
    HtmlFixture("emoji_thumbs", f"<p>I {THUMBS} this</p>"),
    HtmlFixture("emoji_skin_tone", f"<p>I {THUMBS_TONE} this</p>"),
    HtmlFixture("emoji_zwj_family", f"<p>Say {FAMILY} now</p>"),
    HtmlFixture("emoji_flag", f"<p>I {FLAG} this</p>"),
    HtmlFixture("emoji_vs16_heart", f"<p>I {HEART} this</p>"),
    HtmlFixture("emoji_keycap", f"<p>I {KEYCAP} this</p>"),
    HtmlFixture(
        "code_and_pre",
        "<p>Run <code>git status</code> please.</p><pre><code>do_not_translate()</code></pre><p>Done</p>",
    ),
    HtmlFixture(
        "link_with_natural_language",
        '<p>Please read <a href="https://example.com/post">the article</a> today.</p>',
    ),
    HtmlFixture(
        "mention_url_emoji_mixed",
        (
            "<p>Hey "
            '<span class="h-card" translate="no">'
            '<a href="https://example.com/@alice" class="u-url mention" data-account-id="1">'
            "@<span>alice</span></a></span> "
            f"see https://example.com/a {THUMBS}</p>"
        ),
    ),
    HtmlFixture(
        "angle_brackets_in_text",
        "<p>a &lt; b and c &gt; d</p>",
        literal_angle_brackets=True,
    ),
    HtmlFixture(
        "literal_tag_like_text",
        "<p>I said &lt;hello&gt; today</p>",
        literal_angle_brackets=True,
    ),
)

VALIDATION_BASE_HTML = '<p>Hello <span translate="no">@alice</span> world</p>'

VALIDATION_FIXTURES: tuple[str, ...] = (
    "backend_deletes_placeholder",
    "backend_duplicates_placeholder",
    "backend_mutates_placeholder",
    "backend_adds_unknown_placeholder",
    "backend_omits_unit",
    "backend_returns_unknown_unit",
)
