"""Backend that returns each unit unchanged.

Used to prove prepare → translate → validate → restore is semantically
lossless. It does not inspect HTML.
"""

from semantic_translation.core.units import TranslatedUnit, TranslationUnit


class IdentityBackend:
    id = "identity"

    def translate(
        self,
        units: list[TranslationUnit],
        source_language: str | None,
        target_language: str,
    ) -> list[TranslatedUnit]:
        return [TranslatedUnit(id=unit.id, text=unit.text) for unit in units]
