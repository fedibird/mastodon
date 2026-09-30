"""Typed failures for the semantic translation adapter.

Messages are static. They never include source HTML, unit text, or other
user content.
"""


class SemanticTranslationError(Exception):
    """Base error. ``code`` is the stable API identifier."""

    code = "semantic_translation_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class InputTooLarge(SemanticTranslationError):
    code = "input_too_large"

    def __init__(self) -> None:
        super().__init__("HTML input exceeds the configured size limit.")


class UnknownBackend(SemanticTranslationError):
    code = "unknown_backend"

    def __init__(self) -> None:
        super().__init__("Unknown translation backend.")


class UnknownPolicy(SemanticTranslationError):
    code = "unknown_policy"

    def __init__(self) -> None:
        super().__init__("Unknown translation policy.")


class UnparseableHtml(SemanticTranslationError):
    code = "unparseable_html"

    def __init__(self) -> None:
        super().__init__("HTML input could not be parsed safely.")


class PlaceholderCollision(SemanticTranslationError):
    code = "placeholder_collision"

    def __init__(self) -> None:
        super().__init__(
            "Document contains a reserved placeholder pattern and cannot be translated safely."
        )


class UnsupportedStructure(SemanticTranslationError):
    code = "unsupported_structure"

    def __init__(self) -> None:
        super().__init__("Document structure cannot be translated safely.")


class InvalidBackendResponse(SemanticTranslationError):
    code = "invalid_backend_response"

    def __init__(self) -> None:
        super().__init__("Backend response failed validation.")


class MissingTranslationUnit(SemanticTranslationError):
    code = "missing_translation_unit"

    def __init__(self) -> None:
        super().__init__("Backend response is missing a translation unit.")


class UnknownTranslationUnit(SemanticTranslationError):
    code = "unknown_translation_unit"

    def __init__(self) -> None:
        super().__init__("Backend response contains an unknown translation unit.")


class DuplicateTranslationUnit(SemanticTranslationError):
    code = "duplicate_translation_unit"

    def __init__(self) -> None:
        super().__init__("Backend response repeats a translation unit.")


class MissingPlaceholder(SemanticTranslationError):
    code = "missing_placeholder"

    def __init__(self) -> None:
        super().__init__("Backend response is missing a required placeholder.")


class UnknownPlaceholder(SemanticTranslationError):
    code = "unknown_placeholder"

    def __init__(self) -> None:
        super().__init__("Backend response contains an unknown placeholder.")


class DuplicatePlaceholder(SemanticTranslationError):
    code = "duplicate_placeholder"

    def __init__(self) -> None:
        super().__init__("Backend response repeats a placeholder.")


class PlaceholderOrderMismatch(SemanticTranslationError):
    code = "placeholder_order_mismatch"

    def __init__(self) -> None:
        super().__init__("Backend response reordered placeholders.")
