---
name: headless-swiftui-render-probe
description: "A temporary test-target file renders any SwiftUI view (Charts included) to PNG headlessly via NSHostingView + cacheDisplay, so a chart change can be LOOKED AT from a background job. Must paint an explicit surface background or dark-mode text renders white-on-white and reads as missing."
metadata:
  node_type: memory
  type: project
---

`swift build` and the test suite cannot see a squashed axis, a clipped label, or a legend
that lost its text. For any chart or layout change, render it and look at it. The route
that works from a background job — no app launch, so no Keychain wall
([[no-gui-verification-from-bg-jobs]] on the user side) — is a **temporary file in the
feature's test target**, run with `--filter`, then deleted before commit.

The shape: `NSHostingView(rootView:)` sized to a fixed frame, attached to a plain
`NSWindow`, `host.appearance = NSAppearance(named: .darkAqua / .aqua)`, then
`layoutSubtreeIfNeeded()`, `RunLoop.current.run(until: +1.0s)` — Charts needs the runloop
turn or the plot comes out empty — then `bitmapImageRepForCachingDisplay(in:)` +
`cacheDisplay(in:to:)` + `representation(using: .png)` written to an absolute path outside
the repo. A `@Suite(.serialized) @MainActor` struct holds it. Internal views need only
`@testable import`, so nothing about the production code has to be loosened to see it.

**Paint an explicit background or dark mode lies to you.** A bare hosting view has a
transparent (white-rendering) backdrop, so `.rcTextPrimary` in dark appearance is white on
white: the first pass showed a donut with no total in the hole and a legend of colored dots
with no labels, and both were *correct in the app* — the light render proved it in one
look. `.background(Color.rcSurfaceRaised)` fixes it. Render BOTH modes every time; the pair
cross-checks each other, and dark-first (this app's rule) means dark is the one you would
otherwise ship broken.

Render at the size the view really gets, in the container it really sits in. The By Source
breakdown looked fine alone and cramped in its real `HStack` beside the donut, because the
squeeze was a fixed 160pt frame holding nine rows — a defect no assertion in the suite was
ever going to state.
