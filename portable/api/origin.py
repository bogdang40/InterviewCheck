"""Determine the browser origin through the Next.js rewrite on this workstation."""
import os
from urllib.parse import urlsplit

from .access import account_enabled


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
    if not os.getenv("INTERVIEWCHECK_OPERATOR_EMAIL", "").strip() or not account_enabled():
        raise ValueError("A public origin requires an access service and a configured operator email.")
    return "https://" + parsed.netloc.lower()


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
