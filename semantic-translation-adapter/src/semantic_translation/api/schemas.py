"""HTTP schemas for the translation API.

These models stay at the edge. Core units and DOM plans are not serialized.
"""

from pydantic import BaseModel, ConfigDict, Field


class TranslateHtmlRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    html: str
    source: str | None = None
    target: str = Field(min_length=1, max_length=35)
    backend: str = Field(default="identity", min_length=1, max_length=64)
    policy: str = Field(default="mastodon-v1", min_length=1, max_length=64)


class TranslateHtmlResponse(BaseModel):
    translated_html: str
    source: str | None
    target: str
    backend: str
    policy: str
    segments_total: int
    segments_translated: int
    segments_skipped: int


class ErrorBody(BaseModel):
    code: str
    message: str


class ErrorResponse(BaseModel):
    error: ErrorBody
