"""A bounded continuation position for one literal query, kind set and ordering."""
import base64
import binascii
import hashlib
import hmac
import json
from typing import NamedTuple
from uuid import UUID

from fastapi import HTTPException


VERSION = 1
KINDS = ("role", "session", "session", "answer", "answer")


class Position(NamedTuple):
    rank: int
    priority: int
    id: str


def _binding(needle, kinds, boundary):
    # This binds a position hint to its query. The query itself always controls
    # matching, authorization and field selection, even for a fabricated hint.
    scope = json.dumps([needle, sorted(set(kinds))], ensure_ascii=True, separators=(",", ":")).encode("ascii")
    return hashlib.sha256(boundary + scope).digest()[:16]


def encode(needle, kinds, position):
    try:
        key = position.id
        if not isinstance(key, str) or len(key) != 36 or str(UUID(key)) != key.lower():
            raise ValueError
        boundary = bytes([VERSION, position.rank, position.priority]) + key.encode("ascii")
    except (ValueError, UnicodeError) as exc:
        raise HTTPException(409, "A saved record has an unsupported ID. Refine the search to continue.") from exc
    return base64.urlsafe_b64encode(boundary + _binding(needle, kinds, boundary)).decode("ascii").rstrip("=")


def decode(token, needle, kinds):
    try:
        # Three ordering bytes, a canonical UUID string, and the binding.
        if len(token) != 74:
            raise ValueError
        raw = base64.b64decode(token + "==", altchars=b"-_", validate=True)
        boundary = raw[:39]
        version, rank, priority = boundary[:3]
        key = boundary[3:].decode("ascii")
        if (version != VERSION or priority >= len(KINDS) or KINDS[priority] not in kinds or rank > 5
                or (rank >= 3) != (priority == 4) or str(UUID(key)) != key.lower()
                or not hmac.compare_digest(raw[39:], _binding(needle, kinds, boundary))):
            raise ValueError
        # Reject alternate alphabets and noncanonical trailing base64 bits.
        if base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=") != token:
            raise ValueError
        return Position(rank, priority, key)
    except (ValueError, UnicodeError, binascii.Error) as exc:
        raise HTTPException(422, "This search cursor is invalid. Start the search again.") from exc
