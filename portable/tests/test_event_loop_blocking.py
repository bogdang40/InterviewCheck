"""Async request code never runs synchronous SQLite work on the event loop.

A write waits up to ten seconds for SQLite's lock. On the loop that wait freezes
every request in the single worker, including /api/health.
"""
import ast
import asyncio
from contextlib import closing
from pathlib import Path
import sqlite3
import threading
from uuid import uuid4

import httpx

from api import store
from api.main import app
from api.models import AnswerInput, Reference, SessionInput

API = Path(__file__).resolve().parents[1] / "api"
SEEDS = frozenset({("sqlite3", "connect")})


class BlockingCallIndex:
    """Call graph of a package that marks every sync function able to open SQLite."""

    def __init__(self, sources: dict[str, str]):
        self.functions: dict[tuple[str, str], list[ast.AST]] = {}
        self.aliases: dict[tuple[str, str], tuple[str, str]] = {}
        self.modules: dict[tuple[str, str], str] = {}
        for module, source in sources.items():
            self._index(module, ast.parse(source))
        self.blocking = self._close_over_sync_callers()

    def _index(self, module: str, tree: ast.AST) -> None:
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                self.functions.setdefault((module, node.name), []).append(node)
            elif isinstance(node, ast.ImportFrom) and node.level == 1:
                for name in node.names:
                    local = name.asname or name.name
                    if node.module:
                        self.aliases[(module, local)] = (node.module, name.name)
                    else:
                        self.modules[(module, local)] = name.name

    def calls(self, module: str, function: ast.AST):
        """Calls made by the function itself, not by functions or lambdas it defines."""
        pending = list(ast.iter_child_nodes(function))
        while pending:
            node = pending.pop()
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                continue
            pending.extend(ast.iter_child_nodes(node))
            if isinstance(node, ast.Call):
                target = self._resolve(module, node.func)
                if target is not None:
                    yield target

    def _resolve(self, module: str, func: ast.AST):
        if isinstance(func, ast.Name):
            key = (module, func.id)
            return self.aliases.get(key, key)
        if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
            owner = self.modules.get((module, func.value.id), func.value.id)
            key = (owner, func.attr)
            return self.aliases.get(key, key)
        return None

    def _close_over_sync_callers(self) -> set[tuple[str, str]]:
        blocking = set(SEEDS)
        changed = True
        while changed:
            changed = False
            for key, nodes in self.functions.items():
                if key in blocking:
                    continue
                for node in nodes:
                    if isinstance(node, ast.FunctionDef) and any(t in blocking for t in self.calls(key[0], node)):
                        blocking.add(key)
                        changed = True
                        break
        return blocking

    def violations(self) -> list[str]:
        found = []
        for (module, name), nodes in sorted(self.functions.items()):
            for node in nodes:
                if isinstance(node, ast.AsyncFunctionDef):
                    hits = sorted({f"{t[0]}.{t[1]}" for t in self.calls(module, node) if t in self.blocking})
                    if hits:
                        found.append(f"{module}.{name} line {node.lineno} calls {', '.join(hits)}")
        return found


def package_index() -> BlockingCallIndex:
    return BlockingCallIndex({path.stem: path.read_text(encoding="utf-8") for path in sorted(API.glob("*.py"))})


def test_index_finds_direct_transitive_and_aliased_calls():
    index = BlockingCallIndex({
        "store": "import sqlite3\ndef connection():\n    return sqlite3.connect('x')\n",
        "helpers": "from . import store\ndef load():\n    with store.connection():\n        pass\n",
        "routes": (
            "from starlette.concurrency import run_in_threadpool\n"
            "from . import helpers as h\nfrom .store import connection as open_db\n"
            "async def direct():\n    open_db()\n"
            "async def transitive():\n    await thing()\n    h.load()\n"
            "async def offloaded():\n    return await run_in_threadpool(h.load)\n"
            "async def nested():\n    def work():\n        h.load()\n    return await run_in_threadpool(work)\n"
        ),
    })
    assert [line.split(" line")[0] for line in index.violations()] == ["routes.direct", "routes.transitive"]


def test_async_functions_offload_sqlite_work():
    assert package_index().violations() == []


def answered_session(path):
    with store.connection(path, write=True) as db:
        session = store.create_session(db, SessionInput(candidate="Lock", role="Operator", policy="Notes allowed.", consent=True))
        answer = store.write_answer(db, session["id"], AnswerInput(
            question="Describe the rollout.", answer="We paused the queue first.",
            references=[Reference(label="Ref", text="An unrelated reference text for comparison.")]))
    return session["id"], answer["id"]


def test_health_answers_while_a_write_waits_for_the_lock(tmp_path, monkeypatch):
    path = tmp_path / "review.sqlite3"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(path))
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_MODE", raising=False)
    store.initialize(path)
    sid, aid = answered_session(path)

    async def scenario():
        transport = httpx.ASGITransport(app=app, client=("127.0.0.1", 50000))
        async with httpx.AsyncClient(transport=transport, base_url="http://127.0.0.1",
                                     headers={"X-InterviewCheck": "1"}) as client:
            with closing(sqlite3.connect(path, check_same_thread=False)) as holder:
                holder.execute("BEGIN IMMEDIATE")
                release = threading.Timer(2.0, holder.rollback)
                release.start()
                try:
                    review = asyncio.create_task(client.patch(
                        f"/api/sessions/{sid}/answers/{aid}", json={"disposition": "explained", "note": "Checked."}))
                    await asyncio.sleep(0.2)
                    health = await client.get("/api/health")
                    still_waiting = not review.done()
                    saved = await review
                finally:
                    release.join()
        return health, still_waiting, saved

    health, still_waiting, saved = asyncio.run(scenario())
    assert health.status_code == 200
    assert still_waiting, "/api/health only answered after the blocked write finished"
    assert saved.status_code == 200 and saved.json()["disposition"] == "explained"
