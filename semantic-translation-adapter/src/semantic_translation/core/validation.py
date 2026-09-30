"""Fail-closed checks for backend output.

Nothing in this module writes HTML. A failed check raises before restore.
"""

from collections.abc import Sequence

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
from semantic_translation.core.units import TranslatedUnit, UnitContract


def validate_backend_response(
    contracts: Sequence[UnitContract],
    translated: object,
) -> None:
    """Validate a backend response against the contracts for one document.

    Unit checks run before placeholder checks. Placeholder checks, in order,
    are duplicates, unknown tokens, missing tokens, then order. An empty
    source gap that gains text is ``invalid_backend_response`` because there
    is no text node that can receive it.
    """

    items = _coerce_units(translated)
    _validate_unit_ids(contracts, items)
    by_id = {item.id: item for item in items}
    for contract in contracts:
        _validate_unit_text(contract, by_id[contract.id].text)


def _coerce_units(translated: object) -> list[TranslatedUnit]:
    if not isinstance(translated, list):
        raise InvalidBackendResponse()
    items: list[TranslatedUnit] = []
    for item in translated:
        if not isinstance(item, TranslatedUnit):
            raise InvalidBackendResponse()
        if not isinstance(item.id, str) or not isinstance(item.text, str):
            raise InvalidBackendResponse()
        items.append(item)
    return items


def _validate_unit_ids(contracts: Sequence[UnitContract], items: Sequence[TranslatedUnit]) -> None:
    response_ids = [item.id for item in items]
    if len(response_ids) != len(set(response_ids)):
        raise DuplicateTranslationUnit()
    expected_ids = {contract.id for contract in contracts}
    if any(unit_id not in expected_ids for unit_id in response_ids):
        raise UnknownTranslationUnit()
    if any(unit_id not in response_ids for unit_id in expected_ids):
        raise MissingTranslationUnit()


def _validate_unit_text(contract: UnitContract, translated_text: str) -> None:
    expected = PlaceholderCodec.find_tokens(contract.text)
    actual = PlaceholderCodec.find_tokens(translated_text)
    if len(actual) != len(set(actual)):
        raise DuplicatePlaceholder()
    expected_set = set(expected)
    actual_set = set(actual)
    if actual_set - expected_set:
        raise UnknownPlaceholder()
    if expected_set - actual_set:
        raise MissingPlaceholder()
    if actual != expected:
        raise PlaceholderOrderMismatch()
    _validate_gaps(contract, translated_text)


def _validate_gaps(contract: UnitContract, translated_text: str) -> None:
    source_gaps = split_by_anchors(contract.text, contract.anchor_tokens)
    translated_gaps = split_by_anchors(translated_text, contract.anchor_tokens)
    if len(source_gaps) != len(translated_gaps):
        raise InvalidBackendResponse()
    for source_gap, translated_gap in zip(source_gaps, translated_gaps, strict=True):
        if source_gap == "" and translated_gap != "":
            raise InvalidBackendResponse()


def split_by_anchors(text: str, anchors: Sequence[str]) -> list[str]:
    """Split ``text`` on anchor tokens, keeping the gaps between them."""

    gaps: list[str] = []
    rest = text
    for anchor in anchors:
        index = rest.find(anchor)
        if index < 0:
            raise InvalidBackendResponse()
        gaps.append(rest[:index])
        rest = rest[index + len(anchor) :]
    gaps.append(rest)
    return gaps
