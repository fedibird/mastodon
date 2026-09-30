"""Prepared document and restore.

The original DOM stays here. Backends never receive it. Restore writes
translated natural language back into existing text nodes and expands
literal placeholders. It does not create elements or change attributes.
"""

from dataclasses import dataclass, field

from lxml import etree

from semantic_translation.core.dom import ParsedHtml, serialize_html
from semantic_translation.core.errors import InvalidBackendResponse
from semantic_translation.core.placeholders import PlaceholderCodec, ProtectedFragment
from semantic_translation.core.units import TranslatedUnit, TranslationUnit, UnitContract
from semantic_translation.core.validation import split_by_anchors


@dataclass
class TextSlot:
    """One existing text node or tail that a unit may rewrite.

    ``location`` is ``text`` or ``tail``.
    """

    element: etree._Element
    location: str
    source: str


@dataclass
class RestorePlan:
    id: str
    slots: tuple[TextSlot | None, ...]
    anchor_tokens: tuple[str, ...]
    literals: dict[str, str]


@dataclass
class PreparedDocument:
    """A policy's view of one HTML input, ready for a backend."""

    policy_id: str
    units: tuple[TranslationUnit, ...]
    contracts: tuple[UnitContract, ...]
    plans: tuple[RestorePlan, ...]
    protected_fragments: tuple[ProtectedFragment, ...]
    segments_skipped: int
    _parsed: ParsedHtml = field(repr=False)

    def restore(self, translated: list[TranslatedUnit]) -> str:
        """Write validated translations back and serialize.

        Caller must validate first. This method still refuses to emit HTML
        when a placeholder would leak into a text node.
        """

        by_id = {item.id: item.text for item in translated}
        writes: list[tuple[etree._Element, str, str]] = []
        for plan in self.plans:
            if plan.id not in by_id:
                raise InvalidBackendResponse()
            writes.extend(_plan_writes(plan, by_id[plan.id]))
        for element, location, value in writes:
            if location == "text":
                element.text = value
            elif location == "tail":
                element.tail = value
            else:
                raise InvalidBackendResponse()
        return serialize_html(self._parsed)


def _plan_writes(plan: RestorePlan, translated_text: str) -> list[tuple[etree._Element, str, str]]:
    gaps = split_by_anchors(translated_text, plan.anchor_tokens)
    if len(gaps) != len(plan.slots):
        raise InvalidBackendResponse()
    writes: list[tuple[etree._Element, str, str]] = []
    for slot, gap in zip(plan.slots, gaps, strict=True):
        if slot is None:
            if gap != "":
                raise InvalidBackendResponse()
            continue
        expanded = _expand_literals(gap, plan.literals)
        if PlaceholderCodec.collides(expanded):
            raise InvalidBackendResponse()
        writes.append((slot.element, slot.location, expanded))
    return writes


def _expand_literals(text: str, literals: dict[str, str]) -> str:
    for token in sorted(literals, key=len, reverse=True):
        text = text.replace(token, literals[token])
    return text
