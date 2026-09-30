"""Protected literals inside text nodes.

Grapheme segmentation and emoji classification are separate steps.
URL spans are found first so an emoji that is part of a URL stays inside
that single literal.
"""

from dataclasses import dataclass

import emoji
import regex

# Absolute http(s) URLs only. Matching is case-insensitive and does not
# consume whitespace or angle brackets. Trailing sentence punctuation is
# trimmed afterwards.
_URL_RE = regex.compile(r"(?i)(?<![\w/])https?://[^\s<>]+")

_TRAILING_PUNCTUATION = frozenset(".,;:!?\"'`，．。、！？")
_CLOSING_TO_OPENING = {
    ")": "(",
    "]": "[",
    "}": "{",
    "）": "（",
    "】": "【",
    "」": "「",
    "』": "『",
}
_SCHEME_ONLY_RE = regex.compile(r"(?i)https?://\Z")


@dataclass(frozen=True)
class LiteralSpan:
    start: int
    end: int
    kind: str
    original: str


def find_literal_spans(text: str) -> list[LiteralSpan]:
    """Return non-overlapping URL and emoji spans in document order."""

    urls = _find_urls(text)
    occupied = [(span.start, span.end) for span in urls]
    emojis = _find_emojis(text, occupied)
    return sorted([*urls, *emojis], key=lambda span: span.start)


def is_emoji_cluster(cluster: str) -> bool:
    """True when one grapheme cluster is a single emoji sequence."""

    return emoji.is_emoji(cluster)


def _find_urls(text: str) -> list[LiteralSpan]:
    spans: list[LiteralSpan] = []
    for match in _URL_RE.finditer(text):
        raw = match.group(0)
        trimmed = _trim_url(raw)
        if not trimmed:
            continue
        start = match.start()
        spans.append(LiteralSpan(start, start + len(trimmed), "url", trimmed))
    return spans


def _trim_url(url: str) -> str:
    while url:
        last = url[-1]
        if last in _TRAILING_PUNCTUATION:
            url = url[:-1]
            continue
        opening = _CLOSING_TO_OPENING.get(last)
        if opening is not None and url.count(opening) < url.count(last):
            url = url[:-1]
            continue
        break
    if not url or _SCHEME_ONLY_RE.fullmatch(url):
        return ""
    return url


def _find_emojis(text: str, occupied: list[tuple[int, int]]) -> list[LiteralSpan]:
    spans: list[LiteralSpan] = []
    for match in regex.finditer(r"\X", text):
        start, end = match.start(), match.end()
        if _overlaps(start, end, occupied):
            continue
        cluster = match.group(0)
        if is_emoji_cluster(cluster):
            spans.append(LiteralSpan(start, end, "emoji", cluster))
    return spans


def _overlaps(start: int, end: int, occupied: list[tuple[int, int]]) -> bool:
    return any(start < occupied_end and end > occupied_start for occupied_start, occupied_end in occupied)
