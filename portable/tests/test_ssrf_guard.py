import asyncio
import socket
from unittest.mock import AsyncMock

import pytest

from api import ssrf_guard


def _fake_addrinfo(ip: str):
    family = socket.AF_INET6 if ":" in ip else socket.AF_INET
    return lambda host, port, type=0: [(family, socket.SOCK_STREAM, 6, "", (ip, port))]


@pytest.mark.parametrize("bad_ip", [
    "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254",
    "100.64.0.1", "0.0.0.0", "224.0.0.1", "::1", "fc00::1", "fe80::1",
    "fe80::1%en0", "::ffff:127.0.0.1", "::ffff:169.254.169.254", "2002:7f00:0001::",
])
def test_is_disallowed_ip_blocks_non_global_and_mapped(bad_ip):
    assert ssrf_guard.is_disallowed_ip(bad_ip) is True


@pytest.mark.parametrize("good_ip", ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"])
def test_is_disallowed_ip_allows_public_ips(good_ip):
    assert ssrf_guard.is_disallowed_ip(good_ip) is False


@pytest.mark.parametrize(("provider", "url"), [
    ("openai_compatible", "http://api.example.com/v1"),
    ("openai_compatible", "file:///etc/passwd"),
    ("openai_compatible", "https://user:pass@api.example.com/v1"),
    ("openai_compatible", "https://api.example.com:8443/v1"),
    ("openai_compatible", "https://api.example.com/v1?debug=1"),
    ("openai_compatible", "https://api.example.com/v1#frag"),
    ("openai_compatible", "https://api.example.com/v1\\admin"),
    ("openai_compatible", "https://localhost/v1"),
    ("openai_compatible", "https://service.internal/v1"),
    ("openai_compatible", "https://printer.local/v1"),
    ("openai_compatible", "https://127.0.0.1/v1"),
    ("openai_compatible", "https://169.254.169.254/latest/meta-data"),
    ("openai_compatible", "https://0x7f000001/v1"),
    ("openai_compatible", "https://[::1]/v1"),
    ("openai_compatible", "https://[::ffff:127.0.0.1]/v1"),
    ("openai_compatible", "https://api.example.com/../secret"),
    ("openai_compatible", "https://api.example.com//v1"),
    ("azure_openai", "https://evil.example.com"),
    ("azure_openai", "https://openai.azure.com"),
    ("azure_openai", "https://res.openai.azure.com/extra/path"),
    ("openai", "https://api.openai.com/v1"),
])
def test_validate_endpoint_url_rejects_unsafe_inputs(provider, url):
    with pytest.raises(ssrf_guard.SSRFValidationError):
        ssrf_guard.validate_endpoint_url(url, provider=provider, resolve_dns=False)


@pytest.mark.parametrize("resolved_ips", [
    ["127.0.0.1"],
    ["169.254.169.254"],
    ["100.64.0.1"],
    ["93.184.216.34", "10.0.0.5"],
    ["::ffff:127.0.0.1"],
])
def test_dns_resolution_rejects_restricted_and_mixed_answers(monkeypatch, resolved_ips):
    def fake_getaddrinfo(host, port, type=0):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, port)) for ip in resolved_ips]

    monkeypatch.setattr(ssrf_guard.socket, "getaddrinfo", fake_getaddrinfo)
    with pytest.raises(ssrf_guard.SSRFValidationError):
        ssrf_guard.validate_endpoint_url("https://api.example.com/v1", provider="openai_compatible")


def test_dns_failure_fails_closed_and_public_ip_succeeds(monkeypatch):
    def fail_dns(host, port, type=0):
        raise socket.gaierror("NXDOMAIN")

    monkeypatch.setattr(ssrf_guard.socket, "getaddrinfo", fail_dns)
    with pytest.raises(ssrf_guard.SSRFValidationError):
        ssrf_guard.validate_endpoint_url("https://api.example.com/v1", provider="openai_compatible")

    monkeypatch.setattr(ssrf_guard.socket, "getaddrinfo", _fake_addrinfo("93.184.216.34"))
    assert ssrf_guard.validate_endpoint_url("https://res.openai.azure.com/", provider="azure_openai") == "https://res.openai.azure.com"
    assert ssrf_guard.validate_endpoint_url("https://API.Example.com/v1/", provider="openai_compatible") == "https://api.example.com/v1"


def test_safe_network_backend_pins_tcp_to_resolved_public_ip(monkeypatch):
    monkeypatch.setattr(ssrf_guard.socket, "getaddrinfo", _fake_addrinfo("93.184.216.34"))
    backend = ssrf_guard.SafeNetworkBackend()
    inner_connect = AsyncMock(return_value="pinned-stream")
    monkeypatch.setattr(backend._inner, "connect_tcp", inner_connect)

    stream = asyncio.run(backend.connect_tcp("api.example.com", 443, timeout=5.0))
    assert stream == "pinned-stream"
    assert inner_connect.await_args.args[0] == "93.184.216.34"
    assert inner_connect.await_args.args[1] == 443

    monkeypatch.setattr(ssrf_guard.socket, "getaddrinfo", _fake_addrinfo("127.0.0.1"))
    with pytest.raises(ssrf_guard.SSRFValidationError):
        asyncio.run(backend.connect_tcp("rebind.example.com", 443))

    with pytest.raises(ssrf_guard.SSRFValidationError):
        asyncio.run(backend.connect_tcp("api.example.com", 8443))

    transport = ssrf_guard.SafeAsyncTransport()
    assert isinstance(transport._pool._network_backend, ssrf_guard.SafeNetworkBackend)


def test_provider_http_fetch_json_ssrf_safe_blocks_private_dns(monkeypatch):
    from fastapi import HTTPException
    from api import provider_http

    monkeypatch.setattr(ssrf_guard.socket, "getaddrinfo", _fake_addrinfo("127.0.0.1"))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(provider_http.fetch_json("Custom", "GET", "https://rebind.example.com/v1/models", ssrf_safe=True))
    assert exc.value.status_code == 502 and "restricted" in exc.value.detail.lower()
