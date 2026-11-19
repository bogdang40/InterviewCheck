"""Redact credentials, filesystem paths, and configuration variable names from error text."""
import re

_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]+")
_SPACE_RE = re.compile(r"\s+")

_ENV_NAMES = (
    "OPENAI_API_KEY|ANTHROPIC_API_KEY|AZURE_OPENAI_API_KEY|AZURE_OPENAI_DEPLOYMENT|"
    "AZURE_OPENAI_ENDPOINT|AZURE_OPENAI_API_VERSION|DEEPGRAM_API_KEY|"
    "STRIPE_SECRET_KEY|STRIPE_WEBHOOK_SECRET|STRIPE_PRICE_MONTHLY|STRIPE_PRICE_ANNUAL|"
    "INTERVIEWCHECK_MODEL_SECRET_KEY|INTERVIEWCHECK_MODEL_SECRET_FILE|"
    "INTERVIEWCHECK_REFERENCE_MODEL|INTERVIEWCHECK_ANTHROPIC_MODEL|"
    "ADMIN_BOOTSTRAP_SECRET|INTERVIEWCHECK_SIGNUP_SECRET|INTERVIEWCHECK_ACCESS_URL|"
    "GREENHOUSE_CLIENT_ID|GREENHOUSE_CLIENT_SECRET|PERSONIO_CLIENT_ID|PERSONIO_CLIENT_SECRET|"
    "WORKABLE_API_KEY|WORKABLE_SUBDOMAIN|WORKABLE_MEMBER_ID|TEAMTAILOR_API_KEY|"
    "SMARTRECRUITERS_API_KEY|BAMBOOHR_API_KEY|BAMBOOHR_SUBDOMAIN|"
    "RECRUITEE_API_KEY|RECRUITEE_COMPANY_ID|JOBADDER_ACCESS_TOKEN|"
    "KOMBO_API_KEY|KOMBO_INTEGRATION_ID|UNIFIED_API_KEY|UNIFIED_CONNECTION_ID|"
    "ASHBY_API_KEY|LEVER_API_KEY|MERGE_API_KEY|MERGE_ACCOUNT_TOKEN|MERGE_REMOTE_USER_ID|"
    "GOOGLE_CALENDAR_ACCESS_TOKEN|GOOGLE_CLIENT_ID|GOOGLE_CLIENT_SECRET|GOOGLE_REFRESH_TOKEN|"
    "MS_GRAPH_ACCESS_TOKEN|MS_GRAPH_CLIENT_ID|MS_GRAPH_CLIENT_SECRET|MS_GRAPH_REFRESH_TOKEN|"
    "ZOOM_ACCESS_TOKEN|WEBEX_ACCESS_TOKEN|CALCOM_API_KEY|CALENDLY_ACCESS_TOKEN|"
    "IMAP_HOST|IMAP_USERNAME|IMAP_PASSWORD|IMAP_FOLDER|IMAP_PORT|PUBLIC_BASE_URL"
)

_REPLACEMENTS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"https?://[^/\s:@]+:[^/\s@]+@"), "https://[redacted]@"),
    (re.compile(r"([?&](?:api[-_]?key|token|access_token|secret|sig|signature|key)=)[^&\s]+", re.IGNORECASE), r"\1[redacted]"),
    (re.compile(r"\b(?:Bearer|Token)\s+(?:token=)?[^\s,;]+", re.IGNORECASE), "[redacted-token]"),
    (re.compile(r"\b(?:api[-_]?key|x-api-key|client_secret|access_token|refresh_token|password|secret)\s*[=:]\s*[^\s,;]+", re.IGNORECASE), "[redacted]"),
    (re.compile(r"\bsk-(?:proj-|svcacct-|admin-|ant-api\d+-)?[A-Za-z0-9_-]{12,}\b"), "[redacted-key]"),
    (re.compile(r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{8,}\b"), "[redacted-key]"),
    (re.compile(r"\bwhsec_[A-Za-z0-9]{8,}\b"), "[redacted-key]"),
    (re.compile(r"\bmm_[A-Za-z0-9_-]{12,}\b"), "[redacted-token]"),
    (re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), "[redacted-key]"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{20,}\b"), "[redacted-key]"),
    (re.compile(r"\b(?:ghp_|github_pat_)[A-Za-z0-9_]{16,}\b"), "[redacted-key]"),
    (re.compile(r"(?:[A-Za-z]:\\|/(?:Users|home|var|tmp|private|opt|etc|srv|root)/)[^\s\"']+"), "[redacted-path]"),
    (re.compile(rf"\b(?:{_ENV_NAMES})\b"), "[config]"),
)


def sanitize_error_text(text: str | None, fallback: str = "Request failed.", *, max_len: int = 400) -> str:
    if not text:
        return fallback
    cleaned = _CONTROL_RE.sub(" ", str(text))
    for pattern, replacement in _REPLACEMENTS:
        cleaned = pattern.sub(replacement, cleaned)
    cleaned = _SPACE_RE.sub(" ", cleaned).strip()
    if not cleaned:
        return fallback
    return cleaned[:max_len]
