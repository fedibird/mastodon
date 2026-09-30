"""Translation policy interface.

A policy reads HTML and decides which natural-language runs are translation
units. It keeps the DOM. Backends do not implement policies.
"""

from typing import Protocol

from semantic_translation.core.document import PreparedDocument


class TranslationPolicy(Protocol):
    id: str

    def prepare(self, html: str) -> PreparedDocument:
        """Parse ``html`` and build units. Do not translate."""
