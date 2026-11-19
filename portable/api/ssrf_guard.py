"""Strict SSRF validation, DNS checks, and TCP-pinning HTTP transport for model endpoints."""
import ipaddress
import re
import socket
from urllib.parse import urlsplit

import httpcore
from httpcore._backends.auto import AutoBackend
import httpx
from starlette.concurrency import run_in_threadpool

DISALLOWED_SUFFIXES = (".localhost", ".local", ".internal", ".localdomain", ".arpa", ".home.arpa")
NUMERIC_HOST_RE = re.compile(r"^(?:0x[0-9a-f]+|0[0-7]+|\d+)(?:\.(?:0x[0-9a-f]+|0[0-7]+|\d+)){0,3}$", re.IGNORECASE)
AZURE_SUFFIXES = (".openai.azure.com", ".cognitiveservices.azure.com")


class SSRFValidationError(ValueError):
    """Raised when a model endpoint violates HTTPS or network safety policy."""


def is_disallowed_ip(addr: str) -> bool:
    if not addr or "%" in addr:
        return True
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return True
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped is not None and is_disallowed_ip(str(ip.ipv4_mapped)):
            return True
        if ip.sixtofour is not None and is_disallowed_ip(str(ip.sixtofour)):
            return True
        if ip.teredo is not None and (is_disallowed_ip(str(ip.teredo[0])) or is_disallowed_ip(str(ip.teredo[1]))):
            return True
    return (
        not ip.is_global
        or ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
    )


def resolve_public_ips(hostname: str, port: int = 443) -> list[str]:
    try:
        records = socket.getaddrinfo(hostname, port, type=socket.SOCK_STREAM)
    except OSError as exc:
        raise SSRFValidationError("Endpoint hostname could not be resolved.") from exc
    if not records:
        raise SSRFValidationError("Endpoint hostname resolved to no addresses.")
    ips: list[str] = []
    for record in records:
        sockaddr = record[4]
        if not sockaddr:
            continue
        ip = sockaddr[0]
        if is_disallowed_ip(ip):
            raise SSRFValidationError("Endpoint resolves to a restricted network address.")
        if ip not in ips:
            ips.append(ip)
    if not ips:
        raise SSRFValidationError("Endpoint hostname resolved to no usable addresses.")
    return ips


def _normalize_hostname(raw_host: str) -> str:
    if not raw_host or "%" in raw_host or ":" in raw_host:
        raise SSRFValidationError("Endpoint must use a valid domain hostname.")
    try:
        hostname = raw_host.rstrip(".").encode("idna").decode("ascii").lower()
    except UnicodeError as exc:
        raise SSRFValidationError("Endpoint hostname is invalid.") from exc
    if not hostname or "." not in hostname:
        raise SSRFValidationError("Endpoint must use a fully qualified public domain name.")
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        pass
    else:
        raise SSRFValidationError("Raw IP addresses are not permitted for model endpoints.")
    if NUMERIC_HOST_RE.fullmatch(hostname):
        raise SSRFValidationError("Numeric IP-like hostnames are not permitted.")
    if hostname == "localhost" or any(hostname.endswith(suffix) for suffix in DISALLOWED_SUFFIXES):
        raise SSRFValidationError("Local and internal hostnames are not permitted.")
    return hostname


def validate_endpoint_url(raw_url: str, *, provider: str, resolve_dns: bool = True) -> str:
    if not isinstance(raw_url, str):
        raise SSRFValidationError("Endpoint must be a string URL.")
    cleaned = raw_url.strip()
    if not cleaned or len(cleaned) > 512:
        raise SSRFValidationError("Endpoint URL must be between 1 and 512 characters.")
    if any(ord(ch) < 32 or ord(ch) == 127 or ch.isspace() or ch == "\\" for ch in cleaned):
        raise SSRFValidationError("Endpoint URL contains invalid characters.")
    try:
        parsed = urlsplit(cleaned)
        port = parsed.port
    except ValueError as exc:
        raise SSRFValidationError("Endpoint URL is malformed.") from exc
    if parsed.scheme.lower() != "https":
        raise SSRFValidationError("Endpoint URL must use HTTPS.")
    if parsed.username is not None or parsed.password is not None or "@" in parsed.netloc:
        raise SSRFValidationError("Endpoint URL must not include credentials.")
    if parsed.query or parsed.fragment:
        raise SSRFValidationError("Endpoint URL must not include query parameters or fragments.")
    if port not in (None, 443):
        raise SSRFValidationError("Endpoint URL must use standard HTTPS port 443.")

    hostname = _normalize_hostname(parsed.hostname or "")
    if parsed.netloc.lower() not in {hostname, f"{hostname}:443"}:
        raise SSRFValidationError("Endpoint authority must match its hostname.")

    if provider == "azure_openai":
        if parsed.path not in {"", "/"}:
            raise SSRFValidationError("Azure OpenAI endpoint must not include a path.")
        if not any(hostname.endswith(suffix) and len(hostname) > len(suffix) for suffix in AZURE_SUFFIXES):
            raise SSRFValidationError("Azure OpenAI endpoint must use an *.openai.azure.com or *.cognitiveservices.azure.com host.")
        normalized = f"https://{hostname}"
    elif provider == "openai_compatible":
        if ".." in parsed.path.split("/") or "//" in parsed.path:
            raise SSRFValidationError("Endpoint path contains invalid segments.")
        path = parsed.path.rstrip("/")
        normalized = f"https://{hostname}{path}"
    else:
        raise SSRFValidationError("Custom endpoints are only supported for azure_openai and openai_compatible.")

    if resolve_dns:
        resolve_public_ips(hostname, 443)
    return normalized


async def validate_endpoint_url_async(raw_url: str, *, provider: str, resolve_dns: bool = True) -> str:
    normalized = validate_endpoint_url(raw_url, provider=provider, resolve_dns=False)
    if resolve_dns:
        hostname = urlsplit(normalized).hostname or ""
        await run_in_threadpool(resolve_public_ips, hostname, 443)
    return normalized


validate_model_endpoint = validate_endpoint_url


class SafeNetworkBackend(httpcore.AsyncNetworkBackend):
    """Pin outbound TCP connections to DNS-validated public IP addresses."""

    def __init__(self) -> None:
        self._inner = AutoBackend()

    async def connect_tcp(self, host, port, timeout=None, local_address=None, socket_options=None):
        if port != 443:
            raise SSRFValidationError("Only HTTPS port 443 is permitted.")
        try:
            ipaddress.ip_address(host)
        except ValueError:
            ips = await run_in_threadpool(resolve_public_ips, host, port)
            target_host = ips[0]
        else:
            if is_disallowed_ip(host):
                raise SSRFValidationError("Target IP address is not permitted.")
            target_host = host
        return await self._inner.connect_tcp(
            target_host, port, timeout=timeout, local_address=local_address, socket_options=socket_options
        )

    async def connect_unix_socket(self, path, timeout=None, socket_options=None):
        raise SSRFValidationError("Unix socket connections are not permitted.")

    async def sleep(self, seconds):
        await self._inner.sleep(seconds)


class SafeAsyncTransport(httpx.AsyncHTTPTransport):
    """Async HTTP transport disabling proxy env vars and pinning public TCP IPs."""

    def __init__(self, **kwargs) -> None:
        kwargs["trust_env"] = False
        super().__init__(**kwargs)
        self._pool._network_backend = SafeNetworkBackend()
