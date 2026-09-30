"""URL anchors and plain-URL boundaries stay out of the backend payload."""

from semantic_translation.core.dom import attribute_diff, fingerprint
from semantic_translation.core.units import TranslatedUnit
from tests.fixtures import HTML_FIXTURES
from tests.formatter_snapshots import (
    DOUBLE_ENCODED_HREF,
    DOUBLE_ENCODED_INNER,
    IDN_HREF,
    IDN_INNER,
    LONG_HREF,
    LONG_INNER,
    PERCENT_HREF,
    PERCENT_INNER,
    PRETTY_SHORT_ANCHOR,
    SHORT_HREF,
    SHORT_INNER,
    SNAPSHOTS,
    WWW_HREF,
    WWW_INNER,
    display_url,
    link_html,
    status_anchor,
)
from tests.helpers import ScriptedBackend, prepare, run

_URL = "https://example.com/foo"
_BOUNDARY_CASES = (
    "詳細https://example.com/foo",
    "詳細：https://example.com/foo",
    "（https://example.com/foo）",
    "https://example.com/foo。",
    "https://example.com/fooを確認",
    "😀https://example.com/foo",
)


def _payload(html: str) -> str:
    prepared = prepare(html)
    return "\n".join(unit.text for unit in prepared.units)


def test_frozen_link_html_matches_the_formatter_mirror():
    for name, href, inner in SNAPSHOTS:
        assert link_html(display_url(href)) == inner, name
        assert 'class=""' in inner or 'class="ellipsis"' in inner, name


def test_short_formatter_anchor_middle_span_is_not_a_backend_string():
    html = f"<p>See {status_anchor(SHORT_HREF, SHORT_INNER)} today.</p>"
    prepared = prepare(html)
    payload = prepared.units[0].text
    assert payload == "See {{MSTDN_P_0000}} today."
    assert [fragment.reason for fragment in prepared.protected_fragments] == ["url-anchor"]
    assert prepared.protected_fragments[0].kind == "element"
    for leaked in ("example.com", "https://", "/foo", "foo"):
        assert leaked not in payload
    assert 'class=""' in SHORT_INNER


def test_long_formatter_anchor_is_one_url_anchor():
    html = f"<p>See {status_anchor(LONG_HREF, LONG_INNER)} today.</p>"
    prepared = prepare(html)
    payload = prepared.units[0].text
    assert payload == "See {{MSTDN_P_0000}} today."
    assert [fragment.reason for fragment in prepared.protected_fragments] == ["url-anchor"]
    assert "ellipsis" in LONG_INNER
    for leaked in ("example.com", "resource-name", "very/long", "https://"):
        assert leaked not in payload


def test_percent_encoded_formatter_anchors_do_not_leak_path_text():
    space = f"<p>See {status_anchor(PERCENT_HREF, PERCENT_INNER)} today.</p>"
    space_payload = _payload(space)
    assert space_payload == "See {{MSTDN_P_0000}} today."
    for leaked in ("example.com", "%20", "foo bar", "foo"):
        assert leaked not in space_payload
    assert prepare(space).protected_fragments[0].reason == "url-anchor"

    encoded = f"<p>See {status_anchor(DOUBLE_ENCODED_HREF, DOUBLE_ENCODED_INNER)} today.</p>"
    encoded_payload = _payload(encoded)
    assert encoded_payload == "See {{MSTDN_P_0000}} today."
    for leaked in ("example.com", "%20", "a%20b"):
        assert leaked not in encoded_payload

    www = f"<p>See {status_anchor(WWW_HREF, WWW_INNER)} today.</p>"
    assert "example.com" not in _payload(www)
    assert prepare(www).protected_fragments[0].reason == "url-anchor"

    idn = f"<p>See {status_anchor(IDN_HREF, IDN_INNER)} today.</p>"
    idn_payload = _payload(idn)
    assert idn_payload == "See {{MSTDN_P_0000}} today."
    assert "example.com" not in idn_payload
    assert "東京" not in idn_payload


def test_pretty_printed_short_anchor_is_still_one_url_anchor():
    html = f"<p>See {PRETTY_SHORT_ANCHOR} today.</p>"
    prepared = prepare(html)
    assert prepared.units[0].text == "See {{MSTDN_P_0000}} today."
    assert [fragment.reason for fragment in prepared.protected_fragments] == ["url-anchor"]
    assert "example.com" not in prepared.units[0].text


def test_human_readable_label_stays_translatable():
    prepared = prepare(
        '<p>Please read <a href="https://example.com/article">the article</a> today.</p>'
    )
    assert prepared.units[0].text == "Please read {{MSTDN_P_0000}}the article{{MSTDN_P_0001}} today."
    assert "the article" in prepared.units[0].text
    assert all(fragment.reason != "url-anchor" for fragment in prepared.protected_fragments)
    assert "example.com" not in prepared.units[0].text


def test_url_only_anchor_is_url_anchor_not_a_text_literal():
    prepared = prepare(f"<p><a href=\"{_URL}\">{_URL}</a></p>")
    assert prepared.units == ()
    assert len(prepared.protected_fragments) == 1
    assert prepared.protected_fragments[0].reason == "url-anchor"
    assert prepared.protected_fragments[0].kind == "element"


def test_mention_and_hashtag_reasons_stay_class_based():
    mention = prepare(
        '<p>Hello <span class="h-card" translate="no">'
        f'<a href="{_URL}" class="u-url mention">{_URL}</a>'
        "</span> today</p>"
    )
    assert mention.protected_fragments[0].reason == "class:h-card"
    assert "example.com" not in mention.units[0].text

    hashtag = prepare(
        '<p>See <a href="https://example.com/tags/mastodon" class="mention hashtag" rel="tag">'
        "#<span>mastodon</span></a> today</p>"
    )
    assert hashtag.protected_fragments[0].reason == "class:hashtag"
    assert "mastodon" not in hashtag.units[0].text


def test_plain_url_boundaries_keep_language_and_hide_the_url_body():
    for text in _BOUNDARY_CASES:
        prepared = prepare(f"<p>{text}</p>")
        payload = "\n".join(unit.text for unit in prepared.units)
        assert "example.com" not in payload, text
        assert "/foo" not in payload, text
        assert "https://example.com/foo" not in payload, text
        urls = [fragment for fragment in prepared.protected_fragments if fragment.kind == "url"]
        assert len(urls) == 1, text
        assert urls[0].original == _URL, text
        if text.startswith("詳細"):
            assert "詳細" in payload, text
        if text.endswith("を確認"):
            assert "を確認" in payload, text
        if "。" in text:
            assert "。" in payload, text
        if text.startswith("（"):
            assert "（" in payload and "）" in payload, text


def test_plain_url_strings_are_unchanged_after_restore():
    def translate(units, _source, _target):
        replaced = []
        for unit in units:
            text = unit.text.replace("詳細", "DETAIL").replace("を確認", "CHECK")
            replaced.append(TranslatedUnit(id=unit.id, text=text))
        return replaced

    backend = ScriptedBackend(translate)
    for text in _BOUNDARY_CASES:
        html = f"<p>{text}</p>"
        result = run(html, backend=backend)
        assert result.translated_html.count(_URL) == 1, text
        assert attribute_diff(html, result.translated_html) == [], text
        if "詳細" in text:
            assert "DETAIL" in result.translated_html, text
            assert "詳細" not in result.translated_html, text
        if text.endswith("を確認"):
            assert f"{_URL}CHECK" in result.translated_html, text
            assert "を確認" not in result.translated_html, text
        else:
            assert f"{_URL}CHECK" not in result.translated_html, text
        if "詳細" not in text and "を確認" not in text:
            assert fingerprint(html) == fingerprint(result.translated_html), text


def test_formatter_fixtures_roundtrip_without_leaking_url_text():
    names = {
        "formatter_link_html_short",
        "formatter_link_html_long",
        "formatter_link_html_percent20",
        "formatter_link_html_percent2520",
        "formatter_link_html_www",
        "formatter_link_html_idn",
        "formatter_link_html_short_pretty",
        "url_anchor_text",
        "link_with_natural_language",
        "url_between_natural_language",
    }
    fixtures = [fixture for fixture in HTML_FIXTURES if fixture.name in names]
    assert {fixture.name for fixture in fixtures} == names
    for fixture in fixtures:
        result = run(fixture.html)
        assert fingerprint(fixture.html) == fingerprint(result.translated_html), fixture.name
        assert attribute_diff(fixture.html, result.translated_html) == []
        payload = _payload(fixture.html)
        assert "example.com" not in payload, fixture.name
