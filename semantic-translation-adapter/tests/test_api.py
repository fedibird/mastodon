"""HTTP API for HTML translation."""

from fastapi.testclient import TestClient

from semantic_translation.config import AdapterConfig
from semantic_translation.api.app import create_app
from semantic_translation.core.dom import attribute_diff, fingerprint

API_HTML = '<p>Hello <span translate="no">@alice@example.com</span></p>'


def _client(max_html_bytes: int = 100_000) -> TestClient:
    return TestClient(create_app(AdapterConfig(max_html_bytes=max_html_bytes)))


def test_healthz():
    response = _client().get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_translate_html_identity_contract():
    response = _client().post(
        "/v1/translate/html",
        json={
            "html": API_HTML,
            "source": "en",
            "target": "ja",
            "backend": "identity",
            "policy": "mastodon-v1",
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert set(body) == {
        "translated_html",
        "source",
        "target",
        "backend",
        "policy",
        "segments_total",
        "segments_translated",
        "segments_skipped",
    }
    assert body["source"] == "en"
    assert body["target"] == "ja"
    assert body["backend"] == "identity"
    assert body["policy"] == "mastodon-v1"
    assert body["segments_total"] == 1
    assert body["segments_translated"] == 1
    assert body["segments_skipped"] == 1
    assert fingerprint(API_HTML) == fingerprint(body["translated_html"])
    assert attribute_diff(API_HTML, body["translated_html"]) == []


def test_unknown_backend_and_policy_do_not_echo_html():
    client = _client()
    for payload, code in (
        ({"html": API_HTML, "target": "ja", "backend": "deepl"}, "unknown_backend"),
        ({"html": API_HTML, "target": "ja", "policy": "other"}, "unknown_policy"),
    ):
        response = client.post("/v1/translate/html", json=payload)
        assert response.status_code == 400
        body = response.json()
        assert body["error"]["code"] == code
        assert "@alice@example.com" not in response.text
        assert "<p>" not in response.text


def test_oversized_html_is_rejected_without_echoing_the_body():
    marker = "SECRET_HTML_MARKER"
    response = _client(max_html_bytes=64).post(
        "/v1/translate/html",
        json={"html": f"<p>{marker}{'x' * 80}</p>", "target": "ja"},
    )
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "input_too_large"
    assert marker not in response.text


def test_placeholder_collision_is_fail_closed():
    marker = "SECRET_COLLISION_MARKER"
    response = _client().post(
        "/v1/translate/html",
        json={"html": f"<p>Hello {{{{MSTDN_P_0000}}}} {marker}</p>", "target": "ja"},
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "placeholder_collision"
    assert marker not in response.text
    assert "translated_html" not in response.json()


def test_invalid_request_does_not_echo_submitted_html():
    marker = "SECRET_REQUEST_MARKER"
    response = _client().post("/v1/translate/html", json={"html": f"<p>{marker}</p>"})
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_request"
    assert marker not in response.text


def test_source_may_be_omitted():
    response = _client().post(
        "/v1/translate/html",
        json={"html": "<p>Hello</p>", "target": "ja"},
    )
    assert response.status_code == 200
    assert response.json()["source"] is None
    assert response.json()["segments_total"] == 1
