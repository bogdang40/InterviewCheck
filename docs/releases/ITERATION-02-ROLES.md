# Role portability

An operator can move one saved role between workspaces or make a separate copy in the same library. A role file contains its portable UUID, name, description, ordered questions, assistance policy and permitted materials. Free text entered into those fields travels with the file.

## Contract

1. Download one role through the protected role router. Use the format identifier `interviewcheck.role-kit` and integer version 1. Select only the portable fields. Keep the native export and workspace backup formats separate. Verify that the exported role can be imported under the existing role input limits.
2. Extend the existing role file preview and import paths. Validate the envelope, required UUID, field types and bounds. Compare decoded content by ID. A new ID can be imported. Identical content is an idempotent duplicate. Different content at the same ID is a conflict. Check again in the import transaction so a change after preview cannot overwrite a stored template. Native version 1 imports retain their existing behavior.
3. Add export and duplicate actions to the role library. A duplicate starts from the selected role, keeps its editable fields and uses a new UUID. Use the existing role create contract. Keep that UUID stable if a write must be retried. Library edits continue to use the role version check.
4. Test with fictional roles in temporary databases and through the browser. Cover Unicode, ordered and repeated questions, policy and materials, identical reimport, a conflict after preview, independent clone edits, and retained native import behavior. Check the actual downloaded JSON against the field list and a synthetic legacy record containing private metadata. Check controls on a narrow screen.

## Ownership

The role lane owns the role file module, the role routes in `session_workflow.py`, portable dispatch in `migrate.py`, the role request limit, role library controls and role tests.

## Verification

The API tests moved a template between temporary databases, detected a conflict after preview, preserved a frozen interview when its role copy changed, and rejected a native template outside the portable limits. The role create, edit, export and file input paths support 4 MiB. The independent tests exercised maximum size Unicode and escaped JSON content and checked the request limit for other routes. Chrome downloaded the actual file, imported it into a second database, detected a duplicate and saved independent edits to a clone on a 320 pixel screen. The native import browser test also passed.

Role implementation is frozen for the integrated review. Focused verification on macOS passed 18 role and migration service tests, 3 independent capacity and request boundary tests, and 2 Chrome workflows on the Next.js development server. The shared release orchestrator owns the production build and CI.
