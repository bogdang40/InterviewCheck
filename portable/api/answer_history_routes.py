"""Read private answer revisions under the workspace access boundary."""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Path, Query

from . import answer_history, store
from .access import require_entitlement

router = APIRouter(prefix="/sessions/{sid}/answers/{aid}/history")


def mutation_actor(user=Depends(require_entitlement)):
    if user is None:
        return {"kind": "local_operator"}
    account_id = user.get("id")
    if isinstance(account_id, str):
        try:
            return {"kind": "account", "id": str(UUID(account_id))}
        except ValueError:
            return None
    return None


@router.get("")
def revisions(sid: UUID, aid: UUID, before_revision: Annotated[int | None, Query(ge=1, lt=2**63)] = None,
              limit: Annotated[int, Query(ge=1, le=50)] = 20):
    with store.connection() as db:
        return answer_history.page(db, str(sid), str(aid), before_revision, limit)


@router.get("/{revision}")
def revision_detail(sid: UUID, aid: UUID, revision: Annotated[int, Path(ge=1, lt=2**63)]):
    key, answer_id = str(sid), str(aid)
    with store.connection() as db:
        current = answer_history.current_revision(db, key, answer_id)
        saved = answer_history.saved_revision(db, answer_id, revision)
        if saved is not None and revision <= current:
            return saved
        if revision == current:
            return {**answer_history.baseline(current), "snapshot": answer_history.snapshot(store.get_answer(db, key, answer_id))}
    raise HTTPException(404, "Answer revision does not exist.")
