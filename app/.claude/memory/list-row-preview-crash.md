---
name: list-row-preview-crash
description: Xcode 26 Previews crash when a List row is a custom View struct defined in the same file as the
metadata: 
  node_type: memory
  type: project
  originSessionId: 975ecfe7-f068-4427-b7a3-bc1cc500602c
---

Xcode 26 / macOS 26 has a SwiftUI Previews bug: the preview agent crashes with an assertion in `ViewListTree.visitItem` (SIGTRAP) whenever a macOS `List` row is a **custom `View` struct that the preview JIT recompiles in the same file as the `#Preview`**. Reduced/verified: `List { ForEach { CustomRow(...) } }` crashes; the identical content inlined into the `ForEach` renders; a trivial `struct Row { Text }` also crashes; the same struct in a **separate (prebuilt) file** renders. Reproduces across modules, survives clean build + cache wipe. The shipping app binary is unaffected (never uses the preview JIT path); only previews crash.

**Fix / convention adopted:** row `View` structs used in a `List` live in their **own file**, not nested beside their `*ListView` + `#Preview`. Already done for: `MessageRow` (MessagesFeature), `BlueprintRow` (BlueprintsFeature), `ActivityRow`/`BobnetRow` (DevicesFeature), `LocationEventRow` (LocationEventsFeature), `LocationOutlineRow`/`LocationRow`/`ReconDot` (LocationsFeature → LocationRows.swift). When extracting, a `private` row must become `internal` so its `*ListView` (now in a different file) can see it.

**Why:** keeps preview-driven development working without changing how anything renders.
**How to apply:** any NEW `List`-based content view — put its row struct in a separate file from the `#Preview` from the start. If a `List` preview crashes with a `ViewListTree.visitItem` / `XCPreviewAgent may have crashed` error, this is the cause.
