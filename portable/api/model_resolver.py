"""Read-only runtime model resolution and completion dispatch."""
from contextlib import closing
from dataclasses import dataclass, field
import os
import sqlite3
from typing import Any, Literal

from fastapi import HTTPException

from . import model_registry, provider_http, secret_box, ssrf_guard, store

CANONICAL_PROVIDER: dict[str, str] = {
    "OpenAI": "openai",
    "Anthropic": "anthropic",
    "Azure OpenAI": "azure_openai",
    "Deepgram": "deepgram",
    "OpenAI-Compatible": "openai_compatible",
    "openai": "openai",
    "anthropic": "anthropic",
    "azure_openai": "azure_openai",
    "azure-openai": "azure_openai",
    "deepgram": "deepgram",
    "openai_compatible": "openai_compatible",
    "openai-compatible": "openai_compatible",
}
DISPLAY_PROVIDER: dict[str, str] = {
    "openai": "OpenAI",
    "anthropic": "Anthropic",
    "azure_openai": "Azure OpenAI",
    "deepgram": "Deepgram",
    "openai_compatible": "OpenAI-Compatible",
}


@dataclass(frozen=True)
class ResolvedModel:
    source: Literal["registry", "env"]
    id: str | None
    slug: str | None
    display_name: str
    provider: Literal["openai", "anthropic", "azure_openai", "deepgram", "openai_compatible"]
    capability: str
    model_id: str
    api_key: str = field(repr=False)
    endpoint: str | None
    api_version: str | None
    config: dict[str, Any]
    status: str


def _has_registry_table() -> bool:
    path = store.db_path()
    if not path.is_file():
        return False
    try:
        with closing(sqlite3.connect(path, timeout=5)) as db:
            db.row_factory = sqlite3.Row
            row = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='connected_models'").fetchone()
            return row is not None
    except sqlite3.Error:
        return False


def _query_rows(capability: str, provider: str | None = None) -> list[sqlite3.Row]:
    if not _has_registry_table():
        return []
    with store.connection() as db:
        if provider:
            return db.execute(
                """SELECT * FROM connected_models WHERE capability=? AND provider=?
                   ORDER BY is_default DESC, COALESCE(json_extract(config_json, '$.fallback_priority'), 100) ASC,
                            updated_at DESC, id ASC""",
                (capability, provider),
            ).fetchall()
        return db.execute(
            """SELECT * FROM connected_models WHERE capability=?
               ORDER BY is_default DESC, COALESCE(json_extract(config_json, '$.fallback_priority'), 100) ASC,
                        updated_at DESC, id ASC""",
            (capability,),
        ).fetchall()


def _find_by_slug_or_id(identifier: str, capabilities: tuple[str, ...]) -> sqlite3.Row | None:
    if not _has_registry_table():
        return None
    placeholders = ",".join("?" for _ in capabilities)
    with store.connection() as db:
        rows = db.execute(
            f"SELECT * FROM connected_models WHERE (slug=? OR id=?) AND capability IN ({placeholders})",
            (identifier, identifier, *capabilities),
        ).fetchall()
    if not rows:
        return None
    rows.sort(key=lambda r: capabilities.index(r["capability"]))
    return rows[0]


def _from_row(row: sqlite3.Row) -> ResolvedModel:
    try:
        key = secret_box.decrypt_secret(row["encrypted_api_key"], aad=row["id"])
    except secret_box.SecretBoxError as exc:
        raise HTTPException(503, "Stored model credential could not be decrypted.") from exc
    return ResolvedModel(
        source="registry",
        id=row["id"],
        slug=row["slug"],
        display_name=row["display_name"],
        provider=row["provider"],
        capability=row["capability"],
        model_id=row["model_id"],
        api_key=key,
        endpoint=row["endpoint"],
        api_version=row["api_version"],
        config=model_registry.parse_parameters(row["config_json"]),
        status=row["status"],
    )


def _env(key: str) -> str:
    return os.getenv(key, "").strip()


def _env_fallbacks(
    capability: str,
    provider: str | None,
    *,
    suppressed_providers: set[str] | frozenset[str] = frozenset(),
) -> list[ResolvedModel]:
    if capability == "transcription":
        if provider in (None, "deepgram") and "deepgram" not in suppressed_providers and _env("DEEPGRAM_API_KEY"):
            return [ResolvedModel(
                source="env", id=None, slug=None, display_name="Deepgram", provider="deepgram",
                capability="transcription", model_id="nova-2", api_key=_env("DEEPGRAM_API_KEY"),
                endpoint=None, api_version=None, config=dict(model_registry.DEFAULT_PARAMETERS), status="connected",
            )]
        return []
    if capability == "embedding":
        if (
            provider in (None, "openai")
            and "openai" not in suppressed_providers
            and _env("OPENAI_API_KEY")
            and _env("INTERVIEWCHECK_EMBEDDING_MODEL")
        ):
            return [ResolvedModel(
                source="env", id=None, slug=None, display_name="OpenAI", provider="openai",
                capability="embedding", model_id=_env("INTERVIEWCHECK_EMBEDDING_MODEL"), api_key=_env("OPENAI_API_KEY"),
                endpoint=None, api_version=None, config=dict(model_registry.DEFAULT_PARAMETERS), status="connected",
            )]
        return []
    if capability == "judge":
        if (
            provider in (None, "openai")
            and "openai" not in suppressed_providers
            and _env("OPENAI_API_KEY")
            and _env("INTERVIEWCHECK_JUDGE_MODEL")
        ):
            return [ResolvedModel(
                source="env", id=None, slug=None, display_name="OpenAI", provider="openai",
                capability="judge", model_id=_env("INTERVIEWCHECK_JUDGE_MODEL"), api_key=_env("OPENAI_API_KEY"),
                endpoint=None, api_version=None, config=dict(model_registry.DEFAULT_PARAMETERS), status="connected",
            )]
        return []
    if capability not in {"reference", "question_planning"}:
        return []
    results: list[ResolvedModel] = []
    order = [provider] if provider else ["openai", "anthropic", "azure_openai"]
    for item in order:
        if item in suppressed_providers:
            continue
        if item == "openai" and _env("OPENAI_API_KEY") and _env("INTERVIEWCHECK_REFERENCE_MODEL"):
            results.append(ResolvedModel(
                source="env", id=None, slug=None, display_name="OpenAI", provider="openai",
                capability=capability, model_id=_env("INTERVIEWCHECK_REFERENCE_MODEL"), api_key=_env("OPENAI_API_KEY"),
                endpoint=None, api_version=None, config=dict(model_registry.DEFAULT_PARAMETERS), status="connected",
            ))
        elif item == "anthropic" and _env("ANTHROPIC_API_KEY") and _env("INTERVIEWCHECK_ANTHROPIC_MODEL"):
            results.append(ResolvedModel(
                source="env", id=None, slug=None, display_name="Anthropic", provider="anthropic",
                capability=capability, model_id=_env("INTERVIEWCHECK_ANTHROPIC_MODEL"), api_key=_env("ANTHROPIC_API_KEY"),
                endpoint=None, api_version=None, config=dict(model_registry.DEFAULT_PARAMETERS), status="connected",
            ))
        elif (
            item == "azure_openai"
            and _env("AZURE_OPENAI_API_KEY")
            and _env("AZURE_OPENAI_DEPLOYMENT")
            and _env("AZURE_OPENAI_ENDPOINT")
            and _env("AZURE_OPENAI_API_VERSION")
        ):
            results.append(ResolvedModel(
                source="env", id=None, slug=None, display_name="Azure OpenAI", provider="azure_openai",
                capability=capability, model_id=_env("AZURE_OPENAI_DEPLOYMENT"), api_key=_env("AZURE_OPENAI_API_KEY"),
                endpoint=_env("AZURE_OPENAI_ENDPOINT"), api_version=_env("AZURE_OPENAI_API_VERSION"),
                config=dict(model_registry.DEFAULT_PARAMETERS), status="connected",
            ))
    return results


def resolve_chain(
    capability: str,
    *,
    provider: str | None = None,
    allow_reference_fallback: bool = False,
    allow_slug_lookup: bool = True,
) -> list[ResolvedModel]:
    caps = (capability, "reference") if allow_reference_fallback and capability == "question_planning" else (capability,)
    if provider is not None:
        norm_provider = CANONICAL_PROVIDER.get(provider)
        if norm_provider is None:
            if not allow_slug_lookup:
                return []
            direct = _find_by_slug_or_id(provider, caps)
            if direct is None or direct["enabled"] != 1:
                return []
            return [_from_row(direct)]
    else:
        norm_provider = None

    chain: list[ResolvedModel] = []
    rows = _query_rows(capability, norm_provider)
    for row in rows:
        if row["enabled"] == 1:
            chain.append(_from_row(row))
    blocked_providers = {row["provider"] for row in rows}
    if allow_reference_fallback and capability == "question_planning":
        ref_rows = _query_rows("reference", norm_provider)
        for row in ref_rows:
            if row["provider"] not in blocked_providers and row["enabled"] == 1:
                chain.append(_from_row(row))
        blocked_providers |= {row["provider"] for row in ref_rows}
    chain.extend(_env_fallbacks(capability, norm_provider, suppressed_providers=blocked_providers))
    return chain


def resolve_capability(
    capability: str,
    *,
    provider: str | None = None,
    allow_reference_fallback: bool = False,
    allow_slug_lookup: bool = True,
) -> ResolvedModel | None:
    chain = resolve_chain(
        capability,
        provider=provider,
        allow_reference_fallback=allow_reference_fallback,
        allow_slug_lookup=allow_slug_lookup,
    )
    return chain[0] if chain else None


def resolve_or_503(
    capability: str,
    *,
    provider: str | None = None,
    allow_reference_fallback: bool = False,
    allow_slug_lookup: bool = True,
) -> ResolvedModel:
    target = resolve_capability(
        capability,
        provider=provider,
        allow_reference_fallback=allow_reference_fallback,
        allow_slug_lookup=allow_slug_lookup,
    )
    if target is None:
        label = capability.replace("_", " ")
        raise HTTPException(503, f"Configure an enabled {label} model before running this action.")
    return target


def list_model_summaries(*, provider: str | None = None, capability: str | None = None) -> list[dict[str, Any]]:
    if not _has_registry_table():
        return []
    with store.connection() as db:
        return model_registry.list_models(db, capability=capability, provider=provider)


def env_fallback_summaries() -> list[dict[str, Any]]:
    items = [
        ("openai", "reference", bool(_env("OPENAI_API_KEY") and _env("INTERVIEWCHECK_REFERENCE_MODEL")),
         _env("INTERVIEWCHECK_REFERENCE_MODEL") or None),
        ("anthropic", "reference", bool(_env("ANTHROPIC_API_KEY") and _env("INTERVIEWCHECK_ANTHROPIC_MODEL")),
         _env("INTERVIEWCHECK_ANTHROPIC_MODEL") or None),
        ("azure_openai", "reference",
         bool(_env("AZURE_OPENAI_API_KEY") and _env("AZURE_OPENAI_DEPLOYMENT")
              and _env("AZURE_OPENAI_ENDPOINT") and _env("AZURE_OPENAI_API_VERSION")),
         _env("AZURE_OPENAI_DEPLOYMENT") or None),
        ("deepgram", "transcription", bool(_env("DEEPGRAM_API_KEY")), "nova-2" if _env("DEEPGRAM_API_KEY") else None),
        ("openai", "embedding", bool(_env("OPENAI_API_KEY") and _env("INTERVIEWCHECK_EMBEDDING_MODEL")),
         _env("INTERVIEWCHECK_EMBEDDING_MODEL") or None),
        ("openai", "judge", bool(_env("OPENAI_API_KEY") and _env("INTERVIEWCHECK_JUDGE_MODEL")),
         _env("INTERVIEWCHECK_JUDGE_MODEL") or None),
    ]
    return [
        {"provider": prov, "capability": cap, "configured": ready, "model_id": model_id if ready else None}
        for prov, cap, ready, model_id in items
    ]


def openai_compatible_url(endpoint: str, resource: Literal["chat/completions", "embeddings"]) -> str:
    base = ssrf_guard.validate_endpoint_url(endpoint, provider="openai_compatible", resolve_dns=False).rstrip("/")
    for suffix in ("/chat/completions", "/embeddings"):
        if base.endswith(suffix):
            base = base[:-len(suffix)]
            break
    if base.endswith("/v1"):
        return f"{base}/{resource}"
    return f"{base}/v1/{resource}"


async def dispatch_completion(
    target: ResolvedModel,
    instructions: str,
    prompt: str,
    *,
    fetch_fn=None,
    max_tokens: int | None = None,
) -> tuple[str, str]:
    fetch = fetch_fn or provider_http.fetch_json
    extra_fetch_opts = {"ssrf_safe": True} if fetch is provider_http.fetch_json else {}
    raw_timeout = target.config.get("timeout_s")
    timeout = min(max(float(raw_timeout if raw_timeout is not None else 75.0), 1.0), 180.0)
    limit_tokens = max_tokens or target.config.get("max_tokens")
    label = DISPLAY_PROVIDER.get(target.provider, target.display_name)

    if target.provider == "anthropic":
        body: dict[str, Any] = {
            "model": target.model_id,
            "max_tokens": limit_tokens or 1600,
            "system": instructions,
            "messages": [{"role": "user", "content": prompt}],
        }
        if target.config.get("temperature") is not None:
            body["temperature"] = target.config["temperature"]
        data = await fetch(
            "Anthropic", "POST", "https://api.anthropic.com/v1/messages",
            headers={"x-api-key": target.api_key, "anthropic-version": "2023-06-01"},
            json=body, timeout=timeout, **extra_fetch_opts,
        )
        if not isinstance(data, dict) or data.get("stop_reason") not in {"end_turn", "stop_sequence"}:
            raise HTTPException(502, "Anthropic did not complete its response.")
        blocks = data.get("content")
        text = "\n".join(
            b["text"] for b in blocks
            if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)
        ) if isinstance(blocks, list) else ""
    else:
        messages = [{"role": "system", "content": instructions}, {"role": "user", "content": prompt}]
        if target.provider == "azure_openai":
            try:
                root = ssrf_guard.validate_endpoint_url(target.endpoint or "", provider="azure_openai", resolve_dns=False)
            except ssrf_guard.SSRFValidationError as exc:
                raise HTTPException(503, "Configure a valid Azure OpenAI HTTPS endpoint.") from exc
            from urllib.parse import quote
            url = f"{root}/openai/deployments/{quote(target.model_id, safe='')}/chat/completions"
            headers, params = {"api-key": target.api_key}, {"api-version": target.api_version or ""}
            body = {"messages": messages, "max_completion_tokens": limit_tokens or 2000}
        elif target.provider == "openai_compatible":
            try:
                url = openai_compatible_url(target.endpoint or "", "chat/completions")
            except ssrf_guard.SSRFValidationError as exc:
                raise HTTPException(503, "Configure a valid HTTPS model endpoint.") from exc
            headers = {"Authorization": f"Bearer {target.api_key}"} if target.api_key else {}
            params = {}
            body = {"model": target.model_id, "messages": messages, "max_tokens": limit_tokens or 2000}
        else:
            url = "https://api.openai.com/v1/chat/completions"
            headers, params = {"Authorization": "Bearer " + target.api_key}, {}
            body = {"model": target.model_id, "messages": messages, "max_completion_tokens": limit_tokens or 2000, "store": False}
        if target.config.get("temperature") is not None:
            body["temperature"] = target.config["temperature"]
        data = await fetch(label, "POST", url, json=body, headers=headers, params=params, timeout=timeout, **extra_fetch_opts)
        try:
            choice = data["choices"][0]
            if choice.get("finish_reason") != "stop":
                raise HTTPException(502, f"{label} did not complete its response.")
            text = choice["message"]["content"]
        except (KeyError, TypeError, IndexError, AttributeError) as exc:
            raise HTTPException(502, f"{label} returned an invalid response.") from exc

    if not isinstance(text, str) or not 0 < len(text.strip()) <= 24000:
        raise HTTPException(502, f"{label} returned no usable text.")
    return target.model_id, text.strip()
