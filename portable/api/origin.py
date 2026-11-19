"""Determine the browser origin through the Next.js rewrite on this workstation."""
import os
from ipaddress import ip_address
from urllib.parse import urlsplit

from .access import account_enabled, operator_id, production_mode, public_remote
from .provider_http import configured


LOOPBACK = {"localhost", "127.0.0.1", "::1"}


def authority(host):
    # A Host header is an authority only. Reject credentials, paths, malformed
    # ports and lists of forwarded values before making an origin comparison.
    try:
        parsed = urlsplit("//" + host)
        if (not host or not parsed.hostname or parsed.username is not None or parsed.password is not None
                or parsed.netloc != host or any(c.isspace() or c in ",#?/\\@" for c in host)):
            return None
        _ = parsed.port
        return parsed
    except ValueError:
        return None


def public_origin():
    value = os.getenv("INTERVIEWCHECK_PUBLIC_ORIGIN", "").strip()
    if not value:
        return None
    parsed = urlsplit(value)
    host = authority(parsed.netloc)
    if (parsed.scheme != "https" or not host or host.hostname in LOOPBACK or parsed.path not in ("", "/")
            or parsed.query or parsed.fragment):
        raise ValueError("INTERVIEWCHECK_PUBLIC_ORIGIN requires a single external HTTPS origin.")
    if not account_enabled():
        raise ValueError("A public origin requires an access service.")
    if public_remote() and (configured("INTERVIEWCHECK_OPERATOR_EMAIL") or configured("INTERVIEWCHECK_OPERATOR_ID")):
        operator_id()
    return "https://" + parsed.netloc.lower()


def validate_runtime_exposure():
    origin = public_origin()
    if production_mode() and not account_enabled():
        raise ValueError("Production mode requires embedded or remote account authentication.")
    return origin


def _single_header(headers, name: str) -> tuple[bool, str | None]:
    if hasattr(headers, "getlist"):
        values = headers.getlist(name)
        if len(values) > 1 or any("," in v for v in values):
            return (False, None)
        return (True, values[0] if values else None)
    value = headers.get(name)
    return (False, None) if value is not None and "," in value else (True, value)


def has_duplicate_proxy_headers(headers) -> bool:
    return any(not _single_header(headers, n)[0] for n in ("x-forwarded-host", "x-interviewcheck-client-ip"))


def browser_origin(headers, scheme):
    ok_host, raw_host = _single_header(headers, "host")
    if not ok_host:
        return None
    host = (raw_host or "").lower()
    backend = authority(host)
    if not backend or backend.hostname not in LOOPBACK:
        return None
    ok_fwd, forwarded = _single_header(headers, "x-forwarded-host")
    if not ok_fwd:
        return None
    if forwarded is None:
        return ("https" if scheme in ("https", "wss") else "http") + "://" + host
    forwarded = forwarded.lower()
    frontend = authority(forwarded)
    if not frontend:
        return None
    public = public_origin()
    if public and public == "https://" + forwarded:
        return public
    port = os.getenv("INTERVIEWCHECK_WEB_PORT", "3000")
    if frontend.hostname in LOOPBACK and str(frontend.port) == port:
        return "http://" + forwarded
    return None


def workspace_client(request):
    peer = request.client.host if request.client else "local"
    ok_ip, forwarded = _single_header(request.headers, "x-interviewcheck-client-ip")
    if not ok_ip or not forwarded or "%" in forwarded or peer not in LOOPBACK or os.getenv("INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP") != "1":
        return peer
    public = public_origin()
    if not public or browser_origin(request.headers, request.url.scheme) != public:
        return peer
    try:
        address = ip_address(forwarded)
        return str(getattr(address, "ipv4_mapped", None) or address)
    except ValueError:
        return peer
