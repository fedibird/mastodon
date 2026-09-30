"""Direct TranslateGemma backend.

The adapter does not load model weights. Each translation unit is one HTTP
request to a local vLLM server that is already serving
``google/translategemma-12b-it``. Placeholder checks stay in A1 validation;
this module does not add a system prompt or a placeholder instruction.

``translate`` sends units sequentially. ``_translate_unit`` is one request,
so a later revision can map it with a bounded pool without changing
``TranslationBackend.translate``.
"""

import os
import re
from dataclasses import dataclass
from urllib.parse import urlparse

import httpx

from semantic_translation.backends.errors import (
    BackendChoicesMissing,
    BackendConnectionFailed,
    BackendContentInvalid,
    BackendContextOverflow,
    BackendFinishReasonInvalid,
    BackendHttpError,
    BackendOutputTruncated,
    BackendInvalidJson,
    BackendMessageMissing,
    BackendNotConfigured,
    BackendTimeout,
    InvalidBackendConfiguration,
    InvalidLanguageTag,
    SourceLanguageRequired,
)
from semantic_translation.core.units import TranslatedUnit, TranslationUnit

OFFICIAL_MODEL_ID = "google/translategemma-12b-it"
# v0.26.0 added structured content for this model. A2 reproduction pins one
# later release rather than a floating "latest".
PINNED_VLLM_VERSION = "0.30.0"
_DEFAULT_TIMEOUT_SECONDS = 120.0
_DEFAULT_MAX_TOKENS = 1024
_ENV_ENDPOINT = "TRANSLATEGEMMA_ENDPOINT"
_ENV_MODEL = "TRANSLATEGEMMA_MODEL"
_ENV_TIMEOUT = "TRANSLATEGEMMA_TIMEOUT"
_ENV_MAX_TOKENS = "TRANSLATEGEMMA_MAX_TOKENS"
_FORK_MODEL_MARKER = "vllm-translategemma"

# TranslateGemma wire contract only. This does not rewrite Fedibird language
# tags. Script subtags such as zh-Hans and zh-Hant are rejected here; A3 may
# map them after a measured probe. Tags are not case-folded.
_LANGUAGE_TAG = re.compile(r"(?:[a-z]{2}|[a-z]{2}[-_][A-Z]{2})\Z")
_CONTEXT_OVERFLOW_MARKERS = (
    "context length",
    "context_length_exceeded",
    "maximum context",
    "max_model_len",
    "too many tokens",
)


@dataclass(frozen=True)
class TranslateGemmaConfig:
    """Administrator settings. Callers cannot supply an endpoint per request."""

    endpoint: str | None
    model: str = OFFICIAL_MODEL_ID
    timeout_seconds: float = _DEFAULT_TIMEOUT_SECONDS
    max_tokens: int = _DEFAULT_MAX_TOKENS

    def __post_init__(self) -> None:
        if _FORK_MODEL_MARKER in self.model.casefold():
            raise InvalidBackendConfiguration()

    @classmethod
    def from_env(cls) -> "TranslateGemmaConfig":
        endpoint = os.environ.get(_ENV_ENDPOINT, "").strip() or None
        model = os.environ.get(_ENV_MODEL, OFFICIAL_MODEL_ID).strip() or OFFICIAL_MODEL_ID
        return cls(
            endpoint=endpoint,
            model=model,
            timeout_seconds=_env_float(_ENV_TIMEOUT, _DEFAULT_TIMEOUT_SECONDS),
            max_tokens=_env_int(_ENV_MAX_TOKENS, _DEFAULT_MAX_TOKENS),
        )


def validated_language_tag(value: str | None, *, source: bool) -> str:
    """Return ``value`` unchanged when it is a tag this backend will send.

    ``source=True`` and ``value is None`` is ``source_language_required``.
    Missing source is not auto-detection.
    """

    if source and value is None:
        raise SourceLanguageRequired()
    if not isinstance(value, str) or _LANGUAGE_TAG.fullmatch(value) is None:
        raise InvalidLanguageTag()
    return value


class TranslateGemmaBackend:
    """HTTP client for one local vLLM OpenAI chat endpoint."""

    id = "translategemma"

    def __init__(
        self,
        config: TranslateGemmaConfig | None = None,
        *,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._config = config if config is not None else TranslateGemmaConfig.from_env()
        self._transport = transport

    def translate(
        self,
        units: list[TranslationUnit],
        source_language: str | None,
        target_language: str,
    ) -> list[TranslatedUnit]:
        if not units:
            return []
        source = validated_language_tag(source_language, source=True)
        target = validated_language_tag(target_language, source=False)
        endpoint = self._endpoint()
        return [self._translate_unit(unit, source, target, endpoint) for unit in units]

    def _translate_unit(
        self,
        unit: TranslationUnit,
        source_language: str,
        target_language: str,
        endpoint: str,
    ) -> TranslatedUnit:
        payload = _request_payload(
            model=self._config.model,
            source_language=source_language,
            target_language=target_language,
            text=unit.text,
            max_tokens=self._config.max_tokens,
        )
        response = self._post(endpoint, payload)
        return TranslatedUnit(id=unit.id, text=_content_from_response(response))

    def _endpoint(self) -> str:
        raw = self._config.endpoint
        if not raw:
            raise BackendNotConfigured()
        return _normalize_endpoint(raw)

    def _post(self, endpoint: str, payload: dict[str, object]) -> httpx.Response:
        url = f"{endpoint}/v1/chat/completions"
        try:
            with httpx.Client(
                transport=self._transport,
                timeout=httpx.Timeout(self._config.timeout_seconds),
                follow_redirects=False,
                trust_env=False,
            ) as client:
                return client.post(url, json=payload, headers=self._headers_hook())
        except httpx.TimeoutException:
            raise BackendTimeout() from None
        except httpx.TransportError:
            raise BackendConnectionFailed() from None

    def _headers_hook(self) -> dict[str, str]:
        """Request headers. An authorization header can be added here later."""

        return _headers()


def _headers() -> dict[str, str]:
    return {"Content-Type": "application/json"}


def _request_payload(
    *,
    model: str,
    source_language: str,
    target_language: str,
    text: str,
    max_tokens: int,
) -> dict[str, object]:
    return {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "source_lang_code": source_language,
                        "target_lang_code": target_language,
                        "text": text,
                    }
                ],
            }
        ],
        "temperature": 0.0,
        "max_tokens": max_tokens,
    }


def _content_from_response(response: httpx.Response) -> str:
    if response.is_redirect or not response.is_success:
        if _is_context_overflow(response):
            raise BackendContextOverflow()
        raise BackendHttpError()
    try:
        payload = response.json()
    except ValueError:
        raise BackendInvalidJson() from None
    return _content_from_payload(payload)


def _content_from_payload(payload: object) -> str:
    if not isinstance(payload, dict):
        raise BackendInvalidJson()
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        raise BackendChoicesMissing()
    choice = choices[0]
    _require_stop(choice)
    message = choice.get("message")
    if not isinstance(message, dict):
        raise BackendMessageMissing()
    content = message.get("content") if "content" in message else None
    if not isinstance(content, str):
        raise BackendContentInvalid()
    return content


def _require_stop(choice: dict[str, object]) -> None:
    """Accept only a completed generation. ``length`` is an incomplete translation."""

    if "finish_reason" not in choice:
        raise BackendFinishReasonInvalid()
    reason = choice.get("finish_reason")
    if reason == "length":
        raise BackendOutputTruncated()
    if reason != "stop":
        raise BackendFinishReasonInvalid()


def _is_context_overflow(response: httpx.Response) -> bool:
    try:
        payload = response.json()
    except ValueError:
        return False
    if not isinstance(payload, dict):
        return False
    error = payload.get("error")
    parts: list[str] = []
    if isinstance(error, dict):
        for key in ("message", "type", "code"):
            value = error.get(key)
            if isinstance(value, str):
                parts.append(value)
    elif isinstance(error, str):
        parts.append(error)
    blob = " ".join(parts).casefold()
    return any(marker in blob for marker in _CONTEXT_OVERFLOW_MARKERS)


def _normalize_endpoint(endpoint: str) -> str:
    parsed = urlparse(endpoint)
    if parsed.scheme not in {"http", "https"} or parsed.hostname is None:
        raise InvalidBackendConfiguration()
    if parsed.username is not None or parsed.password is not None:
        raise InvalidBackendConfiguration()
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise InvalidBackendConfiguration()
    return endpoint.rstrip("/")


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = float(raw)
    except ValueError:
        raise InvalidBackendConfiguration() from None
    if value <= 0:
        raise InvalidBackendConfiguration()
    return value


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = int(raw)
    except ValueError:
        raise InvalidBackendConfiguration() from None
    if value < 1:
        raise InvalidBackendConfiguration()
    return value
