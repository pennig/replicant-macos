---
name: sourcekit-lsp-warmup
description: "Empty LSP references = the index hasn't reached that symbol, not broken config. Indexing is LAZY (demand-driven by open files) and each server imports the store ONCE at startup, so a long-lived session never sees newly indexed symbols. Don't point LSP at the swiftbuild store — indexStorePath is ignored for SwiftPM."
metadata:
  node_type: memory
  type: project
---

`findReferences`/`workspaceSymbol` returning **0 results is the index not covering that symbol, not a configuration problem.** First diagnosed 2026-07-22; substantially corrected and extended 2026-07-25 after every subagent on a feature branch independently concluded "LSP is broken".

**Sharpest discriminator:** query a long-existing symbol, then one your branch just added. On main, `ResourceSite` returned 18–19 references while `SiteAssay` — added that day, referenced from six files — returned 0, from the same server in the same session. `hover` answered both. **"hover works but findReferences is empty" means the index hasn't covered that symbol**, not that config is broken.

## Two layers, and the second one is the trap

**Layer 1 — the shared index store.** sourcekit-lsp does *not* read the store your `swift build` produces. It runs its own build into `Modules/.build/index-build/` (native/llbuild layout) and reads `…/arm64-apple-macosx/debug/index/store/v5/{units,records}`.

Indexing there is **lazy and demand-driven, not a proactive whole-package sweep.** Measured 2026-07-25: holding a server open with four files opened added ~22 units in the first 60s then **plateaued completely** for the next 90s. Files nobody opened were never indexed at all — `ResourceAmountRows.swift` still had zero units after the entire exercise. "Leave it running and it'll finish" is false.

**Layer 2 — each server imports the store into its own per-process LMDB database at startup and does not pick up units added later.** Proven directly: with `SiteAssay` present in the shared store, a *freshly spawned* sourcekit-lsp returned 2 references while the long-running session's server returned 0 — same store, same second. **Waiting cannot fix a long-lived session; only a new server process (a new Claude Code session) sees newly indexed symbols.** This is why the old "wait and re-query" advice kept failing for same-session code.

## Two dead ends — don't repeat them

- **`index.indexStorePath` is ignored for SwiftPM workspaces.** The `swiftbuild` engine writes a genuinely complete, current store to `Modules/.build/out/v5/` (it had units for every new file while LSP's store had none), so redirecting LSP at it looks like the obvious fix. It does nothing: setting `indexStorePath` to `/tmp/definitely-not-an-index-store` still returned 18 references. A `.sourcekit-lsp/config.json` was created and deleted during this investigation.
- **`backgroundIndexing` is already on by default.** The store grew 3543 → 3741 units across sessions that never set it.
- The tempting theory that "swiftbuild writes to `.build/out` so LSP can't find its index" is **wrong on both counts** — LSP never uses that store, and its own store works fine, it's just incomplete.

## How to apply

- Empty refs on **long-existing** code → warm-up; wait and re-query. A prior `swift build` in `Modules/` makes target *preparation* near-instant.
- Empty refs on **code written this session**, or in a **fresh worktree** (which starts from an empty index — the expensive case, and what bit every subagent on the salvage-amounts branch) → the running server will never see it. Either restart the session, or use the compiler as the source of truth: a clean `swift build --build-tests` type-checks every cross-module call site, which is what `findReferences` was approximating. State which you used.
- Cold-index noise reads exactly like real errors. `No such module 'ComposableArchitecture'`, `Cannot find 'SiteAssay' in scope`, `Type 'SystemDetail' has no member 'where'` all appeared constantly during the salvage branch while `swift build` stayed green throughout. **Diagnostics on code that demonstrably compiles are noise.**
- Concurrent sessions each run their own server against the same `.build` and serialize on the SwiftPM build lock.
- `macOS/` app-target files (xcodeproj) stay uncovered without xcode-build-server — grep remains the tool for that sliver.

**CLAUDE.md mandates LSP verification before sign-off.** That is only satisfiable once the index covers the symbols in question; for same-session code and fresh worktrees it generally is not, and the compiler is the honest fallback. Worth softening the mandate rather than having agents report LSP checks they could not actually perform.

See [[running-package-tests]] and [[spm-stale-layout-crash]] — the latter records the swiftbuild/native build-system split behind all of this, and had its own `rm -rf .build` ritual retired the same day.
