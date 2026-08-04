# Vertical `fixedSize` in window chrome pins the window's minimum height

**Symptom (2026-08-04, shipped in the tendMesh brain work):** selecting the
Directives sidebar item grew the window to a huge height and made it
impossible to resize vertically at all. Nothing about it looked like a layout
bug on screen — the card rendered correctly; only the window's *minimum* was
wrong.

**Mechanism, measured — not inferred.** AppKit derives a window's minimum
content height from the root view's minimum height, and SwiftUI computes that
by proposing a **near-zero width**. A `Text` carrying
`.fixedSize(horizontal: false, vertical: true)` answers a zero-width proposal
with the height it would need wrapped roughly one word per line. So an
unbounded line reports hundreds of points of "minimum" it will never use, and
the window is pinned to the sum.

**Why a `List` row never shows this:** a scroll view clamps its content's
minimum height to nothing. **Fixed chrome passes it straight to the window** —
so this only bites in a `safeAreaInset`, a sidebar header/footer, or any
non-scrolling container. `NavigationSplitView`'s
`navigationSplitViewColumnWidth(min:)` does **not** save you: the min-height
pass still proposes ~0 width regardless of the column's declared minimum
(verified with the real 280pt content column).

Measured on the real `BrainWhyView` in the real three-column split view:

| | before | after |
|---|---|---|
| window minimum height | **4,014pt** (unresizable) | **328pt** |
| card rendered (wide / narrow column) | 458 / 486 | 458 / 486 — unchanged |

**The fix is `lineLimit`, and it costs nothing visually.** Keep `fixedSize` —
it is what stops a line being *compressed* below the space it needs — and add
a `lineLimit` to bound that need. Proof the caps are not truncating: raising
them to 10 produced a byte-identical 458/486 render, so the caps bound only
the *measurement*. `RCErrorBanner` already had this right (`.lineLimit(2)`),
which makes it the house idiom for text in chrome.

**How to measure this without running the app** (the login wall blocks running
a scratch build, but this needs no signed-in app): a throwaway SPM package
depending on `Modules` by path, hosting the real view in an `NSHostingView` as
an `NSWindow`'s `contentView`, then `win.setContentSize(small)` +
`layoutIfNeeded()` and read back `win.contentLayoutRect.size`. The clamp is
the bug, directly. `NSHostingController.sizeThatFits(in:)` with a zero
proposal gives the same number analytically. (`NSHostingView.sizingOptions =
[.minSize]` + `fittingSize` returns 0×0 — a dead end, don't retry it.)

**Still open — the same defect, pre-existing, deliberately NOT fixed here:**

- `SidebarFeature/Sources/SidebarChrome.swift` `planRow` — arbitrary-length
  **user-authored** plan text with `fixedSize(vertical:)`, in the sidebar's
  non-scrolling header above `SelectableList`. A long plan pins the window
  minimum from *every* screen, not just Directives. The worse of the two.
- `BobnetFeature/Sources/BobnetChannelsView.swift` `NoRelayBanner` — a fixed
  ~95-char string with `fixedSize(vertical:)` in a `safeAreaInset`, sitting
  right beside a correctly-bounded `RCErrorBanner`.

Related: [[list-row-preview-crash]], [[swiftui-view-statics-trap-in-tests]].
