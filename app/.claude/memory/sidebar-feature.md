---
name: sidebar-feature
description: "SidebarFeature module — signed-in window's left column, extracted from MainFeature."
metadata: 
  node_type: memory
  type: project
  originSessionId: a152c5b7-926a-4e21-ab2a-d531fc3ba240
---

`SidebarFeature` (Modules/SidebarFeature) owns the signed-in window's whole left column: the active-replicant header (switcher + live progress + editable plan), the grouped category `List`, and the account footer + Account sheet. It also owns the **category selection** (`SidebarItem`, moved here and made public); `MainView` reads `store.sidebar.category` to drive its content/detail panes. `MainFeature` is now a thin container that scopes child features + `detailSelection`; it bridges `sidebar.delegate(.loggedOut)` → its own `.delegate(.loggedOut)` and `sidebar.delegate(.categoryChanged)` → reset `detailSelection`.

Deps: GameServices, UI, MessagesFeature (unread-badge `Message` query), ReplicantsFeature (`replicantsClient` for plan load/save). Session bootstrap (`refreshAccount` on `.task`) stays in MainFeature.

The header progress bar is derived from the **Operation table** (`SidebarProgress.active/row`, a SwiftUI-free namespace — see [[swiftui-view-statics-trap-in-tests]]), not the device's live activity block, so it clears atomically the instant an op completes — in lock-step with the device inspector's bar. Uses [[device-command-shapes]] op kinds. Related: [[replicants-feature]].
