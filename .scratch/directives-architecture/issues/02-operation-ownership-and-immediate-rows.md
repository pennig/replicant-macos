# 02 — `operations` ownership columns + a row for every immediate verb

Type: task
Status: open
Blocked by: 01
Labels: directives-architecture, stage-0

Spec S0.1. Today an `Operation` row has no owner and ~25 immediate verbs (`stow`, `adopt`, `set_directive`, `activate`, `deploy`, `launch`, `recall`, `deactivate`, `attach`, `detach`, `configure`, `collect_resources`, `deposit_resources`, every `.simple`) write no row at all (`CommandClient.swift` `.immediate` branch, was `:98-153`). After this ticket every dispatch — immediate or tracked — writes a row carrying `directiveID`, `step` and `paramsDigest` when the dispatcher is a directive, and the Operations Log shows those rows honestly (D1).

**Files:**
- Modify: `app/Modules/GameModels/Sources/Operation.swift` (struct + new migration)
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift` (append migration to `manifest`)
- Create: `app/Modules/GameServices/Sources/CommandOwner.swift`
- Modify: `app/Modules/GameServices/Sources/CommandParams.swift` (`dedupKey`)
- Modify: `app/Modules/GameServices/Sources/CommandClient.swift` (`dispatchOwned`, immediate rows, owner on optimistic insert)
- Modify: `app/Modules/GameServices/Sources/CommandGovernor.swift`, `CommandGovernorClient.swift` (`owner:` threaded through; de-dup itself is ticket 03)
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift` (`.dispatch` case passes the owner)
- Test: `app/Modules/GameModels/Tests/SchemaManifestTests.swift`, `GoldenSchemaTests` fixture (regenerate deliberately), `app/Modules/GameServices/Tests/CommandClientTests.swift` (extend), `app/Modules/DirectiveEngine/Tests/DirectiveEngineTests.swift` (extend)

**Interfaces:**
- Produces:
  ```swift
  // GameServices/Sources/CommandOwner.swift
  public struct CommandOwner: Sendable, Equatable {
      public let directiveID: String
      public let step: String
      /// The dispatching directive's `stepStartedAt`; the de-dup window opens here (ticket 03).
      public let since: Date
      public init(directiveID: String, step: String, since: Date)
  }
  // Operation gains
  public var directiveID: String?
  public var step: String?
  public var paramsDigest: String?
  // CommandParams gains
  public var dedupKey: String   // canonical JSON of the set fields, keys sorted, no whitespace
  // CommandClient gains (dispatch stays and calls this with owner nil)
  public var dispatchOwned: @Sendable (OperationKind, String, CommandParams, CommandOwner?) async -> CommandOutcome
  // CommandGovernorClient gains (dispatch stays and calls this with owner nil)
  public var dispatchOwned: @Sendable (OperationKind, String, CommandParams, CommandOwner?) async -> CommandDispatchResult
  ```
- Consumes: nothing new.

---

- [ ] **Step 1: Migration + struct**

In `Operation.swift`, add the three optional properties after `detail`, add them to `init` with default `nil` (keep the existing parameter order; append `directiveID: String? = nil, step: String? = nil, paramsDigest: String? = nil` at the end), and append:

```swift
extension Operation {
    /// Appended, never folded into `createOperations`: that one has shipped.
    public static let addOwnerColumns = SchemaMigration("Add 'directiveID','step','paramsDigest' to 'operations'") { db in
        try #sql(#"ALTER TABLE "operations" ADD COLUMN "directiveID" TEXT"#).execute(db)
        try #sql(#"ALTER TABLE "operations" ADD COLUMN "step" TEXT"#).execute(db)
        try #sql(#"ALTER TABLE "operations" ADD COLUMN "paramsDigest" TEXT"#).execute(db)
        try #sql(#"CREATE INDEX "operation_by_directive" ON "operations" ("directiveID", "startedAt")"#).execute(db)
    }
}
```

Append `GameModels.Operation.addOwnerColumns` as the LAST entry of `GameDatabase.manifest`.

- [ ] **Step 2: Freeze the schema change**

Run `SchemaManifestTests` (expect the identifier-list assertion to fail), update its expected list, then regenerate the golden schema with `RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --filter GoldenSchemaTests` and inspect the diff: exactly three columns and one index added to `operations`. Commit: `feat(ops): add directiveID/step/paramsDigest to operations`.

- [ ] **Step 3: `CommandOwner` + `dedupKey` with tests**

Create `CommandOwner.swift` as in Interfaces. In `CommandParams.swift` add:

```swift
extension CommandParams {
    /// Canonical form for de-dup: the SET fields only, keys sorted, no whitespace.
    public var dedupKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // `json` already omits nil fields (see the family builders); encode it.
        return (try? String(decoding: encoder.encode(json), as: UTF8.self)) ?? "{}"
    }
}
```

(`CommandParams.json` exists and is what the optimistic insert stores; if it is not `Encodable`, encode via `JSONValue`'s existing serialiser — check `Utils/JSONValue`.) Test in `CommandClientTests.swift`:

```swift
@Test func dedupKeyIsOrderIndependentAndOmitsNil() {
    var a = CommandParams(); a.destination = "SOL"; a.quantity = 2
    var b = CommandParams(); b.quantity = 2; b.destination = "SOL"
    #expect(a.dedupKey == b.dedupKey)
    var c = CommandParams(); c.destination = "SOL"
    #expect(a.dedupKey != c.dedupKey)
}
```

- [ ] **Step 4: Thread the owner through client and governor**

`CommandClient`: rename the existing closure body to `dispatchOwned` taking `owner: CommandOwner?`; define `dispatch` as `{ kind, code, params in await Self.liveValue.dispatchOwned(kind, code, params, nil) }` is NOT acceptable (recursion through the static); instead build the closure once in a `private static func makeDispatchOwned() -> ...` and set both properties from it in `liveValue`. `testValue`: `dispatchOwned: unimplemented("CommandClient.dispatchOwned", placeholder: .failed("unimplemented"))`. `previewValue`: mirrors `dispatch`.

`CommandGovernor.dispatch(_:on:params:owner:)` takes `owner: CommandOwner?` and passes it to `commandClient.dispatchOwned`. `CommandGovernorClient` gains `dispatchOwned` (same test/preview treatment); `dispatch` calls it with `nil`.

- [ ] **Step 5: Owner on the optimistic insert; a row for immediate verbs**

In the tracked path, the optimistic `Operation(` gains `directiveID: owner?.directiveID, step: owner?.step, paramsDigest: params.dedupKey`.

In the `.immediate` branch, after the `switch output` resolves to an outcome and BEFORE returning, insert one terminal row:

```swift
let stamp = date.now
let record = Operation(
    id: uuid().uuidString, entityCode: deviceCode, kind: kind.rawValue,
    status: status,                       // .completed / .rejected / .failed per branch
    source: .optimistic,
    startedAt: stamp, completesAt: nil, lastConfirmedAt: stamp,
    detail: .object(["params": params.json] + (message.map { ["message": .string($0)] } ?? [:])),
    directiveID: owner?.directiveID, step: owner?.step, paramsDigest: params.dedupKey
)
try? await database.write { db in try Operation.insert { record }.execute(db) }
```

Restructure the branch so each `case` sets `(status, message)` and falls through to one insert + one return; keep the terminating-command `completeOpenOperation` call and the confirm-read exactly where they are (they run before the insert for `.ok`).

- [ ] **Step 6: Executor passes the owner**

`DirectiveExecutor.apply` `.dispatch` case: `commandGovernor.dispatchOwned(kind, deviceCode, params, CommandOwner(directiveID: directive.id, step: directive.step, since: directive.stepStartedAt))`.

- [ ] **Step 7: Tests**

`CommandClientTests.swift` — using the existing test harness for the client (it stubs `gameClient`; follow the pattern in the file's travel tests):

```swift
@Test func immediateVerbWritesATerminalOwnedRow() async throws {
    // stub gameClient POST /devices/{code} → 200 {}
    let owner = CommandOwner(directiveID: "D1", step: "stowing", since: .distantPast)
    let outcome = await client.dispatchOwned(.stow, "RELAY1", CommandParams(target: "CARRIER"), owner)
    #expect(outcome == .accepted(operationID: nil))
    let rows = try await database.read { try Operation.where { $0.entityCode.eq("RELAY1") }.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows[0].status == .completed)
    #expect(rows[0].directiveID == "D1" && rows[0].step == "stowing")
    #expect(rows[0].kind == "stow")
}
@Test func immediateRejectionWritesARejectedRow() async throws { /* stub 400; expect .rejected row with detail.message */ }
@Test func trackedDispatchCarriesOwner() async throws { /* travel; expect optimistic row directiveID == "D1" */ }
```

`DirectiveEngineTests.swift`: extend the existing "dispatch writes commandDispatched" test to assert the governor stub received a non-nil owner whose `since == directive.stepStartedAt`.

- [ ] **Step 8: Run all five targets; commit**

`feat(ops): every dispatch writes an owned Operation row`. Then check that the Operations Log (`ActivityView`, DevicesFeature) renders the new rows without a crash: it fetches unfiltered, so a `stow` row appears — this is intended. If the row's summary formatter switches on kind exhaustively, add a default line `"<kind> — completed"`.
