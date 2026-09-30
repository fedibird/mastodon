"""Shared test helpers."""

from semantic_translation.backends.identity import IdentityBackend
from semantic_translation.core.units import TranslatedUnit, TranslationUnit
from semantic_translation.policies.mastodon_v1 import MastodonV1Policy
from semantic_translation.service import TranslationResult, translate_html

POLICY = MastodonV1Policy()
IDENTITY = IdentityBackend()
MAX_BYTES = 100_000


def run(html: str, backend=None, source: str | None = "en", target: str = "ja") -> TranslationResult:
    return translate_html(
        html,
        source_language=source,
        target_language=target,
        backend=backend or IDENTITY,
        policy=POLICY,
        max_html_bytes=MAX_BYTES,
    )


def prepare(html: str):
    return POLICY.prepare(html)


class ScriptedBackend:
    id = "scripted"

    def __init__(self, fn) -> None:
        self._fn = fn

    def translate(
        self,
        units: list[TranslationUnit],
        source_language: str | None,
        target_language: str,
    ) -> list[TranslatedUnit]:
        return self._fn(units, source_language, target_language)
