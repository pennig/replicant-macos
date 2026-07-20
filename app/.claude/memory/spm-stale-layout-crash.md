---
name: spm-stale-layout-crash
description: Adding stored fields to a shared struct can segfault consumer modules until .build is cleaned
metadata: 
  node_type: memory
  type: feedback
  originSessionId: acf63055-6a9a-4ae6-b6f4-c4d5ed6f2b46
---

Local SPM modules compile WITHOUT library evolution, so a struct's memory layout is baked into every consumer module at compile time. Adding stored properties to a shared type (e.g. new optional fields on `SystemStar` in `UniverseModels`) changes the layout of anything containing it (`StarSystem`), and SPM's incremental build sometimes does NOT recompile a downstream consumer (e.g. `LocationsFeature`) — leaving it reading the old field offsets.

**Symptom:** `swift test` crashes with **signal 11 (segfault)**, not a clean failure — backtrace shows garbage array access like `_ArrayBuffer.count.getter` inside a `.map` over the struct's arrays. It reproduces per-module in isolation, passes on a clean HEAD, and the changed types' own tests pass (they were recompiled).

**Why:** stale `.o` in the consumer, not a code bug.

**How to apply:** when a segfault appears after adding/removing stored fields on a cross-module type, don't hunt for recursion — `rm -rf Modules/.build` and re-run. Grab the real backtrace from `~/Library/Logs/DiagnosticReports/swiftpm-testing-helper-*.ips` (parse the JSON, faultingThread frames) since `SWIFT_BACKTRACE` is disabled for the privileged test helper.

**Also hits the Xcode app run, not just `swift test`.** Adding `@State` stored properties to a PUBLIC SwiftUI `View` in a module (e.g. new `nebulaConfig`/`nebulaParams` on `NewStarMapView`) changes the view's size; the app target keeps the old smaller layout under Xcode's INCREMENTAL build, so when `MainView.content` constructs the view it allocates too small and the init corrupts the heap. **Symptom:** `EXC_BAD_ACCESS` in `swift::RefCounts::incrementSlow` (an ARC retain) inside `ViewBuilder.buildBlock` while building the view — a wild address, not a nil. `BuildProject` reports success and the crash still happens. **Fix:** clear the Xcode build products too — `rm -rf ~/Library/Developer/Xcode/DerivedData/<proj>-*/Build` (and `Modules/.build`), then a full rebuild (~80s vs the usual ~6s incremental confirms it actually recompiled). A one-line default-value change afterward rebuilds incrementally and safely (no layout change).
