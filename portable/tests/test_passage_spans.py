from api.evidence import compare
from api.models import Reference


def test_unicode_spans_locate_entire_match_in_answer_and_correct_source():
    phrase = "Monitor saturation across neighboring routers before altering queue limits"
    answer = "🙂 At first: " + phrase + "."
    refs = [
        Reference(label="Notes", text="A permitted reference about network monitoring.", permitted=True),
        Reference(label="Notes", text="⚙️ Trial: " + phrase + "!"),
    ]
    (passage,) = compare("Which test?", answer, refs)["passages"]
    assert passage["source_index"] == 1
    assert answer[slice(*passage["answer_span"])] == phrase
    assert refs[1].text[slice(*passage["source_span"])] == phrase


def test_truncated_excerpt_highlights_full_recorded_run():
    answer = " ".join(f"component{i}" for i in range(50))
    (passage,) = compare("Describe the assembly", answer, [Reference(label="Sequence", text=answer)])[
        "passages"
    ]
    assert passage["words"] == 50 and len(passage["answer_excerpt"].split()) == 36
    assert answer[slice(*passage["answer_span"])] == answer
