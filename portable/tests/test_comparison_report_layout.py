"""The two dossier representations keep per-interview identities and exact cross-candidate counts."""
from html import escape
from itertools import groupby
from xml.etree import ElementTree

import pytest

from api import exports, report, store
from backup_requests import client


LABELS = ("Captured answers", "Answers with a passage match", "Answers without a passage match",
          "Answers with limited evidence", "Pending dispositions", "Explained dispositions",
          "Unresolved dispositions", "Disclosed dispositions")
EXCERPT = "Private synthetic answer wording about measuring an isolated reference clock."
NOTE = "Private synthetic reviewer note."
RATIONALE = "Private synthetic rubric rationale."


def seed(client, size):
    records = []
    for i in range(size):
        name = "Duplicate <reviewer> |" if i < 2 else "N" * 180
        role = "R" * 180
        policy = f"Policy for interview {i}\n" + "X" * 3900 + " <end>"
        response = client.post("/api/sessions", json={"candidate": name, "role": role, "policy": policy, "consent": True})
        session = response.raise_for_status().json()
        sid = session["id"]
        if i == size - 1:
            # A retained historical interview can lack a candidate name and policy.
            with store.connection(write=True) as db:
                db.execute("UPDATE sessions SET candidate='', policy='' WHERE id=?", (sid,))
            name, policy = "Unnamed candidate", "No policy recorded."
        counts = [0] * len(LABELS)
        question = f"Question for fixture {i}?"
        for j in range(i + 1):
            evidence = (i + j) % 3
            reference = EXCERPT if evidence == 0 else "The kernel hashes network packets before delivering them."
            answer = client.post(f"/api/sessions/{sid}/answers", json={
                "question": question, "answer": EXCERPT,
                "references": [] if evidence == 2 else [{"label": "Reference", "text": reference}],
            }).raise_for_status().json()
            assert answer["result"]["status"] == ("match", "no_match", "insufficient")[evidence]
            outcome = (i + j) % 4
            if outcome:
                client.patch(f"/api/sessions/{sid}/answers/{answer['id']}", json={
                    "disposition": ("pending", "explained", "unresolved", "disclosed")[outcome], "note": NOTE,
                }).raise_for_status()
            counts[0] += 1
            counts[evidence + 1] += 1
            counts[outcome + 4] += 1
        records.append({"id": sid, "name": name, "role": role, "policy": policy, "question": question, "counts": counts})
    client.put(f"/api/sessions/{records[0]['id']}/scorecard", json={"items": [{
        "criterion_id": "fixture", "criterion_label": "Long" + "L" * 196, "weight": 3, "rating": 4, "rationale": RATIONALE,
    }]}).raise_for_status()
    return records[::-1]


def markdown_tables(text):
    tables = []
    for is_table, lines in groupby(text.splitlines(), lambda line: line.startswith("|")):
        if is_table:
            rows = [[cell.strip() for cell in line.strip("|").split("|")] for line in lines]
            tables.append([rows[0], *rows[2:]])
    return tables


@pytest.mark.parametrize("size", [4, 6])
def test_dossier_identity_and_metric_grids_match_in_html_markdown_and_print(client, size):
    records = seed(client, size)
    ids = [record["id"] for record in records]
    query = {"session_ids": ids}
    endpoint = "/api/interviews/compare"
    md = client.post(endpoint + "/dossier", json={**query, "format": "markdown"}).raise_for_status().text
    html = client.post(endpoint + "/dossier", json={**query, "format": "html"}).raise_for_status()
    printed = client.get(endpoint + "/print", params={"ids": ",".join(ids)}).raise_for_status()
    assert printed.text == html.text
    assert printed.headers["cache-control"] == html.headers["cache-control"] == "no-store"
    csp = printed.headers["content-security-policy"]
    assert exports.PRINT_STYLE_HASH in csp and "script-src 'self'" in csp and "'unsafe-inline'" not in csp
    # The comparison main is a self-contained fragment with escaped user values.
    main = ElementTree.fromstring("<main" + html.text.split("<main", 1)[1].split("</main>", 1)[0] + "</main>")
    assert main.attrib["class"] == "comparison-report"
    identities = main.findall("./section[@class='candidate-identities']/article")
    titles = [f"Interview {i} · {record['name']}" for i, record in enumerate(records, 1)]
    assert [article.findtext("h3") for article in identities] == titles
    html_tables = main.findall("./section[@class='comparison-counts']/table")
    text_tables = markdown_tables(md)
    assert len(html_tables) == len(text_tables) == 2
    for group_index, table in enumerate(html_tables):
        start = group_index * 3
        group = records[start:start + 3]
        headers = ["Measure", *[f"Interview {n}" for n in range(start + 1, start + len(group) + 1)]]
        rows = [[label, *[str(record["counts"][i]) for record in group]] for i, label in enumerate(LABELS)]
        columns = table.findall("thead/tr/th[@scope='col']")
        assert ["".join(th.itertext()) for th in columns] == headers
        for column, header, number in zip(columns[1:], headers[1:], range(start + 1, start + len(group) + 1)):
            assert column.get("aria-label") == header
            prefix = column.find("span[@class='interview-prefix']")
            assert prefix is not None and prefix.text == "Interview " and prefix.tail == str(number)
        assert [[tr.findtext("th[@scope='row']"), *[td.text for td in tr.findall("td")]]
                for tr in table.findall("tbody/tr")] == rows
        assert text_tables[group_index] == [headers, *rows]

    slots = main.findall("./section")[-1]
    for record, title, article in zip(records, titles, identities):
        assert record["id"] not in html.text
        assert record["id"] in md and report.heading(title) in md
        assert record["role"] in article.itertext() and record["policy"] in article.itertext()
        assert report.literal(record["policy"]) in md
        owner = next(block for block in slots.findall("article") if record["question"] in "".join(block.itertext()))
        assert owner.findtext("div/h3") == title
    for content in [html.text, md]:
        assert all(private not in content for private in (EXCERPT, NOTE, RATIONALE))

    flags = {"include_excerpts": True, "include_notes": True, "include_scorecards": True, "include_rationales": True}
    full_md = client.post(endpoint + "/dossier", json={**query, **flags, "format": "markdown"}).raise_for_status().text
    full_html = client.get(endpoint + "/print", params={"ids": ",".join(ids), **flags}).raise_for_status().text
    score_sections = [value.split("Saved interview scorecards", 1)[1].split("Question slot comparison", 1)[0]
                      for value in (full_md, full_html)]
    for title, record in zip(titles, records):
        assert f"### {report.heading(title)}\n\nInterview {record['id']}" in score_sections[0]
        assert f"<h3>{escape(title)}</h3><p>Interview {record['id']}</p>" in score_sections[1]
    for content in [full_md, full_html]:
        assert all(private in content for private in (EXCERPT, NOTE, RATIONALE))
