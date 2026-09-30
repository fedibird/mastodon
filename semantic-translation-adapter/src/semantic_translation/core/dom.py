"""HTML parsing and structural fingerprints.

The parser does not resolve external entities and does not fetch network
resources. No temporary attributes are written onto the tree.
"""

from dataclasses import dataclass

from lxml import etree
from lxml.html import Element, HTMLParser, document_fromstring, fragments_fromstring, tostring

from semantic_translation.core.errors import UnparseableHtml, UnsupportedStructure

MAX_NODE_DEPTH = 256
# libxml2's HTML parser silently drops content past roughly 254 nested
# elements. Reject earlier, from the raw markup, so that loss cannot be
# treated as a successful parse.
MAX_MARKUP_DEPTH = 128
_VOID_TAGS = frozenset(
    {
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "param",
        "source",
        "track",
        "wbr",
    }
)


def make_parser() -> HTMLParser:
    """Return an HTML parser that cannot load external resources."""

    return HTMLParser(
        recover=True,
        huge_tree=False,
        no_network=True,
        remove_blank_text=False,
    )


@dataclass(frozen=True)
class ParsedHtml:
    """A parsed fragment or document.

    Fragment inputs are held under a synthetic ``div`` that is not part of
    the caller's HTML and is omitted when serializing.
    """

    root: etree._Element
    kind: str


def parse_html(html: str) -> ParsedHtml:
    if not isinstance(html, str):
        raise UnparseableHtml()
    parser = make_parser()
    try:
        _reject_deep_markup(html)
        head = html.lstrip()[:64].lower()
        if head.startswith("<!doctype") or head.startswith("<html"):
            root = document_fromstring(html, parser=parser)
            return ParsedHtml(root, "document")
        return ParsedHtml(_parse_fragment(html, parser), "fragment")
    except (UnparseableHtml, UnsupportedStructure):
        raise
    except Exception:
        raise UnparseableHtml() from None


def serialize_html(parsed: ParsedHtml) -> str:
    if parsed.kind == "document":
        return tostring(parsed.root, encoding="unicode", method="html")
    return _serialize_fragment(parsed.root)


def fingerprint(html: str) -> tuple[object, ...]:
    """Structural fingerprint of ``html`` after the same parse used for translation."""

    return _fingerprint_element(parse_html(html).root)


def attribute_diff(left_html: str, right_html: str) -> list[str]:
    """Return attribute mismatches. An empty list means every attribute matches."""

    diffs: list[str] = []
    _diff_attributes(parse_html(left_html).root, parse_html(right_html).root, "root", diffs)
    return diffs


def iter_text_and_attributes(root: etree._Element):
    """Yield text, tails, comment bodies, and attribute values for collision scans."""

    for node in root.iter():
        if isinstance(node.tag, str):
            if node.text:
                yield node.text
            for value in node.attrib.values():
                yield value
        elif node.text:
            yield node.text
        if node.tail:
            yield node.tail


def check_depth(root: etree._Element) -> None:
    try:
        depth = _depth(root)
    except RecursionError:
        raise UnsupportedStructure() from None
    if depth > MAX_NODE_DEPTH:
        raise UnsupportedStructure()


def _parse_fragment(html: str, parser: HTMLParser) -> etree._Element:
    parts = fragments_fromstring(html, parser=parser)
    root = Element("div")
    pending: list[str] = []
    last: etree._Element | None = None
    for part in parts:
        if isinstance(part, str):
            if last is None:
                pending.append(part)
            else:
                last.tail = (last.tail or "") + part
            continue
        if pending:
            root.text = "".join(pending)
            pending.clear()
        root.append(part)
        last = part
    if pending:
        if last is None:
            root.text = "".join(pending)
        else:
            last.tail = (last.tail or "") + "".join(pending)
    return root


def _serialize_fragment(root: etree._Element) -> str:
    parts: list[str] = []
    if root.text:
        parts.append(_escape_text(root.text))
    for child in root:
        parts.append(tostring(child, encoding="unicode", method="html", with_tail=True))
    return "".join(parts)


def _escape_text(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def _fingerprint_element(element: etree._Element) -> tuple[object, ...]:
    if not isinstance(element.tag, str):
        return ("comment", element.text, element.tail)
    attributes = tuple(sorted(element.attrib.items()))
    children = tuple(_fingerprint_element(child) for child in element)
    return ("element", element.tag, attributes, element.text, children, element.tail)


def _diff_attributes(
    left: etree._Element,
    right: etree._Element,
    path: str,
    diffs: list[str],
) -> None:
    left_element = isinstance(left.tag, str)
    right_element = isinstance(right.tag, str)
    if left_element != right_element:
        diffs.append(f"{path}: node kind differs")
        return
    if not left_element:
        if len(left) != len(right):
            diffs.append(f"{path}: child count differs")
        return
    if left.tag != right.tag:
        diffs.append(f"{path}: tag {left.tag} != {right.tag}")
    left_attrs = sorted(left.attrib.items())
    right_attrs = sorted(right.attrib.items())
    if left_attrs != right_attrs:
        diffs.append(f"{path}: attributes {left_attrs!r} != {right_attrs!r}")
    if len(left) != len(right):
        diffs.append(f"{path}: child count differs")
        return
    for index, (left_child, right_child) in enumerate(zip(left, right, strict=True)):
        child_tag = left_child.tag if isinstance(left_child.tag, str) else "comment"
        _diff_attributes(left_child, right_child, f"{path}/{index}:{child_tag}", diffs)


def _reject_deep_markup(html: str) -> None:
    depth = 0
    index = 0
    limit = len(html)
    while index < limit:
        if html[index] != "<":
            index += 1
            continue
        if index + 1 >= limit:
            break
        nxt = html[index + 1]
        if nxt == "!":
            if html.startswith("<!--", index):
                end = html.find("-->", index + 4)
                if end < 0:
                    raise UnsupportedStructure()
                index = end + 3
                continue
            end = _find_tag_end(html, index)
            if end < 0:
                raise UnsupportedStructure()
            index = end + 1
            continue
        if nxt == "?":
            end = html.find("?>", index + 2)
            if end < 0:
                raise UnsupportedStructure()
            index = end + 2
            continue
        if nxt != "/" and not nxt.isalpha():
            index += 1
            continue
        end = _find_tag_end(html, index)
        if end < 0:
            raise UnsupportedStructure()
        name = _tag_name(html, index, end)
        self_closing = end > index and html[end - 1] == "/"
        if name in _VOID_TAGS or self_closing:
            index = end + 1
            continue
        if nxt == "/":
            depth = max(0, depth - 1)
        elif name:
            depth += 1
            if depth > MAX_MARKUP_DEPTH:
                raise UnsupportedStructure()
        index = end + 1


def _tag_name(html: str, start: int, end: int) -> str:
    index = start + 1
    if index < end and html[index] == "/":
        index += 1
    while index < end and html[index].isspace():
        index += 1
    stop = index
    while stop < end and (html[stop].isalnum() or html[stop] in "-:"):
        stop += 1
    return html[index:stop].lower()


def _find_tag_end(html: str, start: int) -> int:
    quote = ""
    index = start + 1
    limit = len(html)
    while index < limit:
        char = html[index]
        if quote:
            if char == quote:
                quote = ""
            index += 1
            continue
        if char in "\"'":
            quote = char
            index += 1
            continue
        if char == ">":
            return index
        index += 1
    return -1


def _depth(element: etree._Element) -> int:
    deepest = 1
    for child in element:
        deepest = max(deepest, 1 + _depth(child))
    return deepest
