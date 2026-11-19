"""Authenticated admin API for connected AI and speech models."""
import re
from typing import Annotated, Any, Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import JSONResponse
from pydantic import Field, SecretStr, StringConstraints, field_validator, model_validator

from . import access, account_auth, account_db, model_probe, model_registry, model_resolver, secret_box, ssrf_guard, store
from .models import Input
from .provider_http import configured

router = APIRouter(prefix="/api/admin/models", tags=["model-admin"])

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

SlugStr = Annotated[str, StringConstraints(min_length=2, max_length=64, pattern=r"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$")]
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


class ModelParametersPatch(Input):
    temperature: float | None = Field(default=None, ge=0.0, le=2.0, allow_inf_nan=False)
    max_tokens: int | None = Field(default=None, ge=1, le=128000)
    timeout_s: float | None = Field(default=None, ge=1.0, le=180.0, allow_inf_nan=False)
    fallback_priority: int | None = Field(default=None, ge=0, le=10000)

    @model_validator(mode="after")
    def reject_null_priority(self):
        if "fallback_priority" in self.model_fields_set and self.fallback_priority is None:
            raise ValueError("fallback_priority cannot be null.")
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


async def require_admin(request: Request) -> dict[str, Any]:
    token = request.cookies.get(access.COOKIE)
    if not token:
        raise HTTPException(401, "Sign in with an administrator account.")
    enabled = access.account_enabled()
    if not enabled or access.embedded_enabled():
        if not account_db.database().is_file():
            raise HTTPException(401, "Sign in with an administrator account.")
        user, _ = account_auth.authenticate(f"Bearer {token}")
    else:
        data = await access.upstream("me", token=token)
        if not isinstance(data, dict) or not isinstance(data.get("user"), dict):
            raise HTTPException(502, "The access service returned an invalid account.")
        if access.public_remote() or configured("INTERVIEWCHECK_OPERATOR_EMAIL"):
            access.verify_account(data)
        user = data["user"]
    if user.get("disabled"):
        raise HTTPException(401, "Session expired. Sign in again.")
    if user.get("role") != "admin":
        raise HTTPException(403, "Admin access required.")
    return user


def _record_audit(review_db, *, actor: dict[str, Any], action: str, model_uuid: str, details: dict[str, Any], post_commit: list) -> None:
    if account_db.database().is_file():
        post_commit.append((action, model_uuid, actor["id"], details))
    else:
        model_registry.write_fallback_audit(review_db, actor_user_id=actor["id"], action=action, model_uuid=model_uuid, details=details)


def _flush_account_audits(post_commit: list) -> None:
    if post_commit:
        with account_db.connection(write=True) as adb:
            for action, model_uuid, actor_id, details in post_commit:
                account_db.audit(adb, action, model_uuid, actor_id, details)


@router.get("")
def list_models(
    capability: Capability | None = Query(default=None),
    provider: Provider | None = Query(default=None),
    _: dict = Depends(require_admin),
):
    with store.connection() as db:
        models = model_registry.list_models(db, capability=capability, provider=provider)
    return {"models": models, "providers": list(model_registry.PROVIDERS), "envFallbacks": model_resolver.env_fallback_summaries()}


@router.post("", status_code=201)
async def create_model(item: ModelCreateInput, actor: dict = Depends(require_admin)):
    endpoint = item.endpoint
    if endpoint is not None:
        try:
            endpoint = await ssrf_guard.validate_endpoint_url_async(endpoint, provider=item.provider)
        except ssrf_guard.SSRFValidationError as exc:
            raise HTTPException(400, str(exc)) from exc

    model_uuid = str(uuid4())
    raw_key = item.apiKey.get_secret_value() if item.apiKey is not None else ""
    encrypted_key = secret_box.encrypt_secret(raw_key, aad=model_uuid) if raw_key else None
    key_hint = secret_box.mask_key_hint(raw_key) if raw_key else None
    post_commit: list = []

    with store.connection(write=True) as db:
        created = model_registry.create_model(
            db, model_uuid=model_uuid, slug=item.slug, display_name=item.display_name, provider=item.provider,
            capability=item.capability, model_id=item.model_id, endpoint=endpoint, api_version=item.api_version,
            parameters=item.parameters.model_dump(), encrypted_api_key=encrypted_key, key_hint=key_hint,
            enabled=item.enabled, is_default=item.is_default,
        )
        details = {"slug": created["slug"], "provider": created["provider"], "capability": created["capability"],
                   "model_id": created["model_id"], "enabled": created["enabled"], "is_default": created["is_default"]}
        _record_audit(db, actor=actor, action="admin.model.create", model_uuid=model_uuid, details=details, post_commit=post_commit)
    _flush_account_audits(post_commit)
    return {"model": created}


@router.patch("/{model_id}")
async def update_model(model_id: UUID, item: ModelUpdateInput, actor: dict = Depends(require_admin)):
    model_uuid = str(model_id)
    with store.connection() as db:
        existing = model_registry.get_row(db, model_uuid)

    provider = existing["provider"]
    merged_capability = item.capability if item.capability is not None else existing["capability"]
    if merged_capability not in ALLOWED_CAPABILITIES[provider]:
        raise HTTPException(422, "Selected capability is not supported for this provider.")

    merged_endpoint = item.endpoint if "endpoint" in item.model_fields_set else existing["endpoint"]
    if provider in ENDPOINT_REQUIRED_PROVIDERS and not merged_endpoint:
        raise HTTPException(422, "An HTTPS endpoint is required for this provider.")
    if provider not in ENDPOINT_REQUIRED_PROVIDERS and merged_endpoint is not None:
        raise HTTPException(422, "Custom endpoints are only supported for azure_openai and openai_compatible.")

    merged_api_version = item.api_version if "api_version" in item.model_fields_set else existing["api_version"]
    if provider == "azure_openai" and not merged_api_version:
        raise HTTPException(422, "An API version is required for Azure OpenAI.")
    if provider != "azure_openai" and merged_api_version is not None:
        raise HTTPException(422, "api_version is only supported for azure_openai.")

    if merged_endpoint is not None and ("endpoint" in item.model_fields_set or merged_endpoint != existing["endpoint"]):
        try:
            merged_endpoint = await ssrf_guard.validate_endpoint_url_async(merged_endpoint, provider=provider)
        except ssrf_guard.SSRFValidationError as exc:
            raise HTTPException(400, str(exc)) from exc

    params = model_registry.parse_parameters(existing["config_json"])
    if item.parameters is not None:
        params.update(item.parameters.model_dump(exclude_unset=True))

    rotated_key = cleared_key = False
    encrypted_key, key_hint = existing["encrypted_api_key"], existing["key_hint"]
    raw_key = item.apiKey.get_secret_value() if item.apiKey is not None else ""
    if item.clearApiKey:
        if provider in KEY_REQUIRED_PROVIDERS:
            raise HTTPException(422, "Cannot clear the API key for this provider.")
        encrypted_key, key_hint, cleared_key = None, None, True
    elif "apiKey" in item.model_fields_set and raw_key != "":
        encrypted_key = secret_box.encrypt_secret(raw_key, aad=model_uuid)
        key_hint = secret_box.mask_key_hint(raw_key)
        rotated_key = True

    merged_slug = item.slug if item.slug is not None else existing["slug"]
    merged_name = item.display_name if item.display_name is not None else existing["display_name"]
    merged_model_id = item.model_id if item.model_id is not None else existing["model_id"]
    merged_enabled = item.enabled if item.enabled is not None else bool(existing["enabled"])
    merged_default = item.is_default if item.is_default is not None else bool(existing["is_default"])
    conn_changed = (
        merged_model_id != existing["model_id"] or merged_endpoint != existing["endpoint"]
        or merged_api_version != existing["api_version"] or rotated_key or cleared_key
    )
    if not merged_enabled:
        next_status, next_error = "disabled", existing["last_error"]
    elif conn_changed or existing["status"] == "disabled":
        next_status = "unverified" if conn_changed else ("error" if existing["last_error"] else ("connected" if existing["last_checked_at"] else "unverified"))
        next_error = None if conn_changed else existing["last_error"]
    else:
        next_status, next_error = existing["status"], existing["last_error"]

    changed = sorted(f for f in item.model_fields_set if f not in {"apiKey", "clearApiKey"})
    post_commit: list = []
    with store.connection(write=True) as db:
        updated = model_registry.update_model(
            db, model_uuid, slug=merged_slug, display_name=merged_name, capability=merged_capability,
            model_id=merged_model_id, endpoint=merged_endpoint, api_version=merged_api_version,
            parameters=params, encrypted_api_key=encrypted_key, key_hint=key_hint,
            enabled=merged_enabled, is_default=merged_default, status=next_status, last_error=next_error,
        )
        details = {"slug": updated["slug"], "changed": changed, "rotated_key": rotated_key, "cleared_key": cleared_key}
        _record_audit(db, actor=actor, action="admin.model.update", model_uuid=model_uuid, details=details, post_commit=post_commit)
    _flush_account_audits(post_commit)
    return {"model": updated}


@router.post("/{model_id}/toggle")
def toggle_model(model_id: UUID, item: ModelToggleInput, actor: dict = Depends(require_admin)):
    model_uuid = str(model_id)
    post_commit: list = []
    with store.connection(write=True) as db:
        updated = model_registry.toggle_model(db, model_uuid, enabled=item.enabled)
        details = {"slug": updated["slug"], "enabled": updated["enabled"], "status": updated["status"]}
        _record_audit(db, actor=actor, action="admin.model.toggle", model_uuid=model_uuid, details=details, post_commit=post_commit)
    _flush_account_audits(post_commit)
    return {"model": updated}


def _persist_probe(actor: dict[str, Any], model_uuid: str, outcome: model_probe.ProbeOutcome) -> dict[str, Any]:
    post_commit: list = []
    with store.connection(write=True) as db:
        updated = model_registry.record_probe_result(
            db, model_uuid, ok=outcome.ok, latency_ms=outcome.latency_ms,
            error=outcome.last_error, checked_at=outcome.checked_at,
        )
        details = {"slug": updated["slug"], "provider": updated["provider"], "status": updated["status"],
                   "latency_ms": outcome.latency_ms, "error": outcome.last_error}
        _record_audit(db, actor=actor, action="admin.model.probe", model_uuid=model_uuid, details=details, post_commit=post_commit)
    _flush_account_audits(post_commit)
    return updated


@router.post("/{model_id}/probe")
async def probe_model(model_id: UUID, actor: dict = Depends(require_admin)):
    model_uuid = str(model_id)
    with store.connection() as db:
        row = model_registry.get_row(db, model_uuid)
    try:
        api_key = secret_box.decrypt_secret(row["encrypted_api_key"], aad=model_uuid)
    except secret_box.SecretBoxError:
        outcome = model_probe.ProbeOutcome(
            ok=False, status="error", http_status=None, latency_ms=None,
            last_error="Stored model credential could not be decrypted.", checked_at=model_probe._now_iso(),
        )
        updated = _persist_probe(actor, model_uuid, outcome)
        return JSONResponse(status_code=502, content={"detail": outcome.last_error, "model": updated})

    outcome = await model_probe.probe_model(row, api_key=api_key)
    updated = _persist_probe(actor, model_uuid, outcome)
    if outcome.ok:
        return {"ok": True, "model": updated}
    code = 400 if outcome.ssrf_blocked else (504 if outcome.timed_out else 502)
    return JSONResponse(status_code=code, content={"detail": outcome.last_error, "model": updated})


@router.delete("/{model_id}")
def delete_model(model_id: UUID, actor: dict = Depends(require_admin)):
    model_uuid = str(model_id)
    post_commit: list = []
    with store.connection(write=True) as db:
        removed = model_registry.delete_model(db, model_uuid)
        details = {"slug": removed["slug"], "provider": removed["provider"], "capability": removed["capability"]}
        _record_audit(db, actor=actor, action="admin.model.delete", model_uuid=model_uuid, details=details, post_commit=post_commit)
    _flush_account_audits(post_commit)
    return {"deleted": True, "id": model_uuid}
