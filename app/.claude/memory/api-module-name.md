---
name: api-module-name
description: "The local Swift package is named ReplicouldKit but the importable module/target is \"API\""
metadata: 
  node_type: memory
  type: project
  originSessionId: eb0d443f-fe59-4aee-aee3-614051786294
---

In `app/Modules/Package.swift`, the package is named `ReplicouldKit`, but the library
target/module containing the OpenAPI client and event pipeline is named **`API`**

Test files must use `@testable import API` (not the package name) and additionally
`import Utils` when they reference `JSONValue`.

**How to apply:** when adding/fixing tests or app imports for this package, import
the specific module (`API`, `Utils`, `MessagesFeature`, …), never the package name
`ReplicouldKit`. The generated OpenAPI `Client` and `Components.Schemas.*` types
live in the `API` module.
