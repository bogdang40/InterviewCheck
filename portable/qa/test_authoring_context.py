"""Delayed generated material must not attach to another role or exchange."""

import asyncio
from threading import Event

import httpx
import pytest
from playwright.sync_api import expect


@pytest.mark.parametrize("operation", ["questions", "reference"])
def test_provider_reply_remains_bound_to_original_context(
    workspace_url, browser_page, monkeypatch, operation
):
    from api import authoring

    monkeypatch.setenv("OPENAI_API_KEY", "fixture")
    monkeypatch.setenv("INTERVIEWCHECK_REFERENCE_MODEL", "fixture")
    started, release, returned = Event(), Event(), Event()
    prompts = []

    async def delayed(provider, instructions, prompt):
        prompts.append(prompt)
        started.set()
        try:
            assert await asyncio.to_thread(release.wait, 15)
        finally:
            returned.set()
        return "fixture-model", (
            '["Old cold room checklist?"]' if operation == "questions" else "Old cold room reference."
        )

    monkeypatch.setattr(authoring, "complete", delayed)
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        if operation == "questions":
            page.goto(workspace_url + "/roles/")
            page.get_by_role("button", name="Add role").click()
            page.get_by_label("Role name").fill("Cold room operator")
            page.get_by_role("textbox", name="Description", exact=True).fill("Follow the cold chain.")
            page.get_by_text("Draft role questions", exact=True).click()
            generate = page.get_by_role("button", name="Draft questions", exact=True)
        else:
            response = client.post(
                "/api/sessions",
                json={
                    "candidate": "Operator fixture",
                    "role": "Engineer",
                    "policy": "Manual",
                    "consent": True,
                },
            )
            response.raise_for_status()
            path = "/api/sessions/" + response.json()["id"]
            page.goto(workspace_url + "/interviews/review/?id=" + response.json()["id"])
            page.get_by_role("textbox", name="Question", exact=True).fill(
                "How do you calibrate the cold room?"
            )
            page.get_by_label("Candidate answer").fill("I use a control measurement.")
            page.get_by_text("Generate a reference answer", exact=True).click()
            generate = page.get_by_role("button", name="Generate reference", exact=True)
        generate.click()
        try:
            assert started.wait(timeout=8)
            if operation == "questions":
                page.get_by_label("Role name").fill("Data engineer")
                page.get_by_role("textbox", name="Description", exact=True).fill("Manage ingestion jobs.")
            else:
                question = page.get_by_role("textbox", name="Question", exact=True)
                question.fill("Which query plan was slow?")
                question.fill("How do you calibrate the cold room?")
        finally:
            release.set()
        assert returned.wait(timeout=8)
        if operation == "questions":
            expect(page.get_by_role("button", name="Save role")).to_be_enabled()
            expect(page.get_by_role("textbox", name="Planned questions, one per line")).to_have_value("")
            with page.expect_response(lambda response: response.url.endswith("/api/roles") and response.request.method == "POST") as stored:
                page.get_by_role("button", name="Save role").click()
            assert stored.value.ok
            expect(page.get_by_text("Data engineer", exact=True)).to_be_visible()
            assert client.get("/api/roles").json()[0]["questions"] == []
        else:
            save = page.get_by_role("button", name="Save and compare")
            expect(save).to_be_enabled()
            save.click()
            expect(
                page.get_by_role("heading", name="How do you calibrate the cold room?", exact=True)
            ).to_be_visible()
            assert client.get(path).json()["answers"][0]["references"] == []
        assert len(prompts) == 1


def test_reference_lineup_retries_only_failed_provider(workspace_url,browser_page,monkeypatch):
    from fastapi import HTTPException
    from api import authoring
    monkeypatch.setenv("OPENAI_API_KEY","fixture")
    monkeypatch.setenv("INTERVIEWCHECK_REFERENCE_MODEL","openai-fixture")
    monkeypatch.setenv("ANTHROPIC_API_KEY","fixture")
    monkeypatch.setenv("INTERVIEWCHECK_ANTHROPIC_MODEL","anthropic-fixture")
    calls = []
    async def response(provider,instructions,prompt):
        calls.append(provider)
        if provider == "Anthropic" and calls.count(provider) == 1:
            raise HTTPException(503,"Synthetic provider timeout.")
        return "fixture", provider + " returned this source."
    monkeypatch.setattr(authoring,"complete",response)
    page=browser_page
    with httpx.Client(base_url=workspace_url,headers={"X-InterviewCheck":"1"}) as c:
        created=c.post("/api/sessions",json={"candidate":"Lineup fixture","role":"Engineer","policy":"Notes","consent":True})
        created.raise_for_status()
        path="/api/sessions/"+created.json()["id"]
        page.goto(workspace_url+"/interviews/review/?id="+created.json()["id"])
        page.get_by_role("textbox",name="Question",exact=True).fill("How would you calibrate the meter?")
        page.get_by_label("Candidate answer").fill("I would compare several reference measurements.")
        page.get_by_role("button",name="Add source").click()
        page.get_by_label("Source name").fill("Operator source")
        page.get_by_label("Source passage").fill("Keep the manual record.")
        page.get_by_text("Generate a reference answer",exact=True).click()
        page.get_by_role("button",name="Add provider and format").click()
        expect(page.get_by_text("2 requests:",exact=False)).to_be_visible()
        assert not calls
        page.get_by_role("button",name="Generate references",exact=True).click()
        retry=page.get_by_role("button",name="Retry failed")
        expect(retry).to_be_visible()
        expect(page.get_by_text("Synthetic provider timeout.",exact=False)).to_be_visible()
        assert sorted(calls) == ["Anthropic","OpenAI"]
        retry.click()
        expect(retry).to_have_count(0)
        assert calls.count("OpenAI") == 1 and calls.count("Anthropic") == 2
        page.get_by_role("button",name="Save and compare").click()
        expect(page.get_by_role("heading",name="How would you calibrate the meter?",exact=True)).to_be_visible()
        sources=c.get(path).json()["answers"][0]["references"]
        assert [s["text"] for s in sources] == ["Keep the manual record.","OpenAI returned this source.","Anthropic returned this source."]
