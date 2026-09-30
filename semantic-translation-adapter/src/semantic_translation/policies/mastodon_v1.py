"""Mastodon v1 semantic policy.

Block boundaries
----------------
A translation unit is one run of inline content inside a block container.
``<br>`` starts a new unit, including when it appears inside inline markup.
Block containers include the fragment root, ``p``, ``blockquote``, ``li``,
and the other tags in ``_BLOCK_TAGS``. An element that is not itself a
block becomes a container when it contains one, so a ``div`` nested in a
``span`` is segmented rather than flattened.

Protected elements are one placeholder. The walker does not descend into
them, so a ``translate="no"`` subtree stays protected as author intent.
This policy never writes ``translate`` itself.

Unprotected inline elements (``em``, ``strong``, ``a``, ``span``, and the
rest of ``_TRANSPARENT_INLINE``) are transparent. Their text stays in the
parent unit. Structural placeholders separate adjacent text nodes so each
node can be restored. Those placeholders are not tags.

Elements outside the known inline and block sets are protected as a whole
and are not translated. That is fail-closed preservation, not a repair.

``<br>`` inside inline markup is supported. Raw markup nested deeper than
128 elements fails closed: the HTML parser drops content past roughly
254 levels, and that loss must not become a translated document.
"""

from dataclasses import dataclass

from lxml import etree

from semantic_translation.core.document import PreparedDocument, RestorePlan, TextSlot
from semantic_translation.core.dom import (
    check_depth,
    iter_text_and_attributes,
    parse_html,
)
from semantic_translation.core.errors import PlaceholderCollision, UnsupportedStructure
from semantic_translation.core.literals import find_literal_spans, is_absolute_http_url, same_url_display
from semantic_translation.core.placeholders import PlaceholderCodec, ProtectedFragment
from semantic_translation.core.units import TranslationUnit, UnitContract

_PROTECTED_TAGS = frozenset(
    {
        "base",
        "button",
        "canvas",
        "code",
        "embed",
        "head",
        "iframe",
        "input",
        "kbd",
        "link",
        "math",
        "meta",
        "noscript",
        "object",
        "option",
        "pre",
        "rp",
        "rt",
        "ruby",
        "samp",
        "script",
        "select",
        "style",
        "svg",
        "template",
        "textarea",
        "title",
    }
)

_PROTECTED_CLASSES = frozenset(
    {
        "custom-emoji",
        "ellipsis",
        "emojione",
        "h-card",
        "hashtag",
        "invisible",
        "mention",
    }
)

_TRANSPARENT_INLINE = frozenset(
    {
        "a",
        "abbr",
        "b",
        "bdi",
        "bdo",
        "cite",
        "data",
        "del",
        "dfn",
        "em",
        "font",
        "i",
        "ins",
        "label",
        "mark",
        "q",
        "s",
        "small",
        "span",
        "strong",
        "sub",
        "sup",
        "time",
        "u",
        "var",
        "wbr",
    }
)

_BLOCK_TAGS = frozenset(
    {
        "address",
        "article",
        "aside",
        "blockquote",
        "body",
        "caption",
        "center",
        "col",
        "colgroup",
        "dd",
        "details",
        "dialog",
        "div",
        "dl",
        "dt",
        "fieldset",
        "figcaption",
        "figure",
        "footer",
        "form",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "header",
        "hgroup",
        "hr",
        "html",
        "li",
        "main",
        "nav",
        "ol",
        "p",
        "section",
        "summary",
        "table",
        "tbody",
        "td",
        "tfoot",
        "th",
        "thead",
        "tr",
        "ul",
    }
)

_CLASS_REASON_ORDER = (
    "h-card",
    "hashtag",
    "mention",
    "invisible",
    "ellipsis",
    "custom-emoji",
    "emojione",
)


@dataclass
class _Anchor:
    token: str


@dataclass
class _Text:
    slot: TextSlot
    literals: dict[str, str]


_Part = _Anchor | _Text


class MastodonV1Policy:
    id = "mastodon-v1"

    def prepare(self, html: str) -> PreparedDocument:
        parsed = parse_html(html)
        try:
            check_depth(parsed.root)
            for value in iter_text_and_attributes(parsed.root):
                if PlaceholderCodec.collides(value):
                    raise PlaceholderCollision()
            builder = _Builder()
            builder.walk_block(parsed.root, depth=0)
        except RecursionError:
            raise UnsupportedStructure() from None
        fragments = tuple(builder.fragments)
        return PreparedDocument(
            policy_id=self.id,
            units=tuple(builder.units),
            contracts=tuple(builder.contracts),
            plans=tuple(builder.plans),
            protected_fragments=fragments,
            segments_skipped=len(fragments),
            _parsed=parsed,
        )


class _Builder:
    def __init__(self) -> None:
        self.codec = PlaceholderCodec()
        self.fragments: list[ProtectedFragment] = []
        self.units: list[TranslationUnit] = []
        self.contracts: list[UnitContract] = []
        self.plans: list[RestorePlan] = []
        self._unit_index = 0
        self._block_cache: dict[int, bool] = {}
        self.runs: list[list[_Part]] = [[]]

    def walk_block(self, element: etree._Element, depth: int) -> None:
        if depth > 256:
            raise UnsupportedStructure()
        if element.text:
            self._add_text(element, "text", element.text)
        for child in list(element):
            self._consume_child(child, depth)
        self._flush_runs()

    def _consume_child(self, child: etree._Element, depth: int) -> None:
        if not isinstance(child.tag, str):
            self._append_protected_anchor("comment", "comment")
            if child.tail:
                self._add_text(child, "tail", child.tail)
            return
        if child.tag == "br":
            self.runs.append([])
            if child.tail:
                self._add_text(child, "tail", child.tail)
            return
        if _is_atomic(child):
            self._append_protected_anchor("element", _protection_reason(child))
            if child.tail:
                self._add_text(child, "tail", child.tail)
            return
        if self._is_block_container(child):
            self._flush_runs()
            self.walk_block(child, depth + 1)
            if child.tail:
                self._add_text(child, "tail", child.tail)
            return
        subruns = self._walk_inline(child, depth + 1)
        self._merge_runs(self.runs, subruns)
        if child.tail:
            self._add_text(child, "tail", child.tail)

    def _walk_inline(self, element: etree._Element, depth: int) -> list[list[_Part]]:
        if depth > 256:
            raise UnsupportedStructure()
        runs: list[list[_Part]] = [[]]
        if element.text:
            self._add_text_to(runs, element, "text", element.text)
        for child in list(element):
            if not isinstance(child.tag, str):
                self._append_protected_anchor_to(runs, "comment", "comment")
                if child.tail:
                    self._add_text_to(runs, child, "tail", child.tail)
                continue
            if child.tag == "br":
                runs.append([])
                if child.tail:
                    self._add_text_to(runs, child, "tail", child.tail)
                continue
            if _is_atomic(child):
                self._append_protected_anchor_to(runs, "element", _protection_reason(child))
                if child.tail:
                    self._add_text_to(runs, child, "tail", child.tail)
                continue
            if self._is_block_container(child):
                raise UnsupportedStructure()
            subruns = self._walk_inline(child, depth + 1)
            self._merge_runs(runs, subruns)
            if child.tail:
                self._add_text_to(runs, child, "tail", child.tail)
        return runs

    def _add_text(self, element: etree._Element, location: str, text: str) -> None:
        self._add_text_to(self.runs, element, location, text)

    def _add_text_to(
        self,
        runs: list[list[_Part]],
        element: etree._Element,
        location: str,
        text: str,
    ) -> None:
        if text == "":
            return
        masked, literals = self._mask_literals(text)
        if runs[-1] and isinstance(runs[-1][-1], _Text):
            runs[-1].append(_Anchor(self.codec.issue()))
        slot = TextSlot(element=element, location=location, source=masked)
        runs[-1].append(_Text(slot, literals))

    def _append_protected_anchor(self, kind: str, reason: str) -> None:
        self._append_protected_anchor_to(self.runs, kind, reason)

    def _append_protected_anchor_to(self, runs: list[list[_Part]], kind: str, reason: str) -> None:
        placeholder = self.codec.issue_placeholder()
        self.fragments.append(ProtectedFragment(placeholder=placeholder, kind=kind, reason=reason))
        runs[-1].append(_Anchor(placeholder.token))

    def _mask_literals(self, text: str) -> tuple[str, dict[str, str]]:
        spans = find_literal_spans(text)
        if not spans:
            return text, {}
        pieces: list[str] = []
        literals: dict[str, str] = {}
        cursor = 0
        for span in spans:
            pieces.append(text[cursor : span.start])
            placeholder = self.codec.issue_placeholder()
            literals[placeholder.token] = span.original
            self.fragments.append(
                ProtectedFragment(
                    placeholder=placeholder,
                    kind=span.kind,
                    original=span.original,
                    reason=span.kind,
                )
            )
            pieces.append(placeholder.token)
            cursor = span.end
        pieces.append(text[cursor:])
        return "".join(pieces), literals

    def _merge_runs(self, runs: list[list[_Part]], subruns: list[list[_Part]]) -> None:
        if not subruns:
            return
        first, *rest = subruns
        if first:
            if runs[-1] and isinstance(runs[-1][-1], _Text) and isinstance(first[0], _Text):
                runs[-1].append(_Anchor(self.codec.issue()))
            runs[-1].extend(first)
        for extra in rest:
            runs.append(extra)

    def _flush_runs(self) -> None:
        for run in self.runs:
            self._emit(run)
        self.runs = [[]]

    def _emit(self, parts: list[_Part]) -> None:
        if not parts:
            return
        gaps: list[TextSlot | None] = [None]
        anchors: list[str] = []
        literals: dict[str, str] = {}
        for part in parts:
            if isinstance(part, _Anchor):
                anchors.append(part.token)
                gaps.append(None)
            else:
                if gaps[-1] is not None:
                    raise UnsupportedStructure()
                gaps[-1] = part.slot
                literals.update(part.literals)
        if not _has_translatable(gaps):
            return
        text = _render(gaps, anchors)
        unit_id = f"u-{self._unit_index:04d}"
        self._unit_index += 1
        self.units.append(TranslationUnit(unit_id, text))
        self.contracts.append(UnitContract(unit_id, text, tuple(anchors)))
        self.plans.append(
            RestorePlan(
                id=unit_id,
                slots=tuple(gaps),
                anchor_tokens=tuple(anchors),
                literals=literals,
            )
        )

    def _is_block_container(self, element: etree._Element) -> bool:
        key = id(element)
        cached = self._block_cache.get(key)
        if cached is not None:
            return cached
        result = False
        if isinstance(element.tag, str) and not _is_atomic(element):
            if element.tag in _BLOCK_TAGS:
                result = True
            else:
                result = any(
                    isinstance(child.tag, str) and self._is_block_container(child) for child in element
                )
        self._block_cache[key] = result
        return result


def _has_translatable(gaps: list[TextSlot | None]) -> bool:
    for gap in gaps:
        if gap is None:
            continue
        if PlaceholderCodec.strip_tokens(gap.source).strip() != "":
            return True
    return False


def _render(gaps: list[TextSlot | None], anchors: list[str]) -> str:
    pieces: list[str] = []
    for index, gap in enumerate(gaps):
        if gap is not None:
            pieces.append(gap.source)
        if index < len(anchors):
            pieces.append(anchors[index])
    return "".join(pieces)


def _classes(element: etree._Element) -> set[str]:
    return set((element.get("class") or "").split())


def _is_protected(element: etree._Element) -> bool:
    if not isinstance(element.tag, str):
        return False
    if element.tag in _PROTECTED_TAGS:
        return True
    classes = _classes(element)
    if classes & _PROTECTED_CLASSES:
        return True
    if element.tag == "picture" and _is_emoji_picture(element):
        return True
    if (element.get("translate") or "").lower() == "no":
        return True
    if _is_url_anchor(element):
        return True
    return False


def _is_unknown(element: etree._Element) -> bool:
    if not isinstance(element.tag, str):
        return False
    tag = element.tag
    if tag in _PROTECTED_TAGS or tag in _BLOCK_TAGS or tag in _TRANSPARENT_INLINE or tag == "br":
        return False
    return not _is_protected(element)


def _is_atomic(element: etree._Element) -> bool:
    return _is_protected(element) or _is_unknown(element)


def _is_emoji_picture(element: etree._Element) -> bool:
    images = [
        node
        for node in element.iterdescendants()
        if isinstance(node.tag, str) and node.tag == "img"
    ]
    if not images:
        return False
    return all(_classes(image) & _PROTECTED_CLASSES for image in images)


def _protection_reason(element: etree._Element) -> str:
    if not isinstance(element.tag, str):
        return "comment"
    if element.tag in _PROTECTED_TAGS:
        return f"tag:{element.tag}"
    classes = _classes(element)
    for name in _CLASS_REASON_ORDER:
        if name in classes:
            return f"class:{name}"
    if element.tag == "picture" and _is_emoji_picture(element):
        return "emoji-picture"
    if (element.get("translate") or "").lower() == "no":
        return "translate-no"
    if _is_url_anchor(element):
        return "url-anchor"
    return "unknown"


def _is_url_anchor(element: etree._Element) -> bool:
    """True when an anchor's own text is an HTTP(S) URL display.

    Mention and hashtag anchors are classified by class before this runs.
    A human-readable label such as ``the article`` does not match.
    Whitespace-only text nodes are ignored so pretty-printed Formatter HTML
    still matches. Spaces that belong to a decoded ``%20`` are kept.
    ``.invisible`` and ``.ellipsis`` children are included in the
    concatenation; the anchor is one fragment, not one fragment per child.
    """

    if not isinstance(element.tag, str) or element.tag != "a":
        return False
    href = element.get("href") or ""
    if not is_absolute_http_url(href):
        return False
    return same_url_display(href, _anchor_display_text(element))


def _anchor_display_text(element: etree._Element) -> str:
    chunks: list[str] = []

    def add(text: str | None) -> None:
        if text and text.strip():
            chunks.append(text)

    def walk(node: etree._Element) -> None:
        add(node.text)
        for child in node:
            if isinstance(child.tag, str):
                walk(child)
            add(child.tail)

    walk(element)
    return "".join(chunks).strip()
