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


def _invalid_members(obj, allowed):
    # Unknown and repeated keys must not let Python's last-key-wins decoding see a
    # different value from the first selection made by SQLite's JSON path.
    keys = ",".join(f"'{key}'" for key in allowed)
    return f"""EXISTS (SELECT 1 FROM json_each({obj}) m GROUP BY m.key
                       HAVING count(*)!=1 OR m.key NOT IN ({keys}))"""


def _invalid_span(name):
    path = f"$.{name}"
    return f"""(coalesce(json_type(p.value,'{path}'),'null')!='null' AND (
        json_type(p.value,'{path}')!='array' OR json_array_length(p.value,'{path}')!=2
        OR json_type(p.value,'{path}[0]') IS NOT 'integer' OR json_type(p.value,'{path}[1]') IS NOT 'integer'
        OR json_extract(p.value,'{path}[0]')<0 OR json_extract(p.value,'{path}[1]')<=json_extract(p.value,'{path}[0]')))"""


_TOP_KEYS = ("status", "explanation", "passages", "follow_up", "archived")
_PASSAGE_KEYS = ("label", "words", "answer_excerpt", "source_excerpt", "source_index", "answer_span", "source_span")
_INVALID_PASSAGE = f"""(
    {_invalid_members('p.value', _PASSAGE_KEYS)}
    OR json_type(p.value,'$.answer_excerpt') IS NOT 'text' OR json_extract(p.value,'$.answer_excerpt') IS NOT :rf_mask
    OR json_type(p.value,'$.source_excerpt') IS NOT 'text' OR length(json_extract(p.value,'$.source_excerpt'))>24000
    OR json_type(p.value,'$.label') IS NOT 'text' OR length(json_extract(p.value,'$.label'))>180
    OR json_type(p.value,'$.words') IS NOT 'integer' OR json_extract(p.value,'$.words') NOT BETWEEN 1 AND 24000
    OR coalesce(json_type(p.value,'$.source_index'),'null') NOT IN ('integer','null')
    OR coalesce(json_extract(p.value,'$.source_index'),0)<0
    OR {_invalid_span('answer_span')} OR {_invalid_span('source_span')}
)"""
# A literal backslash followed by u0000 is valid source wording. Remove paired
# backslash escapes before checking for a real JSON null-character escape.
_ENCODED_NUL = r"instr(replace(r.result,'\\',''),'\u0000')>0"
FINDING_PARAMS = {**TEXT_PARAMS, "rf_mask": REDACTED_TEXT}
UNSAFE_FINDING_SQL = f"""(
    json_type(r.result) IS NOT 'object' OR {_invalid_members('r.result', _TOP_KEYS)} OR {_ENCODED_NUL}
    OR json_type(r.result,'$.status') IS NOT 'text' OR json_extract(r.result,'$.status') NOT IN ('insufficient','match','no_match')
    OR coalesce(json_type(r.result,'$.archived'),'null') NOT IN ('null','true','false')
    OR {UNSAFE_TEXT_SQL}
    OR json_type(r.result,'$.passages') IS NOT 'array' OR json_array_length(r.result,'$.passages')>3
    OR EXISTS (SELECT 1 FROM json_each(r.result,'$.passages') p
               WHERE CASE WHEN p.type='object' THEN {_INVALID_PASSAGE} ELSE 1 END)
)"""


def portable_answer(answer):
    """Describe the retained marker instead of claiming an unverifiable original comparison.

    The old scrubber left the original status, source offsets and word counts in SQLite.
    A native archive could also retain its fixed finding after the native payload was erased.
    Preserve the source database, and recompute only the download representation.
    """
    from .evidence import compare

    result = answer["result"]
    if (not recognized_text(result["explanation"], result["follow_up"]) or
            any(p["answer_excerpt"] != REDACTED_TEXT for p in result["passages"])):
        raise ValueError("Unrecognized retained finding.")
    state = result["status"]
    explanation = result["explanation"]
    archived = bool(result.get("archived"))
    if archived:
        historical = (state == "insufficient" and not result["passages"]
                      and (explanation, result["follow_up"]) == _NATIVE)
    elif state == "match":
        historical = explanation == _MATCH and bool(result["passages"])
    elif state == "no_match":
        historical = explanation == _NO_MATCH and not result["passages"]
    else:
        historical = state == "insufficient" and explanation in {_SHORT, _NO_SOURCE} and not result["passages"]
    if not historical:
        raise ValueError("Inconsistent retained finding.")
    out = dict(answer)
    if archived or state != "insufficient" or explanation != _SHORT:
        out["result"] = compare(answer["question"], REDACTED_TEXT, [])
    # The older writer erased the disclosure note but kept its disposition.
    if out["disposition"] == "disclosed" and not out["note"]:
        out["disposition"] = "pending"
    return out
