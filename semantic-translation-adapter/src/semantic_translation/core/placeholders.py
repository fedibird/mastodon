"""Versioned placeholder codec.

Callers depend on ``issue``, ``find_tokens``, ``strip_tokens``, and
``collides``. The token spelling is an implementation detail of codec
version 1 and is not a semantic contract for policies or backends.
"""

from dataclasses import dataclass

import regex


@dataclass(frozen=True)
class Placeholder:
    """One opaque token.

    ``version`` is the codec version that issued it. Callers compare
    ``token`` and do not parse the spelling.
    """

    token: str
    version: int


@dataclass(frozen=True)
class ProtectedFragment:
    """A protected region replaced by one placeholder before translation.

    ``original`` is set for text literals (URLs and emoji sequences) that
    must be written back into a text node. Element and comment protections
    stay in the original DOM, so ``original`` is empty.
    """

    placeholder: Placeholder
    kind: str
    original: str | None = None
    reason: str = ""

    @property
    def token(self) -> str:
        return self.placeholder.token


class PlaceholderCodec:
    """Codec v1.

    Tokens look like ``{{MSTDN_P_0000}}``. Validation compares tokens as
    opaque strings; nothing else may interpret the numeric field.
    """

    version = 1
    _PREFIX = "{{MSTDN_P_"
    _PATTERN = regex.compile(r"\{\{MSTDN_P_\d{4,}\}\}")

    def __init__(self) -> None:
        self._next = 0

    def issue(self) -> str:
        return self.issue_placeholder().token

    def issue_placeholder(self) -> Placeholder:
        token = f"{{{{MSTDN_P_{self._next:04d}}}}}"
        self._next += 1
        return Placeholder(token=token, version=self.version)

    @classmethod
    def find_tokens(cls, text: str) -> list[str]:
        """Return placeholder tokens in left-to-right order."""

        return [match.group(0) for match in cls._PATTERN.finditer(text)]

    @classmethod
    def strip_tokens(cls, text: str) -> str:
        return cls._PATTERN.sub("", text)

    @classmethod
    def collides(cls, text: str) -> bool:
        """True when ``text`` already contains the reserved token prefix.

        A shorter or truncated token would be ambiguous after substitution,
        so any occurrence of the prefix fails closed.
        """

        return cls._PREFIX in text
