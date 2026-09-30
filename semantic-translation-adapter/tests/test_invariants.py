"""Identity translation preserves the parsed DOM."""

import html

from semantic_translation.core.dom import attribute_diff, fingerprint
from semantic_translation.core.placeholders import PlaceholderCodec
from tests.fixtures import HTML_FIXTURES
from tests.helpers import prepare, run


def _assert_identity(source: str) -> None:
    result = run(source)
    assert fingerprint(source) == fingerprint(result.translated_html)
    assert attribute_diff(source, result.translated_html) == []
    assert PlaceholderCodec.collides(result.translated_html) is False
    for unit in prepare(source).units:
        assert "<p" not in unit.text
        assert "href=" not in unit.text


def test_identity_roundtrip_on_fixed_fixtures():
    for fixture in HTML_FIXTURES:
        _assert_identity(fixture.html)


def test_identity_roundtrip_on_generated_documents():
    mention = (
        '<span class="h-card" translate="no">'
        '<a href="https://example.com/@alice" class="u-url mention" data-account-id="9">'
        "@<span>alice</span></a></span>"
    )
    hashtag = (
        '<a href="https://example.com/tags/fedibird" class="mention hashtag" rel="tag">'
        "#<span>fedibird</span></a>"
    )
    emoji = (
        '<img draggable="false" class="emojione custom-emoji" alt=":coolcat:" '
        'title=":coolcat:" src="https://cdn.example/e.png" '
        'data-original="https://cdn.example/e.png" data-static="https://cdn.example/s.png">'
    )
    sentences = [
        "Hello",
        "Good morning",
        "今日はいい天気です",
        html.escape("a < b"),
        "See https://example.com/path_(ok)",
        "Visit http://example.com/x.",
    ]
    documents = []
    for sentence in sentences:
        documents.append(f"<p>{sentence}</p>")
        documents.append(f"<p>{sentence} {mention} end</p>")
        documents.append(f"<p>{sentence} {hashtag}</p>")
        documents.append(f"<p>{sentence} {emoji} end</p>")
        documents.append(f"<p>{sentence}<br>{sentence}</p>")
        documents.append(f"<blockquote><p>{sentence}</p></blockquote>")
        documents.append(f"<ul><li>{sentence}</li><li>{sentence} {mention}</li></ul>")
        documents.append(
            f"<p>{sentence} <a href=\"https://example.com/post\">{sentence}</a> tail</p>"
        )
        documents.append(f"<p><span translate=\"no\">{sentence}</span> {sentence}</p>")
        documents.append(f"<p>Run <code>{sentence}</code> now</p><pre>{sentence}</pre>")
    documents.append("intro<p>body</p>outro")
    documents.append("<p>A <!-- secret note --> B</p>")
    documents.append("<p></p>")
    documents.append("")
    documents.append(
        '<p><a href="https://example.com/a?b=1&amp;c=2">'
        '<span class="invisible">https://</span><span class="ellipsis">example.com/a</span>'
        '<span class="invisible">?b=1&amp;c=2</span></a></p>'
    )
    assert len(documents) > 50
    for document in documents:
        _assert_identity(document)


def test_backend_may_change_only_natural_language():
    from semantic_translation.core.units import TranslatedUnit

    from tests.helpers import ScriptedBackend

    source = (
        '<p>Hello <span class="h-card" translate="no">'
        '<a href="https://example.com/@alice" class="u-url mention" data-account-id="1">'
        "@<span>alice</span></a></span> today</p>"
    )

    def translate(units, _source, _target):
        return [
            TranslatedUnit(id=unit.id, text=unit.text.replace("Hello", "こんにちは").replace("today", "今日"))
            for unit in units
        ]

    result = run(source, backend=ScriptedBackend(translate))
    assert attribute_diff(source, result.translated_html) == []
    assert "こんにちは" in result.translated_html
    assert "今日" in result.translated_html
    assert 'href="https://example.com/@alice"' in result.translated_html
    assert 'data-account-id="1"' in result.translated_html
    assert "alice" in result.translated_html
    assert "translate=\"no\"" in result.translated_html or "translate='no'" in result.translated_html


def test_backend_markup_is_stored_as_text_not_elements():
    from semantic_translation.core.dom import parse_html
    from semantic_translation.core.units import TranslatedUnit

    from tests.helpers import ScriptedBackend

    source = "<p>Hello world.</p>"

    def translate(units, _source, _target):
        return [
            TranslatedUnit(
                id=units[0].id,
                text='Hello <script>alert(1)</script> <a href="https://evil.test">x</a>',
            )
        ]

    result = run(source, backend=ScriptedBackend(translate))
    root = parse_html(result.translated_html).root
    tags = [node.tag for node in root.iter() if isinstance(node.tag, str)]
    assert "script" not in tags
    assert "a" not in tags
    assert "<script>" not in result.translated_html
    assert "&lt;script&gt;" in result.translated_html
