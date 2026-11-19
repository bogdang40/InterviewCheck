"""Pydantic request schemas and validation rules for the model admin API."""
import re
from typing import Annotated, Literal

from pydantic import AfterValidator, Field, SecretStr, StringConstraints, field_validator, model_validator

from . import model_registry
from .models import Input

Provider = Literal["openai", "anthropic", "azure_openai", "deepgram", "openai_compatible"]
Capability = Literal["reference", "question_planning", "transcription", "embedding", "judge"]
ALLOWED_CAPABILITIES: dict[str, set[str]] = {
    "openai": {"reference", "question_planning", "embedding", "judge"},
    "anthropic": {"reference", "question_planning", "judge"},
    "azure_openai": {"reference", "question_planning", "embedding", "judge"},
    "openai_compatible": {"reference", "question_planning", "embedding", "judge"},
    "deepgram": {"transcription"},
}
KEY_REQUIRED_PROVIDERS = {"openai", "anthropic", "azure_openai", "deepgram"}
ENDPOINT_REQUIRED_PROVIDERS = {"azure_openai", "openai_compatible"}


def _check_slug(value: str) -> str:
    if value in model_registry.RESERVED_SLUGS:
        raise ValueError("Slug cannot match a reserved provider identifier.")
    return value


SlugStr = Annotated[
    str,
    StringConstraints(min_length=2, max_length=64, pattern=r"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$"),
    AfterValidator(_check_slug),
]
DisplayNameStr = Annotated[str, StringConstraints(min_length=1, max_length=120)]
ModelIdStr = Annotated[str, StringConstraints(min_length=1, max_length=180)]
ApiVersionStr = Annotated[str, StringConstraints(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")]


def _check_model_id(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,179}", value) or ".." in value or "//" in value:
        raise ValueError("Model identifier contains unsupported characters.")
    return value


def _check_display_name(value: str) -> str:
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        raise ValueError("Display name contains invalid control characters.")
    return value


class ModelParameters(Input):
    temperature: float | None = Field(default=None, ge=0.0, le=2.0, allow_inf_nan=False)
    max_tokens: int | None = Field(default=None, ge=1, le=128000)
    timeout_s: float | None = Field(default=None, ge=1.0, le=180.0, allow_inf_nan=False)
    fallback_priority: int = Field(default=100, ge=0, le=10000)
    max_retries: int = Field(default=0, ge=0, le=3)
    rpm_limit: int | None = Field(default=None, ge=1, le=10000)
    daily_token_limit: int | None = Field(default=None, ge=1, le=100_000_000)
    monthly_cost_limit_usd: float | None = Field(default=None, ge=0.01, le=100_000.0, allow_inf_nan=False)
    input_cost_per_1m_usd: float | None = Field(default=None, ge=0.0, le=1000.0, allow_inf_nan=False)
    output_cost_per_1m_usd: float | None = Field(default=None, ge=0.0, le=1000.0, allow_inf_nan=False)


class ModelParametersPatch(Input):
    temperature: float | None = Field(default=None, ge=0.0, le=2.0, allow_inf_nan=False)
    max_tokens: int | None = Field(default=None, ge=1, le=128000)
    timeout_s: float | None = Field(default=None, ge=1.0, le=180.0, allow_inf_nan=False)
    fallback_priority: int | None = Field(default=None, ge=0, le=10000)
    max_retries: int | None = Field(default=None, ge=0, le=3)
    rpm_limit: int | None = Field(default=None, ge=1, le=10000)
    daily_token_limit: int | None = Field(default=None, ge=1, le=100_000_000)
    monthly_cost_limit_usd: float | None = Field(default=None, ge=0.01, le=100_000.0, allow_inf_nan=False)
    input_cost_per_1m_usd: float | None = Field(default=None, ge=0.0, le=1000.0, allow_inf_nan=False)
    output_cost_per_1m_usd: float | None = Field(default=None, ge=0.0, le=1000.0, allow_inf_nan=False)

    @model_validator(mode="after")
    def reject_null_priority(self):
        for field in ("fallback_priority", "max_retries"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null.")
        return self


class ModelCreateInput(Input):
    slug: SlugStr | None = None
    display_name: DisplayNameStr
    provider: Provider
    capability: Capability
    model_id: ModelIdStr
    endpoint: str | None = Field(default=None, min_length=8, max_length=512)
    api_version: ApiVersionStr | None = None
    parameters: ModelParameters = Field(default_factory=ModelParameters)
    apiKey: SecretStr | None = Field(default=None, max_length=512)
    enabled: bool = True
    is_default: bool = False

    @field_validator("display_name")
    @classmethod
    def valid_display_name(cls, value: str) -> str:
        return _check_display_name(value)

    @field_validator("model_id")
    @classmethod
    def valid_model_id(cls, value: str) -> str:
        return _check_model_id(value)

    @model_validator(mode="after")
    def check_provider_rules(self):
        if self.capability not in ALLOWED_CAPABILITIES[self.provider]:
            raise ValueError("Selected capability is not supported for this provider.")
        secret = self.apiKey.get_secret_value() if self.apiKey is not None else None
        if self.provider in KEY_REQUIRED_PROVIDERS and not secret:
            raise ValueError("An API key is required for this provider.")
        if self.provider == "openai_compatible" and secret == "":
            raise ValueError("Provide a non-empty API key or omit apiKey.")
        if self.provider in ENDPOINT_REQUIRED_PROVIDERS and not self.endpoint:
            raise ValueError("An HTTPS endpoint is required for this provider.")
        if self.provider not in ENDPOINT_REQUIRED_PROVIDERS and self.endpoint is not None:
            raise ValueError("Custom endpoints are only supported for azure_openai and openai_compatible.")
        if self.provider == "azure_openai" and not self.api_version:
            raise ValueError("An API version is required for Azure OpenAI.")
        if self.provider != "azure_openai" and self.api_version is not None:
            raise ValueError("api_version is only supported for azure_openai.")
        return self


class ModelUpdateInput(Input):
    slug: SlugStr | None = None
    display_name: DisplayNameStr | None = None
    capability: Capability | None = None
    model_id: ModelIdStr | None = None
    endpoint: str | None = Field(default=None, min_length=8, max_length=512)
    api_version: ApiVersionStr | None = None
    parameters: ModelParametersPatch | None = None
    apiKey: SecretStr | None = Field(default=None, max_length=512)
    clearApiKey: bool = False
    enabled: bool | None = None
    is_default: bool | None = None

    @field_validator("display_name")
    @classmethod
    def valid_display_name(cls, value: str | None) -> str | None:
        return _check_display_name(value) if value is not None else None

    @field_validator("model_id")
    @classmethod
    def valid_model_id(cls, value: str | None) -> str | None:
        return _check_model_id(value) if value is not None else None

    @model_validator(mode="after")
    def check_patch(self):
        if not self.model_fields_set:
            raise ValueError("Specify at least one field to update.")
        for field in ("slug", "display_name", "capability", "model_id", "parameters", "enabled", "is_default"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null.")
        if self.clearApiKey and self.apiKey is not None and self.apiKey.get_secret_value() != "":
            raise ValueError("Cannot provide apiKey and clearApiKey together.")
        return self


class ModelToggleInput(Input):
    enabled: bool
