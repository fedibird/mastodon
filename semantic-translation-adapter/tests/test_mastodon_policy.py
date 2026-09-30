"""Mastodon v1 unit boundaries and the backend payload contract."""

import regex

from semantic_translation.core.placeholders import PlaceholderCodec
from tests.fixtures import HTML_FIXTURES
from tests.helpers import prepare

_TAG_RE = regex.compile(r"</?[A-Za-z][^<>]*>")


def _payload(html: str) -> str:
    prepared = prepare(html)
    return "\n".join(unit.text for unit in prepared.units)


def test_required_fixtures_do_not_send_serialized_tags():
    for fixture in HTML_FIXTURES:
        payload = _payload(fixture.html)
        assert "href=" not in payload, fixture.name
        assert "translate=" not in payload, fixture.name
        assert "class=" not in payload, fixture.name
        assert "data-" not in payload, fixture.name
        assert "<span" not in payload, fixture.name
        assert "<a " not in payload and "<a>" not in payload, fixture.name
        assert "<img" not in payload, fixture.name
        assert "<p" not in payload, fixture.name
        assert "</" not in payload, fixture.name
        if not fixture.literal_angle_brackets:
            assert "<" not in payload, fixture.name
            assert _TAG_RE.search(payload) is None, fixture.name


def test_literal_angle_brackets_stay_text_and_are_not_element_markup():
    prepared = prepare("<p>a &lt; b and I said &lt;hello&gt; today</p>")
    text = prepared.units[0].text
    assert text == "a < b and I said <hello> today"
    assert "<p" not in text
    assert "</" not in text
    assert _TAG_RE.search(text)


def test_plain_sentence_is_one_unit():
    prepared = prepare("<p>Hello world.</p>")
    assert [unit.text for unit in prepared.units] == ["Hello world."]
    assert prepared.segments_skipped == 0


def test_paragraphs_blockquote_list_and_br_are_block_boundaries():
    paragraphs = prepare("<p>First paragraph.</p><p>Second paragraph.</p>")
    assert [unit.text for unit in paragraphs.units] == ["First paragraph.", "Second paragraph."]

    broken = prepare("<p>Line one<br>Line two</p>")
    assert [unit.text for unit in broken.units] == ["Line one", "Line two"]

    quoted = prepare("<blockquote><p>Quoted line.</p></blockquote>")
    assert [unit.text for unit in quoted.units] == ["Quoted line."]

    items = prepare("<ul><li>One</li><li>Two</li></ul>")
    assert [unit.text for unit in items.units] == ["One", "Two"]

    root = prepare("Intro<p>Body</p>Outro")
    assert [unit.text for unit in root.units] == ["Intro", "Body", "Outro"]


def test_br_inside_inline_markup_splits_units_without_dropping_the_element():
    prepared = prepare("<p><em>Hello<br>world</em></p>")
    assert [unit.text for unit in prepared.units] == ["Hello", "world"]


def test_inline_markup_is_boundary_placeholders_not_tags():
    prepared = prepare("<p>Hello <em>world</em>!</p>")
    text = prepared.units[0].text
    assert text == "Hello {{MSTDN_P_0000}}world{{MSTDN_P_0001}}!"
    assert "<em" not in text
    assert prepared.segments_skipped == 0


def test_mention_hashtag_emoji_and_translate_no_are_atomic():
    mention = prepare(
        '<p>Hello <span class="h-card" translate="no">'
        '<a href="https://example.com/@alice" class="u-url mention">@<span>alice</span></a>'
        "</span> today</p>"
    )
    assert mention.units[0].text == "Hello {{MSTDN_P_0000}} today"
    assert "alice" not in mention.units[0].text
    assert mention.protected_fragments[0].reason == "class:h-card"

    hashtag = prepare(
        '<p>See <a href="https://example.com/tags/mastodon" class="mention hashtag" rel="tag">'
        "#<span>mastodon</span></a> today</p>"
    )
    assert "mastodon" not in hashtag.units[0].text
    assert hashtag.protected_fragments[0].reason == "class:hashtag"

    emoji = prepare(
        '<p>Hello <img class="emojione custom-emoji" alt=":coolcat:" title=":coolcat:" '
        'src="https://cdn.example/emoji.png" data-original="https://cdn.example/emoji.png"> there</p>'
    )
    assert ":coolcat:" not in emoji.units[0].text
    assert "cdn.example" not in emoji.units[0].text
    assert emoji.protected_fragments[0].reason == "class:custom-emoji"

    picture = prepare(
        '<p>Hi <picture><source srcset="/a.svg">'
        '<img class="emojione" alt="😀" src="/a.svg"></picture> there</p>'
    )
    assert picture.units[0].text == "Hi {{MSTDN_P_0000}} there"
    assert picture.protected_fragments[0].reason == "emoji-picture"

    hidden = prepare(
        '<p>Keep <span translate="no">secret <b>nested</b> '
        '<a href="https://example.com/hidden">link</a></span> please</p>'
    )
    assert hidden.units[0].text == "Keep {{MSTDN_P_0000}} please"
    assert "secret" not in hidden.units[0].text
    assert "nested" not in hidden.units[0].text
    assert "hidden" not in hidden.units[0].text
    assert hidden.protected_fragments[0].reason == "translate-no"


def test_formatted_url_and_url_anchor_are_not_sent_as_language():
    formatted = prepare(
        '<p><a href="https://example.com/very/long/path">'
        '<span class="invisible">https://</span>'
        '<span class="ellipsis">example.com/very/long</span>'
        '<span class="invisible">/path</span></a></p>'
    )
    assert formatted.units == ()
    assert [fragment.reason for fragment in formatted.protected_fragments] == ["url-anchor"]
    assert "class:ellipsis" not in [fragment.reason for fragment in formatted.protected_fragments]

    anchor = prepare('<p><a href="https://example.com/foo">https://example.com/foo</a></p>')
    assert anchor.units == ()
    assert anchor.protected_fragments[0].kind == "element"
    assert anchor.protected_fragments[0].reason == "url-anchor"
    assert anchor.protected_fragments[0].original is None


def test_plain_urls_in_text_nodes_are_placeholders():
    prepared = prepare("<p>See https://example.com/a and http://example.com/b for details.</p>")
    assert prepared.units[0].text == "See {{MSTDN_P_0000}} and {{MSTDN_P_0001}} for details."
    assert [fragment.original for fragment in prepared.protected_fragments] == [
        "https://example.com/a",
        "http://example.com/b",
    ]
    assert "example.com" not in prepared.units[0].text


def test_url_only_line_is_skipped():
    prepared = prepare("<p>https://example.com/only</p>")
    assert prepared.units == ()
    assert prepared.segments_skipped == 1
    assert prepared.protected_fragments[0].original == "https://example.com/only"


def test_code_and_pre_text_is_absent_from_the_payload():
    prepared = prepare("<p>Run <code>git status</code> please.</p><pre>do_not_translate()</pre>")
    payload = _payload("<p>Run <code>git status</code> please.</p><pre>do_not_translate()</pre>")
    assert prepared.units[0].text == "Run {{MSTDN_P_0000}} please."
    assert "git status" not in payload
    assert "do_not_translate" not in payload


def test_mixed_mention_url_and_emoji_share_one_unit():
    prepared = prepare(
        '<p>Hey <span class="h-card" translate="no"><a class="u-url mention" '
        'href="https://example.com/@alice">@<span>alice</span></a></span> '
        "see https://example.com/a \U0001f44d</p>"
    )
    text = prepared.units[0].text
    assert text.startswith("Hey ")
    assert "alice" not in text
    assert "example.com" not in text
    assert "\U0001f44d" not in text
    assert PlaceholderCodec.find_tokens(text) == [
        "{{MSTDN_P_0000}}",
        "{{MSTDN_P_0001}}",
        "{{MSTDN_P_0002}}",
    ]
    assert [fragment.kind for fragment in prepared.protected_fragments] == ["element", "url", "emoji"]


def test_class_token_must_match_exactly():
    prepared = prepare('<p>Keep <span class="not-invisible">this phrase</span> please</p>')
    assert "this phrase" in prepared.units[0].text
    assert all(fragment.reason != "class:invisible" for fragment in prepared.protected_fragments)


def test_unknown_elements_are_preserved_and_not_translated():
    prepared = prepare("<p>Hello <marquee>scroll</marquee> there</p>")
    assert prepared.units[0].text == "Hello {{MSTDN_P_0000}} there"
    assert "scroll" not in prepared.units[0].text
    assert prepared.protected_fragments[0].reason == "unknown"


def test_bare_shortcode_text_is_not_a_protected_literal():
    """A1 protects custom-emoji elements, not ``:shortcode:`` text."""

    prepared = prepare("<p>Hello :coolcat: there</p>")
    assert prepared.units[0].text == "Hello :coolcat: there"
    assert prepared.protected_fragments == ()


def test_translate_yes_inside_translate_no_stays_protected():
    prepared = prepare(
        '<p>Keep <span translate="no">secret <span translate="yes">still hidden</span></span> please</p>'
    )
    assert prepared.units[0].text == "Keep {{MSTDN_P_0000}} please"
    assert "still hidden" not in prepared.units[0].text


def test_ruby_annotation_is_preserved_and_not_translated():
    prepared = prepare("<p>Read <ruby>漢字<rt>かんじ</rt></ruby> today</p>")
    assert "かんじ" not in prepared.units[0].text
    assert "漢字" not in prepared.units[0].text
    assert prepared.protected_fragments[0].reason == "tag:ruby"


def test_plain_email_is_not_a_protected_literal_in_a1():
    prepared = prepare("<p>Write to alice@example.com today</p>")
    assert prepared.units[0].text == "Write to alice@example.com today"
    assert prepared.protected_fragments == ()


def test_api_example_segment_counts():
    prepared = prepare('<p>Hello <span translate="no">@alice@example.com</span></p>')
    assert len(prepared.units) == 1
    assert prepared.segments_skipped == 1
    assert "@alice@example.com" not in prepared.units[0].text
