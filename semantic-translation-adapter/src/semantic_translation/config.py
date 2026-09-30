"""Process configuration.

The HTML size limit is the only A1 setting. It is read from the environment
when the API process starts and can be passed explicitly in tests.
"""

import os
from dataclasses import dataclass

DEFAULT_MAX_HTML_BYTES = 100_000
_ENV_MAX_HTML_BYTES = "SEMANTIC_TRANSLATION_MAX_HTML_BYTES"


@dataclass(frozen=True)
class AdapterConfig:
    max_html_bytes: int = DEFAULT_MAX_HTML_BYTES

    @classmethod
    def from_env(cls) -> "AdapterConfig":
        raw = os.environ.get(_ENV_MAX_HTML_BYTES, str(DEFAULT_MAX_HTML_BYTES))
        try:
            value = int(raw)
        except ValueError as exc:
            raise ValueError(f"{_ENV_MAX_HTML_BYTES} must be an integer") from exc
        if value < 1:
            raise ValueError(f"{_ENV_MAX_HTML_BYTES} must be positive")
        return cls(max_html_bytes=value)
