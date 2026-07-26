---
name: sourcekit-lsp-warmup
description: "FIXED 2026-07-25: .sourcekit-lsp/config.json now points LSP at SwiftPM's swiftbuild BSP server so it reads the index YOUR builds write. Requires scripts/link-index-store.sh (upstream advertises .build/index-store but builds write .build/out). Background info on the old lazy/stale-index behaviour retained below."
metadata:
  node_type: memory
  type: project
---

## Current setup (working — verified 2026-07-25)

`Modules/.sourcekit-lsp/config.json`:

```json
{ "backgroundIndexing": false, "swiftPM": { "buildSystem": "swiftbuild" } }
```

This makes sourcekit-lsp launch `swift package experimental-build-server --build-system swiftbuild` and read the index store **your own `swift build` produces**, instead of maintaining a second 3.8 GB index build of its own. `swift build` has `--auto-index-store` on by default, so building keeps the index current — including code you just wrote.

**One required local step, per checkout/worktree:** run `Modules/scripts/link-index-store.sh` after your first `swift build`.

Why it's needed: SwiftPM's BSP server advertises `indexStorePath: .build/index-store`, but the swiftbuild engine compiles with `-index-store-path .build/out` — so the advertised store is empty and every query returns nothing. (Confirmed by driving `build/initialize` against the BSP server directly; it also reports `indexDatabasePath: .build/out`, which looks like the two paths are crossed.) The script symlinks `.build/index-store -> out` so they agree. Re-run it after anything that wipes `.build`. **This looks like an upstream bug worth reporting** against swiftlang/swift-package-manager.

Measured before/after on the same symbols: `SiteAssay` (written that day, used in 6 files) went **0 → 45 references across 8 files**; `ResourceSite` 0 → 19. Both had returned 0 under the swiftbuild config until the symlink was added.

Trade-off to know: with `backgroundIndexing: false`, LSP no longer indexes on its own — **the index is only as fresh as your last build.** Build, then query. In exchange there's no lazy-indexing lag, no duplicate index build, and no build-lock contention (6.4 passes `--experimental-skip-acquiring-lock` in this mode specifically so LSP doesn't block your builds).

## Why the default behaviour was so confusing (background)

Left here because the default config will still be in play in other checkouts, and because every subagent on the salvage branch independently concluded "LSP is broken".

**Discriminator:** query a long-existing symbol, then one just added. On main, `ResourceSite` returned 18–19 references while `SiteAssay` returned 0, same server, same moment. `hover` answered both — hover needs no cross-file index. "hover works, findReferences empty" = the index hasn't covered that symbol.

**Layer 1 — separate store.** By default (`backgroundIndexing: true`) sourcekit-lsp does *not* read your build's store. `SwiftPMBuildServer.swift` sets its scratch dir to `.build/index-build` — the source comment says "independent of the user's build" — and hardcodes `buildSystemKind: .native`. Indexing there is **lazy and demand-driven**: a server held open with four files added ~22 units in 60s then plateaued; files nobody opened were never indexed at all.

**Layer 2 — refresh is deliberately rare.** `pollForUnitChangesAndWait()` runs only at initial indexing, after LSP's own index tasks, and on `workspace/synchronize`. The source explains why: "a costly operation since it iterates through all the unit files on the file system… worth the cost during initial indexing and during the manual re-index command." **Nothing triggers it when an external process writes units**, which is why a manual index-store prime never showed up in a running session while a freshly spawned server saw it immediately.

**The native default is explicitly temporary.** `BuildServerManager.swift` selects the build system as: explicit `swiftPM.buildSystem` wins; otherwise background-indexing → `.native` with the comment *"default to native **for now**"*; otherwise it infers from `.build` contents ("to match the user's manually initiated builds to maximize compatibility"). So sharing the user's build system was always intended — it just isn't the default yet.

**Dead ends — don't retry.** `index.indexStorePath` **does not exist** in 6.4.x; `IndexOptions` has only `indexPrefixMap`, `maxCoresPercentageToUseForBackgroundIndexing`, `updateIndexStoreTimeout`, so that key is silently dropped. `backgroundIndexing` already defaults to `true`. And `workspace/triggerReindex` exists but re-runs the whole graph+index pipeline — on this package it showed no new units after a minute and reads as a hang.

**Verifying the config is actually read:** set `swiftPM.configuration: "release"` temporarily — a known-good symbol should drop to 0 references, because the scratch subdirectory changes. That's how the config file's location was confirmed.

`macOS/` app-target files (xcodeproj) stay uncovered without xcode-build-server — grep remains the tool for that sliver.

See [[running-package-tests]] and [[spm-stale-layout-crash]] (which records the swiftbuild/native split behind all of this).
