"""Translation backend interface.

A backend receives translation units and returns translated units. It does
not receive a DOM, tag names, or attributes.

Two capability levels are expected in later stages. A1 implements neither
of the remote kinds; it only ships ``IdentityBackend``.

DirectTranslationBackend
    Translates each unit's text as an opaque string. DeepL, LibreTranslate,
    and a direct TranslateGemma deployment sit here. The adapter owns every
    structural decision. The backend never sees HTML.

StructuredLLMBackend
    May exchange a JSON list of units and can be instructed that placeholder
    tokens are immutable. It is still HTML-unaware: it does not receive the
    DOM and is not allowed to emit tags. Placeholder validation is identical
    to the direct path. Returning structured JSON does not grant permission
    to rebuild the document.
"""

from typing import Protocol

from semantic_translation.core.units import TranslatedUnit, TranslationUnit


class TranslationBackend(Protocol):
    id: str

    def translate(
        self,
        units: list[TranslationUnit],
        source_language: str | None,
        target_language: str,
    ) -> list[TranslatedUnit]:
        """Return one translated unit for each input unit."""
