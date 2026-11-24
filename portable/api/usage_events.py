"""Daily usage counters behind the admin Usage tab.

Public page visits are counted per UTC day. A visitor is known only by a hash of their address
and browser mixed with a random salt that is replaced every day, so no address is stored and the
same person cannot be followed from one day to the next. Workspace events are plain daily counts.
"""
from datetime import datetime, timedelta, timezone
import hashlib
import re
import secrets

from . import sql_script

SCHEMA = """
CREATE TABLE IF NOT EXISTS usage_daily (
 day TEXT NOT NULL,
 kind TEXT NOT NULL,
 visitor TEXT NOT NULL DEFAULT '',
 count INTEGER NOT NULL DEFAULT 0 CHECK (count >= 0),
 PRIMARY KEY (day, kind, visitor)
);
CREATE INDEX IF NOT EXISTS idx_usage_daily_kind ON usage_daily(kind, day);
CREATE TABLE IF NOT EXISTS usage_salt (
 day TEXT PRIMARY KEY,
 salt TEXT NOT NULL
);
"""

PAGES = ("home", "sample", "signin")
# Link previews, crawlers, uptime checks and scripted browsers are not visitors.
AUTOMATED = re.compile(
    r"bot|crawl|spider|slurp|preview|facebookexternalhit|embedly|curl|wget|python|httpx|go-http|java/|"
    r"okhttp|headless|lighthouse|monitor|uptime|pingdom|scan",
    re.IGNORECASE,
)
VIEW_CAP = 50  # page views counted per visitor, page and day
KEEP_DAYS = 400


def migrate(db) -> None:
    sql_script.execute(db, SCHEMA)


def today() -> str:
    return datetime.now(timezone.utc).date().isoformat()


def since(days: int) -> str:
    """First UTC day of a window that ends today and spans `days` days."""
    return (datetime.now(timezone.utc).date() - timedelta(days=days - 1)).isoformat()


def bump(db, kind: str, amount: int = 1) -> None:
    db.execute(
        """INSERT INTO usage_daily(day,kind,visitor,count) VALUES (?,?,'',?)
           ON CONFLICT(day,kind,visitor) DO UPDATE SET count=count+excluded.count""",
        (today(), kind, amount),
    )


def _salt(db, day: str) -> str:
    row = db.execute("SELECT salt FROM usage_salt WHERE day=?", (day,)).fetchone()
    if row:
        return row[0]
    # A new day: forget yesterday's salt so earlier visitor hashes can never be matched again.
    db.execute("DELETE FROM usage_salt WHERE day<>?", (day,))
    cutoff = since(KEEP_DAYS)
    db.execute("DELETE FROM usage_daily WHERE day<?", (cutoff,))
    salt = secrets.token_hex(16)
    db.execute("INSERT OR IGNORE INTO usage_salt(day,salt) VALUES (?,?)", (day, salt))
    return db.execute("SELECT salt FROM usage_salt WHERE day=?", (day,)).fetchone()[0]


def is_automated(user_agent: str) -> bool:
    return not user_agent.strip() or bool(AUTOMATED.search(user_agent))


def record_visit(db, page: str, address: str, user_agent: str) -> bool:
    """Count one public page view. Returns False when the request is not counted."""
    if page not in PAGES or is_automated(user_agent):
        return False
    day = today()
    digest = hashlib.sha256(f"{_salt(db, day)}\n{address}\n{user_agent[:300]}".encode()).hexdigest()[:16]
    db.execute(
        """INSERT INTO usage_daily(day,kind,visitor,count) VALUES (?,?,?,1)
           ON CONFLICT(day,kind,visitor) DO UPDATE SET count=MIN(count+1,?)""",
        (day, f"visit:{page}", digest, VIEW_CAP),
    )
    return True


def daily_counts(db, first_day: str) -> dict[str, dict[str, int]]:
    """{day: {kind: count}} for workspace counters, and visitors/views per public page."""
    out: dict[str, dict[str, int]] = {}
    rows = db.execute(
        """SELECT day, kind, COUNT(*) AS visitors, SUM(count) AS total FROM usage_daily
           WHERE day>=? GROUP BY day, kind""",
        (first_day,),
    ).fetchall()
    for row in rows:
        day, kind = row[0], row[1]
        bucket = out.setdefault(day, {})
        if kind.startswith("visit:"):
            bucket[kind] = int(row[2])
            bucket[kind + ":views"] = int(row[3])
        else:
            bucket[kind] = int(row[3])
    for day, visitors in db.execute(
        """SELECT day, COUNT(DISTINCT visitor) FROM usage_daily
           WHERE day>=? AND kind LIKE 'visit:%' GROUP BY day""",
        (first_day,),
    ).fetchall():
        out.setdefault(day, {})["visitors"] = int(visitors)
    return out


def tracking_since(db) -> str | None:
    row = db.execute("SELECT MIN(day) FROM usage_daily").fetchone()
    return row[0] if row and row[0] else None
