"""Backend responses that fail validation do not produce HTML."""

import pytest

from semantic_translation.core.errors import (
    DuplicatePlaceholder,
    DuplicateTranslationUnit,
    InvalidBackendResponse,
    MissingPlaceholder,
    MissingTranslationUnit,
    PlaceholderOrderMismatch,
    UnknownPlaceholder,
    UnknownTranslationUnit,
)
from semantic_translation.core.placeholders import PlaceholderCodec
from semantic_translation.core.units import TranslatedUnit
from tests.fixtures import VALIDATION_BASE_HTML, VALIDATION_FIXTURES
from tests.helpers import ScriptedBackend, prepare, run


def _replace(units, text: str) -> list[TranslatedUnit]:
    assert len(units) == 1
    return [TranslatedUnit(id=units[0].id, text=text)]


def test_validation_fixture_names_are_fixed():
    assert VALIDATION_FIXTURES == (
        "backend_deletes_placeholder",
        "backend_duplicates_placeholder",
        "backend_mutates_placeholder",
        "backend_adds_unknown_placeholder",
        "backend_omits_unit",
        "backend_returns_unknown_unit",
    )


def test_backend_deletes_placeholder():
    _expect(MissingPlaceholder, lambda units: _replace(units, "Hello  world"))


def test_backend_duplicates_placeholder():
    def mutate(units):
        token = _only_token(units[0].text)
        return _replace(units, units[0].text.replace(token, token + token))

    _expect(DuplicatePlaceholder, mutate)


def test_backend_mutates_placeholder():
    def mutate(units):
        token = _only_token(units[0].text)
        return _replace(units, units[0].text.replace(token, "{{MSTDN_P_9999}}"))

    _expect(UnknownPlaceholder, mutate)


def test_backend_adds_unknown_placeholder():
    def mutate(units):
        return _replace(units, units[0].text + "{{MSTDN_P_9999}}")

    _expect(UnknownPlaceholder, mutate)


def test_backend_omits_unit():
    _expect(MissingTranslationUnit, lambda _units: [])


def test_backend_returns_unknown_unit():
    def mutate(units):
        return [*_replace(units, units[0].text), TranslatedUnit(id="u-9999", text="extra")]

    _expect(UnknownTranslationUnit, mutate)


def test_backend_duplicates_unit_id():
    def mutate(units):
        return _replace(units, units[0].text) * 2

    _expect(DuplicateTranslationUnit, mutate)


def test_backend_reorders_placeholders():
    source = "<p>Hello <code>a</code> and <code>b</code> there</p>"
    prepared = prepare(source)
    tokens = PlaceholderCodec.find_tokens(prepared.units[0].text)
    assert tokens == ["{{MSTDN_P_0000}}", "{{MSTDN_P_0001}}"]
    swapped = prepared.units[0].text.replace(tokens[0], "__A__").replace(tokens[1], tokens[0]).replace("__A__", tokens[1])

    def mutate(units):
        return [TranslatedUnit(id=units[0].id, text=swapped)]

    _expect(PlaceholderOrderMismatch, mutate, html=source)


def test_text_inserted_between_adjacent_placeholders_is_rejected():
    source = "<p>Hello <code>a</code><code>b</code> there</p>"
    prepared = prepare(source)
    text = prepared.units[0].text
    assert "{{MSTDN_P_0000}}{{MSTDN_P_0001}}" in text
    inserted = text.replace("{{MSTDN_P_0000}}{{MSTDN_P_0001}}", "{{MSTDN_P_0000}}X{{MSTDN_P_0001}}")

    def mutate(units):
        return [TranslatedUnit(id=units[0].id, text=inserted)]

    _expect(InvalidBackendResponse, mutate, html=source)


def test_non_unit_payload_is_invalid():
    _expect(InvalidBackendResponse, lambda units: [{"id": units[0].id, "text": units[0].text}])


def test_garbled_placeholder_is_missing():
    def mutate(units):
        token = _only_token(units[0].text)
        return _replace(units, units[0].text.replace(token, token[:-2]))

    _expect(MissingPlaceholder, mutate)


def _expect(error_type, mutate, html: str = VALIDATION_BASE_HTML) -> None:
    with pytest.raises(error_type) as caught:
        run(html, backend=ScriptedBackend(lambda units, _source, _target: mutate(units)))
    assert caught.value.code == error_type.code
    assert html not in str(caught.value)
    assert "@alice" not in str(caught.value)


def _only_token(text: str) -> str:
    tokens = PlaceholderCodec.find_tokens(text)
    assert len(tokens) == 1
    return tokens[0]
