"""TranslateGemma HTTP contract. No model weights and no GPU."""

import json

import httpx
import pytest

from semantic_translation.backends.errors import (
    BackendChoicesMissing,
    BackendConnectionFailed,
    BackendContentInvalid,
    BackendContextOverflow,
    BackendHttpError,
    BackendInvalidJson,
    BackendMessageMissing,
    BackendNotConfigured,
    BackendTimeout,
    InvalidBackendConfiguration,
    InvalidLanguageTag,
    SourceLanguageRequired,
)
from semantic_translation.backends.translategemma import (
    OFFICIAL_MODEL_ID,
    TranslateGemmaBackend,
    TranslateGemmaConfig,
    validated_language_tag,
)
from semantic_translation.core.errors import PlaceholderOrderMismatch
from semantic_translation.core.units import TranslatedUnit, TranslationUnit
from semantic_translation.policies.mastodon_v1 import MastodonV1Policy
from semantic_translation.service import translate_html

SECRET = "SECRET_UNIT_TEXT {{MSTDN_P_0000}} do-not-leak"
ENDPOINT = "http://127.0.0.1:8001"


def _config(**overrides) -> TranslateGemmaConfig:
    values = {
        "endpoint": ENDPOINT,
        "model": OFFICIAL_MODEL_ID,
        "timeout_seconds": 5.0,
        "max_tokens": 128,
    }
    values.update(overrides)
    return TranslateGemmaConfig(**values)


def _backend(handler, **overrides) -> tuple[TranslateGemmaBackend, list[httpx.Request]]:
    seen: list[httpx.Request] = []

    def wrapped(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return handler(request)

    backend = TranslateGemmaBackend(_config(**overrides), transport=httpx.MockTransport(wrapped))
    return backend, seen


def _ok(text: str) -> httpx.Response:
    return httpx.Response(
        200,
        json={"choices": [{"message": {"role": "assistant", "content": text}}]},
    )


def _payload(request: httpx.Request) -> dict:
    return json.loads(request.content.decode("utf-8"))


def test_en_ja_request_uses_the_official_template_and_raw_unit_text():
    unit = TranslationUnit("u-0000", "Hello {{MSTDN_P_0000}} world.")
    backend, seen = _backend(lambda _request: _ok("こんにちは {{MSTDN_P_0000}} 世界。"))
    translated = backend.translate([unit], "en", "ja")
    assert translated == [TranslatedUnit("u-0000", "こんにちは {{MSTDN_P_0000}} 世界。")]
    assert len(seen) == 1
    assert seen[0].method == "POST"
    assert seen[0].url.path == "/v1/chat/completions"
    body = _payload(seen[0])
    assert body == {
        "model": OFFICIAL_MODEL_ID,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "source_lang_code": "en",
                        "target_lang_code": "ja",
                        "text": "Hello {{MSTDN_P_0000}} world.",
                    }
                ],
            }
        ],
        "temperature": 0.0,
        "max_tokens": 128,
    }
    assert "system" not in json.dumps(body)
    assert "<p" not in json.dumps(body)
    assert "placeholder" not in json.dumps(body).casefold()


def test_two_units_are_independent_requests_in_order():
    units = [
        TranslationUnit("u-0000", "First {{MSTDN_P_0000}}"),
        TranslationUnit("u-0001", "Second line"),
    ]

    def handler(request: httpx.Request) -> httpx.Response:
        text = _payload(request)["messages"][0]["content"][0]["text"]
        return _ok(text.replace("First", "最初").replace("Second line", "二行目"))

    backend, seen = _backend(handler)
    translated = backend.translate(units, "en", "ja")
    assert [item.id for item in translated] == ["u-0000", "u-0001"]
    assert [item.text for item in translated] == ["最初 {{MSTDN_P_0000}}", "二行目"]
    assert [_payload(request)["messages"][0]["content"][0]["text"] for request in seen] == [
        "First {{MSTDN_P_0000}}",
        "Second line",
    ]


@pytest.mark.parametrize("status", [400, 500])
def test_non_success_status_is_a_typed_error_without_the_source_text(status: int):
    backend, _seen = _backend(lambda _request: httpx.Response(status, content=SECRET.encode()))
    with pytest.raises(BackendHttpError) as caught:
        backend.translate([TranslationUnit("u-0000", SECRET)], "en", "ja")
    assert SECRET not in str(caught.value)
    assert caught.value.__cause__ is None


def test_timeout_and_connection_failure_hide_the_source_text():
    def timeout(_request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout(SECRET)

    backend, _seen = _backend(timeout)
    with pytest.raises(BackendTimeout) as caught:
        backend.translate([TranslationUnit("u-0000", SECRET)], "en", "ja")
    assert SECRET not in str(caught.value)

    def offline(_request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError(SECRET)

    backend, _seen = _backend(offline)
    with pytest.raises(BackendConnectionFailed) as caught:
        backend.translate([TranslationUnit("u-0000", SECRET)], "en", "ja")
    assert SECRET not in str(caught.value)


def test_invalid_json_choices_message_and_content_are_distinct():
    cases = (
        (httpx.Response(200, content=b"not-json {"), BackendInvalidJson),
        (httpx.Response(200, json={"id": "x"}), BackendChoicesMissing),
        (httpx.Response(200, json={"choices": []}), BackendChoicesMissing),
        (httpx.Response(200, json={"choices": [{}]}), BackendMessageMissing),
        (httpx.Response(200, json={"choices": [{"message": {}}]}), BackendContentInvalid),
        (httpx.Response(200, json={"choices": [{"message": {"content": None}}]}), BackendContentInvalid),
        (
            httpx.Response(200, json={"choices": [{"message": {"content": [{"type": "text", "text": SECRET}]}}]}),
            BackendContentInvalid,
        ),
    )
    for response, error in cases:
        backend, _seen = _backend(lambda _request, response=response: response)
        with pytest.raises(error) as caught:
            backend.translate([TranslationUnit("u-0000", SECRET)], "en", "ja")
        assert SECRET not in str(caught.value)
        assert SECRET not in (caught.value.__cause__.__str__() if caught.value.__cause__ else "")


def test_context_overflow_is_classified_without_copying_the_body():
    body = {
        "error": {
            "message": f"This model's maximum context length is 2048 tokens. Input was {SECRET}",
            "type": "BadRequestError",
            "code": "context_length_exceeded",
        }
    }
    backend, _seen = _backend(lambda _request: httpx.Response(400, json=body))
    with pytest.raises(BackendContextOverflow) as caught:
        backend.translate([TranslationUnit("u-0000", SECRET)], "en", "ja")
    assert SECRET not in str(caught.value)


def test_redirects_are_not_followed():
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(302, headers={"location": "http://evil.example/collect"})

    backend, seen = _backend(handler)
    with pytest.raises(BackendHttpError):
        backend.translate([TranslationUnit("u-0000", SECRET)], "en", "ja")
    assert len(seen) == 1
    assert seen[0].url.host == "127.0.0.1"


def test_missing_source_is_rejected_before_any_request():
    backend, seen = _backend(lambda _request: _ok("x"))
    with pytest.raises(SourceLanguageRequired) as caught:
        backend.translate([TranslationUnit("u-0000", SECRET)], None, "ja")
    assert seen == []
    assert SECRET not in str(caught.value)


@pytest.mark.parametrize("tag", ["zh", "zh-TW", "zh-Hans", "zh-Hant", "en", "ja", "ko", "en-US", "en_US"])
def test_language_tags_are_forwarded_without_rewriting(tag: str):
    assert validated_language_tag(tag, source=True) == tag
    backend, seen = _backend(lambda _request: _ok("訳"))
    backend.translate([TranslationUnit("u-0000", "fixed probe")], tag, "ja")
    content = _payload(seen[0])["messages"][0]["content"][0]
    assert content["source_lang_code"] == tag
    assert content["target_lang_code"] == "ja"
    assert content["text"] == "fixed probe"


@pytest.mark.parametrize("tag", ["", "und", "EN", "zh-hans", "zh-Hant-TW", "zh-CN ", "en US"])
def test_language_tags_outside_the_contract_are_rejected(tag: str):
    backend, seen = _backend(lambda _request: _ok("訳"))
    with pytest.raises(InvalidLanguageTag):
        backend.translate([TranslationUnit("u-0000", SECRET)], tag, "ja")
    assert seen == []


def test_unconfigured_endpoint_fails_the_request_and_not_process_startup():
    backend = TranslateGemmaBackend(TranslateGemmaConfig(endpoint=None))
    with pytest.raises(BackendNotConfigured):
        backend.translate([TranslationUnit("u-0000", SECRET)], "en", "ja")


def test_fork_model_ids_and_bad_endpoints_are_rejected():
    with pytest.raises(InvalidBackendConfiguration):
        TranslateGemmaConfig(endpoint=ENDPOINT, model="Infomaniak-AI/vllm-translategemma-12b-it")
    backend = TranslateGemmaBackend(_config(endpoint="http://127.0.0.1:8001/v1/chat/completions"))
    with pytest.raises(InvalidBackendConfiguration):
        backend.translate([TranslationUnit("u-0000", "Hi")], "en", "ja")
    backend = TranslateGemmaBackend(_config(endpoint="file:///tmp/model"))
    with pytest.raises(InvalidBackendConfiguration):
        backend.translate([TranslationUnit("u-0000", "Hi")], "en", "ja")


def test_reordered_placeholders_still_fail_a1_validation(monkeypatch):
    monkeypatch.delenv("TRANSLATEGEMMA_ENDPOINT", raising=False)

    def handler(_request: httpx.Request) -> httpx.Response:
        return _ok("{{MSTDN_P_0001}} world {{MSTDN_P_0000}}")

    backend, _seen = _backend(handler)
    with pytest.raises(PlaceholderOrderMismatch):
        translate_html(
            "<p>Hello <em>world</em>!</p>",
            source_language="en",
            target_language="ja",
            backend=backend,
            policy=MastodonV1Policy(),
            max_html_bytes=100_000,
        )


def test_api_reports_missing_endpoint_without_echoing_html(monkeypatch):
    from fastapi.testclient import TestClient

    from semantic_translation.api.app import create_app

    monkeypatch.delenv("TRANSLATEGEMMA_ENDPOINT", raising=False)
    client = TestClient(create_app())
    assert client.get("/healthz").status_code == 200
    response = client.post(
        "/v1/translate/html",
        json={
            "html": "<p>SECRET_UNIT_TEXT</p>",
            "source": "en",
            "target": "ja",
            "backend": "translategemma",
        },
    )
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "backend_not_configured"
    assert "SECRET_UNIT_TEXT" not in response.text


def test_api_reports_missing_source_without_echoing_html(monkeypatch):
    from fastapi.testclient import TestClient

    from semantic_translation.api.app import create_app

    monkeypatch.setenv("TRANSLATEGEMMA_ENDPOINT", ENDPOINT)
    client = TestClient(create_app())
    response = client.post(
        "/v1/translate/html",
        json={"html": "<p>SECRET_UNIT_TEXT</p>", "source": None, "target": "ja", "backend": "translategemma"},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "source_language_required"
    assert "SECRET_UNIT_TEXT" not in response.text
