"""Run real browser authoring controls against delayed local providers."""
import asyncio
import json
from threading import Event

from fastapi import HTTPException
import httpx
from playwright.sync_api import expect

from api import authoring


def configure(monkeypatch, *names):
    for name in authoring.MODEL_KEYS:
        for setting in authoring.MODEL_KEYS[name]:
            if name in names:
                monkeypatch.setenv(setting, "fixture")
            else:
                monkeypatch.delenv(setting, raising=False)


async def wait_release(release):
    for _ in range(1000):
        if release.is_set():
            return
        await asyncio.sleep(.01)
    raise RuntimeError("Test provider was not released")


def test_role_edit_then_revert_discards_late_reply(workspace_url, browser_page, monkeypatch):
    configure(monkeypatch, "OpenAI")
    started, release, finished = Event(), Event(), Event()
    calls = []
    async def delayed(provider, instructions, prompt):
        calls.append(json.loads(prompt))
        started.set()
        await wait_release(release)
        finished.set()
        return "fixture", '["A stale role question?"]'
    monkeypatch.setattr(authoring, "complete", delayed)
    page = browser_page
    page.goto(workspace_url + "/roles/")
    page.get_by_role("button", name="Add role").click()
    page.get_by_label("Role name", exact=True).fill("Initial role")
    desc = page.get_by_role("textbox", name="Description", exact=True)
    desc.fill("Only this description is authorized.")
    planned = page.get_by_label("Planned questions, one per line")
    planned.fill("Existing plan?")
    page.get_by_text("Draft role questions", exact=True).click()
    generate = page.get_by_role("button", name="Draft questions", exact=True)
    generate.evaluate("(button) => { button.click(); button.click() }")
    try:
        assert started.wait(3)
        desc.fill("A different role description.")
        desc.fill("Only this description is authorized.")
        expect(page.get_by_text("The inputs changed. The pending reply was discarded.")).to_be_visible()
    finally:
        release.set()
    assert finished.wait(3)
    expect(planned).to_have_value("Existing plan?")
    page.get_by_role("button", name="Save role", exact=True).click()
    expect(page.get_by_role("button", name="Edit role", exact=True)).to_be_visible()
    assert calls == [{"role": "Initial role", "description": "Only this description is authorized."}]
    assert httpx.get(workspace_url + "/api/roles").json()[0]["questions"] == ["Existing plan?"]


def open_editor(base, page):
    session = httpx.post(base + "/api/sessions", headers={"X-InterviewCheck": "1"}, json={
        "candidate": "Private participant", "role": "Signal engineer", "policy": "Notes allowed.", "consent": True,
    }).json()
    page.goto(base + "/interviews/review/?id=" + session["id"])
    q = page.get_by_role("textbox", name="Question", exact=True)
    q.fill("Which register changes first?")
    page.get_by_label("Candidate answer").fill("Private material stays local.")
    page.get_by_role("button", name="Add source", exact=True).click()
    page.get_by_label("Source name", exact=True).fill("Original manual")
    page.get_by_label("Source passage").fill("An existing source.")
    page.get_by_text("Generate a reference answer", exact=True).click()
    return q


def test_lineup_preserves_sources_and_retries_only_failed_pair(workspace_url, browser_page, monkeypatch):
    configure(monkeypatch, "OpenAI", "Anthropic")
    calls = []
    async def mixed(provider, instructions, prompt):
        calls.append((provider, json.loads(prompt)))
        if provider == "Anthropic" and sum(p == "Anthropic" for p, _ in calls) == 1:
            raise HTTPException(502, "Fixture provider unavailable.")
        return "fixture", "Reference from " + provider
    monkeypatch.setattr(authoring, "complete", mixed)
    page = browser_page
    open_editor(workspace_url, page)
    page.get_by_role("button", name="Add provider and format").click()
    expect(page.get_by_text("2 requests: OpenAI · Spoken answer, Anthropic · Spoken answer")).to_be_visible()
    page.get_by_role("button", name="Generate references", exact=True).click()
    expect(page.get_by_text("Anthropic · Spoken answer: Fixture provider unavailable.")).to_be_visible()
    expect(page.get_by_label("Source name", exact=True)).to_have_count(2)
    page.get_by_role("button", name="Retry failed").click()
    expect(page.get_by_text("Anthropic · Spoken answer: Added to sources")).to_be_visible()
    expect(page.get_by_label("Source name", exact=True)).to_have_count(3)
    expect(page.get_by_role("button", name="Retry failed")).to_have_count(0)
    expect(page.get_by_label("Source passage").first).to_have_value("An existing source.")
    assert [name for name, _ in calls].count("OpenAI") == 1
    assert [name for name, _ in calls].count("Anthropic") == 2
    assert all(body == {"role": "Signal engineer", "question": "Which register changes first?"} for _, body in calls)


def test_edit_and_cancel_discard_reference_responses(workspace_url, browser_page, monkeypatch):
    configure(monkeypatch, "OpenAI")
    started = [Event(), Event()]
    release = [Event(), Event()]
    finished = [Event(), Event()]
    calls = []
    async def delayed(provider, instructions, prompt):
        index = len(calls)
        calls.append(prompt)
        started[index].set()
        await wait_release(release[index])
        finished[index].set()
        return "fixture", "A stale reference"
    monkeypatch.setattr(authoring, "complete", delayed)
    page = browser_page
    q = open_editor(workspace_url, page)
    for n in range(2):
        page.get_by_role("button", name="Generate reference", exact=True).click()
        try:
            assert started[n].wait(3)
            if n == 0:
                q.fill("Another register?")
                q.fill("Which register changes first?")
                expect(page.get_by_text("The inputs changed. The pending reply was discarded.")).to_be_visible()
            else:
                page.get_by_role("button", name="Discard pending output").click()
                expect(page.get_by_text("Pending output discarded.", exact=False)).to_be_visible()
        finally:
            release[n].set()
        assert finished[n].wait(3)
        expect(page.get_by_label("Source name", exact=True)).to_have_count(1)
    page.get_by_role("button", name="Save and compare").click()
    expect(page.get_by_role("heading", name="Which register changes first?").first).to_be_visible()
    assert len(calls) == 2
