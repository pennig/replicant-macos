---
name: running-package-tests
description: "SPM module tests ARE in the Xcode test plan — schemes with test targets run as expected; `swift test` also works."
metadata:
  node_type: memory
  type: project
  originSessionId: 7557982c-5cd6-43df-82ab-61f339812e78
---

SPM module tests run fine through Xcode: the schemes with test targets are wired up and work as expected (an earlier note that the test plan had no targets was outdated/from before schemes were regenerated — corrected by the user 2026-07-05).

**How to apply:** Prefer the Xcode test tooling (`RunSomeTests`/`RunAllTests` via xcode-tools) for module tests. `swift test --filter <Suite>` from `/Users/matt/Developer/replicant-macos/app/Modules` also works and is handy for a quick single-suite run from the CLI. Use `BuildProject` (xcode-tools) for compiling the whole app. See [[api-module-name]].

**Each module has its own shared scheme** (in the `Modules` container: `DevicesFeature`, `GameServices`, `UI`, etc.). The default active scheme is the app scheme **`Replicould`, which carries NO test targets** — so `GetTestList`/`RunSomeTests` return "0 tests / target not found" against it. To run a module's tests via the Xcode tooling, **first `XcodeSwitchScheme` to that module's scheme** (e.g. `DevicesFeature`), then `GetTestList`/`RunSomeTests`/`RunAllTests`. (User pointed this out 2026-07-19 — don't fall straight back to `swift test` when the app scheme shows no tests; switch schemes instead.)

**Two gotchas hit 2026-07-10:** (1) A *newly added* SPM test target is NOT auto-picked-up by the "Replicould" test plan — `GetTestList` returned 0 tests right after adding `NewStarMapFeatureTests`' first suite, so the Xcode tooling couldn't run it until the scheme/test plan is regenerated (the user has to do this in Xcode). Existing test targets are fine. (2) `swift test` failed to *link* the macro-plugin tools (`CasePathsMacros-tool`, undefined SwiftSyntax symbol) from a stale `Modules/.build` — `rm -rf Modules/.build` then re-run fixed it (~2 min full rebuild). Same root cause as [[spm-stale-layout-crash]].
