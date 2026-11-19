# Exchange history UI

**Frozen for integration and independent review.**

The saved exchange now has a Revision history disclosure above the assessment form. It reads metadata when opened and fetches one selected snapshot at a time. The picker identifies the current and earlier saved revisions. When another view has saved a newer revision, the panel identifies both the editor revision and the latest saved revision. The baseline shows unknown operator and save time. A saved snapshot includes the question, candidate response, outcome, note, available lineage, sources and comparison findings.

The current assessment owns its draft throughout inspection. The history panel has no mutation action. Closing it returns focus to its trigger. Changing metadata pages returns focus to the picker. The download and restore controls explain the difference between current state JSON recovery and full SQLite history.

## Verification

The portable static export compiled and passed TypeScript in a scratch copy of the release checkout. Chrome exercised the export against FastAPI with isolated SQLite databases and synthetic interview records. All six tests passed in 9.64 seconds in the following run.

```sh
python -m pytest -q qa/test_revision_history_ui.py qa/test_review_workbench.py
```

The three focused history tests cover:

1. Two views edited the same review. After the stale save, keyboard selection opened the earlier baseline. Closing history restored focus and preserved the first view's unsaved note. The database retained the second view's saved note. History issued only GET requests.
2. An earlier snapshot response was held while the reviewer switched questions. Releasing the original response did not replace the second answer's displayed snapshot.
3. A history of 22 revisions crossed the metadata page boundary. Keyboard focus returned to the picker in both directions. A simulated 503 on the selected snapshot displayed a retry control that fetched the real saved revision successfully.

Desktop and 320 pixel phone screenshots were inspected in the default dark theme. The phone layout stayed within the viewport. The focused test writes both screenshots to its pytest temporary directory. The existing queue, stale draft recovery and Unicode passage attribution tests also passed.

The main failure mode is a delayed history response appearing under the wrong answer. The delayed response test exercises that boundary with the real history API. The orchestrator owns release integration and CI.
