#!/usr/bin/env python3
"""Evaluate a running TranslateGemma vLLM server on fixed cases.

The script does not download weights and does not invent translations when
the server cannot be reached. Output is JSONL of fixed test sentences only.
"""

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from semantic_translation.backends.errors import BackendConnectionFailed, BackendNotConfigured
from semantic_translation.backends.translategemma import (
    OFFICIAL_MODEL_ID,
    PINNED_VLLM_VERSION,
    TranslateGemmaBackend,
    TranslateGemmaConfig,
)
from semantic_translation.evaluation.cases import EVAL_CASES
from semantic_translation.evaluation.report import execute_case, summarize
from semantic_translation.policies.mastodon_v1 import MastodonV1Policy


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="JSONL path, or - for stdout")
    parser.add_argument("--summary", help="Summary JSON path. Defaults to <output>.summary.json")
    parser.add_argument("--gpu", default="not recorded")
    parser.add_argument("--cuda", default="not recorded")
    parser.add_argument("--dtype", default="not recorded")
    parser.add_argument("--extra-args", default="not recorded")
    args = parser.parse_args(argv)

    config = TranslateGemmaConfig.from_env()
    backend = TranslateGemmaBackend(config)
    policy = MastodonV1Policy()
    observed = _probe_version(config.endpoint) if config.endpoint else None
    records = []
    infrastructure_error = None
    for index, case in enumerate(EVAL_CASES):
        record = execute_case(case, backend=backend, policy=policy)
        if index == 0 and record["error_code"] in {BackendConnectionFailed.code, BackendNotConfigured.code}:
            infrastructure_error = record["error_code"]
            break
        records.append(record)

    summary = summarize(records)
    summary_document = {
        **summary,
        "executed": infrastructure_error is None,
        "infrastructure_error": infrastructure_error,
        "model": config.model or OFFICIAL_MODEL_ID,
        "vllm_version_pinned": PINNED_VLLM_VERSION,
        "vllm_version_observed": observed,
        "gpu": args.gpu,
        "cuda": args.cuda,
        "dtype": args.dtype,
        "extra_args": args.extra_args,
        "max_model_len_expected": 2048,
        "case_count_planned": len(EVAL_CASES),
        "case_count_recorded": len(records),
    }
    _write_outputs(args.output, args.summary, records, summary_document)
    if infrastructure_error is not None:
        print(
            f"evaluation not executed: {infrastructure_error}",
            file=sys.stderr,
        )
        return 2
    return 0


def _probe_version(endpoint: str | None) -> str | None:
    if not endpoint:
        return None
    import httpx

    url = endpoint.rstrip("/") + "/version"
    try:
        response = httpx.get(url, timeout=5.0, follow_redirects=False, trust_env=False)
    except httpx.HTTPError:
        return None
    if response.status_code != 200:
        return None
    try:
        payload = response.json()
    except ValueError:
        return None
    if isinstance(payload, dict) and isinstance(payload.get("version"), str):
        return payload["version"]
    return None


def _write_outputs(output: str, summary_path: str | None, records: list[dict], summary: dict) -> None:
    lines = [json.dumps(record, ensure_ascii=False) for record in records]
    body = ("\n".join(lines) + ("\n" if lines else ""))
    summary_text = json.dumps(summary, ensure_ascii=False, indent=2) + "\n"
    if output == "-":
        sys.stdout.write(body)
        if summary_path:
            Path(summary_path).write_text(summary_text, encoding="utf-8")
        else:
            print(summary_text, file=sys.stderr)
        return
    destination = Path(output)
    destination.write_text(body, encoding="utf-8")
    summary_destination = Path(summary_path) if summary_path else destination.with_suffix(destination.suffix + ".summary.json")
    summary_destination.write_text(summary_text, encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
