"""The parser does not fetch resources, and failures stay fail-closed."""

import socket

import pytest

from semantic_translation.core.errors import InputTooLarge, PlaceholderCollision, UnsupportedStructure
from tests.helpers import run


def test_translate_does_not_open_sockets(monkeypatch):
    def boom(*_args, **_kwargs):
        raise AssertionError("network access attempted")

    monkeypatch.setattr(socket, "socket", boom)
    monkeypatch.setattr(socket, "create_connection", boom)
    result = run(
        '<p>Hello <img src="http://127.0.0.1/secret.png" alt="x"> '
        '<a href="http://127.0.0.1/private">docs</a></p>'
    )
    assert "docs" in result.translated_html
    assert "secret.png" in result.translated_html


def test_external_entity_is_not_loaded():
    html = '<!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><p>&xxe;</p>'
    try:
        result = run(html)
    except (UnsupportedStructure, PlaceholderCollision):
        return
    assert "root:x:" not in result.translated_html
    assert "/bin/bash" not in result.translated_html
    assert "daemon:x:" not in result.translated_html


def test_deep_markup_fails_closed_before_the_parser_drops_text():
    marker = "DEEP_MARKER"
    html = "<span>" * 200 + marker + "</span>" * 200
    with pytest.raises(UnsupportedStructure):
        run(html)


def test_moderate_nesting_still_roundtrips():
    marker = "NESTED_OK"
    html = "<span>" * 20 + marker + "</span>" * 20
    result = run(html)
    assert marker in result.translated_html


def test_size_limit_is_enforced_in_the_service():
    from semantic_translation.backends.identity import IdentityBackend
    from semantic_translation.policies.mastodon_v1 import MastodonV1Policy
    from semantic_translation.service import translate_html

    with pytest.raises(InputTooLarge) as caught:
        translate_html(
            "<p>SECRET_SIZE</p>",
            source_language="en",
            target_language="ja",
            backend=IdentityBackend(),
            policy=MastodonV1Policy(),
            max_html_bytes=8,
        )
    assert "SECRET_SIZE" not in str(caught.value)


def test_reserved_placeholder_in_an_attribute_fails_closed():
    html = '<p><a href="https://example.com/{{MSTDN_P_0001}}">read</a></p>'
    with pytest.raises(PlaceholderCollision):
        run(html)
