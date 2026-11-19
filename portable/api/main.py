from contextlib import asynccontextmanager
from pathlib import Path
import sys
from uuid import UUID

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles

from . import access, ats_notes, authoring, backup, bulk_operations, drafts, health_probes, model_admin, model_execution, rate_limit, role_analytics, role_versions, scoring_hooks, secret_box, store, trash
from .access import embedded_enabled, require_entitlement
from .error_sanitizer import sanitize_error_text
from .evidence import compare
from .integrations import router as integrations
from .local_boundary import LocalBoundary
from .origin import validate_runtime_exposure
from .migrate import import_role, preview_role
from .discovery import router as discovery
from .interview_catalog import router as interview_catalog
from .exports import router as exports
from .models import AnswerEdit, AnswerInput, ReviewInput, RoleInput, SessionInput
from .report import report
from .security_headers import SecurityHeadersMiddleware
from .session_workflow import router as session_workflow
from .transcript_import import router as transcript_import


@asynccontextmanager
async def lifespan(_):
    rate_limit.reset_all()
    model_execution.reset_quotas()
    validate_runtime_exposure()  # Validate configured web exposure before opening the database.
    if embedded_enabled():
        from .account_db import check_database
        check_database()
    store.initialize(store.db_path())
    if secret_box.key_source() == "file":
        try:
            secret_box.active_key_id()
        except secret_box.SecretBoxError:
            pass
    yield


static = Path(__file__).resolve().parents[1] / "web" / "out"
app = FastAPI(title="InterviewCheck", lifespan=lifespan)
app.add_middleware(LocalBoundary)
app.add_middleware(SecurityHeadersMiddleware, static_dir=static if static.is_dir() else None)
workspace = APIRouter(prefix="/api", dependencies=[Depends(require_entitlement)])


@app.exception_handler(RequestValidationError)
async def invalid_input(_request, error):
    issues = [{"field": ".".join(map(str, item["loc"])), "message": item["msg"]} for item in error.errors()]
    detail = "; ".join(f"{issue['field']}: {issue['message']}" for issue in issues)
    return JSONResponse(status_code=422, content={"detail": sanitize_error_text(detail, "Invalid input.")})


@app.exception_handler(Exception)
async def unhandled_error(_request, exc):
    sys.stderr.write(f"[api] unhandled {exc.__class__.__name__}\n")
    return JSONResponse(status_code=500, content={"detail": "Internal server error."})


@app.get("/api/health")
def health():
    with store.connection() as db:
        db.execute("SELECT 1 FROM sessions LIMIT 1").fetchone()
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


@workspace.get("/sessions/{sid}/answers/{aid}")
def answer_detail(sid: UUID, aid: UUID):
    with store.connection() as db:
        return store.get_answer(db, str(sid), str(aid))


@workspace.put("/sessions/{sid}/answers/{aid}")
def revise(sid: UUID, aid: UUID, item: AnswerEdit):
    with store.connection(write=True) as db:
        return store.write_answer(db, str(sid), item, str(aid))


@workspace.patch("/sessions/{sid}/answers/{aid}")
async def review(sid: UUID, aid: UUID, item: ReviewInput, request: Request):
    actor = await access.optional_actor(request)
    with store.connection(write=True) as db:
        return store.update_review(db, str(sid), str(aid), item, actor=actor)


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
async def new_role(item: RoleInput, request: Request):
    _, actor_email = await access.optional_actor(request)
    with store.connection(write=True) as db:
        return store.create_role(db, item, created_by=actor_email)


@workspace.post("/roles/import")
async def import_exported_role(document: dict, request: Request):
    _, actor_email = await access.optional_actor(request)
    with store.connection(write=True) as db:
        try:
            added, role = import_role(db, document)
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        if added:
            role_versions.ensure_initial_snapshot(
                db, role["id"], change_note="Imported role", created_by=actor_email
            )
        return role


@workspace.post("/roles/import/preview")
def preview_exported_role(document: dict):
    with store.connection() as db:
        try:
            return preview_role(db, document)
        except ValueError as error:
            raise HTTPException(422, str(error)) from error


workspace.include_router(trash.router)
workspace.include_router(drafts.router)
workspace.include_router(backup.router)
workspace.include_router(bulk_operations.router)
workspace.include_router(role_analytics.router)
workspace.include_router(role_versions.router)
workspace.include_router(session_workflow)
workspace.include_router(transcript_import)
workspace.include_router(ats_notes.router)
workspace.include_router(discovery)
workspace.include_router(interview_catalog)
workspace.include_router(exports)
app.include_router(health_probes.router)
app.include_router(authoring.router)
app.include_router(model_admin.router)
app.include_router(scoring_hooks.router)
app.include_router(workspace)
app.include_router(integrations)


@app.api_route("/api/admin", methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
               dependencies=[Depends(model_admin.require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))], include_in_schema=False)
@app.api_route("/api/admin/{unknown:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
               dependencies=[Depends(model_admin.require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))], include_in_schema=False)
def missing_admin(unknown: str = ""):
    raise HTTPException(404, "Unknown admin route.")


@app.api_route("/api/{unknown:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"], include_in_schema=False)
def missing(unknown: str):
    raise HTTPException(404, "Unknown API route.")


from .account_server import local_service

app.mount("/v1", local_service)

if static.is_dir():
    app.mount("/", StaticFiles(directory=static, html=True), name="workspace")
