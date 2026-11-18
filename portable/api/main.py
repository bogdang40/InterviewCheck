from contextlib import asynccontextmanager
from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles

from . import ats_notes, authoring, store
from .access import require_entitlement
from .evidence import compare
from .integrations import router as integrations
from .local_boundary import LocalBoundary
from .origin import public_origin
from .migrate import import_role, preview_role
from .exports import router as exports
from .models import AnswerInput, ReviewInput, RoleInput, SessionInput
from .report import report
from .session_workflow import router as session_workflow


@asynccontextmanager
async def lifespan(_):
    public_origin()  # Validate configured web exposure before opening the database.
    store.initialize(store.db_path())
    yield


app = FastAPI(title="InterviewCheck", lifespan=lifespan)
app.add_middleware(LocalBoundary)
workspace = APIRouter(prefix="/api", dependencies=[Depends(require_entitlement)])


@app.exception_handler(RequestValidationError)
async def invalid_input(_request, error):
    issues = [{"field": ".".join(map(str, item["loc"])), "message": item["msg"]} for item in error.errors()]
    return JSONResponse(status_code=422, content={"detail": "; ".join(
        f"{issue['field']}: {issue['message']}" for issue in issues)})


@app.middleware("http")
async def private_content(request: Request, call_next):
    response = await call_next(request)
    if request.url.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Frame-Options"] = "DENY"
    return response


@app.get("/api/health")
def health():
    return {"ok": True}


@workspace.get("/sessions")
def sessions():
    with store.connection() as db:
        return [store.summary(row) for row in db.execute(store.SUMMARY + " GROUP BY s.id ORDER BY s.created_at DESC, s.rowid DESC")]


@workspace.post("/sessions", status_code=201)
def new_session(item: SessionInput):
    with store.connection(write=True) as db:
        return store.create_session(db, item)


@workspace.get("/sessions/{sid}")
def detail(sid: UUID):
    with store.connection() as db:
        return store.get_session(db, str(sid))


@workspace.post("/preview")
def preview(item: AnswerInput):
    return compare(item.question, item.answer, item.references)


@workspace.post("/sessions/{sid}/answers", status_code=201)
def add(sid: UUID, item: AnswerInput):
    with store.connection(write=True) as db:
        return store.write_answer(db, str(sid), item)


@workspace.put("/sessions/{sid}/answers/{aid}")
def revise(sid: UUID, aid: UUID, item: AnswerInput):
    with store.connection(write=True) as db:
        return store.write_answer(db, str(sid), item, str(aid))


@workspace.patch("/sessions/{sid}/answers/{aid}")
def review(sid: UUID, aid: UUID, item: ReviewInput):
    with store.connection(write=True) as db:
        return store.update_review(db, str(sid), str(aid), item)


@workspace.get("/sessions/{sid}/report")
def download(sid: UUID):
    with store.connection() as db:
        return Response(report(store.get_session(db, str(sid))), media_type="text/markdown",
                        headers={"Content-Disposition": f'attachment; filename="interview-{sid}.md"'})


@workspace.get("/roles")
def roles():
    with store.connection() as db:
        return [store.role_row(row) for row in db.execute("SELECT * FROM roles ORDER BY name COLLATE NOCASE,id")]


@workspace.post("/roles", status_code=201)
def new_role(item: RoleInput):
    with store.connection(write=True) as db:
        return store.create_role(db, item)


@workspace.post("/roles/import")
def import_exported_role(document: dict):
    with store.connection(write=True) as db:
        try:
            _, role = import_role(db, document)
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        return role


@workspace.post("/roles/import/preview")
def preview_exported_role(document: dict):
    with store.connection() as db:
        try:
            return preview_role(db, document)
        except ValueError as error:
            raise HTTPException(422, str(error)) from error


workspace.include_router(session_workflow)
workspace.include_router(ats_notes.router)
workspace.include_router(exports)
app.include_router(authoring.router)
app.include_router(workspace)
app.include_router(integrations)


@app.api_route("/api/{unknown:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"], include_in_schema=False)
def missing(unknown: str):
    raise HTTPException(404, "Unknown API route.")



from .account_server import local_service

app.mount("/v1", local_service)

static = Path(__file__).resolve().parents[1] / "web" / "out"
if static.is_dir():
    app.mount("/", StaticFiles(directory=static, html=True), name="workspace")
