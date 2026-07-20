---
name: feature-module-import-dependencyclients
description: "A new feature module's domain client must import GameServices to resolve @Dependency(\\.gameClient)."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 74790192-5494-4cc2-912c-4dadd165ac6b
---

When adding a domain client in a new feature module (e.g. `BlueprintsClient`), the file must `import GameServices` to see `@Dependency(\.gameClient)` (and other clients vended there). Add it alongside `import API` / `import ComposableArchitecture`.

> **Note (2026-07-20):** the module was named `DependencyClients` until it was renamed to `GameServices` on 2026-07-03 (see `ARCHITECTURE_REVIEW.md`). Older notes and any lingering `import DependencyClients` refer to this same module.

**Why:** `gameClient` is a `DependencyValues` extension defined in the `GameServices` module (`Modules/GameServices/Sources/GameClient.swift`). Without the import the key path isn't in scope.

**How to apply:** The compiler error is misleading — it surfaces as "cannot infer key path type from context" / "generic parameter 'Key' could not be inferred" at the `@Dependency(\.gameClient)` line, *not* a clear "no such member" error. If you see that, the fix is almost always the missing `import GameServices`. Mirror `MessagesClient.swift`, which imports it. Relates to [[api-module-name]].
