"""Application service for one HTML translation request.

This module wires a policy to a backend. It does not import FastAPI, and it
does not log HTML.
"""

from dataclasses import dataclass

from semantic_translation.backends.base import TranslationBackend
from semantic_translation.core.errors import InputTooLarge, UnparseableHtml
from semantic_translation.core.validation import validate_backend_response
from semantic_translation.policies.base import TranslationPolicy


@dataclass(frozen=True)
class TranslationResult:
    translated_html: str
    source_language: str | None
    target_language: str
    backend_id: str
    policy_id: str
    segments_total: int
    segments_translated: int
    segments_skipped: int


def translate_html(
    html: str,
    *,
    source_language: str | None,
    target_language: str,
    backend: TranslationBackend,
    policy: TranslationPolicy,
    max_html_bytes: int,
) -> TranslationResult:
    """Translate HTML. Validation failure raises and returns no document."""

    _check_size(html, max_html_bytes)
    prepared = policy.prepare(html)
    translated = backend.translate(list(prepared.units), source_language, target_language)
    validate_backend_response(prepared.contracts, translated)
    translated_html = prepared.restore(translated)
    return TranslationResult(
        translated_html=translated_html,
        source_language=source_language,
        target_language=target_language,
        backend_id=backend.id,
        policy_id=prepared.policy_id,
        segments_total=len(prepared.units),
        segments_translated=len(prepared.units),
        segments_skipped=prepared.segments_skipped,
    )


def _check_size(html: str, max_html_bytes: int) -> None:
    if not isinstance(html, str):
        raise UnparseableHtml()
    try:
        size = len(html.encode("utf-8"))
    except UnicodeError:
        raise UnparseableHtml() from None
    if size > max_html_bytes:
        raise InputTooLarge()
