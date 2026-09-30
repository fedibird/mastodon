"""Module boundaries stay intact."""

import ast
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "semantic_translation"


def _imports(path: Path) -> list[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    found: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            found.extend(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            found.append(node.module)
    return found


def test_core_does_not_import_fastapi_or_backends():
    for path in (SRC / "core").rglob("*.py"):
        modules = _imports(path)
        assert not any(name == "fastapi" or name.startswith("fastapi.") for name in modules), path
        assert not any("semantic_translation.api" in name for name in modules), path
        assert not any("semantic_translation.backends" in name for name in modules), path
        assert not any("semantic_translation.policies" in name for name in modules), path


def test_backends_do_not_import_html_or_lxml():
    for path in (SRC / "backends").rglob("*.py"):
        modules = _imports(path)
        assert not any("lxml" in name for name in modules), path
        assert not any(name.endswith(".dom") or name.endswith(".document") for name in modules), path
        assert not any("fastapi" in name for name in modules), path
        assert not any(name in {"torch", "transformers"} or name.startswith(("torch.", "transformers.")) for name in modules), path
        joined = path.read_text(encoding="utf-8")
        assert "ProtectedFragment" not in joined, path
        assert "RestorePlan" not in joined, path


def test_package_does_not_log_request_content():
    for path in SRC.rglob("*.py"):
        modules = _imports(path)
        assert not any(name == "logging" or name.startswith("logging.") for name in modules), path


def test_importing_the_backend_does_not_load_lxml_or_fastapi():
    code = """
import semantic_translation.backends.identity
import semantic_translation.core.units
import sys
assert "lxml" not in sys.modules
assert "fastapi" not in sys.modules
assert "httpx" not in sys.modules
"""
    env = os.environ.copy()
    env["PYTHONPATH"] = str(ROOT / "src")
    completed = subprocess.run(
        [sys.executable, "-c", code],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    assert completed.returncode == 0, completed.stderr
