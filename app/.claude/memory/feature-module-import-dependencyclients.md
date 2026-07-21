---
name: feature-module-import-dependencyclients
description: "A new feature module's domain client must import GameSession to resolve @Dependency(\\.gameClient)."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 74790192-5494-4cc2-912c-4dadd165ac6b
---

When adding a domain client in a new feature module (e.g. `BlueprintsClient`), the file must `import GameSession` to see `@Dependency(\.gameClient)`. Add it alongside `import API` / `import ComposableArchitecture`. Depend on `GameServices` only when the feature also needs engine services (Reconciler, deviceRefresher, domainFreshness, or a domain client that lives there).

> **Note (2026-07-21):** `GameClient`/`KeychainClient` moved to the new session-tier `GameSession` module (M2 split; they lived in `GameServices` 2026-07-03→2026-07-21, and in `DependencyClients` before that rename). Older notes saying `import GameServices`/`import DependencyClients` for `gameClient` refer to this same dependency at its earlier homes.

**Why:** `gameClient` is a `DependencyValues` extension defined in the `GameSession` module (`Modules/GameSession/Sources/GameClient.swift`). Without the import the key path isn't in scope (today leaky member visibility can mask the omission when the target links GameSession transitively, but it breaks the moment `MemberImportVisibility` is enabled).

**How to apply:** The compiler error is misleading — it surfaces as "cannot infer key path type from context" / "generic parameter 'Key' could not be inferred" at the `@Dependency(\.gameClient)` line, *not* a clear "no such member" error. If you see that, the fix is almost always the missing `import GameSession`. Mirror `MessagesClient.swift`, which imports it. Relates to [[api-module-name]].
