"""Synthetic interview records and browser observations for pending question handoff tests."""
from contextlib import closing, contextmanager
import hashlib
import sqlite3
from urllib.parse import urlsplit
from uuid import uuid4

from playwright.sync_api import expect

from e2e_suite.harness import signup_user

EMAIL = "handoff-reviewer@example.test"
PASSWORD = "Synthetic-handoff-browser-password"
SHARED = "¿Qué medición cambió tu decisión? Δ"
SECOND = "どの観測をもう一度確認しますか？"
PRIVATE = {
    "candidate": "Private candidate Q17", "role": "Private role Q18", "policy": "Private policy Q19",
    "source": "Private source Q20", "body": "Private permitted source body Q21",
    "note": "Private reviewer reasoning Q22", "draft": "Unrelated saved draft Q23",
    "grade": "Private criterion Q24", "rationale": "Private grade reasoning Q25",
}
HEADERS = {"X-InterviewCheck": "1"}


@contextmanager
def records(ws, page, count):
    ws.configure_embedded_auth(admin_emails=(), trial_days="3")
    ws.restart()
    with ws.client() as client:
        signup_user(client, email=EMAIL, password=PASSWORD)
        login = page.request.post(ws.base_url + "/api/integrations/access/login", headers=HEADERS,
                                  data={"email": EMAIL, "password": PASSWORD})
        assert login.ok
        sid = client.post("/api/sessions", json={"candidate": PRIVATE["candidate"], "role": PRIVATE["role"],
                  "policy": PRIVATE["policy"], "consent": True,
                  "permitted_sources": [{"label": PRIVATE["source"], "text": PRIVATE["body"]}]}).raise_for_status().json()["id"]
        path = "/api/sessions/" + sid
        answers = []
        for i in (1, 2):
            answer = client.post(path + "/answers", json={"question": f"Private source question {i}",
                                 "answer": f"Private original response {i}."}).raise_for_status().json()
            answers.append(answer)
            client.patch(path + "/answers/" + answer["id"], json={"expected_revision": answer["revision"],
                         "disposition": "explained", "note": PRIVATE["note"]}).raise_for_status()
        client.put(path + "/draft", json={"id": str(uuid4()), "expected_revision": 0,
                   "question": PRIVATE["draft"], "answer": "Private draft answer."}).raise_for_status()
        client.put(path + "/scorecard", json={"items": [{"criterion_id": "private", "criterion_label": PRIVATE["grade"],
                   "rating": 4, "weight": 1, "rationale": PRIVATE["rationale"]}]}).raise_for_status()
        versions = [client.get(f"{path}/answers/{a['id']}/worksheet").raise_for_status().json()["material"] for a in answers]
        items = []
        for index in range(count):
            parent = 1 if index == 10 else 0
            text = SHARED if index in (0, 10) else SECOND if index == 3 else f"Unselected private prompt {index:02d}."
            item = client.post(path + "/deferred-questions", json={"id": str(uuid4()),
                         "parent_answer_id": answers[parent]["id"], "question": text, "expected_material": versions[parent]})
            items.append(item.raise_for_status().json())
        actual = client.get(path + "/deferred-questions", params={"page_size": 100}).raise_for_status().json()
        assert [r["id"] for r in actual["items"]] == [r["id"] for r in items]
        yield client, sid, path, answers, items


def state(path, sid):
    queries = {
        "sessions": "SELECT * FROM sessions WHERE id=?",
        "answers": "SELECT * FROM answers WHERE session_id=? ORDER BY id",
        "drafts": "SELECT * FROM session_drafts WHERE session_id=?",
        "votes": "SELECT * FROM answer_review_events WHERE session_id=? ORDER BY id",
        "history": """SELECT h.* FROM answer_history h JOIN answers a ON a.id=h.answer_id
                      WHERE a.session_id=? ORDER BY a.id,h.revision""",
        "scorecard": "SELECT * FROM session_scorecards WHERE session_id=? ORDER BY criterion_id",
        "deferred": "SELECT * FROM deferred_questions WHERE session_id=? ORDER BY id",
    }
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as db:
        db.execute("BEGIN")
        summary = {}
        for name, sql in queries.items():
            rows = db.execute(sql, (sid,)).fetchall()
            summary[name] = (len(rows), hashlib.sha256(repr(rows).encode()).hexdigest())
        return summary


class Observed:
    def __init__(self, page, base, path, *, capture_clipboard=True):
        self.preview_path = path + "/deferred-questions/handoff/preview"
        self.verify_path = path + "/deferred-questions/handoff/verify"
        self.calls = []
        self.downloads = []
        self.external = []
        self.workspace_writes = []
        origin = urlsplit(base).netloc

        def sent(request):
            url = urlsplit(request.url)
            if url.scheme in ("http", "https") and url.netloc != origin:
                self.external.append(request.method)
            if url.path in (self.preview_path, self.verify_path):
                self.calls.append((url.path, request.post_data_json))
            elif request.method not in ("GET", "HEAD", "OPTIONS") and url.path.startswith("/api/sessions/"):
                self.workspace_writes.append((request.method, url.path))
        page.on("request", sent)
        page.on("websocket", lambda ws: self.external.append("websocket") if urlsplit(ws.url).netloc != origin else None)
        page.on("download", self.downloads.append)
        if capture_clipboard:
            # Capture the adapter's UTF-8 input without changing the host clipboard.
            page.add_init_script("""window.handoffCopies = [];
                Object.defineProperty(navigator, 'clipboard', {configurable:true, value:{
                  writeText: async (text) => { window.handoffCopies.push([...new TextEncoder().encode(text)]); }
                }});""")

    def assert_private(self):
        assert self.external == [] and self.workspace_writes == []


def controls(page, base, sid, parent):
    page.goto(base + f"/interviews/review/?id={sid}&answer={parent['id']}", wait_until="domcontentloaded")
    queue = page.locator("#deferred-questions")
    queue.locator("summary").focus()
    page.keyboard.press("Enter")
    handoff = queue.get_by_role("region", name="Pending question handoff")
    status = queue.get_by_label("Deferred question status")
    expect(status).to_have_value("all")
    expect(handoff).to_have_count(0)
    status.select_option("pending")
    expect(handoff).to_be_visible()
    return queue, handoff


def toggle(page, queue, parent_number, question):
    row = queue.get_by_role("listitem", name=f"Deferred question from exchange {parent_number}", exact=True)
    row = row.filter(has=page.get_by_text(question, exact=True))
    checkbox = row.get_by_role("checkbox", name=f"Include question from exchange {parent_number}", exact=True)
    checkbox.focus()
    page.keyboard.press("Space")
    return checkbox


def disabled_transfer(page, handoff):
    for label in ("Copy text", "Download text file"):
        expect(handoff.get_by_role("button", name=label, exact=True).and_(page.locator(":enabled"))).to_have_count(0)


def show_preview(page, handoff, observer, expected_text):
    with page.expect_response(lambda res: urlsplit(res.url).path == observer.preview_path) as reply:
        handoff.get_by_role("button", name="Preview selected questions", exact=True).click()
    raw = expected_text.encode("utf-8")
    expected = {"text": expected_text, "sha256": hashlib.sha256(raw).hexdigest()}
    assert reply.value.status == 200 and reply.value.json() == expected
    expect(handoff.get_by_role("textbox", name="Exact handoff text")).to_have_value(expected_text)
    return expected
