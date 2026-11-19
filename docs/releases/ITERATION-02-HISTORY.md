# Answer history contract

**Owner** Backend history lane. **Status** Implementation frozen for integrated review. See the independent review in ITERATION-02-REVIEW.md.

## Read API for the timeline

`GET /api/sessions/{sid}/answers/{aid}/history?before_revision=<integer>&limit=<integer>` returns `{current_revision, baseline_revision, entries, next_before_revision}`. Entries are ordered by revision, newest first, including the current revision on the first page. The optional cursor excludes its own revision. The default limit is 20 and the maximum is 50. The next cursor is null when there are no more entries.

Each entry has `{revision, kind, saved_at, actor}`. The kind is `baseline`, `answer_edit`, or `review_update`. A baseline has null time and actor. A tracked change has a UTC timestamp and one of `{"kind":"local_operator"}`, `{"kind":"account","id":"<verified account UUID>"}`, or null if the access service cannot identify the account. The UUID is private workspace data. It is available as attribution for an authenticated account. Labels can use “Workspace account” without displaying the UUID.

`GET /api/sessions/{sid}/answers/{aid}/history/{revision}` returns the same four metadata fields and `snapshot`. Its keys are `question`, `answer`, `references`, `result`, `disposition`, `note`, `parent_answer_id`, and `planned_slot`. Field shapes match the corresponding keys in the current answer. Revision and answer identity are already in the entry and URL. The snapshot excludes import provenance and arbitrary legacy metadata. The current editor continues to read and save through the existing answer API. History has no edit or apply action.

Both history routes inherit the workspace entitlement and cache policy. A missing or trashed session, foreign answer, or unavailable revision gives 404.

## Storage and writes

The history table uses the answer ID and revision as its key. Each effective correction or review change captures the exact resulting saved state in the same SQLite transaction as the current answer write. Before replacing a current state with no recorded snapshot, the write saves it as an unknown baseline. Until then, history presents that state at its actual revision as a virtual baseline. This also covers a rollback to an older application that can save changes without recording snapshots. Any unrecorded intervening revisions are unavailable. Creation, draft publication, transcript import and upgrade do not backfill prior states.

Attribution comes from the same server entitlement decision as the successful mutation. Body data, browser labels, and inherited notes cannot supply the actor. A stale expected revision continues to return 409. A no-op or a retry adds zero extra rows. Older clients with no expected revision keep their existing write rules. History metadata pages exclude snapshot bodies. The implementation sets no automatic pruning limit. The answer foreign key cascades permanent purge.

## Recovery and privacy

JSON workspace backup stays at version 1 and contains only the current answer, its current revision, and the existing recovery fields. It omits earlier revisions and all history actor metadata. Restoring into a new workspace gives the saved revision an unknown baseline. An identical restore into an existing workspace leaves its history intact. A consistent SQLite backup preserves the full history. The recovery UI must explain the difference before download and restore.

Trash hides access to history. Restoring from Trash returns the same history. Permanent purge deletes it in the same transaction. Current answer detail, search, reports, briefs, ATS notes, role exports, and JSON backup retain their existing shapes and do not read history. A copied note marked as retained from an earlier answer remains part of the current answer when the existing edit rule retains it.

## Acceptance

Verify current and historical evidence, review notes, actor attribution, unchanged saves, stale writes, concurrent writes, failure rollback, cursor boundaries, and session ownership through the normal API. Use an earlier-only marker to verify that current responses and the redacted brief never gain history content. Verify Trash restore and purge, v1 recovery, and SQLite recovery with synthetic data.

## Implementation and verification

`portable/api/answer_history.py` owns the table and snapshot queries. `portable/api/answer_history_routes.py` serves history through the workspace router and derives the actor from the entitlement check already used to authorize the write. The existing `store.py` write transaction owns the baseline, answer mutation, and resulting snapshot. The history table cascades deletion when Trash purges the answer. The JSON backup code and format required no changes.

All 205 portable backend tests passed on the delivery checkout. The independent HTTP QA fixture also passed. It checked an earlier-only answer and note against the current answer, session, report, redacted brief, brief download, and JSON backup. It verified that SQLite recovery preserved history, a JSON restore into an empty workspace started at the saved current revision, and an identical JSON restore preserved existing history. The focused tests covered a stale write, concurrent writes, an injected snapshot failure, actor attribution, earlier findings and lineage, application rollback, and Trash. SQLite used the primary key for the bounded metadata query.

The backend lane is frozen for integration. Its principal failure mode is older answer or note content appearing in a current or redacted response. Browser and release checks remain with the integration lane.
