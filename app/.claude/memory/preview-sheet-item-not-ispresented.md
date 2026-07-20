---
name: preview-sheet-item-not-ispresented
description: "Travel/print preview sheets must use .sheet(item:) not isPresented, or rapid back-to-back presentations drop"
metadata: 
  node_type: memory
  type: project
  originSessionId: 9006fba4-1c5b-4dcd-a09e-9d2c9b6a59c6
---

The `travel` route-review and `print` confirmation sheets (backed by `TravelPreview` / `PrintPreview`, both `Identifiable` in GameModels) must be presented with `.sheet(item:)`, NOT `.sheet(isPresented: Binding(get: { store.travelPreview != nil }))`.

**Why:** With an `isPresented` bool, presenting a new preview for a different device/location in quick succession toggles the bool off (dismiss) then on (present) within the dismiss-animation window. SwiftUI coalesces and silently drops the re-presentation, so the dialog never appears the second time. `.sheet(item:)` keys on the preview's identity and swaps sheets reliably across rapid device-to-device switches. Content still reads `store.travelPreview` live (closure param ignored) so the loading→loaded phase renders.

**How to apply:** Three travel entry points fixed this way — `DeviceDetailView` (DevicesFeature), `NewStarMapView` (NewStarMapFeature), `LocationDetailView` (LocationsFeature). Each reducer's `travelPreviewRequested` effect also got `.cancellable(id: CancelID.travelPreview, cancelInFlight: true)` so a prior device's late dry-run response can't overwrite the current preview's phase (the `travelPreviewResponse` guard only checks non-nil, not which device).

Note: two `.sheet` modifiers on one view DO work on macOS 26 — that was a wrong first guess; the real bug was the isPresented re-presentation race. See [[replicants-feature]].
