"""Backend-facing translation units.

These types carry natural-language text and placeholder tokens. They do
not reference the DOM, HTML tags, or attributes.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class TranslationUnit:
    """One block of text a backend is allowed to translate.

    ``text`` may contain placeholder tokens. It is not HTML.
    """

    id: str
    text: str


@dataclass(frozen=True)
class TranslatedUnit:
    """A backend's replacement for one ``TranslationUnit``."""

    id: str
    text: str


@dataclass(frozen=True)
class UnitContract:
    """What validation expects back for one unit.

    ``anchor_tokens`` are the placeholders that separate text slots
    (protected elements, comments, and inline boundaries). Literal
    placeholders live inside the gap text and are not anchors.
    """

    id: str
    text: str
    anchor_tokens: tuple[str, ...]
