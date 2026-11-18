"""Compare normalized word sequences and return the two original passages."""
from collections import Counter
from dataclasses import dataclass
import re
import unicodedata

from .models import Reference

WORD = re.compile(r"[^\W_]+(?:['’][^\W_]+)*", re.UNICODE)
MIN_RUN = 6
MAX_EXCERPT = 36
STOP = frozenset(
    "a an the and or but of in at by to for with from is are was were be been "
    "it its that this those these i we you he she they my our your their would "
    "could should will can have has had as if so then yes do does just about "
    "really think thing things how why what which on".split()
)


@dataclass
class Words:
    text: str

    def __post_init__(self):
        parts = list(WORD.finditer(self.text))
        self.spans = [m.span() for m in parts]
        self.tokens = [unicodedata.normalize("NFKC", m[0]).casefold().replace("’", "'") for m in parts]

    def grams(self, size):
        return (tuple(self.tokens[pos:pos + size]) for pos in range(len(self.tokens) - size + 1))

    def excerpt(self, start, length):
        return self.text[self.spans[start][0]:self.spans[start + length - 1][1]]


def mask_grams(words, size, grams):
    """Exclude every answer token covered by a question, permitted or shared passage."""
    mask = set()
    for pos, gram in enumerate(words.grams(size)):
        if gram in grams:
            mask.update(range(pos, pos + size))
    return mask


# These words can appear in a recording without identifying a claim to examine.
VAGUE = STOP | set(
    "am i'm i'd i've don't didn't can't didn't the not no yes good great question "
    "answer sure know maybe well really quite actually basically perhaps um uh er "
    "thank thanks okay ok let me see depends something anything nothing very "
    "say saying mean remember sorry probably much right guess".split()
)


def probe(question, spoken):
    prompt_words = set(Words(question).tokens)
    best = None
    # Prefer a short literal clause with concrete words beyond the prompt.
    # Offsets into the original transcript keep model paraphrases out of the probe.
    for clause in re.split(r"(?<=[.!?;])\s+|\n+", spoken.text):
        words = Words(clause)
        content = [i for i, token in enumerate(words.tokens) if token not in VAGUE and len(token) > 2]
        distinct = {words.tokens[i] for i in content}
        new = distinct - prompt_words
        if len(distinct) < 2 or not new or len(words.tokens) < 3:
            continue
        start = max(0, content[0] - 3)
        sample = words.excerpt(start, min(18, len(words.tokens) - start))
        rank = (min(len(new), 6), min(len(distinct), 8))
        if best is None or rank > best[0]:
            best = (rank, sample)
    if best:
        return f'You said “{best[1]}”. Walk me through a concrete example and explain the choice you made.'
    return "Which assumption in your answer matters most? Walk through what changes if it fails."


def compare(question: str, answer: str, references: list[Reference]) -> dict:
    spoken = Words(answer)
    sources = [(ref.label, Words(ref.text)) for ref in references if not ref.permitted]
    usable = [(label, words) for label, words in sources if len(words.tokens) >= MIN_RUN]
    result = {
        "status": "insufficient",
        "explanation": "Supply a comparison source with at least six words.",
        "passages": [],
        "follow_up": probe(question, spoken),
    }
    if len(spoken.tokens) < MIN_RUN:
        result["explanation"] = "The answer contains fewer than six words. Ask for a worked example."
        return result
    if not usable:
        return result

    allowed = set(Words(question).grams(4))
    for ref in references:
        if ref.permitted:
            allowed.update(Words(ref.text).grams(4))
    excluded = mask_grams(spoken, 4, allowed)
    owners = Counter()
    for _, source in usable:
        owners.update(set(source.grams(MIN_RUN)))
    common = {gram for gram, count in owners.items() if count > 1}
    excluded.update(mask_grams(spoken, MIN_RUN, common))

    matches = []
    for label, source in usable:
        # Ambiguous repeated seeds within one source are omitted. Adjacent unique
        # seeds merge only when both answer and reference offsets advance together.
        seeds = {}
        for pos, gram in enumerate(source.grams(MIN_RUN)):
            if owners[gram] == 1 and len(set(gram) - STOP) >= 3:
                seeds[gram] = pos if gram not in seeds else None
        segments = []
        for pos, gram in enumerate(spoken.grams(MIN_RUN)):
            start = seeds.get(gram)
            if start is None or any(i in excluded for i in range(pos, pos + MIN_RUN)):
                continue
            if segments:
                a, b, length = segments[-1]
                if pos - a == start - b and pos <= a + length:
                    segments[-1] = (a, b, pos - a + MIN_RUN)
                    continue
            segments.append((pos, start, MIN_RUN))
        matches.extend((length, pos, start, label, source) for pos, start, length in segments)

    result.update(status="no_match", explanation="No eligible shared passage was found in the supplied sources.")
    if not matches:
        return result
    reported = set()
    for length, pos, start, label, source in sorted(matches, key=lambda item: (-item[0], item[1])):
        # Suppress reuse of a single source passage repeated in the answer.
        key = (label, start, length)
        if key in reported:
            continue
        reported.add(key)
        shown = min(length, MAX_EXCERPT)
        result["passages"].append({
            "label": label, "words": length,
            "answer_excerpt": spoken.excerpt(pos, shown), "source_excerpt": source.excerpt(start, shown),
        })
        if len(result["passages"]) == 3:
            break
    result.update(status="match", explanation="The quoted words also occur in the named source. Ask how the candidate arrived at this answer.")
    anchor = result["passages"][0]["answer_excerpt"].split()[:12]
    result["follow_up"] = f'You said “{" ".join(anchor)}”. Which part would you change under a different constraint, and why?'
    return result
