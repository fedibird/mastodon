"""ASGI application for the semantic translation adapter.

Request bodies are not logged. Error payloads contain an error code and a
static message, never the submitted HTML.
"""

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from semantic_translation.config import AdapterConfig
from semantic_translation.core.errors import (
    DuplicatePlaceholder,
    DuplicateTranslationUnit,
    InputTooLarge,
    InvalidBackendResponse,
    MissingPlaceholder,
    MissingTranslationUnit,
    PlaceholderCollision,
    PlaceholderOrderMismatch,
    SemanticTranslationError,
    UnknownBackend,
    UnknownPlaceholder,
    UnknownPolicy,
    UnknownTranslationUnit,
    UnparseableHtml,
    UnsupportedStructure,
)
from semantic_translation.registry import get_backend, get_policy
from semantic_translation.service import translate_html
from semantic_translation.api.schemas import ErrorBody, ErrorResponse, TranslateHtmlRequest, TranslateHtmlResponse

_STATUS = {
    InputTooLarge.code: 413,
    UnknownBackend.code: 400,
    UnknownPolicy.code: 400,
    UnparseableHtml.code: 422,
    PlaceholderCollision.code: 422,
    UnsupportedStructure.code: 422,
    InvalidBackendResponse.code: 422,
    MissingTranslationUnit.code: 422,
    UnknownTranslationUnit.code: 422,
    DuplicateTranslationUnit.code: 422,
    MissingPlaceholder.code: 422,
    UnknownPlaceholder.code: 422,
    DuplicatePlaceholder.code: 422,
    PlaceholderOrderMismatch.code: 422,
}


def create_app(config: AdapterConfig | None = None) -> FastAPI:
    settings = config or AdapterConfig.from_env()
    app = FastAPI(title="Semantic Translation Adapter", version="0.1.0")
    app.state.config = settings

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/v1/translate/html", response_model=TranslateHtmlResponse)
    def translate_html_endpoint(body: TranslateHtmlRequest) -> TranslateHtmlResponse:
        result = translate_html(
            body.html,
            source_language=body.source,
            target_language=body.target,
            backend=get_backend(body.backend),
            policy=get_policy(body.policy),
            max_html_bytes=settings.max_html_bytes,
        )
        return TranslateHtmlResponse(
            translated_html=result.translated_html,
            source=result.source_language,
            target=result.target_language,
            backend=result.backend_id,
            policy=result.policy_id,
            segments_total=result.segments_total,
            segments_translated=result.segments_translated,
            segments_skipped=result.segments_skipped,
        )

    @app.exception_handler(SemanticTranslationError)
    async def handle_domain_error(_request, exc: SemanticTranslationError) -> JSONResponse:
        status = _STATUS.get(exc.code, 422)
        payload = ErrorResponse(error=ErrorBody(code=exc.code, message=exc.message))
        return JSONResponse(status_code=status, content=payload.model_dump())

    @app.exception_handler(RequestValidationError)
    async def handle_request_validation(_request, _exc: RequestValidationError) -> JSONResponse:
        payload = ErrorResponse(
            error=ErrorBody(code="invalid_request", message="Request validation failed.")
        )
        return JSONResponse(status_code=422, content=payload.model_dump())

    return app


app = create_app()
