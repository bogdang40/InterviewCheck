"""Read bounded iCalendar MIME parts from a configured TLS mailbox."""
import base64
import binascii
from datetime import datetime, timedelta, timezone
import imaplib
import os
import quopri
import re
import ssl
from time import monotonic

from fastapi import HTTPException
from icalendar import Calendar

from .calendar_sources import calendar_file
from .provider_http import setting

PART_LIMIT = 400_000
SEARCH_WINDOW = 500
MESSAGE_LIMIT = 60
PART_COUNT = 30
TOKEN = re.compile(rb'\(|\)|"(?:[^"\\]|\\.)*"|[^\s()]+')
MONTH = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()


def parts_from_structure(line):
    """Return leaf calendar section numbers and their transfer encodings."""
    match = re.search(rb'\bBODYSTRUCTURE\s+(?=\()', line, re.I)
    if not match:
        return []
    stack = []
    root = None
    for token in TOKEN.findall(line[match.end():]):
        if token == b"(":
            if len(stack) == 24:
                raise ValueError("MIME structure too deep")
            branch = []
            if stack:
                stack[-1].append(branch)
            stack.append(branch)
        elif token == b")":
            if not stack:
                raise ValueError("Invalid MIME structure")
            root = stack.pop()
            if not stack:
                break
        elif stack:
            stack[-1].append(token.strip(b'"').lower())
    if stack or not root:
        raise ValueError("Invalid MIME structure")

    def walk(node, prefix=""):
        if not node:
            return
        if isinstance(node[0], list):
            for i, child in enumerate(node, 1):
                if not isinstance(child, list):
                    break
                yield from walk(child, f"{prefix}.{i}" if prefix else str(i))
            return
        if len(node) < 7:
            return
        params = node[2] if isinstance(node[2], list) else []
        disposition = next((v for v in node[7:] if isinstance(v, list) and len(v) > 1 and
                            v[0] in (b"attachment", b"inline") and isinstance(v[1], list)), None)
        names = params + (disposition[1] if disposition else [])
        named = any(key in (b"name", b"filename") and isinstance(value, bytes) and value.endswith(b".ics")
                    for key, value in zip(names[::2], names[1::2]))
        if node[:2] in ([b"text", b"calendar"], [b"application", b"ics"]) or named:
            if not isinstance(node[6], bytes) or not node[6].isdigit():
                raise ValueError("Invalid calendar part size")
            yield prefix or "1", node[5], int(node[6])
    return list(walk(root))


def read_mailbox(mail, now, *, deadline):
    def check_time():
        remaining = deadline - monotonic()
        if remaining <= 0:
            raise TimeoutError("Mailbox sync timed out")
        if getattr(mail, "sock", None):
            mail.sock.settimeout(min(8, remaining))

    def command(operation, *args):
        check_time()
        status, data = mail.uid(operation, *args)
        if status != "OK":
            raise imaplib.IMAP4.error("Mailbox command refused")
        return data

    _, values = mail.response("UIDNEXT")
    if not values or not values[0] or not values[0].isdigit():
        raise HTTPException(502, "The mailbox did not supply the next message UID.")
    next_uid = int(values[0])
    if next_uid <= 1:
        return {"items": [], "note": "No recent invites found."}
    begin = now - timedelta(days=60)
    since = f"{begin.day:02d}-{MONTH[begin.month - 1]}-{begin.year}"
    found = command("SEARCH", None, "UID", f"{max(1, next_uid - SEARCH_WINDOW)}:{next_uid - 1}", "SINCE", since)
    available = sorted({int(v) for row in found if isinstance(row, bytes) for v in row.split()
                        if v.isdigit() and max(1, next_uid - SEARCH_WINDOW) <= int(v) < next_uid})
    uids = available[-MESSAGE_LIMIT:]
    # Start with the newest notices so a cancellation is seen even in a busy folder.
    notices = Calendar()
    notices.add("version", "2.0")
    warnings = []
    if len(available) > MESSAGE_LIMIT:
        warnings.append("Checked the newest 60 matching messages.")
    if not uids:
        return {"items": [], "note": "No recent invites found."}
    structures = command("FETCH", ",".join(map(str, uids)), "(UID BODYSTRUCTURE)")
    candidates = []
    for line in structures:
        if not isinstance(line, bytes):
            warnings.append("A MIME structure could not be read.")
            continue
        uid = re.search(rb'\bUID\s+(\d+)\b', line, re.I)
        if not uid or int(uid[1]) not in uids:
            continue
        try:
            candidates.extend((int(uid[1]), part, encoding, size) for part, encoding, size in parts_from_structure(line))
        except ValueError:
            warnings.append("An invalid MIME structure was skipped.")
    if len(candidates) > PART_COUNT:
        warnings.append("Checked the newest 30 invite parts.")
    for uid, part, encoding, size in sorted(sorted(candidates, reverse=True)[:PART_COUNT]):
        if size > PART_LIMIT:
            warnings.append("An invite exceeded the attachment size limit.")
            continue
        payload = command("FETCH", str(uid), f"(UID BODY.PEEK[{part}]<0.{PART_LIMIT + 1}>)")
        raw = next((chunk[1] for chunk in payload if isinstance(chunk, tuple) and isinstance(chunk[1], bytes)), None)
        if raw is None or len(raw) != size or len(raw) > PART_LIMIT:
            warnings.append("An incomplete invite was skipped.")
            continue
        try:
            if encoding == b"base64":
                raw = base64.b64decode(b"".join(raw.split()), validate=True)
            elif encoding == b"quoted-printable":
                raw = quopri.decodestring(raw)
            elif encoding not in (b"7bit", b"8bit", b"binary"):
                raise ValueError("Unknown transfer encoding")
            calendar = Calendar.from_ical(raw)
            if not isinstance(calendar, Calendar):
                raise ValueError("Missing calendar")
            for event in calendar.walk("VEVENT"):
                if str(calendar.get("method", "")).upper() == "CANCEL":
                    event["STATUS"] = "CANCELLED"
                notices.add_component(event)
        except (ValueError, binascii.Error, UnicodeError, TypeError):
            warnings.append("An invalid calendar attachment was skipped.")
    result = calendar_file(notices.to_ical().decode("utf-8"))
    result["items"] = [item for item in result["items"] if item["start"][:10] >= now.date().isoformat()]
    result["note"] = " ".join(dict.fromkeys([result["note"], *warnings])).strip()
    return result


def sync_imap():
    """The endpoint accepts no hostname or credentials from the browser."""
    host, user, password = (setting(name) for name in ("IMAP_HOST", "IMAP_USERNAME", "IMAP_PASSWORD"))
    folder = os.getenv("IMAP_FOLDER", "INBOX")
    if not folder or any(ch in folder for ch in ('"', '\\', '\r', '\n')) or not folder.isascii():
        raise HTTPException(503, "Set IMAP_FOLDER to a valid ASCII mailbox name.")
    try:
        port = int(os.getenv("IMAP_PORT", "993"))
        if not 0 < port <= 65535:
            raise ValueError()
    except ValueError as error:
        raise HTTPException(503, "Set a valid IMAP_PORT.") from error
    deadline = monotonic() + 45
    try:
        with imaplib.IMAP4_SSL(host, port, ssl_context=ssl.create_default_context(), timeout=8) as mail:
            mail.login(user, password)
            status, _ = mail.select(f'"{folder}"', readonly=True)
            if status != "OK":
                raise HTTPException(502, "The configured mailbox folder could not be opened.")
            return read_mailbox(mail, datetime.now(timezone.utc), deadline=deadline)
    except TimeoutError as error:
        raise HTTPException(504, "Mailbox sync timed out.") from error
    except (imaplib.IMAP4.error, OSError) as error:
        raise HTTPException(502, "Mailbox connection, authentication or invite retrieval failed.") from error
