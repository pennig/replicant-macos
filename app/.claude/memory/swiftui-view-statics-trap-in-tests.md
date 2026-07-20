---
name: swiftui-view-statics-trap-in-tests
description: "Testing pure logic that lives as a static on a SwiftUI View traps under `swift test`; extract to a plain namespace."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f0fd6b43-49b9-4019-9671-70649fedacdd
---

Pure logic (fraction math, geometry helpers) attached as a `static` func or nested type on a SwiftUI `View` cannot be unit-tested via `swift test`: referencing a symbol nested in a `View` forces realization of that view's runtime metadata, which traps with **signal code 5** in the headless test process. Symptom: tests print "started" but never "passed", and the run exits `exited with unexpected signal code 5`. A single such test may pass alone but the suite dies as soon as one constructs the View-nested type.

**Why:** the SwiftUI runtime can't initialize a View's metadata outside a GUI/app context.

**How to apply:** put testable pure logic in a plain, SwiftUI-free namespace (e.g. `enum ProgressMath`, `enum TravelBar` in `UI/Sources/ProgressGeometry.swift`) and have the `View` delegate to it. Then the tests touch only the value types. See `Modules/UI/Tests/TravelProgressViewTests.swift`. Relates to [[running-package-tests]] (SPM tests run via `swift test` from `Modules/`, not the Xcode test plan).
