import base64
from datetime import datetime, timezone
from time import monotonic
from unittest.mock import patch

from fastapi import HTTPException
import pytest

from api import mailbox


def invite(subject, seq=0, method="REQUEST"):
    return ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//example//EN\r\n"
            f"METHOD:{method}\r\nBEGIN:VEVENT\r\nUID:stable@fake\r\nSEQUENCE:{seq}\r\n"
            f"DTSTART:20270103T170000Z\r\nSUMMARY:{subject}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n").encode()


class Mail:
    def __init__(self, notices, *, fail=None):
        self.commands = []
        self.notices = {400 + i: base64.b64encode(data) for i, data in enumerate(notices)}
        self.fail = fail
        self.sock = None

    def response(self, key):
        assert key == "UIDNEXT"
        return "UIDNEXT", [b"801"]

    def uid(self, operation, *args):
        self.commands.append((operation, args))
        if operation == self.fail:
            return "NO", []
        if operation == "SEARCH":
            assert args == (None, "UID", "301:800", "SINCE", "02-Nov-2026")
            return "OK", [" ".join(map(str, self.notices)).encode()]
        if args[-1] == "(UID BODYSTRUCTURE)":
            rows = []
            for uid, raw in self.notices.items():
                leaf = f'("TEXT" "CALENDAR" NIL NIL NIL "BASE64" {len(raw)} 2)'
                body = f'(("TEXT" "PLAIN" NIL NIL NIL "7BIT" 14 2){leaf} "MIXED")'
                rows.append(f'1 (UID {uid} BODYSTRUCTURE {body})'.encode())
            return "OK", rows
        assert args[-1] == f"(UID BODY.PEEK[2]<0.{mailbox.PART_LIMIT + 1}>)"
        return "OK", [(b"literal", self.notices[int(args[0])]), b")"]


NOW = datetime(2027, 1, 1, tzinfo=timezone.utc)


def test_invite_parts_only_and_latest_update():
    mail = Mail([invite("First", 0), invite("Updated", 1)])
    response = mailbox.read_mailbox(mail, NOW, deadline=monotonic() + 45)
    assert [event["title"] for event in response["items"]] == ["Updated"]
    assert len(mail.commands) == 4


def test_cancellation_across_emails_removes_interview():
    result = mailbox.read_mailbox(Mail([invite("First"), invite("Cancelled", 1, "CANCEL")]), NOW,
                                  deadline=monotonic() + 45)
    assert result["items"] == []


def test_structure_accepts_ics_attachment_without_accessing_other_body_parts():
    line = b'2 (UID 2 BODYSTRUCTURE ("APPLICATION" "OCTET-STREAM" NIL NIL NIL "BASE64" 100 NIL ("attachment" ("filename" "event.ics"))))'
    assert mailbox.parts_from_structure(line) == [("1", b"base64", 100)]


def test_connection_is_tls_and_folder_is_read_only(monkeypatch):
    for key, value in {"IMAP_HOST": "imap.fake", "IMAP_USERNAME": "example", "IMAP_PASSWORD": "mock"}.items():
        monkeypatch.setenv(key, value)
    with patch("api.mailbox.imaplib.IMAP4_SSL") as connect:
        mail = connect.return_value.__enter__.return_value
        mail.select.return_value = ("OK", [b"0"])
        mail.response.return_value = ("UIDNEXT", [b"1"])
        assert mailbox.sync_imap()["items"] == []
        mail.select.assert_called_once_with('"INBOX"', readonly=True)
        assert connect.call_args.kwargs["ssl_context"].check_hostname
        assert connect.call_args.kwargs["timeout"] == 8


def test_partial_and_malformed_calendar_warn():
    result = mailbox.read_mailbox(Mail([b"not a calendar"]), NOW, deadline=monotonic() + 45)
    assert result["items"] == []
    assert "skipped" in result["note"]


def test_deadline_and_invalid_configuration(monkeypatch):
    with pytest.raises(TimeoutError):
        mailbox.read_mailbox(Mail([invite("First")]), NOW, deadline=monotonic() - 1)
    for key in ("IMAP_HOST", "IMAP_USERNAME", "IMAP_PASSWORD"):
        monkeypatch.setenv(key, "fake")
    monkeypatch.setenv("IMAP_PORT", "65536")
    with pytest.raises(HTTPException) as error:
        mailbox.sync_imap()
    assert error.value.status_code == 503
