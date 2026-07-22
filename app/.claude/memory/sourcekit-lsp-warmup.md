---
name: sourcekit-lsp-warmup
description: "0 LSP references right after session start = index warm-up race, not stale config; check diagnostics for fallback-args errors, retry after warm-up."
metadata:
  node_type: memory
  type: project
---

`findReferences`/`workspaceSymbol` returning **0 results shortly after a session starts is a warm-up race, not a configuration problem**. Diagnosed 2026-07-22: the same `findReferences` query on `BobnetFeature` returned 0, then 16 refs across 5 files a few minutes later, with no config change and no manual build.

**Why:** Each Claude Code session launches a fresh `sourcekit-lsp`. It auto-discovers `Modules/Package.swift` (verified via `lsof`: the server opens `Modules/.build/index-build/.../index/db/v13/p<pid>--<hash>/`) — no buildServer.json or index path config is needed for the package. But on startup it must (1) *prepare* targets — building macro plugins (TCA, CasePaths) and the OpenAPI generator plugin — and (2) import ~3,500 shared unit files into a fresh **per-process** LMDB database. Until that finishes, reference/symbol queries return empty and semantic answers use fallback compiler args.

**How to tell "index cold" from "genuinely 0 references":** check the file's diagnostics. Fallback-args errors like `No such module 'ComposableArchitecture'`, `External macro implementation ... could not be found`, or bogus `Cannot find X in scope` mean the target isn't prepared yet → **wait and re-query** instead of falling back to grep. Clean diagnostics + full hover info mean the index answer is trustworthy.

**Speed-ups / gotchas:**
- A prior `swift build`/`swift test` in `Modules/` makes target preparation near-instant (artifacts already exist), but the per-process db import still takes a little time.
- Multiple concurrent sessions each run their own `sourcekit-lsp` against the same `Modules/.build`, and can serialize on the SwiftPM build lock — warm-up takes longer when parallel jobs are building.
- A `.build`/`app/.build` dir at other levels of the repo is leftover noise from mis-rooted runs; the live store is `Modules/.build/index-build`.
- `macOS/` app-target files (xcodeproj) remain uncovered without xcode-build-server — grep is still the tool for that sliver, per CLAUDE.md.

See [[running-package-tests]] and [[spm-stale-layout-crash]] for related `.build` hygiene.
