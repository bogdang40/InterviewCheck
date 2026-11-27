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
    """Resolve undecided receipts in the caller's transaction and preserve witnessed conflicts."""
    # Select timestamps only. Historical narrative text must not enter a diagnostic or leave SQLite.
    where = "AND x.session_id=?" if session_id is not None else ""
    params = (session_id,) if session_id is not None else ()
    cutoff = lru_cache(maxsize=128)(_instant)
    held = set()
    tables = {row[0] for row in db.execute("""SELECT name FROM sqlite_master WHERE type='table'
               AND name IN ('session_handoff_notes','session_scorecards')""")}
    for table, field, recorded in (("session_handoff_notes", "body", "created_at"),
                                   ("session_scorecards", "rationale", "updated_at")):
        if table not in tables:
            continue
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
    if held:
        db.executemany("""INSERT INTO retention_read_holds(session_id,needs_timestamp_check) VALUES(?,0)
                          ON CONFLICT(session_id) DO UPDATE SET needs_timestamp_check=0
                          WHERE retention_read_holds.needs_timestamp_check=1""", ((sid,) for sid in held))
    # A receipt can be inserted by an older writer, before this checker runs. Only clear
    # its provisional hold after examining its stored prose. A later write witnessed by
    # the database remains a conflict even when its client supplied an earlier timestamp.
    scope = "AND session_id=?" if session_id is not None else ""
    db.execute(f"""DELETE FROM retention_read_holds WHERE needs_timestamp_check=1 {scope}
                   AND EXISTS (SELECT 1 FROM session_anonymizations x WHERE x.session_id=retention_read_holds.session_id)""",
               params)
