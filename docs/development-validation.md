# Development Validation Notes

This repository currently has two known validation blockers in local CLI workflows.

## Supported local workflow

- Use `./scripts/build-debug.sh` and `./scripts/build-release.sh` for app builds.
- Use `./scripts/test.sh` for XCTest runs, including focused selectors such as `./scripts/test.sh -only-testing:memanagerTests/SeparateStreamAudioRouterTests`.
- These scripts intentionally reuse `/Users/abekhadra/Desktop/Container 3/memanager/build/DerivedData` and `/Users/abekhadra/Desktop/Container 3/memanager/build/xcresult-export`.
- Do not create ad hoc `DerivedDataReview`, `DerivedDataReasoning`, `DerivedDataStarModeVerifyEsc`, or similar directories. Those duplicate caches and logs instead of reusing the canonical local build path.
- If multiple `DerivedData*` directories appear under `memanager/build`, run `./scripts/clean.sh` before the next build or test run.

## 1) `swift test` currently fails

- File: `/Users/abekhadra/Desktop/Container 3/memanager/Package.swift`
- Reason: the manifest still points at the legacy `GhostMentor` target path, but the current code lives under `memanager`.
- Current failure shape:
  - invalid custom path for target in the package manifest

This project is currently validated through the Xcode project path, not SwiftPM.

## 2) `xcodebuild test` currently fails in unsigned local CLI context

- File: `/Users/abekhadra/Desktop/Container 3/memanager/project.yml`
- Reason: signing expects a development team (`MEMANAGER_DEVELOPMENT_TEAM`) for app and test targets.
- Current failure shape:
  - signing requires a development team for `memanager` / `memanagerTests`

`./scripts/test.sh` is the canonical local entrypoint even when focused selectors are needed. If `MEMANAGER_DEVELOPMENT_TEAM` is unset, the script falls back to an unsigned local configuration, which may still hit macOS sandbox limits around `testmanagerd` depending on the environment.
