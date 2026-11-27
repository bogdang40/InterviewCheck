"""Exact finding wording produced by the historical scrubber and the current retention writer."""

from .retention_anonymizer import REDACTED_TEXT


# The original scrubber retained the matcher's explanation and nonquoted probe. It replaced
# every "You said" probe with the marker, including the mandatory quoted probe on a match.
_SHORT = "The answer contains fewer than six words. Ask for a worked example."
_NO_SOURCE = "Supply a comparison source with at least six words."
_NO_MATCH = "No eligible shared passage was found in the supplied sources."
_MATCH = "The quoted words also occur in the named source. Ask how the candidate arrived at this answer."
_FALLBACK = "Which assumption in your answer matters most? Walk through what changes if it fails."
# The later writer compares the marker itself. Its only possible quote is the marker's four words.
_MARKER_PROBE = "You said “Redacted by retention policy”. Walk me through a concrete example and explain the choice you made."
# An early native import has this fixed pair. Neither field contained a quote for the old scrubber to replace.
_NATIVE = ("Imported native record. The original assessment is available in the report.",
           "Review the original transcript and agreed resources before interpreting this record.")

_PAIRS = (
    (_SHORT, _MARKER_PROBE), (_SHORT, _FALLBACK), (_SHORT, REDACTED_TEXT),
    (_NO_SOURCE, _FALLBACK), (_NO_SOURCE, REDACTED_TEXT),
    (_NO_MATCH, _FALLBACK), (_NO_MATCH, REDACTED_TEXT),
    (_MATCH, REDACTED_TEXT), _NATIVE,
)


def recognized_text(explanation: str, follow_up: str) -> bool:
    return (explanation, follow_up) in _PAIRS


# The caller validates the JSON before evaluating this predicate. The same parameter values
# support parameterized recovery scans and SQLite-quoted constants in installed triggers.
TEXT_PARAMS = {f"rf_{index}_{field}": value for index, pair in enumerate(_PAIRS)
               for field, value in zip(("explanation", "probe"), pair)}
_SQL_PAIRS = ",".join(f"(:rf_{i}_explanation,:rf_{i}_probe)" for i in range(len(_PAIRS)))
UNSAFE_TEXT_SQL = f"""(
    json_type(r.result,'$.explanation') IS NOT 'text' OR json_type(r.result,'$.follow_up') IS NOT 'text'
    OR (SELECT count(*) FROM json_each(r.result) f WHERE f.key IN ('explanation','follow_up')) != 2
    OR instr(lower(r.result -> '$.explanation'),'\\u0000')>0 OR instr(lower(r.result -> '$.follow_up'),'\\u0000')>0
    OR (json_extract(r.result,'$.explanation') COLLATE BINARY, json_extract(r.result,'$.follow_up') COLLATE BINARY)
       NOT IN (VALUES {_SQL_PAIRS})
)"""
