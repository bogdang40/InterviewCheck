"""Check when nonempty handoff notes and grade rationales were recorded against confirmed erasure."""
from datetime import datetime
from decimal import Decimal, localcontext
from functools import lru_cache
from itertools import chain
import re


_FRACTION_TAIL = re.compile(r"[.,][0-9]{6}([0-9]+)$")


def _instant(stamp: str) -> Decimal:
    """Represent an aware ISO timestamp exactly, including fractional seconds beyond six digits."""
    if not isinstance(stamp, str) or len(stamp) > 64:
        raise ValueError("Unsupported narrative timestamp.")
    value = datetime.fromisoformat(stamp)
    offset = value.utcoffset()
    if offset is None:
        raise ValueError("Timezone required.")

    # fromisoformat validates the calendar, time and offset. It truncates submicrosecond digits.
    # Recover those digits without converting through a float or SQLite's millisecond date functions.
    if stamp.endswith("Z"):
        clock, zone_fraction, sign = stamp[:-1], "", 1
    else:
        boundary = max(stamp.rfind("+"), stamp.rfind("-"))
        clock, zone = stamp[:boundary], stamp[boundary + 1:]
        sign = 1 if stamp[boundary] == "+" else -1
        zone_fraction = zone.replace(",", ".").partition(".")[2].rstrip("0")
    tail = _FRACTION_TAIL.search(clock)
    clock_fraction = (f"{value.microsecond:06d}" + (tail[1] if tail else "")).rstrip("0")
    seconds = value.toordinal() * 86400 + value.hour * 3600 + value.minute * 60 + value.second
    seconds -= sign * abs(offset).seconds
    with localcontext() as context:
        context.prec = 16 + max(len(clock_fraction), len(zone_fraction))
        return Decimal(seconds) + Decimal("0." + (clock_fraction or "0")) - sign * Decimal("0." + (zone_fraction or "0"))


def verify_archive(session):
    recorded = chain((n.created_at for n in session.handoff_notes if n.body),
                     (g.updated_at for g in session.scorecard_items if g.rationale))
    cutoff = None
    for stamp in recorded:
        if cutoff is None:
            cutoff = _instant(session.privacy.anonymized_at)
        if _instant(stamp) > cutoff:
            raise ValueError("The archive contains private narrative text recorded after confirmed anonymization.")


def refresh(db, session_id: str | None = None) -> None:
    """Add read holds in the caller's transaction. Restrict work to a new receipt when given its session."""
    # Select timestamps only. Historical narrative text must not enter a diagnostic or leave SQLite.
    where = "AND x.session_id=?" if session_id is not None else ""
    params = (session_id,) if session_id is not None else ()
    cutoff = lru_cache(maxsize=128)(_instant)
    held = set()
    for table, field, recorded in (("session_handoff_notes", "body", "created_at"),
                                   ("session_scorecards", "rationale", "updated_at")):
        for sid, receipt, entry in db.execute(f"""SELECT x.session_id,x.anonymized_at,n.{recorded}
                    FROM session_anonymizations x JOIN {table} n ON n.session_id=x.session_id
                    WHERE n.{field}<>'' {where}""", params):
            if sid in held:
                continue
            try:
                unsafe = _instant(entry) > cutoff(receipt)
            except (TypeError, ValueError, OverflowError):
                unsafe = True  # A damaged clock cannot attest that this text predates erasure.
            if unsafe:
                held.add(sid)
    db.executemany("INSERT OR IGNORE INTO retention_read_holds(session_id) VALUES(?)", ((sid,) for sid in held))
