"""Fixed evaluation cases and the retention summary. No model calls."""

import json
import os
import subprocess
import sys
from pathlib import Path

from semantic_translation.backends.errors import BackendHttpError, BackendOutputTruncated
from semantic_translation.core.placeholders import PlaceholderCodec
from semantic_translation.evaluation.cases import EVAL_CASES, REQUIRED_GROUPS
from semantic_translation.evaluation.report import execute_case, summarize
from semantic_translation.policies.mastodon_v1 import MastodonV1Policy


def test_required_evaluation_groups_are_present_once():
    present = {group for case in EVAL_CASES for group in case.groups}
    assert REQUIRED_GROUPS <= present
    names = [case.name for case in EVAL_CASES]
    assert len(names) == len(set(names))


def test_chinese_probes_use_one_sentence_and_official_region_tags():
    probes = {
        case.source: case
        for case in EVAL_CASES
        if any(group.startswith("script:") for group in case.groups)
    }
    assert set(probes) == {"zh", "zh-CN", "zh-TW"}
    assert {case.html for case in probes.values()} == {"<p>今天天气很好。</p>"}
    assert all(case.target == "ja" for case in probes.values())
    assert not any(case.source in {"zh-Hans", "zh-Hant"} for case in EVAL_CASES)


def test_placeholder_cases_match_mastodon_v1_units():
    policy = MastodonV1Policy()
    for case in EVAL_CASES:
        prepared = policy.prepare(case.html)
        tokens: list[str] = []
        for unit in prepared.units:
            tokens.extend(PlaceholderCodec.find_tokens(unit.text))
            assert "href=" not in unit.text
            assert "<span" not in unit.text
        assert len(tokens) == case.expected_placeholders, case.name
        if "placeholders:adjacent" in case.groups:
            assert any("}}{{" in unit.text for unit in prepared.units)
        if "placeholders:url" in case.groups:
            assert all("example.com" not in unit.text for unit in prepared.units)
        if "placeholders:inline" in case.groups:
            assert any("world" in unit.text for unit in prepared.units)


def test_harness_writes_no_translations_when_the_endpoint_is_missing(tmp_path, monkeypatch):
    monkeypatch.delenv("TRANSLATEGEMMA_ENDPOINT", raising=False)
    output = tmp_path / "eval.jsonl"
    summary_path = tmp_path / "summary.json"
    script = Path(__file__).resolve().parents[1] / "scripts" / "evaluate_translategemma.py"
    env = os.environ.copy()
    env.pop("TRANSLATEGEMMA_ENDPOINT", None)
    completed = subprocess.run(
        [sys.executable, str(script), "--output", str(output), "--summary", str(summary_path)],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    assert completed.returncode == 2, completed.stderr
    assert output.read_text(encoding="utf-8") == ""
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    assert summary["executed"] is False
    assert summary["infrastructure_error"] == "backend_not_configured"
    assert summary["valid"] == 0
    assert summary["vllm_version_pinned"] == "0.30.0"
    assert summary["model"] == "google/translategemma-12b-it"
    assert "SECRET" not in summary_path.read_text(encoding="utf-8")


def test_truncated_output_is_an_accepted_http_response_and_an_other_failure():
    case = next(item for item in EVAL_CASES if item.name == "zh_cn_ja_probe")

    class Truncated:
        id = "translategemma"

        def translate(self, units, source_language, target_language):
            raise BackendOutputTruncated()

    class Rejected:
        id = "translategemma"

        def translate(self, units, source_language, target_language):
            raise BackendHttpError()

    truncated = execute_case(case, backend=Truncated(), policy=MastodonV1Policy())
    rejected = execute_case(case, backend=Rejected(), policy=MastodonV1Policy())
    assert truncated["http_accepted"] is True
    assert truncated["validation_passed"] is False
    assert truncated["error_code"] == "backend_output_truncated"
    assert truncated["translated_text"] is None
    assert rejected["http_accepted"] is False
    assert rejected["error_code"] == "backend_http_error"
    assert summarize([truncated, rejected])["other_backend_failure"] == 2
    assert "今天天气很好" not in str(truncated["error_code"])


def test_summary_counts_validation_codes_and_other_failures():
    records = [
        {"validation_passed": True, "error_code": None},
        {"validation_passed": True, "error_code": None},
        {"validation_passed": False, "error_code": "missing_placeholder"},
        {"validation_passed": False, "error_code": "unknown_placeholder"},
        {"validation_passed": False, "error_code": "duplicate_placeholder"},
        {"validation_passed": False, "error_code": "placeholder_order_mismatch"},
        {"validation_passed": False, "error_code": "backend_timeout"},
        {"validation_passed": False, "error_code": "backend_context_overflow"},
        {"validation_passed": False, "error_code": "backend_output_truncated"},
    ]
    assert summarize(records) == {
        "total": 9,
        "valid": 2,
        "missing_placeholder": 1,
        "unknown_placeholder": 1,
        "duplicate_placeholder": 1,
        "placeholder_order_mismatch": 1,
        "other_backend_failure": 3,
    }
