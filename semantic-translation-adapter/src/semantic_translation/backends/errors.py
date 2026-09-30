"""Typed failures for remote translation backends.

Messages are static. They never include source text, HTML, response bodies,
or endpoint URLs.
"""

from semantic_translation.core.errors import SemanticTranslationError


class SourceLanguageRequired(SemanticTranslationError):
    code = "source_language_required"

    def __init__(self) -> None:
        super().__init__("TranslateGemma requires an explicit source language.")


class InvalidLanguageTag(SemanticTranslationError):
    code = "invalid_language_tag"

    def __init__(self) -> None:
        super().__init__("Language tag is not a TranslateGemma language code.")


class BackendNotConfigured(SemanticTranslationError):
    code = "backend_not_configured"

    def __init__(self) -> None:
        super().__init__("TranslateGemma endpoint is not configured.")


class InvalidBackendConfiguration(SemanticTranslationError):
    code = "invalid_backend_configuration"

    def __init__(self) -> None:
        super().__init__("TranslateGemma backend configuration is invalid.")


class BackendConnectionFailed(SemanticTranslationError):
    code = "backend_connection_failed"

    def __init__(self) -> None:
        super().__init__("Translation backend connection failed.")


class BackendTimeout(SemanticTranslationError):
    code = "backend_timeout"

    def __init__(self) -> None:
        super().__init__("Translation backend timed out.")


class BackendHttpError(SemanticTranslationError):
    code = "backend_http_error"

    def __init__(self) -> None:
        super().__init__("Translation backend returned a non-success HTTP status.")


class BackendInvalidJson(SemanticTranslationError):
    code = "backend_invalid_json"

    def __init__(self) -> None:
        super().__init__("Translation backend returned invalid JSON.")


class BackendChoicesMissing(SemanticTranslationError):
    code = "backend_choices_missing"

    def __init__(self) -> None:
        super().__init__("Translation backend response has no choices.")


class BackendMessageMissing(SemanticTranslationError):
    code = "backend_message_missing"

    def __init__(self) -> None:
        super().__init__("Translation backend response has no message.")


class BackendContentInvalid(SemanticTranslationError):
    code = "backend_content_invalid"

    def __init__(self) -> None:
        super().__init__("Translation backend response content is not a string.")


class BackendOutputTruncated(SemanticTranslationError):
    code = "backend_output_truncated"

    def __init__(self) -> None:
        super().__init__("Translation backend stopped because the output reached its length limit.")


class BackendFinishReasonInvalid(SemanticTranslationError):
    code = "backend_finish_reason_invalid"

    def __init__(self) -> None:
        super().__init__("Translation backend returned an unexpected finish reason.")


class BackendContextOverflow(SemanticTranslationError):
    code = "backend_context_overflow"

    def __init__(self) -> None:
        super().__init__("Translation backend rejected the unit as too long for its context.")
