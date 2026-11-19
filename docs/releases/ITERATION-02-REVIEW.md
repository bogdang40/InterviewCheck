# Iteration 02 independent review

**Decision. Proceed with the contracts below.** Reviewed against `f9dbdec`. The proposed workflow is useful, but the plan leaves three release decisions open. Settle what a revision represents, which recovery path preserves it, and which role file readers support the new format before wiring the UI.

## Review history

- Each committed content edit or review change records the exact resulting saved revision, with the action, UTC timestamp, and actor for that mutation. An earlier snapshot must retain its own content, evidence, disposition, note, and lineage. A copied note marked as coming from an earlier version does not make the earlier reviewer the actor for the new edit. Use the existing revision counter, transaction, conflict response, and no change behavior. A stale save or retry must create zero extra rows. A failed history insert must roll back the current write.
- Use only authenticated server identity from the same authorization decision as the mutation. Record a stable account ID if available and a local operator label for ungated operation. A baseline from an existing or restored answer uses the actual stored revision number and unknown actor and time. Do not infer identities from configuration, notes, browser input, or the actor who first opens history. Publish and import establish an initial state and never imply a later edit.
- Capture an existing answer's baseline lazily before its first tracked mutation. Keep history reads separate from regular detail, search, reports, briefs, ATS notes, and role exports. Use a bounded index-backed metadata page and fetch the full body for one revision on demand. Verify an older large workspace can open without a snapshot backfill and that regular responses retain their shape and size as revisions accumulate. Record any retention limit explicitly. Avoid silent pruning.
- Authorize reads under the existing workspace and active-session boundary. Trash hides history, restore returns the same history, and purge deletes it in the same transaction. Apply `no-store` to history. Check a synthetic private marker in an earlier answer and note against the redacted brief, its downloads, and regular API responses. Verify wrong-session, Trash, and purged lookups through the actual API.
- Keep JSON workspace backup version 1 as current state recovery for this round. It includes the current answer revision, excludes older snapshots and actor metadata, and never overwrites or truncates existing history on an identical restore. A restore into an empty workspace uses the saved revision as an unknown baseline. A consistent SQLite backup retains history. Explain this difference before download and restore. Test both recovery paths and an old version 1 file. Adding history to JSON requires a separate format and size review. Purge removes the live records. Earlier copies remain subject to the deployment's backup retention. `deploy/backup.sh` includes full review database copies in the nightly and predeployment archives.

Owning seams are `portable/api/store.py` (`write_answer`, `update_review`, `get_answer`), `portable/api/main.py` (workspace entitlement and answer routes), `portable/api/trash.py`, `portable/api/backup.py`, and `portable/api/review_brief.py`. The current answer revision counter already covers both mutations. The backup validator recomputes current evidence, so adding historical evidence to version 1 would change its semantics and increase restore work.

The updated `ITERATION-02-HISTORY.md` agrees with this review. The timestamp and actor belong to the mutation that saved the revision named by the entry. For example, if one operator reviews revision 6 and another edits it to revision 7, revision 6 retains its reviewer and time and revision 7 shows the editor and edit time. The virtual or materialized baseline has null actor and time. The UI can use the agreed `/history` list and `/history/{revision}` detail routes.

## History UI

Keep the current editor and historical display separate. A selected revision is read only. Closing history, changing selection, a delayed response, or a stale save must preserve the unsaved current text and keep it attached to its answer. Label baseline attribution honestly. Verify keyboard entry, selection, and return focus; check a narrow screen and dark mode. The most important browser case uses two views of the same answer, a stale save, and a history selection before returning to the unsaved editor.

## Role portability

The native version 1 role reader expects `workspaceID`, `plannedQuestions` objects, and native field names. Use a distinct portable version for the validated fields that include policy and permitted material. Keep the existing native version 1 import and its ID mapping intact. Never label an export as compatible with the native app unless that app can read it and preserve the supported fields.

Export only the saved template ID, name, description, ordered questions, policy, and ordered permitted materials. Exclude the optimistic edit version, native `legacy` blob, interviews, and account data. A portable import preserves the template ID. Identical reimport is a no-op. Different content for that ID is a visible conflict and must never overwrite. Preview and import must agree for the same saved state, and import must recheck inside its write transaction. Duplicate creates a new ID and preserves editable content. If the action uses a previously opened role, follow the existing role version check or label the action as copying the latest saved role.

Verify a portable export from one database imports through the normal preview and import APIs into another, including Unicode, policy, and permitted materials. Verify a native version 1 fixture, unsupported portable versions, identical and conflicting imports, and a duplicate whose later edits do not change the source or an existing interview snapshot. `portable/api/migrate.py` owns native conversion. `portable/api/role_kits.py` owns the portable create and version checks.

Native imports predate portable field limits. If an existing native role cannot round-trip within the portable limits, return an actionable error before export or duplication. Do not silently truncate it or produce a file the portable importer refuses. Verify a maximum-size valid role uses the same byte limits as the import path.

## Release gate

The most likely failure is an older answer or reviewer note appearing in a path that only promises current or redacted content. After replacing both current fields, verify the earlier-only markers stay out of the regular API, JSON backup, report, and redacted brief, including a brief with the current excerpt and note selected. Use an isolated database for API and browser checks.

Merging into `main` can trigger the Azure production workflow after the Linux job passes, independently of the Windows result. The implementation PR can proceed through CI. Treat merge and release authorization as a separate gate. Record Windows and Linux results on the exact reviewed head before release handoff.

## Verification record

- `f9dbdec` baseline, isolated source archive on macOS. The portable Python backend passed 190 tests. One Starlette TestClient deprecation warning.
- First integration pass after the three lanes began landing. 191 passed and one failed. The independent history case passed cursor, prior text isolation, redacted download, SQLite round trip, JSON restore into an empty workspace, and identical JSON restore without history loss.
- **Closed, P2. The editor could save a role that could not be exported.** The first role check stored a role whose compact portable file was 2,007,122 bytes. Export returned 413 because the export and picker capped files at 2,000,000 bytes and create accepted a 2 MiB body. The corrected 4 MiB allowance covers role create, edit, preview, import, export, and picker. At all field limits, a compact file measures 2,103,140 bytes for four-byte Unicode and 3,154,380 bytes for six-byte JSON control-character escapes. Both forms passed independent export, preview, and import across separate databases. Writes exceeding 4 MiB still returned 413, and an unrelated interview create retained the 2 MiB limit.
- Corrected integration snapshot on macOS. 210 Python tests and independent API checks passed. The attribution case authenticated two successive assigned operators with one entitlement lookup per mutation. The earlier revision kept its original actor, save time, and note after the second operator edited the answer.

### History read benchmark

One synthetic answer had about 9.7 KB of current data, with two references and a fixed-length review note. Recorded 1,000 review updates through the HTTP API. Measured 50 warm requests per path against the local FastAPI listener on macOS. The first, middle, and oldest samples used metadata pages of 50 rows.

| Response | Bytes | Median ms | P95 ms |
| --- | ---: | ---: | ---: |
| Current answer, before 999 further updates | 9,674 | 1.57 | 2.40 |
| Current answer, after 999 further updates | 9,677 | 1.28 | 1.52 |
| Interview detail, before 999 further updates | 10,041 | 1.56 | 1.90 |
| Interview detail, after 999 further updates | 10,044 | 1.34 | 1.66 |
| First 50 revisions | 6,088 | 2.02 | 4.81 |
| Middle 50 revisions | 6,086 | 2.29 | 4.65 |
| Oldest 50 revisions | 6,026 | 2.12 | 3.89 |
| Body of revision 500 | 9,748 | 1.65 | 1.96 |

Ordinary response fields were identical. The three added bytes came from the revision number. These timings describe the local fixture and do not establish a production latency target.
