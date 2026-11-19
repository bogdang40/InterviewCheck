"use client"

import { useId, useRef, useState, type FormEvent } from "react"
import { X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import {
  ALLOWED_CAPABILITIES,
  CAPABILITY_LABELS,
  ENDPOINT_REQUIRED_PROVIDERS,
  KEY_REQUIRED_PROVIDERS,
  PROVIDER_LABELS,
  createAdminModel,
  updateAdminModel,
  type ConnectedModel,
  type ModelCapability,
  type ModelProvider,
} from "@/lib/adminModels"
import { useDialogFocusTrap } from "@/lib/useDialogFocusTrap"
import {
  ModelParameterFields,
  initialParameterValues,
  parseModelParameterValues,
  type ModelParameterValues,
} from "./ModelParameterFields"

export function ModelFormModal({
  editing,
  onClose,
  onSaved,
}: {
  editing: ConnectedModel | null
  onClose: () => void
  onSaved: (model: ConnectedModel, created: boolean) => void
}) {
  const titleId = useId()
  const isEdit = Boolean(editing)
  const [provider, setProvider] = useState<ModelProvider>(editing?.provider ?? "openai")
  const [capability, setCapability] = useState<ModelCapability>(editing?.capability ?? "reference")
  const [displayName, setDisplayName] = useState(editing?.display_name ?? "")
  const [slug, setSlug] = useState(editing?.slug ?? "")
  const [modelId, setModelId] = useState(editing?.model_id ?? "")
  const [endpoint, setEndpoint] = useState(editing?.endpoint ?? "")
  const [apiVersion, setApiVersion] = useState(editing?.api_version ?? "")
  const [apiKey, setApiKey] = useState("")
  const [clearApiKey, setClearApiKey] = useState(false)
  const [paramValues, setParamValues] = useState<ModelParameterValues>(() =>
    initialParameterValues(editing),
  )
  const [enabled, setEnabled] = useState(editing?.enabled ?? true)
  const [isDefault, setIsDefault] = useState(editing?.is_default ?? false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")

  const dialogRef = useRef<HTMLDivElement>(null)

  useDialogFocusTrap({
    open: true,
    containerRef: dialogRef,
    onClose,
    disabled: busy,
  })

  const allowedCaps = ALLOWED_CAPABILITIES[provider]
  const needsEndpoint = ENDPOINT_REQUIRED_PROVIDERS.includes(provider)
  const needsApiVersion = provider === "azure_openai"
  const keyRequiredOnCreate = KEY_REQUIRED_PROVIDERS.includes(provider)

  function handleProviderChange(next: ModelProvider) {
    setProvider(next)
    const allowed = ALLOWED_CAPABILITIES[next]
    if (!allowed.includes(capability)) {
      setCapability(allowed[0])
    }
    if (!ENDPOINT_REQUIRED_PROVIDERS.includes(next)) {
      setEndpoint("")
    }
    if (next !== "azure_openai") {
      setApiVersion("")
    }
  }

  async function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (busy) return
    setError("")
    try {
      const params = parseModelParameterValues(paramValues)
      setBusy(true)
      if (!editing) {
        const created = await createAdminModel({
          display_name: displayName.trim(),
          provider,
          capability,
          model_id: modelId.trim(),
          ...(slug.trim() ? { slug: slug.trim() } : {}),
          ...(needsEndpoint ? { endpoint: endpoint.trim() } : {}),
          ...(needsApiVersion ? { api_version: apiVersion.trim() } : {}),
          ...(apiKey.trim() ? { apiKey: apiKey.trim() } : {}),
          parameters: params,
          enabled,
          is_default: isDefault,
        })
        onSaved(created, true)
      } else {
        const updated = await updateAdminModel(editing.id, {
          display_name: displayName.trim(),
          slug: slug.trim(),
          capability,
          model_id: modelId.trim(),
          ...(needsEndpoint ? { endpoint: endpoint.trim() } : {}),
          ...(needsApiVersion ? { api_version: apiVersion.trim() } : {}),
          ...(clearApiKey
            ? { clearApiKey: true }
            : apiKey.trim()
              ? { apiKey: apiKey.trim() }
              : {}),
          parameters: params,
          enabled,
          is_default: isDefault,
        })
        onSaved(updated, false)
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not save model configuration.")
    } finally {
      setBusy(false)
    }
  }

  return (
    <div
      className="admin-modal-backdrop"
      onClick={(e) => {
        if (e.target === e.currentTarget && !busy) onClose()
      }}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
        className="panel admin-modal"
      >
        <div className="admin-modal-head">
          <h2 id={titleId}>{isEdit ? `Configure ${editing?.display_name}` : "Connect model"}</h2>
          <Button type="button" variant="ghost" size="icon-sm" aria-label="Close modal" disabled={busy} onClick={onClose}>
            <X size={16} aria-hidden="true" />
          </Button>
        </div>

        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}

        <form className="stack" onSubmit={handleSubmit}>
          <div className="dual">
            <label className="field">
              Provider
              <select
                value={provider}
                disabled={busy || isEdit}
                onChange={(e) => handleProviderChange(e.target.value as ModelProvider)}
              >
                {Object.entries(PROVIDER_LABELS).map(([k, label]) => (
                  <option key={k} value={k}>
                    {label}
                  </option>
                ))}
              </select>
            </label>
            <label className="field">
              Capability
              <select
                value={capability}
                disabled={busy}
                onChange={(e) => setCapability(e.target.value as ModelCapability)}
              >
                {allowedCaps.map((cap) => (
                  <option key={cap} value={cap}>
                    {CAPABILITY_LABELS[cap]}
                  </option>
                ))}
              </select>
            </label>
          </div>

          <div className="dual">
            <label className="field">
              Display name
              <Input
                required
                maxLength={120}
                disabled={busy}
                value={displayName}
                placeholder="e.g. Primary Reference GPT-4o"
                onChange={(e) => setDisplayName(e.target.value)}
              />
            </label>
            <label className="field">
              Model ID
              <Input
                required
                maxLength={180}
                disabled={busy}
                value={modelId}
                placeholder={provider === "deepgram" ? "nova-2" : "gpt-4o"}
                onChange={(e) => setModelId(e.target.value)}
              />
            </label>
          </div>

          <label className="field">
            Slug {isEdit ? "" : "(optional, auto-generated if blank)"}
            <Input
              maxLength={64}
              disabled={busy}
              value={slug}
              placeholder="primary-openai-reference"
              onChange={(e) => setSlug(e.target.value)}
            />
          </label>

          {needsEndpoint && (
            <label className="field">
              Endpoint URL (HTTPS)
              <Input
                type="url"
                required
                disabled={busy}
                value={endpoint}
                placeholder={
                  provider === "azure_openai"
                    ? "https://your-resource.openai.azure.com"
                    : "https://api.example.com/v1"
                }
                onChange={(e) => setEndpoint(e.target.value)}
              />
              <small className="muted">
                {provider === "azure_openai"
                  ? "Must use *.openai.azure.com or *.cognitiveservices.azure.com without a path."
                  : "Must be a public HTTPS URL without private/loopback addresses or credentials."}
              </small>
            </label>
          )}

          {needsApiVersion && (
            <label className="field">
              Azure API version
              <Input
                required
                maxLength={64}
                disabled={busy}
                value={apiVersion}
                placeholder="2024-10-21"
                onChange={(e) => setApiVersion(e.target.value)}
              />
            </label>
          )}

          <label className="field">
            API key {isEdit ? "(leave blank to keep current key)" : keyRequiredOnCreate ? "" : "(optional)"}
            <Input
              type="password"
              autoComplete="off"
              required={!isEdit && keyRequiredOnCreate}
              disabled={busy || clearApiKey}
              value={apiKey}
              placeholder={
                isEdit && editing?.hasKey
                  ? `Leave blank to keep ${editing.key_hint || "current key"}`
                  : "Enter provider API key"
              }
              onChange={(e) => setApiKey(e.target.value)}
            />
          </label>

          {isEdit && provider === "openai_compatible" && editing?.hasKey && (
            <label className="check">
              <input
                type="checkbox"
                checked={clearApiKey}
                disabled={busy}
                onChange={(e) => {
                  setClearApiKey(e.target.checked)
                  if (e.target.checked) setApiKey("")
                }}
              />
              Remove stored API key
            </label>
          )}

          <ModelParameterFields values={paramValues} busy={busy} onChange={setParamValues} />

          <div className="row">
            <label className="check">
              <input type="checkbox" checked={enabled} disabled={busy} onChange={(e) => setEnabled(e.target.checked)} />
              Enabled
            </label>
            <label className="check">
              <input type="checkbox" checked={isDefault} disabled={busy} onChange={(e) => setIsDefault(e.target.checked)} />
              Default for capability
            </label>
          </div>

          <div className="row">
            <Button type="submit" disabled={busy}>
              {busy ? "Saving…" : isEdit ? "Save configuration" : "Save and connect"}
            </Button>
            <Button type="button" variant="outline" disabled={busy} onClick={onClose}>
              Cancel
            </Button>
          </div>
        </form>
      </div>
    </div>
  )
}
