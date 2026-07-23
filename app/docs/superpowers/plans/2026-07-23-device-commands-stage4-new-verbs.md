# Device Commands Stage 4 — New Verbs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold the live-but-unsurfaced device commands into the grouped command grid — `configure`, `message`, `repair`, `change_owner` via `CommandClient`, `replicate` via the existing `ReplicantsClient` path — drop the phantom `detonate`, and pin the taxonomy with a derived-universe test.

**Architecture:** Each new POST verb gets a typed body builder in one new `CommandClient+Utility.swift` family file plus a routing line in `makeBody` (the established "new family = new file + one line" shape). The grid surfaces each verb as a `DeviceCommand` case with candidate-gating (empty candidates → hidden, the adopt/release pattern), inline parameter panels per the presentation rule (all new params are light), and the approved group placements. `replicate` does NOT go through `CommandClient` (its 201 response is deliberately unhandled there) — it dispatches through the already-shipped `ReplicantsClient.replicate` with a fleet/roster refresh, mirroring `ReplicantsFeature`'s post-replication flow.

**Tech Stack:** Swift / SwiftUI (macOS 26), TCA, swift-openapi-generator client (generated `oneOf` cases verified present: `.configure`, `.message`, `.repair`, `.changeOwner`, `.replicate`), SQLiteData `@FetchAll`, Swift Testing.

## Global Constraints

- Approved taxonomy (`.claude/memory/device-command-taxonomy.md`) governs grouping and gating: Tasks += Repair; Carrier & Cargo += Configure; Power += Message; Special = Decommission, Replicate, Set Entry Point, Change Owner (detonate dropped). `change_owner` is gated on the account having another replicant (candidate-gating, like adopt). Presentation rule: all new params are light → inline panels, no new sheets.
- `dequeue_print`, `rename`, `set_welcome_message`, `prospect` are OUT of scope (print-queue management / hub-only).
- Design tokens only in view code (`Space.*`, `Radius.*`, `.rc*`, `IconSize.*`).
- House header comment style; commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Run swift commands from `app/Modules/`. Test evidence: `swift build 2>&1 | tail -3` plus `swift test --filter <TargetName> 2>&1 | tail -6` gating on the swift-testing summary line ("Test run with N tests in M suites passed"). For event-stream-based analysis follow the repo skill `swift-test-event-stream` (do NOT combine a bare `--filter` with `--event-stream-output-path`; the swiftbuild backend truncates the shared file per test product).
- Swift-LSP protocol: LSP root `Modules/`, build once to seed the index; prefer LSP symbol queries over grep; fall back deliberately and say so.
- No pushes, no PRs — commits on the worktree branch, ff-merged to local main after final review.

## Verified API facts (probed 2026-07-23, live + openapi.json + docs)

- `configure` (surge_plate): body `{command, mode}` where mode ∈ {"taxi","manual"} (nullable). Device reports current mode top-level as `taxi_mode` (lands in `Device.detail`). Immediate.
- `message` (ftl_relay): body `{command, channel, text}`, both required. Channels are BobNet channel names (local `BobnetChannel` table, GameModels, primary key `name`). Immediate.
- `repair`: body `{command, target}` — target is a device code (docs: "repair a specific device"; the schema's extra nullable `device` field is unused — send `target`). Long-running: the device carries a `repair` block (`started_at`, `progress_percent`, `eta_seconds`); `Device.activityDeadline` already reads `repair.completes_at`, and the dispatch back-fill (`completesAt == nil` → derive from post-command read) already handles a response without a deadline. No live device currently offers `repair` (no service_bot in the roster) — implemented dormant; the grid only surfaces `available_commands`.
- `change_owner` (universal): body `{command, target}` — target is a replicant code, same account. Immediate. Account currently has 1 replicant, so this stays hidden by gating today.
- `replicate` (replicant_matrix): body `{command, target, name?}`, 201 response — already fully implemented as `ReplicantsClient.replicate(sourceMatrixCode:targetCode:name:) → ReplicateOutcome` (`.success(newReplicantCode:newReplicantName:)/.rejected/.failed`). Target must be an `empty_replicant_matrix` at the source's current location. `ReplicantsClient` lives in GameServices; DevicesFeature already depends on GameServices.
- Full universe after Stage 4 (for the derived-universe test): the 15 structured verbs (travel, start_mining, retarget, system_scan, scan, stellar_census, enqueue_print, stow, set_directive, adopt, release, attach, detach, collect_resources, deposit_resources) + `supportedSimpleCommands` (14 after detonate drops) + configure, message, repair, replicate, change_owner = **34 verbs**.

## Reference — current anchors (at branch tip, post-Stage 3)

- `app/Modules/GameServices/Sources/CommandClient.swift` — `makeBody` switch (~line 319); `completion(for:)`; the `.created` cases' comments about replicate.
- `app/Modules/GameServices/Sources/CommandClient+Lifecycle.swift` — `simpleBody` (has `case "detonate"`), `supportedSimpleCommands` (has "detonate"), `deadlineCommands = ["recall","search","compact","unfurl"]`.
- `app/Modules/GameServices/Sources/CommandParams.swift` — fields + memberwise init + `json`.
- `app/Modules/GameModels/Sources/Operation.swift` — `OperationKind` statics (~line 112 on).
- `app/Modules/DevicesFeature/Sources/DevicePresentation.swift` — `DeviceCommand` enum: cases, `init?`, `backendCommand`, `kind`, `title`, `systemImage`, `simpleSymbols` (has "detonate"), `isDestructive` (checks detonate), `Parameter`, `parameter`.
- `app/Modules/DevicesFeature/Sources/CommandGrid.swift` — `@FetchAll` properties, candidate builders (`adoptCandidates` etc.), `commands` (construction + filter), `select(_:)`, `parameterPanel`, `deviceChoicePicker`, `confirmValue`, `params(for:)`, `isConfirmable`.
- `app/Modules/DevicesFeature/Sources/CommandGroup.swift` — `commandOrder` per group.
- `app/Modules/DevicesFeature/Sources/DevicesFeature.swift` — action list, `commandConfirmed` handler, dependency list.
- `app/Modules/DevicesFeature/Tests/CommandGroupTests.swift` — verb-map test listing every verb.
- `app/Modules/GameServices/Tests/CommandClientTests.swift` — `stubGameClient`, `CapturingTransport` (asserts the wire body), `coordinatorBackedRefresher()`, `makeDevice(...)`, `jsonResponse(...)` helpers.

---

### Task 1: Drop `detonate`

**Files:**
- Modify: `app/Modules/GameServices/Sources/CommandClient+Lifecycle.swift`
- Modify: `app/Modules/DevicesFeature/Sources/DevicePresentation.swift`
- Modify: `app/Modules/DevicesFeature/Sources/CommandGroup.swift`
- Test: `app/Modules/DevicesFeature/Tests/CommandGroupTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `supportedSimpleCommands` no longer contains "detonate" (14 entries); later tasks' universe math assumes this.

- [ ] **Step 1: Remove detonate from the client**

In `CommandClient+Lifecycle.swift`:
- Delete the line `case "detonate":        return .json(.detonate(schema))` from `simpleBody`.
- In `supportedSimpleCommands`, delete `"detonate",` (leaving `"search", "set_entry_point",` at the end of that row).

- [ ] **Step 2: Remove detonate from presentation**

In `DevicePresentation.swift`:
- In `simpleSymbols`, delete the entry `"detonate": "burst",` (the `"set_entry_point": "mappin.and.ellipse",` line loses its trailing neighbor).
- In `isDestructive`, change `return c == "decommission" || c == "detonate"` to `return c == "decommission"`.

- [ ] **Step 3: Remove detonate from the taxonomy**

In `CommandGroup.swift`, change the `.special` order from
```swift
        case .special:    return ["decommission", "set_entry_point", "detonate"]
```
to
```swift
        case .special:    return ["decommission", "set_entry_point"]
```

- [ ] **Step 4: Update the tests**

In `CommandGroupTests.swift`: remove `"detonate"` from every verb list it appears in (the all-verbs mapping test and any `.special` ordering expectation). Do not renumber or reword unrelated assertions.

- [ ] **Step 5: Verify nothing else references detonate**

Prefer LSP `findReferences`; fallback:
```bash
grep -rn "detonate" app/Modules --include="*.swift" | grep -v .build
```
Expected: zero hits.

- [ ] **Step 6: Build + test**

From `app/Modules/`:
```bash
swift build 2>&1 | tail -3
swift test --filter DevicesFeatureTests 2>&1 | tail -4
swift test --filter GameServicesTests 2>&1 | tail -4
```
Expected: build clean; both summary lines end "passed" (DevicesFeature target: 39 tests in 4 suites).

- [ ] **Step 7: Commit**

```bash
git add Modules/GameServices/Sources/CommandClient+Lifecycle.swift \
        Modules/DevicesFeature/Sources/DevicePresentation.swift \
        Modules/DevicesFeature/Sources/CommandGroup.swift \
        Modules/DevicesFeature/Tests/CommandGroupTests.swift
git commit -m "Drop detonate: a phantom verb no device has ever offered (Stage 4)

Live-roster probing (2026-07-22/23) found zero devices surfacing it;
the taxonomy memory marked it for removal.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Prefix `app/` on paths when running git from the repo root.)

---

### Task 2: Client plumbing for `configure` / `message` / `repair` / `change_owner`

**Files:**
- Modify: `app/Modules/GameModels/Sources/Operation.swift` (OperationKind statics)
- Modify: `app/Modules/GameServices/Sources/CommandParams.swift` (three new fields)
- Create: `app/Modules/GameServices/Sources/CommandClient+Utility.swift`
- Modify: `app/Modules/GameServices/Sources/CommandClient.swift` (routing)
- Modify: `app/Modules/GameServices/Sources/CommandClient+Lifecycle.swift` (deadline set)
- Test: `app/Modules/GameServices/Tests/CommandClientTests.swift`

**Interfaces:**
- Consumes: generated `oneOf` cases `.configure/.message/.repair/.changeOwner` on `Operations.PostV1DevicesDeviceCode.Input.Body` (verified present); generated schemas `Components.Schemas.AppSchemasDeviceCommandsConfigureSchema` (init `command:mode:`), `…MessageSchema` (`command:channel:text:`), `…RepairSchema` (`command:target:device:`), `…ChangeOwnerSchema` (`command:target:`).
- Produces (Tasks 3–4 rely on these exact names): `OperationKind.configure/.message/.repair/.changeOwner` (rawValues "configure"/"message"/"repair"/"change_owner"); `CommandParams(mode:)`, `CommandParams(channel:text:)`, `CommandParams(target:)` for repair/change_owner.

- [ ] **Step 1: Add the OperationKind statics**

In `Operation.swift`, after the `setDirective` static's block (keep the file's doc-comment style):

```swift
    /// Set a surge plate's carry mode (`taxi` — any same-owner device may ride —
    /// or `manual` — only explicitly attached devices). A synchronous
    /// configuration change; no tracked op.
    public static let configure = OperationKind(rawValue: "configure")

    /// Post a message to a BobNet channel from an FTL relay. Immediate: the
    /// relay accepts the message synchronously; no tracked op.
    public static let message = OperationKind(rawValue: "message")

    /// Repair a damaged device (service/maintenance bot). Long-running: the bot
    /// works the target back to capacity, reporting progress in its `repair`
    /// block — a tracked deadline op whose `completesAt` back-fills from the
    /// post-command read when the dispatch response withholds it (like `search`).
    public static let repair = OperationKind(rawValue: "repair")

    /// Reassign a device to another of the account's replicants. A synchronous
    /// administrative change; no tracked op.
    public static let changeOwner = OperationKind(rawValue: "change_owner")
```

- [ ] **Step 2: Extend CommandParams**

In `CommandParams.swift` add three fields (after `directive`), matching the existing comment style:

```swift
    /// configure — a surge plate's carry mode: "taxi" or "manual".
    public var mode: String?
    /// message — the BobNet channel to post into, and the message body.
    public var channel: String?
    public var text: String?
```

Add `mode: String? = nil, channel: String? = nil, text: String? = nil` to the memberwise init (after `directive:`), assign them, and extend `json`:

```swift
        if let mode { dict["mode"] = .string(mode) }
        if let channel { dict["channel"] = .string(channel) }
        if let text { dict["text"] = .string(text) }
```

- [ ] **Step 3: Create the family file**

`app/Modules/GameServices/Sources/CommandClient+Utility.swift`:

```swift
//
//  CommandClient+Utility.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The utility family: the parameterized odds-and-ends the Stage 4 revamp
//  surfaced — `configure` (surge-plate carry mode), `message` (BobNet post
//  from an FTL relay), `repair` (service-bot repair of a damaged device), and
//  `change_owner` (reassign a device between the account's replicants). Each
//  is a typed body builder that validates its required parameter and fails
//  fast, per the dispatch template. `replicate` is deliberately NOT here — it
//  answers 201 with a new replicant and dispatches through
//  `ReplicantsClient.replicate` instead.
//

import API
import Foundation

extension CommandClient {
    private typealias ConfigureSchema = Components.Schemas.AppSchemasDeviceCommandsConfigureSchema
    private typealias MessageSchema = Components.Schemas.AppSchemasDeviceCommandsMessageSchema
    private typealias RepairSchema = Components.Schemas.AppSchemasDeviceCommandsRepairSchema
    private typealias ChangeOwnerSchema = Components.Schemas.AppSchemasDeviceCommandsChangeOwnerSchema

    static func configureBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let mode = params.mode, !mode.isEmpty else { throw CommandError.missingParameter("mode") }
        guard mode == "taxi" || mode == "manual" else { throw CommandError.invalidParameter("mode", mode) }
        return .json(.configure(.init(command: "configure", mode: mode)))
    }

    static func messageBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let channel = params.channel, !channel.isEmpty else { throw CommandError.missingParameter("channel") }
        guard let text = params.text, !text.isEmpty else { throw CommandError.missingParameter("text") }
        return .json(.message(.init(command: "message", channel: channel, text: text)))
    }

    static func repairBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        // The schema also declares a nullable `device` field, but the docs and
        // server take the device code under `target` — send only that.
        guard let target = params.target, !target.isEmpty else { throw CommandError.missingParameter("target") }
        return .json(.repair(.init(command: "repair", target: target, device: nil)))
    }

    static func changeOwnerBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let target = params.target, !target.isEmpty else { throw CommandError.missingParameter("target") }
        return .json(.changeOwner(.init(command: "change_owner", target: target)))
    }
}
```

- [ ] **Step 4: Route and classify**

In `CommandClient.swift`'s `makeBody` switch, after `case .setDirective:`:

```swift
        case .configure:        return try configureBody(params)
        case .message:          return try messageBody(params)
        case .repair:           return try repairBody(params)
        case .changeOwner:      return try changeOwnerBody(params)
```

In `CommandClient+Lifecycle.swift`, change `deadlineCommands` to include repair and update its doc comment's last sentence:

```swift
    static let deadlineCommands: Set<String> = ["recall", "search", "compact", "unfurl", "repair"]
```

Append to the doc comment above it: `` `repair` (parameterized, but classified here too) works a target back to capacity over time — its deadline lives in the bot's `repair` block, back-filled from the post-command read like `search`. ``

- [ ] **Step 5: Tests**

Append to the `CommandClientTests` suite (use the file's existing `CapturingTransport`-based helper if one wraps it, otherwise construct `GameClient(make:)` over `CapturingTransport` exactly the way the existing wire-body test in this file does — read that test first and mirror it):

```swift
    /// The four Stage 4 utility verbs serialize the documented wire bodies.
    @Test func utilityVerbBodiesSerializeAsDocumented() async throws {
        let cases: [(OperationKind, CommandParams, [String: JSONValue])] = [
            (.configure, CommandParams(mode: "taxi"),
             ["command": .string("configure"), "mode": .string("taxi")]),
            (.message, CommandParams(channel: "#general", text: "hello"),
             ["command": .string("message"), "channel": .string("#general"), "text": .string("hello")]),
            (.changeOwner, CommandParams(target: "REP2"),
             ["command": .string("change_owner"), "target": .string("REP2")]),
        ]
        for (kind, params, expected) in cases {
            let database = try GameDatabase.bootstrap()
            let captured = LockIsolated<Data?>(nil)
            await withDependencies {
                $0.defaultDatabase = database
                $0.date = .constant(Date(timeIntervalSince1970: 1_000))
                $0.uuid = .incrementing
                $0.deviceRefresher = coordinatorBackedRefresher()
                $0.gameClient = capturingGameClient(
                    onBody: { captured.setValue($0) },
                    response: jsonResponse(200, #"{"status":"ok"}"#)
                )
                $0.devicesClient.read = { code in makeDevice(code: code, status: "idle") }
            } operation: {
                let outcome = await CommandClient.liveValue.dispatch(kind, "DEV1", params)
                #expect(outcome == .accepted(operationID: nil), "\(kind.rawValue)")
            }
            let body = try #require(captured.value, "\(kind.rawValue) sent no body")
            let json = try JSONDecoder().decode(JSONValue.self, from: body)
            #expect(json == .object(expected), "\(kind.rawValue)")
        }
    }

    /// `repair` sends `target` (not `device`) and is deadline-tracked: it
    /// confirms an active op, back-filling `completesAt` from the post-command
    /// read's `repair` block when the response withholds a deadline.
    @Test func repairTracksDeadlineAndSendsTarget() async throws {
        let database = try GameDatabase.bootstrap()
        let captured = LockIsolated<Data?>(nil)
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = capturingGameClient(
                onBody: { captured.setValue($0) },
                response: jsonResponse(200, #"{"status":"repairing"}"#)
            )
            $0.devicesClient.read = { code in
                var device = makeDevice(code: code, status: "repairing")
                device.detail = .object([
                    "repair": .object(["completes_at": .string("2026-07-23T12:00:00Z")]),
                ])
                return device
            }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.repair, "BOT1", CommandParams(target: "7C79FCE1"))
            if case .accepted(let opID) = outcome { #expect(opID != nil) } else {
                Issue.record("expected accepted, got \(outcome)")
            }
        }
        let body = try #require(captured.value)
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        #expect(json == .object(["command": .string("repair"), "target": .string("7C79FCE1")]))

        let stored = try await database.read { db in
            try GameModels.Operation.where { $0.entityCode.eq("BOT1") }.fetchOne(db)
        }
        #expect(stored?.status == OperationStatus.active)
        #expect(stored?.kind == "repair")
        #expect(stored?.completesAt == (try Date("2026-07-23T12:00:00Z", strategy: .iso8601)))
    }

    /// A missing required parameter fails fast, before any request or op row.
    @Test func utilityVerbsFailFastOnMissingParams() async throws {
        let database = try GameDatabase.bootstrap()
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in
                Issue.record("no request should be sent")
                return jsonResponse(200, "{}")
            }
        } operation: {
            for (kind, params) in [
                (OperationKind.configure, CommandParams()),
                (.configure, CommandParams(mode: "warp")),   // invalid value
                (.message, CommandParams(channel: "#general")),  // missing text
                (.repair, CommandParams()),
                (.changeOwner, CommandParams()),
            ] {
                let outcome = await CommandClient.liveValue.dispatch(kind, "DEV1", params)
                if case .failed = outcome {} else { Issue.record("\(kind.rawValue): expected .failed, got \(outcome)") }
            }
        }
    }
```

Adaptation notes for the implementer: (a) if no `capturingGameClient(onBody:response:)` helper exists yet, add one beside `stubGameClient` wrapping the file's existing `CapturingTransport` (same `GameClient(make:)` shape); (b) `makeDevice` — check its actual signature/mutability in this file and adapt the repair-read stub accordingly (if `detail` can't be set post-hoc, extend the helper with a `detail:` defaulted parameter); (c) if `JSONValue` dictionary comparison is order-insensitive (it is — dictionaries), the equality asserts are stable.

- [ ] **Step 6: Build + test**

```bash
swift build 2>&1 | tail -3
swift test --filter GameServicesTests 2>&1 | tail -4
```
Expected: clean build; summary line "passed" with 3 more tests than before.

- [ ] **Step 7: Commit**

```bash
git add Modules/GameModels/Sources/Operation.swift \
        Modules/GameServices/Sources/CommandParams.swift \
        Modules/GameServices/Sources/CommandClient+Utility.swift \
        Modules/GameServices/Sources/CommandClient.swift \
        Modules/GameServices/Sources/CommandClient+Lifecycle.swift \
        Modules/GameServices/Tests/CommandClientTests.swift
git commit -m "Add the utility command family: configure, message, repair, change_owner (Stage 4)

Typed body builders + routing for the four unsurfaced POST verbs, with
repair classified deadline-tracked (its ETA back-fills from the bot's
repair block, like search). Wire bodies pinned by capturing-transport
tests. Grid surfacing lands next.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Surface `configure` + `change_owner` in the grid

**Files:**
- Modify: `app/Modules/GameModels/Sources/Device.swift` (taxiMode accessor)
- Modify: `app/Modules/DevicesFeature/Sources/DevicePresentation.swift`
- Modify: `app/Modules/DevicesFeature/Sources/CommandGrid.swift`
- Modify: `app/Modules/DevicesFeature/Sources/CommandGroup.swift`
- Test: `app/Modules/DevicesFeature/Tests/CommandGroupTests.swift`

**Interfaces:**
- Consumes (Task 2): `OperationKind.configure/.changeOwner`, `CommandParams(mode:)`, `CommandParams(target:)`.
- Produces: `DeviceCommand.configure(current: String?)`, `DeviceCommand.changeOwner(owners: [DeviceOption])`; `Device.taxiMode: String?`; `DeviceCommand.SurgeMode` (the mode vocabulary).

- [ ] **Step 1: Device accessor**

In `Device.swift`, in the Attachment extension near `attachCapacity`:

```swift
    /// A surge plate's carry mode (`taxi_mode` in the variable tail): "taxi"
    /// (any same-owner device may ride) or "manual" (explicit attach only).
    /// Nil when the device doesn't report one. Seeds the `configure` picker.
    public var taxiMode: String? {
        detail["taxi_mode"]?.stringValue
    }
```

- [ ] **Step 2: DeviceCommand cases**

In `DevicePresentation.swift`:

1. Add cases after `case unloadCargo`:
```swift
    /// Set a surge plate's carry mode (`configure`). `current` is the mode in
    /// force, seeding the picker so re-opening reflects reality.
    case configure(current: String?)
    /// Reassign this device to another of the account's replicants
    /// (`change_owner`), chosen from the other own replicants (threaded in at
    /// construction; empty — a one-replicant account — hides the command).
    case changeOwner(owners: [DeviceOption])
```
2. In `init?`, add parameters `currentMode: String? = nil` and `ownerCandidates: [DeviceOption] = []` (after `detachCandidates`), and cases before the `default:` branch:
```swift
        case "configure":         self = .configure(current: currentMode)
        case "change_owner":      self = .changeOwner(owners: ownerCandidates)
```
3. `backendCommand`: `case .configure: return "configure"` and `case .changeOwner: return "change_owner"`.
4. `kind`: `case .configure: return .configure` and `case .changeOwner: return .changeOwner`.
5. `title`: `case .configure: return "Configure"` and `case .changeOwner: return "Change Owner"`.
6. `systemImage`: `case .configure: return "gearshape"` and `case .changeOwner: return "person.2"`.
7. `parameter`:
```swift
        case .configure:
            return .choice(label: "Mode", options: SurgeMode.all)
        case let .changeOwner(owners):
            return .deviceChoice(label: "New Owner", options: owners)
```
8. Add the vocabulary near `miningResources`:
```swift
    /// The `configure` carry modes a surge plate accepts.
    enum SurgeMode { static let all = ["taxi", "manual"] }
```
9. `params(_:)`: add `case .configure: return CommandParams(mode: value)` and `case .changeOwner: return CommandParams(target: value)` — and REMOVE `.changeOwner`/`.configure` from none of the existing lines (they're new); the compiler will force totality — the catch-all line listing `.adopt, .release, …` must NOT absorb them.

- [ ] **Step 3: Grid wiring**

In `CommandGrid.swift`:

1. Add below the existing `@FetchAll` properties:
```swift
    /// The account's own replicants, backing the `change_owner` target picker.
    @FetchAll(Replicant.all) private var replicants
```
2. Add a candidate builder near `detachCandidates`:
```swift
    /// The other replicants this device could be reassigned to. Empty on a
    /// one-replicant account, which hides Change Owner entirely (the same
    /// candidate-gating pattern as adopt/release).
    private var ownerCandidates: [DeviceOption] {
        replicants
            .filter { $0.replicantCode != device.replicantCode }
            .map { DeviceOption(id: $0.replicantCode, subtitle: $0.name?.isEmpty == false ? $0.name! : "Replicant") }
    }
```
(Check `Replicant`'s actual field for its display name — `DeviceDetailView.replicantName(for:)` reads `.name` as `String?`; mirror whatever compiles there.)
3. In `commands`, hoist `let owners = ownerCandidates` beside the other hoists, pass `currentMode: device.taxiMode, ownerCandidates: owners` into `DeviceCommand(...)`, and add to the filter:
```swift
                case let .changeOwner(owners):  return !owners.isEmpty
```
(`.configure` needs no gate — the mode picker is always valid.)
4. In `select(_:)`, seed the configure picker from the mode in force — in the `case let .choice(_, options):` branch, replace the body with:
```swift
        case let .choice(_, options):
            // Seed the dropdown with the first option (mine/retarget resources) —
            // except Configure, which seeds from the mode currently in force.
            if case let .configure(current) = command, let current, options.contains(current) {
                choiceValue = current
            } else {
                choiceValue = options.first ?? ""
            }
```

- [ ] **Step 4: Grouping**

In `CommandGroup.swift`:
- `.carrier`: `return ["attach", "detach", "configure", "collect_resources", "deposit_resources"]`
- `.special`: `return ["decommission", "set_entry_point", "change_owner"]`

- [ ] **Step 5: Tests**

In `CommandGroupTests.swift`, extend the verb→group mapping test: `"configure"` → `.carrier`, `"change_owner"` → `.special`; update any ordering expectations those lists appear in.

- [ ] **Step 6: Build + test + commit**

```bash
swift build 2>&1 | tail -3
swift test --filter DevicesFeatureTests 2>&1 | tail -4
git add Modules/GameModels/Sources/Device.swift \
        Modules/DevicesFeature/Sources/DevicePresentation.swift \
        Modules/DevicesFeature/Sources/CommandGrid.swift \
        Modules/DevicesFeature/Sources/CommandGroup.swift \
        Modules/DevicesFeature/Tests/CommandGroupTests.swift
git commit -m "Surface configure and change_owner in the command grid (Stage 4)

Configure joins Carrier & Cargo as a mode picker seeded from the surge
plate's taxi_mode in force; Change Owner joins Special as a picker over
the account's other replicants, hidden on a one-replicant account (the
adopt-style candidate gate).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Surface `message` + `repair` in the grid

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/DevicePresentation.swift`
- Modify: `app/Modules/DevicesFeature/Sources/CommandGrid.swift`
- Modify: `app/Modules/DevicesFeature/Sources/CommandGroup.swift`
- Test: `app/Modules/DevicesFeature/Tests/CommandGroupTests.swift`

**Interfaces:**
- Consumes (Task 2): `OperationKind.message/.repair`, `CommandParams(channel:text:)`, `CommandParams(target:)`; `BobnetChannel` (GameModels, `@Table`, primary key `name`).
- Produces: `DeviceCommand.message(channels: [String])`, `DeviceCommand.repair(candidates: [DeviceOption])`, `Parameter.channelMessage(label: String, channels: [String])`.

- [ ] **Step 1: DeviceCommand cases**

In `DevicePresentation.swift`:

1. Cases (after the Task 3 additions):
```swift
    /// Post a message to a BobNet channel from an FTL relay (`message`). The
    /// channel vocabulary is the locally-known channel list (threaded in at
    /// construction; empty — no channels synced yet — hides the command).
    case message(channels: [String])
    /// Repair a damaged device (`repair`), chosen from the fleet's
    /// under-capacity members (threaded in at construction; a fully healthy
    /// fleet hides the command).
    case repair(candidates: [DeviceOption])
```
2. `init?` parameters `channels: [String] = []` and `repairCandidates: [DeviceOption] = []`, cases:
```swift
        case "message":           self = .message(channels: channels)
        case "repair":            self = .repair(candidates: repairCandidates)
```
3. `backendCommand`: `"message"` / `"repair"`. `kind`: `.message` / `.repair`. `title`: `"Message"` / `"Repair"`. `systemImage`: `"bubble.left"` / `"wrench.and.screwdriver"`.
4. `Parameter` enum — new case after `.blueprint`:
```swift
        /// A BobNet post: a channel dropdown plus the message body text field.
        case channelMessage(label: String, channels: [String])
```
5. `parameter`:
```swift
        case let .message(channels):
            return .channelMessage(label: "Channel", channels: channels)
        case let .repair(candidates):
            return .deviceChoice(label: "Device", options: candidates)
```
6. `params(_:)`: `case .repair: return CommandParams(target: value)`. For `.message` the grid builds params from two fields (see Step 2), so route it with the not-this-mapping group in `params(_:)`'s catch-all (`.adopt, .release, … , .message`).

- [ ] **Step 2: Grid wiring**

In `CommandGrid.swift`:

1. `@FetchAll` addition:
```swift
    /// The locally-known BobNet channels, backing the `message` channel picker.
    @FetchAll(BobnetChannel.order { $0.name }) private var channels
```
2. Candidate builder:
```swift
    /// Fleet members needing repair — anything under full operational capacity
    /// except the bot itself. The server arbitrates range/eligibility; the gate
    /// here just keeps the picker meaningful ("Mining Drone · 62%").
    private var repairCandidates: [DeviceOption] {
        fleet
            .filter { $0.deviceCode != device.deviceCode && $0.operationalCapacity < 100 }
            .map { DeviceOption(id: $0.deviceCode, subtitle: "\(DevicePresentation.displayName($0.deviceType)) · \($0.operationalCapacity)%") }
    }
```
(Adapt the `operationalCapacity` interpolation if the property is `Double` — format via `Int()` then.)
3. In `commands`: hoist `let repairable = repairCandidates` and `let channelNames = channels.map(\.name)`, pass `channels: channelNames, repairCandidates: repairable`, and gate:
```swift
                case let .message(channels):    return !channels.isEmpty
                case let .repair(candidates):   return !candidates.isEmpty
```
4. `select(_:)` seeding — add after the `.deviceChoice` case:
```swift
        case let .channelMessage(_, channels):
            // Seed the channel dropdown; the body text starts empty.
            choiceValue = channels.first ?? ""
```
5. `parameterPanel` — new case after `.deviceChoice`:
```swift
            case let .channelMessage(label, channels):
                VStack(alignment: .leading, spacing: Space.s) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(label.uppercased())
                            .font(.rcSectionLabel)
                            .foregroundStyle(.rcTextTertiary)
                        RCValueSelect(label, options: channels, selection: $choiceValue)
                    }
                    RCField("Message", text: $textValue, placeholder: "On our way with the volatiles.")
                }
```
6. `confirmValue(for:)`: add `case .channelMessage: return choiceValue`.
7. `params(for:)`: add a branch before `default`:
```swift
        case .message:
            return CommandParams(channel: choiceValue, text: textValue.trimmingCharacters(in: .whitespaces))
```
8. `isConfirmable`: add
```swift
        case .channelMessage:
            return !choiceValue.isEmpty && !textValue.trimmingCharacters(in: .whitespaces).isEmpty
```

- [ ] **Step 3: Grouping**

In `CommandGroup.swift`:
- `.tasks`: `return ["start_mining", "retarget", "scan", "search", "system_scan", "stellar_census", "repair"]`
- `.power`: `return ["activate", "deactivate", "message"]`

- [ ] **Step 4: Tests**

`CommandGroupTests.swift`: `"repair"` → `.tasks`, `"message"` → `.power`; update ordering expectations.

- [ ] **Step 5: Build + test + commit**

```bash
swift build 2>&1 | tail -3
swift test --filter DevicesFeatureTests 2>&1 | tail -4
git add Modules/DevicesFeature/Sources/DevicePresentation.swift \
        Modules/DevicesFeature/Sources/CommandGrid.swift \
        Modules/DevicesFeature/Sources/CommandGroup.swift \
        Modules/DevicesFeature/Tests/CommandGroupTests.swift
git commit -m "Surface message and repair in the command grid (Stage 4)

Message joins Power as a channel picker + body field over the local
BobNet channel list; Repair joins Tasks as a picker over the fleet's
under-capacity members. Both candidate-gated, both dormant until a
relay has channels / a bot exists.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: `replicate` + the derived-universe test

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/DevicePresentation.swift`
- Modify: `app/Modules/DevicesFeature/Sources/CommandGrid.swift`
- Modify: `app/Modules/DevicesFeature/Sources/CommandGroup.swift`
- Modify: `app/Modules/DevicesFeature/Sources/DevicesFeature.swift`
- Test: `app/Modules/DevicesFeature/Tests/CommandGroupTests.swift`, `app/Modules/DevicesFeature/Tests/DevicesFeatureTests.swift`

**Interfaces:**
- Consumes: `ReplicantsClient.replicate(_ sourceMatrixCode: String, _ targetCode: String, _ name: String?) async -> ReplicateOutcome` (GameServices; outcome `.success(newReplicantCode:newReplicantName:)/.rejected(String)/.failed(String)`); `@Dependency(\.replicantsClient)`; `DevicesClient.fetchAll` + `Reconciler` (the fleet re-ingest pattern from `DevicesFeature.load`).
- Produces: `DeviceCommand.replicate(targets: [DeviceOption])`, `Parameter.replicateTarget(label: String, options: [DeviceOption])`, `DevicesFeature.Action.replicateConfirmed(deviceCode: String, target: String, name: String?)`.

- [ ] **Step 1: DeviceCommand case**

In `DevicePresentation.swift`:

1. Case:
```swift
    /// Spawn a new replicant from this matrix (`replicate`) into an empty
    /// replicant matrix at its location (threaded in at construction; no
    /// eligible matrix nearby hides the command). Dispatches through
    /// `ReplicantsClient` — the one command that answers 201 with a new
    /// replicant rather than a command result.
    case replicate(targets: [DeviceOption])
```
2. `init?` parameter `replicateTargets: [DeviceOption] = []`, case `case "replicate": self = .replicate(targets: replicateTargets)`.
3. `backendCommand` `"replicate"`; `kind`: `return .simple("replicate")` is WRONG — replicate never dispatches through `commandClient`, but `kind` must still return something total: use `OperationKind(rawValue: "replicate")` inline with a comment `// never dispatched via CommandClient — replicate routes through ReplicantsClient`.
4. `title` `"Replicate"`; `systemImage` `"person.badge.plus"`.
5. `Parameter` case:
```swift
        /// A replication: the target empty-matrix dropdown plus an optional
        /// name for the new replicant.
        case replicateTarget(label: String, options: [DeviceOption])
```
6. `parameter`: `case let .replicate(targets): return .replicateTarget(label: "Target Matrix", options: targets)`.
7. `params(_:)`: replicate never uses it — add `.replicate` to the catch-all group.
8. `isDestructive`: leave false (replication consumes the matrix but creates — not destructive styling).

- [ ] **Step 2: Grid wiring**

In `CommandGrid.swift`:

1. Candidate builder:
```swift
    /// Empty replicant matrices sharing this matrix's location — the vessels a
    /// replication can spawn into (the server requires one at the current
    /// location). Empty hides Replicate.
    private var replicateTargets: [DeviceOption] {
        guard let location = device.location, !location.isEmpty else { return [] }
        return fleet
            .filter { $0.deviceType == "empty_replicant_matrix" && $0.location == location }
            .map { DeviceOption(id: $0.deviceCode, subtitle: DevicePresentation.displayName($0.deviceType)) }
    }
```
2. In `commands`: hoist, pass `replicateTargets:`, gate `case let .replicate(targets): return !targets.isEmpty`.
3. `select(_:)` seeding, after the Task 4 case:
```swift
        case let .replicateTarget(_, options):
            choiceValue = options.first?.id ?? ""
```
4. `parameterPanel` case:
```swift
            case let .replicateTarget(label, options):
                VStack(alignment: .leading, spacing: Space.s) {
                    deviceChoicePicker(label, options: options)
                    RCField("Name", text: $textValue, placeholder: "Optional — server names it otherwise")
                }
```
5. `confirmValue(for:)`: `case .replicateTarget: return choiceValue`.
6. Confirm dispatch — in the confirm `Button` action, add a branch after the `command == .print` branch:
```swift
                    } else if case .replicate = command {
                        let name = textValue.trimmingCharacters(in: .whitespaces)
                        store.send(.replicateConfirmed(
                            deviceCode: device.deviceCode,
                            target: choiceValue,
                            name: name.isEmpty ? nil : name
                        ))
                    } else {
```
7. `isConfirmable`: `case .replicateTarget: return !choiceValue.isEmpty`.
8. `confirmTitle(for:)`: add `if case .replicate = command { return "Replicate" }` — no count suffix needed.

- [ ] **Step 3: DevicesFeature action**

In `DevicesFeature.swift`:

1. Dependency, beside the others: `@Dependency(\.replicantsClient) var replicantsClient`.
2. Action, after `cargoLoadDismissed` block (or after the directive-composer cases — keep the file's grouping tidy):
```swift
        /// The inspector's Replicate confirm: spawn a new replicant from this
        /// matrix into `target`. Routes through `ReplicantsClient` (201 → new
        /// replicant), not `CommandClient`; on success the fleet and roster
        /// re-ingest so the consumed matrix and rehosted device reconcile.
        case replicateConfirmed(deviceCode: String, target: String, name: String?)
```
3. Reducer case:
```swift
            case let .replicateConfirmed(deviceCode, target, name):
                let replicantsClient = self.replicantsClient
                let devicesClient = self.devicesClient
                logger.info("replicate \(deviceCode, privacy: .public) → \(target, privacy: .public) confirmed")
                return .run { send in
                    let outcome = await replicantsClient.replicate(deviceCode, target, name)
                    if let message = outcome.failureMessage {
                        await send(.commandFinished(.rejected(message)))
                        return
                    }
                    // Success: the source matrix is consumed and its device
                    // rehosted — re-ingest the fleet and refresh the roster so
                    // the inspector reflects the new topology.
                    if let devices = try? await devicesClient.fetchAll() {
                        let reconciler = Reconciler()
                        for device in devices { await reconciler.ingest(device) }
                        await reconciler.pruneDevices(presentCodes: devices.map(\.deviceCode))
                    }
                    _ = try? await replicantsClient.refresh()
                }
```
(Verify `ReplicateOutcome.failureMessage` exists — it does, mirroring `CommandOutcome`. Reusing `.commandFinished(.rejected(...))` surfaces the failure in the existing command alert; success needs no nudge — table observation shows the change.)

- [ ] **Step 4: Grouping**

`CommandGroup.swift` `.special`: `return ["decommission", "replicate", "set_entry_point", "change_owner"]`

- [ ] **Step 5: The derived-universe test**

Append to `CommandGroupTests.swift`:

```swift
    /// The taxonomy and the dispatchable universe must be the same set: every
    /// verb the grid can construct has a home group, and every verb the
    /// taxonomy orders is actually constructible. Catches both a new command
    /// landing without a group (it would silently fall to Special) and a
    /// taxonomy entry going stale when a verb is removed.
    @Test func taxonomyExactlyCoversTheDispatchableUniverse() {
        let structured = [
            "travel", "start_mining", "retarget", "system_scan", "scan",
            "stellar_census", "enqueue_print", "stow", "set_directive",
            "adopt", "release", "attach", "detach",
            "collect_resources", "deposit_resources",
            "configure", "message", "repair", "replicate", "change_owner",
        ]
        let universe = Set(structured).union(CommandClient.supportedSimpleCommands)
        let taxonomy = Set(CommandGroup.allCases.flatMap(\.commandOrder))
        #expect(taxonomy == universe)
    }
```

Also extend the existing verb→group mapping test: `"replicate"` → `.special`, and the `.special` ordering expectation to `["decommission", "replicate", "set_entry_point", "change_owner"]`. The structured-verbs list above must match `DeviceCommand.init?`'s cases exactly — if the mapping test derives its list differently, keep both in sync. (Add `import GameServices` to the test file if it isn't already there.)

- [ ] **Step 6: Replicate flow test**

Append to `DevicesFeatureTests.swift`:

```swift
    /// A confirmed replication routes through ReplicantsClient (not
    /// CommandClient) and re-ingests the fleet on success.
    @Test func replicateConfirmedRoutesThroughReplicantsClient() async throws {
        let database = try GameDatabase.bootstrap()
        let replicated = LockIsolated<(String, String, String?)?>(nil)

        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.replicantsClient.replicate = { source, target, name in
                replicated.setValue((source, target, name))
                return .success(newReplicantCode: "REP2", newReplicantName: "Bob")
            }
            $0.replicantsClient.refresh = { [] }
            $0.devicesClient.fetchAll = { [] }
        }
        store.exhaustivity = .off

        await store.send(.replicateConfirmed(deviceCode: "MATRIX1", target: "EMPTY1", name: "Bob"))
        await store.finish()

        #expect(replicated.value?.0 == "MATRIX1")
        #expect(replicated.value?.1 == "EMPTY1")
        #expect(replicated.value?.2 == "Bob")
    }

    /// A rejected replication surfaces in the command alert.
    @Test func replicateRejectionSurfacesCommandError() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.replicantsClient.replicate = { _, _, _ in .rejected("No empty matrix at this location.") }
        }
        store.exhaustivity = .off

        await store.send(.replicateConfirmed(deviceCode: "MATRIX1", target: "EMPTY1", name: nil))
        await store.receive(\.commandFinished)
        #expect(store.state.commandError == "No empty matrix at this location.")
    }
```

Adaptation notes: check `ReplicantsClient.refresh`'s real signature (the return is discarded via `_ = try?` in the reducer; stub with the minimal compiling closure). If `ReplicateOutcome.success` has different label spellings, mirror the real ones.

- [ ] **Step 7: Build + full target tests + commit**

```bash
swift build 2>&1 | tail -3
swift test --filter DevicesFeatureTests 2>&1 | tail -4
swift test --filter GameServicesTests 2>&1 | tail -4
git add Modules/DevicesFeature/Sources/DevicePresentation.swift \
        Modules/DevicesFeature/Sources/CommandGrid.swift \
        Modules/DevicesFeature/Sources/CommandGroup.swift \
        Modules/DevicesFeature/Sources/DevicesFeature.swift \
        Modules/DevicesFeature/Tests/CommandGroupTests.swift \
        Modules/DevicesFeature/Tests/DevicesFeatureTests.swift
git commit -m "Surface replicate; pin the taxonomy to the dispatchable universe (Stage 4)

Replicate joins Special, dispatching through the existing
ReplicantsClient path (the 201-answering command CommandClient
deliberately rejects) with a fleet/roster re-ingest on success. The new
derived-universe test locks taxonomy == constructible verbs both ways.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Verification (whole stage)

1. `swift build` clean from `app/Modules/`.
2. `swift test --filter DevicesFeatureTests` and `--filter GameServicesTests` — summary lines "passed" (DevicesFeature target grows by the new CommandGroup/replicate tests; GameServices by 3).
3. Live sanity (user's, or controller GET-probe): surge plate inspector shows Configure under Carrier & Cargo seeded to its current mode; ftl_relay shows Message under Power with the BobNet channel list; replicant_matrix shows Replicate only when an empty matrix shares its location; Change Owner and Repair stay hidden on this account today (1 replicant, no service_bot, healthy fleet) — that's the gating working, not a bug.
4. No POST probes are needed to verify this stage; do not fire live commands without the user asking.

## Deliberately NOT done in Stage 4

- `dequeue_print` UI (print-queue management), `rename`/`set_welcome_message`/`prospect` (hub commands — no owned hub).
- No sheet for any new command (all params are light → inline per the rule).
- No account-counter refresh after replicate (`accountManager` stays out of DevicesFeature; the roster/fleet re-ingest covers what the inspector shows).
