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


def browser_origin(headers, scheme):
    host = headers.get("host", "").lower()
    backend = authority(host)
    if not backend or backend.hostname not in LOOPBACK:
        return None
    forwarded = headers.get("x-forwarded-host")
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
    forwarded = request.headers.get("x-interviewcheck-client-ip")
    if not forwarded or "%" in forwarded or peer not in LOOPBACK or os.getenv("INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP") != "1":
        return peer
    public = public_origin()
    if not public or browser_origin(request.headers, request.url.scheme) != public:
        return peer
    try:
        address = ip_address(forwarded)
        return str(getattr(address, "ipv4_mapped", None) or address)
    except ValueError:
        return peer
