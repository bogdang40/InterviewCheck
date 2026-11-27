"""Dry-run routing chain simulator and transcription readiness diagnostics."""
import os
import sqlite3
import time
from typing import Any

from pydantic import Field, field_validator

from . import model_budgets, model_execution, model_registry, model_resolver, provider_allowance, ssrf_guard
from .model_schemas import Capability, KEY_REQUIRED_PROVIDERS
from .models import Input

_COLS = (
    "id, slug, display_name, provider, capability, model_id, endpoint, api_version, config_json, "
    "(encrypted_api_key IS NOT NULL AND encrypted_api_key != '') AS has_key, enabled, is_default, status"
)
_ORDER = (
    "ORDER BY is_default DESC, COALESCE(json_extract(config_json, '$.fallback_priority'), 100) ASC, "
    "updated_at DESC, id ASC"
)


class ChainSimulateInput(Input):
    capability: Capability
    provider: str | None = Field(default=None, max_length=120)
    allow_reference_fallback: bool = False

    @field_validator("provider")
    @classmethod
    def _empty_to_none(cls, value: str | None) -> str | None:
        return value or None


def _table_ready(db: sqlite3.Connection) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='connected_models'").fetchone() is not None


def _query_rows(db: sqlite3.Connection, capability: str, provider: str | None = None) -> list[sqlite3.Row]:
    if not _table_ready(db):
        return []
    if provider:
        return db.execute(f"SELECT {_COLS} FROM connected_models WHERE capability=? AND provider=? {_ORDER}", (capability, provider)).fetchall()
    return db.execute(f"SELECT {_COLS} FROM connected_models WHERE capability=? {_ORDER}", (capability,)).fetchall()


def _find_slug_or_id(db: sqlite3.Connection, identifier: str, caps: tuple[str, ...]) -> sqlite3.Row | None:
    if not _table_ready(db):
        return None
    ph = ",".join("?" for _ in caps)
    rows = db.execute(f"SELECT {_COLS} FROM connected_models WHERE (slug=? OR id=?) AND capability IN ({ph})", (identifier, identifier, *caps)).fetchall()
    return sorted(rows, key=lambda r: caps.index(r["capability"]))[0] if rows else None


def _rpm_remaining(model_uuid: str | None, rpm_limit: Any) -> int | None:
    if isinstance(rpm_limit, bool) or not isinstance(rpm_limit, int) or rpm_limit < 1:
        return None
    if not model_uuid:
        return rpm_limit
    lim = model_execution.QUOTA_LIMITER
    now = time.monotonic()
    with lim._lock:
        bucket = lim._buckets.get(model_uuid)
        if bucket is None or now - bucket[1] >= lim.window_seconds:
            return rpm_limit
        return max(0, rpm_limit - bucket[0])


def _endpoint_valid(provider: str, endpoint: str | None) -> bool:
    ssrf_prov = provider if provider in ("azure_openai", "openai_compatible") else ("openai_compatible" if provider == "deepgram" and endpoint else None)
    if ssrf_prov is None:
        return True
    try:
        ssrf_guard.validate_endpoint_url(endpoint or "", provider=ssrf_prov, resolve_dns=False)
        return True
    except ssrf_guard.SSRFValidationError:
        return False


def _evaluate_row(db: sqlite3.Connection, row: sqlite3.Row, *, forced_skip: str | None = None) -> dict[str, Any]:
    params = model_registry.parse_parameters(row["config_json"])
    budget = model_budgets.check_budget(db, row["id"], params)
    budget_status = budget.reason if (not budget.allowed and budget.reason) else "ok"
    rpm_rem = _rpm_remaining(row["id"], params.get("rpm_limit"))
    skip = forced_skip
    if skip is None:
        if row["enabled"] != 1:
            skip = "disabled"
        elif row["provider"] in KEY_REQUIRED_PROVIDERS and not row["has_key"]:
            skip = "missing_api_key"
        elif not _endpoint_valid(row["provider"], row["endpoint"]):
            skip = "invalid_endpoint"
        elif not budget.allowed:
            skip = budget_status
        elif rpm_rem == 0:
            skip = "rpm_quota_exceeded"
    return {
        "rank": None, "source": "registry", "id": row["id"], "slug": row["slug"],
        "display_name": row["display_name"], "provider": row["provider"], "capability": row["capability"],
        "model_id": row["model_id"], "status": row["status"], "is_default": bool(row["is_default"]),
        "fallback_priority": int(params.get("fallback_priority", 100)), "rpm_remaining": rpm_rem,
        "budget_status": budget_status, "eligible": skip is None, "skip_reason": skip,
    }


def _evaluate_env_candidates(capability: str, norm_provider: str | None, suppressed: set[str]) -> list[dict[str, Any]]:
    target_cap = "reference" if capability in {"reference", "question_planning"} else capability
    default_prio = int(model_registry.DEFAULT_PARAMETERS.get("fallback_priority", 100))
    items: list[dict[str, Any]] = []
    for spec in model_resolver.env_fallback_summaries():
        prov = spec["provider"]
        if not spec["configured"] or spec["capability"] != target_cap or (norm_provider is not None and prov != norm_provider):
            continue
        endpoint = os.getenv("AZURE_OPENAI_ENDPOINT", "").strip() if prov == "azure_openai" else None
        skip = "suppressed_by_registry" if prov in suppressed else (None if _endpoint_valid(prov, endpoint) else "invalid_endpoint")
        items.append({
            "rank": None, "source": "env", "id": None, "slug": None,
            "display_name": model_resolver.DISPLAY_PROVIDER.get(prov, prov), "provider": prov,
            "capability": capability, "model_id": spec["model_id"], "status": "connected",
            "is_default": False, "fallback_priority": default_prio, "rpm_remaining": None,
            "budget_status": "ok", "eligible": skip is None, "skip_reason": skip,
        })
    return items


def _sim_payload(
    db: sqlite3.Connection, capability: str, provider_filter: str | None, allow_ref: bool, active: list[dict[str, Any]], skipped: list[dict[str, Any]]
) -> dict[str, Any]:
    blocked = bool(active) and capability != "transcription" and provider_allowance.summary(db)["remaining"] == 0
    if blocked:
        for entry in active:
            entry.update(eligible=False, skip_reason="workspace_attempt_allowance_exhausted")
        skipped = [*active, *skipped]
        active = []
    for idx, entry in enumerate(active, start=1):
        entry["rank"] = idx
    return {
        "capability": capability, "provider_filter": provider_filter,
        "allow_reference_fallback": allow_ref,
        "active_chain": active, "skipped": skipped, "would_fail_503": not active and not blocked,
        "would_fail_429": blocked,
    }


def simulate_chain(
    db: sqlite3.Connection, capability: str, *, provider: str | None = None, allow_reference_fallback: bool = False
) -> dict[str, Any]:
    clean_provider = provider.strip() or None if isinstance(provider, str) else None
    caps = (capability, "reference") if allow_reference_fallback and capability == "question_planning" else (capability,)
    active_chain: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []

    norm_provider = model_resolver.CANONICAL_PROVIDER.get(clean_provider) if clean_provider is not None else None
    if clean_provider is not None and norm_provider is None:
        direct = _find_slug_or_id(db, clean_provider, caps)
        if direct is not None:
            entry = _evaluate_row(db, direct)
            (active_chain if entry["eligible"] else skipped).append(entry)
        return _sim_payload(db, capability, clean_provider, allow_reference_fallback, active_chain, skipped)

    rows = _query_rows(db, capability, norm_provider)
    for row in rows:
        entry = _evaluate_row(db, row)
        (active_chain if entry["eligible"] else skipped).append(entry)

    blocked = {row["provider"] for row in rows}
    if allow_reference_fallback and capability == "question_planning":
        ref_rows = _query_rows(db, "reference", norm_provider)
        for row in ref_rows:
            entry = _evaluate_row(db, row, forced_skip="suppressed_by_primary_capability" if row["provider"] in blocked else None)
            (active_chain if entry["eligible"] else skipped).append(entry)
        blocked |= {row["provider"] for row in ref_rows}

    for entry in _evaluate_env_candidates(capability, norm_provider, blocked):
        (active_chain if entry["eligible"] else skipped).append(entry)
    return _sim_payload(db, capability, clean_provider, allow_reference_fallback, active_chain, skipped)


def transcription_diagnostics(db: sqlite3.Connection) -> dict[str, Any]:
    sim = simulate_chain(db, "transcription")
    active = sim["active_chain"]
    first = active[0] if active else None
    return {
        "ready": len(active) > 0, "active_provider": first["provider"] if first else None,
        "active_model": first["model_id"] if first else None, "candidate_count": len(active),
    }
