"""Exercise fixed, synthetic interview conditions through the production matcher."""
from collections import Counter
import json
from pathlib import Path

from api.evidence import compare
from api.models import Reference


def run():
    fixture = json.loads((Path(__file__).parent / "evaluation/cases.json").read_text())
    counts = Counter()
    failed = []
    for case in fixture["cases"]:
        sources = [Reference(label=name, text=fixture["references"][name], permitted=permitted)
                   for field, permitted in (("compare", False), ("allowed", True)) for name in case.get(field, [])]
        result = compare(case["question"], case["answer"], sources)["status"]
        counts[case["condition"], result] += 1
        if result != case["expected"]:
            failed.append({"case": case["id"], "expected": case["expected"], "observed": result})
    return {"cases": len(fixture["cases"]), "conditions": {
        condition: {state: counts[condition, state] for state in ("match", "no_match", "insufficient")}
        for condition in ("outside", "independent", "permitted")}, "unexpected_results": failed}


if __name__ == "__main__":
    summary = run()
    print(json.dumps(summary, indent=2))
    raise SystemExit(bool(summary["unexpected_results"]))
