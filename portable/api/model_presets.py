"""Authenticated admin API for model provider presets and batch operations."""
import asyncio
from dataclasses import replace
from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import Field, model_validator

from . import model_admin, model_probe, model_registry, rate_limit, secret_box, store
from .error_sanitizer import sanitize_error_text
from .models import Input, RequestID

MAX_BATCH_TOGGLE = 25
MAX_BATCH_PROBE = 10
MAX_BATCH_PROBE_CONCURRENCY = 4

router = APIRouter(
    prefix="/api/admin/models",
    tags=["model-presets"],
    dependencies=[Depends(model_admin.require_admin)],
)

MODEL_PRESETS: tuple[dict[str, Any], ...] = (
    {
        "id": "openai-gpt4o-reference", "provider": "openai", "capability": "reference",
        "model_id": "gpt-4o", "display_name": "OpenAI GPT-4o (Reference)", "slug_prefix": "openai-gpt4o-ref",
        "endpoint_placeholder": None, "api_version_default": None,
        "description": "General-purpose reference evaluation and answer comparison.",
        "parameters": {"temperature": 0.2, "max_tokens": 1200, "timeout_s": 30.0, "fallback_priority": 100,
                       "max_retries": 1, "rpm_limit": 120, "input_cost_per_1m_usd": 2.5, "output_cost_per_1m_usd": 10.0},
    },
    {
        "id": "openai-embed-small", "provider": "openai", "capability": "embedding",
        "model_id": "text-embedding-3-small", "display_name": "OpenAI Embeddings Small", "slug_prefix": "openai-embed-small",
        "endpoint_placeholder": None, "api_version_default": None,
        "description": "Compact dense embeddings for semantic rubric and reference lookup.",
        "parameters": {"timeout_s": 15.0, "fallback_priority": 100, "max_retries": 1, "rpm_limit": 300,
                       "input_cost_per_1m_usd": 0.02, "output_cost_per_1m_usd": 0.0},
    },
    {
        "id": "anthropic-sonnet-planning", "provider": "anthropic", "capability": "question_planning",
        "model_id": "claude-sonnet-4-6", "display_name": "Anthropic Claude Sonnet (Planning)", "slug_prefix": "anthropic-sonnet-plan",
        "endpoint_placeholder": None, "api_version_default": None,
        "description": "Structured role authoring and follow-up question planning.",
        "parameters": {"temperature": 0.3, "max_tokens": 1500, "timeout_s": 35.0, "fallback_priority": 100,
                       "max_retries": 1, "rpm_limit": 80, "input_cost_per_1m_usd": 3.0, "output_cost_per_1m_usd": 15.0},
    },
    {
        "id": "anthropic-sonnet-judge", "provider": "anthropic", "capability": "judge",
        "model_id": "claude-sonnet-4-6", "display_name": "Anthropic Claude Sonnet (Judge)", "slug_prefix": "anthropic-sonnet-judge",
        "endpoint_placeholder": None, "api_version_default": None,
        "description": "Deterministic rubric scoring and evidence extraction.",
        "parameters": {"temperature": 0.0, "max_tokens": 1000, "timeout_s": 35.0, "fallback_priority": 90,
                       "max_retries": 1, "rpm_limit": 80, "input_cost_per_1m_usd": 3.0, "output_cost_per_1m_usd": 15.0},
    },
    {
        "id": "azure-gpt4o-reference", "provider": "azure_openai", "capability": "reference",
        "model_id": "gpt-4o-deployment", "display_name": "Azure OpenAI GPT-4o", "slug_prefix": "azure-gpt4o-ref",
        "endpoint_placeholder": "https://your-resource.openai.azure.com", "api_version_default": "2024-10-21",
        "description": "Enterprise Azure OpenAI deployment for reference evaluation.",
        "parameters": {"temperature": 0.2, "max_tokens": 1200, "timeout_s": 30.0, "fallback_priority": 110,
                       "max_retries": 1, "rpm_limit": 100, "input_cost_per_1m_usd": 2.5, "output_cost_per_1m_usd": 10.0},
    },
    {
        "id": "deepgram-nova2-transcription", "provider": "deepgram", "capability": "transcription",
        "model_id": "nova-2", "display_name": "Deepgram Nova-2 (Transcription)", "slug_prefix": "deepgram-nova2-tx",
        "endpoint_placeholder": None, "api_version_default": None,
        "description": "Low-latency speech-to-text transcription for interview recordings.",
        "parameters": {"timeout_s": 45.0, "fallback_priority": 100, "max_retries": 1, "rpm_limit": 60},
    },
    {
        "id": "compat-qwen-planning", "provider": "openai_compatible", "capability": "question_planning",
        "model_id": "qwen-2.5-72b-instruct", "display_name": "OpenAI-Compatible (Planning)", "slug_prefix": "compat-qwen-plan",
        "endpoint_placeholder": "https://llm.internal.example/v1", "api_version_default": None,
        "description": "Self-hosted or gateway OpenAI-compatible planning model.",
        "parameters": {"temperature": 0.3, "max_tokens": 1400, "timeout_s": 40.0, "fallback_priority": 150,
                       "max_retries": 0, "rpm_limit": 60},
    },
    {
        "id": "compat-llama-judge", "provider": "openai_compatible", "capability": "judge",
        "model_id": "llama-3.3-70b-instruct", "display_name": "OpenAI-Compatible (Judge)", "slug_prefix": "compat-llama-judge",
        "endpoint_placeholder": "https://llm.internal.example/v1", "api_version_default": None,
        "description": "Self-hosted or gateway OpenAI-compatible rubric judge.",
        "parameters": {"temperature": 0.0, "max_tokens": 1000, "timeout_s": 40.0, "fallback_priority": 150,
                       "max_retries": 0, "rpm_limit": 60},
    },
)


class BatchToggleInput(Input):
    model_ids: list[RequestID] = Field(min_length=1, max_length=MAX_BATCH_TOGGLE)
    enabled: bool

    @model_validator(mode="after")
    def require_unique_ids(self):
        if len(set(self.model_ids)) != len(self.model_ids):
            raise ValueError("Select each model only once.")
        return self


class BatchProbeInput(Input):
    model_ids: list[RequestID] = Field(min_length=1, max_length=MAX_BATCH_PROBE)

    @model_validator(mode="after")
    def require_unique_ids(self):
        if len(set(self.model_ids)) != len(self.model_ids):
            raise ValueError("Select each model only once.")
        return self


@router.get("/presets", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def list_presets():
    return {"presets": [{**item, "parameters": dict(item["parameters"])} for item in MODEL_PRESETS]}


@router.post("/batch/toggle", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def batch_toggle_models(item: BatchToggleInput, actor: dict = Depends(model_admin.require_admin)):
    ids = [str(mid) for mid in item.model_ids]
    post_commit: list = []
    with store.connection(write=True) as db:
        for mid in ids:
            model_registry.get_row(db, mid)
        models = [model_registry.toggle_model(db, mid, enabled=item.enabled) for mid in ids]
        details = {"model_ids": ids, "enabled": item.enabled, "updated": len(models)}
        model_admin._record_audit(
            db,
            actor=actor,
            action="admin.model.batch_toggle",
            model_uuid=ids[0],
            details=details,
            post_commit=post_commit,
        )
    model_admin._flush_account_audits(post_commit)
    return {"updated": len(models), "models": models}


def _scrub_probe_outcome(outcome: model_probe.ProbeOutcome, api_key: str) -> model_probe.ProbeOutcome:
    if outcome.ok or not outcome.last_error:
        return outcome
    clean_err = sanitize_error_text(outcome.last_error, "Provider probe failed.")
    if api_key and len(api_key) >= 6 and api_key in clean_err:
        clean_err = clean_err.replace(api_key, "[redacted]")
    if clean_err == outcome.last_error:
        return outcome
    return replace(outcome, last_error=clean_err)


@router.post(
    "/batch/probe",
    dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE)), Depends(rate_limit.limit(rate_limit.ADMIN_PROBE))],
)
async def batch_probe_models(item: BatchProbeInput, actor: dict = Depends(model_admin.require_admin)):
    ids = [str(mid) for mid in item.model_ids]
    with store.connection() as db:
        rows = [dict(model_registry.get_row(db, mid)) for mid in ids]

    semaphore = asyncio.Semaphore(MAX_BATCH_PROBE_CONCURRENCY)

    async def _probe_one(row: dict[str, Any]) -> dict[str, Any]:
        model_uuid = row["id"]
        expected_updated_at = row["updated_at"]
        api_key = ""
        async with semaphore:
            try:
                api_key = secret_box.decrypt_secret(row["encrypted_api_key"], aad=model_uuid)
            except secret_box.SecretBoxError:
                outcome = model_probe.ProbeOutcome(
                    ok=False,
                    status="error",
                    http_status=None,
                    latency_ms=None,
                    last_error="Stored model credential could not be decrypted.",
                    checked_at=model_probe._now_iso(),
                )
            else:
                outcome = await model_probe.probe_model(row, api_key=api_key)

        outcome = _scrub_probe_outcome(outcome, api_key)
        try:
            updated = model_admin._persist_probe(
                actor,
                model_uuid,
                outcome,
                expected_updated_at=expected_updated_at,
            )
        except HTTPException as exc:
            return {
                "id": model_uuid,
                "ok": False,
                "status": "error",
                "detail": sanitize_error_text(str(exc.detail), "Probe result could not be saved."),
                "latency_ms": outcome.latency_ms,
                "model": None,
            }
        detail = None if outcome.ok else (updated.get("last_error") or outcome.last_error)
        return {
            "id": model_uuid,
            "ok": outcome.ok,
            "status": updated["status"],
            "detail": detail,
            "latency_ms": outcome.latency_ms,
            "model": updated,
        }

    results = list(await asyncio.gather(*(_probe_one(row) for row in rows)))
    ok_count = sum(1 for entry in results if entry["ok"])
    error_count = len(results) - ok_count
    post_commit: list = []
    details = {
        "model_ids": ids,
        "probed": len(results),
        "ok_count": ok_count,
        "error_count": error_count,
    }
    with store.connection(write=True) as db:
        model_admin._record_audit(
            db,
            actor=actor,
            action="admin.model.batch_probe",
            model_uuid=ids[0],
            details=details,
            post_commit=post_commit,
        )
    model_admin._flush_account_audits(post_commit)
    return {
        "probed": len(results),
        "ok_count": ok_count,
        "error_count": error_count,
        "results": results,
    }
