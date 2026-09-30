"""Frozen Fedibird ``Formatter#link_html`` output.

The strings below are the regression contract for mastodon-v1. They mirror
``Formatter#link_html`` and ``Formatter#display_url`` in ``app/lib/formatter.rb``
as of fedibird ``ec92ff3a922a9bde27e329dd5e638db7ae30c1a6``. Python tests do
not call Rails.

``link_html`` (after ``display_url``, which percent-decodes once):

- prefix matches ``\\A(https?://(www\\.)?|xmpp:)``
- the next 30 characters are the middle span
- the remainder is the suffix span (empty when the URL is short; Ruby's
  range is nil and the interpolated span is empty)
- the middle class is ``ellipsis`` when the remainder after the prefix is
  longer than 30 characters, otherwise the class attribute is empty

``link_to_url`` wraps that inner HTML in an anchor. The href is the
normalized canonical URL. Stored status HTML carries
``rel="nofollow noopener noreferrer"`` and ``target="_blank"``
(``spec/lib/sanitize_config_spec.rb``).

If Fedibird changes ``link_html``, these literals go stale on purpose.
"""

import re
from urllib.parse import unquote

SHORT_HREF = "https://example.com/foo"
SHORT_INNER = (
    '<span class="invisible">https://</span>'
    '<span class="">example.com/foo</span>'
    '<span class="invisible"></span>'
)

WWW_HREF = "https://www.example.com/foo"
WWW_INNER = (
    '<span class="invisible">https://www.</span>'
    '<span class="">example.com/foo</span>'
    '<span class="invisible"></span>'
)

LONG_HREF = "https://example.com/very/long/path/to/resource-name"
LONG_INNER = (
    '<span class="invisible">https://</span>'
    '<span class="ellipsis">example.com/very/long/path/to/</span>'
    '<span class="invisible">resource-name</span>'
)

PERCENT_HREF = "https://example.com/foo%20bar"
PERCENT_INNER = (
    '<span class="invisible">https://</span>'
    '<span class="">example.com/foo bar</span>'
    '<span class="invisible"></span>'
)

DOUBLE_ENCODED_HREF = "https://example.com/a%2520b"
DOUBLE_ENCODED_INNER = (
    '<span class="invisible">https://</span>'
    '<span class="">example.com/a%20b</span>'
    '<span class="invisible"></span>'
)

IDN_HREF = "https://example.com/%E6%9D%B1%E4%BA%AC/page"
IDN_INNER = (
    '<span class="invisible">https://</span>'
    '<span class="">example.com/東京/page</span>'
    '<span class="invisible"></span>'
)

# The shape called out for a short URL, including indentation. Whitespace-only
# text nodes must not break url-anchor detection.
PRETTY_SHORT_ANCHOR = (
    '<a href="https://example.com/foo">\n'
    '  <span class="invisible">https://</span>\n'
    '  <span class="">example.com/foo</span>\n'
    '  <span class="invisible"></span>\n'
    "</a>"
)


def status_anchor(href: str, inner: str) -> str:
    """Anchor wrapper stored for an autolinked status URL."""

    return (
        f'<a href="{href}" rel="nofollow noopener noreferrer" '
        f'target="_blank">{inner}</a>'
    )


def link_html(display_url: str) -> str:
    """Pure mirror of ``Formatter#link_html`` for snapshot locking.

    ``encode`` is identity for the snapshots in this module: their display
    text has no HTML-special characters.
    """

    match = re.match(r"(https?://(?:www\.)?|xmpp:)", display_url)
    prefix = match.group(0) if match else ""
    rest = display_url[len(prefix) :]
    text = rest[:30]
    suffix = rest[30:]
    css = "ellipsis" if len(rest) > 30 else ""
    return (
        f'<span class="invisible">{prefix}</span>'
        f'<span class="{css}">{text}</span>'
        f'<span class="invisible">{suffix}</span>'
    )


def display_url(url: str) -> str:
    """Percent-decode once, matching ``Formatter#display_url`` for valid UTF-8."""

    return unquote(url)


SNAPSHOTS: tuple[tuple[str, str, str], ...] = (
    ("short", SHORT_HREF, SHORT_INNER),
    ("www", WWW_HREF, WWW_INNER),
    ("long", LONG_HREF, LONG_INNER),
    ("percent20", PERCENT_HREF, PERCENT_INNER),
    ("double_encoded", DOUBLE_ENCODED_HREF, DOUBLE_ENCODED_INNER),
    ("idn", IDN_HREF, IDN_INNER),
)
