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
