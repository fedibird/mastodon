"""Protected literals inside text nodes.

Grapheme segmentation and emoji classification are separate steps.
URL spans are found first so an emoji that is part of a URL stays inside
that single literal.
"""

from dataclasses import dataclass
from urllib.parse import unquote

import emoji
import regex

# ASCII alphanumerics and "/" block a scheme start so that "nothttps://..."
# is not a URL. CJK, emoji, and punctuation do not: Mastodon posts glue
# URLs directly onto Japanese text.
_SCHEME_RE = regex.compile(r"https?://", regex.IGNORECASE)
_SCHEME_ONLY_RE = regex.compile(r"https?://\Z", regex.IGNORECASE)
_ABSOLUTE_HTTP_RE = regex.compile(r"https?://\S+", regex.IGNORECASE)

# RFC 3986 characters. The scanner then decides non-ASCII separately so that
# a following Hiragana particle is not swallowed into the URL.
_ASCII_URL_CHARS = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
)
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


def is_absolute_http_url(value: str) -> bool:
    """True when ``value`` is an absolute http(s) URL with no whitespace."""

    return _ABSOLUTE_HTTP_RE.fullmatch(value.strip()) is not None


def same_url_display(href: str, display_text: str) -> bool:
    """True when anchor text is the URL display of ``href``.

    ``display_url`` decodes percent-encoding once, so the visible string may
    differ from the canonical href (``%20`` becomes a space, UTF-8 sequences
    become characters). Comparison ignores surrounding whitespace, zero-width
    characters, scheme/host case, and one trailing slash. Extra natural
    language does not match.
    """

    return bool(_url_display_forms(href) & _url_display_forms(display_text))


def _find_urls(text: str) -> list[LiteralSpan]:
    spans: list[LiteralSpan] = []
    cursor = 0
    while cursor < len(text):
        match = _SCHEME_RE.search(text, cursor)
        if match is None:
            break
        start = match.start()
        if start > 0 and _blocks_scheme(text[start - 1]):
            cursor = start + 1
            continue
        end = match.end()
        while end < len(text) and _is_url_continuation(text[end], text[end - 1]):
            end += 1
        trimmed = _trim_url(text[start:end])
        if not trimmed:
            cursor = match.end()
            continue
        spans.append(LiteralSpan(start, start + len(trimmed), "url", trimmed))
        cursor = start + len(trimmed)
    return spans


def _blocks_scheme(char: str) -> bool:
    return char.isascii() and (char.isalnum() or char == "/")


def _is_url_continuation(char: str, previous: str) -> bool:
    """Whether ``char`` can still belong to the URL body.

    Hiragana immediately after an ASCII letter or digit stops the scan, so
    ``https://example.com/fooを確認`` keeps ``を確認`` as language. Hiragana
    after ``.`` or ``/`` continues, so an IDN label such as ``nic.みんな``
    stays inside the URL. Han, Katakana, Hangul, and other non-ASCII letters
    continue even when glued to an ASCII URL. That over-protects a Kanji word
    and is preferred to sending an IRI path to the backend. East-Asian and
    fullwidth punctuation stop the scan. Percent-encoded bytes stay inside
    the ASCII URL class.
    """

    if char in _ASCII_URL_CHARS:
        return True
    if char.isascii():
        return False
    code = ord(char)
    if 0x3000 <= code <= 0x303F:
        return False
    if 0xFF00 <= code <= 0xFFEF and not _is_fullwidth_alnum(code):
        return False
    if 0x3040 <= code <= 0x309F and previous.isascii() and previous.isalnum():
        return False
    return True


def _is_fullwidth_alnum(code: int) -> bool:
    return (
        0xFF10 <= code <= 0xFF19
        or 0xFF21 <= code <= 0xFF3A
        or 0xFF41 <= code <= 0xFF5A
    )


_IGNORABLE_DISPLAY = dict.fromkeys(map(ord, "\u200b\u200c\u200d\ufeff"))


def _fold_display(value: str) -> str:
    return value.translate(_IGNORABLE_DISPLAY).strip().casefold()


def _url_display_forms(value: str) -> set[str]:
    forms: set[str] = set()
    folded = _fold_display(value)
    decoded = _fold_display(unquote(value))
    for candidate in (folded, decoded):
        if not candidate:
            continue
        forms.add(candidate)
        if candidate.endswith("/") and len(candidate) > len("https://x"):
            forms.add(candidate[:-1])
    return forms


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
