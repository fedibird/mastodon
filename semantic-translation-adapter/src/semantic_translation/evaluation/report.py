"""Run fixed cases through policy, TranslateGemma, and A1 validation."""

import time
from typing import Any

from semantic_translation.backends.base import TranslationBackend
from semantic_translation.core.errors import SemanticTranslationError
from semantic_translation.core.placeholders import PlaceholderCodec
from semantic_translation.core.units import TranslatedUnit, TranslationUnit
from semantic_translation.core.validation import validate_backend_response
from semantic_translation.evaluation.cases import EvalCase
from semantic_translation.policies.base import TranslationPolicy

SUMMARY_KEYS = (
    "total",
    "valid",
    "missing_placeholder",
    "unknown_placeholder",
    "duplicate_placeholder",
    "placeholder_order_mismatch",
    "other_backend_failure",
)
_COUNTED_ERRORS = frozenset(
    {
        "missing_placeholder",
        "unknown_placeholder",
        "duplicate_placeholder",
        "placeholder_order_mismatch",
    }
)
# These failures mean the server did not accept the generation. Truncation
# and finish-reason rejection happen after HTTP 200, so they stay accepted
# at the HTTP layer and still count as other_backend_failure.
_HTTP_NOT_ACCEPTED = frozenset(
    {
        "backend_connection_failed",
        "backend_timeout",
        "backend_http_error",
        "backend_context_overflow",
        "backend_not_configured",
        "invalid_language_tag",
        "source_language_required",
        "invalid_backend_configuration",
    }
)


def execute_case(case: EvalCase, *, backend: TranslationBackend, policy: TranslationPolicy) -> dict[str, Any]:
    """Translate one fixed case. Failures are recorded; they are not retried."""

    prepared = policy.prepare(case.html)
    source_text = "\n".join(unit.text for unit in prepared.units)
    started = time.perf_counter()
    try:
        translated = backend.translate(list(prepared.units), case.source, case.target)
    except SemanticTranslationError as exc:
        latency = time.perf_counter() - started
        return _record(
            case,
            source_text=source_text,
            translated_text=None,
            validation_passed=False,
            error_code=exc.code,
            exact=None,
            order=None,
            latency=latency,
            http_accepted=exc.code not in _HTTP_NOT_ACCEPTED,
        )
    latency = time.perf_counter() - started
    translated_text = "\n".join(unit.text for unit in translated)
    exact, order = _placeholder_flags(prepared.units, translated)
    try:
        validate_backend_response(prepared.contracts, translated)
        prepared.restore(translated)
    except SemanticTranslationError as exc:
        return _record(
            case,
            source_text=source_text,
            translated_text=translated_text,
            validation_passed=False,
            error_code=exc.code,
            exact=exact,
            order=order,
            latency=latency,
            http_accepted=True,
        )
    return _record(
        case,
        source_text=source_text,
        translated_text=translated_text,
        validation_passed=True,
        error_code=None,
        exact=exact,
        order=order,
        latency=latency,
        http_accepted=True,
    )


def summarize(records: list[dict[str, Any]]) -> dict[str, int]:
    """Count A1 validation outcomes. Other failures stay in one bucket."""

    summary = {key: 0 for key in SUMMARY_KEYS}
    summary["total"] = len(records)
    for record in records:
        if record.get("validation_passed") is True:
            summary["valid"] += 1
            continue
        code = record.get("error_code")
        if code in _COUNTED_ERRORS:
            summary[code] += 1
        else:
            summary["other_backend_failure"] += 1
    return summary


def _record(
    case: EvalCase,
    *,
    source_text: str,
    translated_text: str | None,
    validation_passed: bool,
    error_code: str | None,
    exact: bool | None,
    order: bool | None,
    latency: float,
    http_accepted: bool,
) -> dict[str, Any]:
    return {
        "case": case.name,
        "groups": list(case.groups),
        "source": case.source,
        "target": case.target,
        "source_text": source_text,
        "translated_text": translated_text,
        "http_accepted": http_accepted,
        "validation_passed": validation_passed,
        "error_code": error_code,
        "placeholder_exact_preservation": exact,
        "placeholder_order_preservation": order,
        "latency_seconds": latency,
    }


def _placeholder_flags(
    units: tuple[TranslationUnit, ...] | list[TranslationUnit],
    translated: list[TranslatedUnit],
) -> tuple[bool, bool]:
    by_id = {item.id: item.text for item in translated}
    exact = len(translated) == len(units)
    order = exact
    for unit in units:
        if unit.id not in by_id:
            return False, False
        source_tokens = PlaceholderCodec.find_tokens(unit.text)
        translated_tokens = PlaceholderCodec.find_tokens(by_id[unit.id])
        if source_tokens != translated_tokens:
            order = False
        if sorted(source_tokens) != sorted(translated_tokens):
            exact = False
    return exact, order
