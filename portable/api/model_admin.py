"""Authenticated admin API for connected AI and speech models."""
from typing import Any
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import JSONResponse

from . import access, account_db, model_probe, model_registry, model_resolver, rate_limit, secret_box, ssrf_guard, store
from .error_sanitizer import sanitize_error_text
from .model_schemas import (
    ALLOWED_CAPABILITIES,
    Capability,
    ENDPOINT_REQUIRED_PROVIDERS,
    KEY_REQUIRED_PROVIDERS,
    ModelCreateInput,
    ModelToggleInput,
    ModelUpdateInput,
    Provider,
)

router = APIRouter(prefix="/api/admin/models", tags=["model-admin"])


async def require_admin(request: Request) -> dict[str, Any]:
    user, _ = await access.require_admin_session(request)
    return user


def _record_audit(review_db, *, actor: dict[str, Any], action: str, model_uuid: str, details: dict[str, Any], post_commit: list) -> None:
    actor_id = actor.get("id")
    if account_db.database().is_file():
        post_commit.append((action, model_uuid, actor_id, details))
    else:
        model_registry.write_fallback_audit(review_db, actor_user_id=actor_id, action=action, model_uuid=model_uuid, details=details)


def _flush_account_audits(post_commit: list) -> None:
    if post_commit:
        with account_db.connection(write=True) as adb:
            for action, model_uuid, actor_id, details in post_commit:
                account_db.audit(adb, action, model_uuid, actor_id, details)


@router.get("", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def list_models(
    capability: Capability | None = Query(default=None),
    provider: Provider | None = Query(default=None),
    _: dict = Depends(require_admin),
):
    with store.connection() as db:
        models = model_registry.list_models(db, capability=capability, provider=provider)
    return {"models": models, "providers": list(model_registry.PROVIDERS), "envFallbacks": model_resolver.env_fallback_summaries()}


@router.post("", status_code=201, dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
async def create_model(item: ModelCreateInput, actor: dict = Depends(require_admin)):
    endpoint = item.endpoint
    if endpoint is not None:
        try:
            endpoint = await ssrf_guard.validate_endpoint_url_async(endpoint, provider=item.provider)
        except ssrf_guard.SSRFValidationError as exc:
            raise HTTPException(400, sanitize_error_text(str(exc), "Invalid model endpoint URL.")) from exc

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


@router.patch("/{model_id}", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
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
            raise HTTPException(400, sanitize_error_text(str(exc), "Invalid model endpoint URL.")) from exc

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
        merged_capability != existing["capability"]
        or merged_model_id != existing["model_id"]
        or merged_endpoint != existing["endpoint"]
        or merged_api_version != existing["api_version"]
        or rotated_key
        or cleared_key
    )
    next_error = None if conn_changed else existing["last_error"]
    next_latency_ms = None if conn_changed else existing["last_latency_ms"]
    next_checked_at = None if conn_changed else existing["last_checked_at"]
    if not merged_enabled:
        next_status = "disabled"
    elif conn_changed or existing["status"] == "disabled":
        next_status = (
            "unverified" if conn_changed
            else ("error" if existing["last_error"] else ("connected" if existing["last_checked_at"] else "unverified"))
        )
    else:
        next_status = existing["status"]

    changed = sorted(f for f in item.model_fields_set if f not in {"apiKey", "clearApiKey"})
    post_commit: list = []
    with store.connection(write=True) as db:
        updated = model_registry.update_model(
            db, model_uuid, slug=merged_slug, display_name=merged_name, capability=merged_capability,
            model_id=merged_model_id, endpoint=merged_endpoint, api_version=merged_api_version,
            parameters=params, encrypted_api_key=encrypted_key, key_hint=key_hint,
            enabled=merged_enabled, is_default=merged_default, status=next_status,
            last_error=next_error, last_latency_ms=next_latency_ms, last_checked_at=next_checked_at,
        )
        details = {"slug": updated["slug"], "changed": changed, "rotated_key": rotated_key, "cleared_key": cleared_key}
        _record_audit(db, actor=actor, action="admin.model.update", model_uuid=model_uuid, details=details, post_commit=post_commit)
    _flush_account_audits(post_commit)
    return {"model": updated}


@router.post("/{model_id}/toggle", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
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


@router.post(
    "/{model_id}/probe",
    dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE)), Depends(require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_PROBE))],
)
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


@router.delete("/{model_id}", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def delete_model(model_id: UUID, actor: dict = Depends(require_admin)):
    model_uuid = str(model_id)
    post_commit: list = []
    with store.connection(write=True) as db:
        removed = model_registry.delete_model(db, model_uuid)
        details = {"slug": removed["slug"], "provider": removed["provider"], "capability": removed["capability"]}
        _record_audit(db, actor=actor, action="admin.model.delete", model_uuid=model_uuid, details=details, post_commit=post_commit)
    _flush_account_audits(post_commit)
    return {"deleted": True, "id": model_uuid}
