"""URL and Unicode emoji literals are protected as whole spans."""

import regex

from semantic_translation.core.literals import find_literal_spans, is_emoji_cluster
from semantic_translation.core.placeholders import PlaceholderCodec
from tests.fixtures import FAMILY, FLAG, HEART, KEYCAP, THUMBS, THUMBS_TONE
from tests.helpers import prepare

EMOJI_CASES = {
    "thumbs": THUMBS,
    "skin_tone": THUMBS_TONE,
    "vs16_heart": HEART,
    "zwj_family": FAMILY,
    "flag": FLAG,
    "keycap": KEYCAP,
}


def test_emoji_sequences_are_single_graphemes_and_single_literals():
    for name, sequence in EMOJI_CASES.items():
        clusters = regex.findall(r"\X", sequence)
        assert clusters == [sequence], name
        assert is_emoji_cluster(sequence), name
        spans = find_literal_spans(f"I {sequence} this")
        emoji_spans = [span for span in spans if span.kind == "emoji"]
        assert len(emoji_spans) == 1, name
        assert emoji_spans[0].original == sequence


def test_zwj_skin_tone_and_keycap_are_not_split_inside_units():
    prepared = prepare(f"<p>Say {FAMILY} and {THUMBS_TONE} and {KEYCAP} and {HEART} and {FLAG}</p>")
    originals = [fragment.original for fragment in prepared.protected_fragments if fragment.kind == "emoji"]
    assert originals == [FAMILY, THUMBS_TONE, KEYCAP, HEART, FLAG]
    unit = prepared.units[0].text
    assert "\u200d" not in unit
    assert "\ufe0f" not in unit
    assert "\u20e3" not in unit
    assert KEYCAP[0] not in PlaceholderCodec.strip_tokens(unit)


def test_plain_url_punctuation_is_trimmed_and_balanced_parentheses_stay():
    text = "See (https://example.com/a). Visit https://en.wikipedia.org/wiki/Foo_(bar) now"
    spans = [span for span in find_literal_spans(text) if span.kind == "url"]
    assert [span.original for span in spans] == [
        "https://example.com/a",
        "https://en.wikipedia.org/wiki/Foo_(bar)",
    ]


def test_only_absolute_http_and_https_urls_are_protected():
    text = "www.example.com mailto:a@b.test xmpp:a@b.test https://example.com/a http://example.com/b"
    spans = find_literal_spans(text)
    assert [span.original for span in spans] == [
        "https://example.com/a",
        "http://example.com/b",
    ]


def test_scheme_only_and_relative_paths_are_not_urls():
    assert find_literal_spans("https:// is not enough, nor is /tags/mastodon") == []


def test_angle_bracket_text_is_not_a_url_or_tag_span():
    spans = find_literal_spans("a < b and c > d")
    assert spans == []


def test_cjk_and_emoji_do_not_block_a_url_and_do_not_swallow_following_hiragana():
    cases = {
        "詳細https://example.com/foo": ("詳細", "https://example.com/foo", ""),
        "詳細：https://example.com/foo": ("詳細：", "https://example.com/foo", ""),
        "（https://example.com/foo）": ("（", "https://example.com/foo", "）"),
        "https://example.com/foo。": ("", "https://example.com/foo", "。"),
        "https://example.com/fooを確認": ("", "https://example.com/foo", "を確認"),
        "😀https://example.com/foo": ("😀", "https://example.com/foo", ""),
    }
    for text, (before, url, after) in cases.items():
        spans = find_literal_spans(text)
        urls = [span for span in spans if span.kind == "url"]
        assert len(urls) == 1, text
        assert urls[0].original == url, text
        assert text[: urls[0].start] == before, text
        assert text[urls[0].end :] == after, text
        assert "example.com" not in before and "example.com" not in after


def test_hiragana_idn_stays_inside_the_url_and_han_glued_to_ascii_is_over_protected():
    idn = find_literal_spans("see https://nic.みんな/page now")
    assert [span.original for span in idn if span.kind == "url"] == ["https://nic.みんな/page"]

    han = find_literal_spans("https://example.com/foo詳細")
    assert [span.original for span in han if span.kind == "url"] == ["https://example.com/foo詳細"]


def test_ascii_alnum_still_blocks_a_scheme_start():
    assert find_literal_spans("nothttps://example.com/foo") == []
    assert find_literal_spans("see/https://example.com/foo") == []
