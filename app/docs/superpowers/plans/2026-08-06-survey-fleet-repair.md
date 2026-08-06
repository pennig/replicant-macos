# Survey Fleet Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Survey Run deploys two service bots on arrival, lets them hot-repair the drones while the survey runs, and holds the vessel before departure until the bots go idle.

**Architecture:** Repair is autonomous — co-locating a service bot with a damaged device is the entire trigger, so the engine issues no `repair` command. `SurveyRun` gains three phases: deploy the bots after arrival, a gate after `recovering` that waits for the bots to fall idle, and a stow before the vessel travels on. Every gate is a pure read over `WorldSnapshot`, following `SurveyRun.recover`'s probe-delay / probe-interval / deadline shape exactly.

**Tech Stack:** Swift 6, SwiftPM (`app/Modules`), Swift Testing, GRDB/SQLiteData, `MissionStepMachine` protocol.

**Design source:** `app/docs/superpowers/specs/2026-08-06-fleet-repair-design.md`

## Global Constraints

- **Purity.** `nextAction(directive:world:)` MUST have no I/O, no clock reads (use `world.now`), no randomness, and no state carried between evaluations.
- **Comment budget is hard:** file header ≤ 6 lines, `///` doc ≤ 3 lines, inline `//` ≤ 2 lines. Blank `///` lines count. History goes to `.claude/memory/`, never source.
- **No schema change.** No new column, no new table, no migration.
- **Loud test defaults.** A shared client's `testValue` uses `unimplemented(...)`, never a quiet stub.
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category = module name.
- **Test results come from the JSON event stream**, never console text — use the `swift-test-event-stream` skill. One `--event-stream-output-path` per product or output is truncated.
- **Worktree setup before any LSP query:** `cd app/Modules && swift build --build-tests`, then `./scripts/link-index-store.sh`.
- **Threshold constant:** repair entry threshold is `50` percent capacity, expressed as `Double` because `Device.operationalCapacity` is `Double`.
- **Never compare `device.tags.contains(...)` directly** — always `Device.hasTag(_:)`, which normalises both sides.

---

### Task 1: Correct the service-bot directive vocabulary

`Device.fallbackDirectives` claims a service bot only offers `patrol`, and its doc claims the service bot has no blueprint entry. Both are false: the live blueprint list carries `service_bot` with `directives: ["patrol", "service"]`, and a live bot's runtime `available_directives` reads `["patrol", "service"]`. The fallback is what fixtures and any non-advertising device see, and Task 2 selects bots by directive capability — so a wrong fallback silently makes every fixture bot invisible.

**Files:**
- Modify: `app/Modules/GameModels/Sources/Device.swift:267-276`
- Test: `app/Modules/GameModelsTests/Tests/DeviceDirectivesTests.swift` (create if absent; otherwise append to the existing device suite)

**Interfaces:**
- Consumes: nothing.
- Produces: `Device.availableDirectives` returns `["patrol", "service"]` for a `service_bot` whose `detail` advertises none.

- [ ] **Step 1: Write the failing test**

```swift
@Test func aServiceBotOffersServiceEvenWhenTheRowAdvertisesNothing() {
    let bot = Device.fixture(deviceCode: "BOT1", deviceType: "service_bot", detail: [:])
    #expect(bot.availableDirectives == ["patrol", "service"])
}

@Test func aRuntimeDirectiveListStillWins() {
    let bot = Device.fixture(
        deviceCode: "BOT1", deviceType: "service_bot",
        detail: ["available_directives": .array([.string("patrol")])]
    )
    #expect(bot.availableDirectives == ["patrol"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter aServiceBotOffersServiceEvenWhenTheRowAdvertisesNothing --event-stream-output-path /tmp/rc-t1.jsonl`
Expected: FAIL — `availableDirectives` returns `["patrol"]`.

- [ ] **Step 3: Fix the table and its doc**

```swift
    /// Directive vocabularies the server omits from a device's runtime
    /// `available_directives`. Keyed by `device_type`; consulted only when the
    /// runtime list is empty, so an advertising device always wins.
    private static let fallbackDirectives: [String: [String]] = [
        "maintenance_drone": ["patrol"],
        "service_bot": ["patrol", "service"],
    ]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter DeviceDirectives --event-stream-output-path /tmp/rc-t1b.jsonl`
Expected: PASS, both tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameModels/Sources/Device.swift app/Modules/GameModelsTests/Tests/DeviceDirectivesTests.swift
git commit -m "fix(devices): a service bot offers service, not only patrol"
```

---

### Task 2: `RepairFleet` — the pure queries the steps read

One namespace answering four questions, so the three new steps share one definition each and a correction lands once. Modelled on `AMIFleet`: pure, no I/O, no clock.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/RepairFleet.swift`
- Create: `app/Modules/DirectiveEngine/Tests/RepairFleetTests.swift`

**Interfaces:**
- Consumes: `Device.availableDirectives` (Task 1), `WorldSnapshot.devices`.
- Produces:
  - `RepairFleet.repairThreshold: Double` — `50`
  - `RepairFleet.bots(aboard: Device, in: WorldSnapshot) -> [Device]`
  - `RepairFleet.bots(deployedAt: String?, in: WorldSnapshot) -> [Device]`
  - `RepairFleet.isRepairing(_ bot: Device) -> Bool`
  - `RepairFleet.needsRepair(_ devices: [Device]) -> Bool`
  - `RepairFleet.fleet(of vessel: Device, in world: WorldSnapshot) -> [Device]`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import GameModels
import Testing
import Utils
@testable import DirectiveEngine

private let fixtureNow = Date(timeIntervalSince1970: 1_000)

@Suite struct RepairFleetTests {
    @Test func botsAboardAreServiceOfferingDevicesStowedInTheVessel() {
        let bot = device("BOT1", type: "service_bot", stowedIn: "VESSEL", directives: ["patrol", "service"])
        let drone = device("DRONE1", type: "survey_drone", stowedIn: "VESSEL")
        let elsewhere = device("BOT2", type: "service_bot", stowedIn: "OTHER", directives: ["service"])
        let vessel = device("VESSEL", type: "heaven_vessel")
        let w = world(devices: [vessel, bot, drone, elsewhere])
        #expect(RepairFleet.bots(aboard: vessel, in: w).map(\.deviceCode) == ["BOT1"])
    }

    @Test func botsDeployedAtALocationExcludeStowedOnes() {
        let deployed = device("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let stowed = device("BOT2", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
        let w = world(devices: [deployed, stowed])
        #expect(RepairFleet.bots(deployedAt: "SOL-3", in: w).map(\.deviceCode) == ["BOT1"])
    }

    @Test func aBotWithARepairBlockIsRepairing() {
        var bot = device("BOT1", type: "service_bot", directives: ["service"])
        bot.detail = .object(["repair": .object(["target_device_code": .string("DRONE1")])])
        #expect(RepairFleet.isRepairing(bot))
    }

    @Test func aBotWithNoRepairBlockIsIdle() {
        let bot = device("BOT1", type: "service_bot", directives: ["service"])
        #expect(!RepairFleet.isRepairing(bot))
    }

    @Test func anyDeviceUnderFiftyNeedsRepair() {
        let hurt = device("D1", type: "survey_drone", capacity: 49)
        let fine = device("D2", type: "survey_drone", capacity: 50)
        #expect(RepairFleet.needsRepair([hurt, fine]))
        #expect(!RepairFleet.needsRepair([fine]))
    }

    @Test func exactlyFiftyIsNotBelowTheThreshold() {
        #expect(!RepairFleet.needsRepair([device("D1", type: "survey_drone", capacity: 50)]))
    }

    @Test func theFleetIsTheDeployedBotsPlusWhateverIsAboard() {
        let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let bot = device("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
        let drone = device("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL")
        let stranger = device("OTHER", type: "survey_drone", location: "SOL-3")
        let w = world(devices: [vessel, bot, drone, stranger])
        #expect(RepairFleet.fleet(of: vessel, in: w).map(\.deviceCode) == ["BOT1", "DRONE1"])
    }
}
```

Add a local `device(...)` fixture mirroring `SurveyRunTests`'s, extended with `capacity: Double = 100` writing `operationalCapacity`, and a `world(devices:)` helper building a `WorldSnapshot` at `fixtureNow`. Copy both from `SurveyRunTests.swift` rather than importing them — the existing ones are `private`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter RepairFleetTests --event-stream-output-path /tmp/rc-t2.jsonl`
Expected: FAIL to compile — `cannot find 'RepairFleet' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
//
//  RepairFleet.swift
//  Replicould — DirectiveEngine
//
//  The service-bot queries the repair phases share. Pure by contract, like
//  every mission query: no I/O, no clock, no randomness.
//

import GameModels

/// Fleet queries over a `WorldSnapshot` already in hand, shared by every mission
/// that carries service bots.
public enum RepairFleet {
    /// Capacity below which a fleet is worth holding for repair.
    public static let repairThreshold: Double = 50

    /// The service bots stowed aboard `vessel` in `world`, identified by the
    /// `service` directive rather than `device_type` so a differently-named
    /// repair device still matches.
    public static func bots(aboard vessel: Device, in world: WorldSnapshot) -> [Device] {
        world.devices.values
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
            .filter { $0.availableDirectives.contains("service") }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// The service bots standing at `location` in `world`. A stowed device has no
    /// location, so this returns only genuinely deployed bots.
    public static func bots(deployedAt location: String?, in world: WorldSnapshot) -> [Device] {
        guard let location else { return [] }
        return world.devices.values
            .filter { $0.stowedInDeviceCode == nil && $0.location == location }
            .filter { $0.availableDirectives.contains("service") }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// Whether `bot` is mid-repair, from the `repair` block the server populates
    /// with the target and its progress.
    public static func isRepairing(_ bot: Device) -> Bool {
        bot.detail["repair"]?["target_device_code"]?.stringValue != nil
    }

    /// Whether any of `devices` is worn enough to hold the fleet for.
    public static func needsRepair(_ devices: [Device]) -> Bool {
        devices.contains { $0.operationalCapacity < repairThreshold }
    }

    /// Everything a repair gate judges: the bots standing in the system plus
    /// whatever is stowed aboard `vessel`, which by departure is every drone.
    public static func fleet(of vessel: Device, in world: WorldSnapshot) -> [Device] {
        let aboard = world.devices.values.filter { $0.stowedInDeviceCode == vessel.deviceCode }
        return (bots(deployedAt: vessel.location, in: world) + aboard)
            .sorted { $0.deviceCode < $1.deviceCode }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter RepairFleetTests --event-stream-output-path /tmp/rc-t2b.jsonl`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/RepairFleet.swift app/Modules/DirectiveEngine/Tests/RepairFleetTests.swift
git commit -m "feat(repair): the service-bot queries the repair phases share"
```

---

### Task 3: A stall reason for repair that will not finish

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift` (the `DirectiveAttentionReason` cases near `dronesNotRecovered:84`, and its `brainDisposition` switch near `:199`)
- Test: `app/Modules/DirectiveEngine/Tests/SurveyRunTests.swift`

**Interfaces:**
- Produces: `DirectiveAttentionReason.repairUnfinished`, whose `brainDisposition` is `.escalate`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func repairUnfinishedEscalatesRatherThanRetrying() {
    #expect(DirectiveAttentionReason.repairUnfinished.brainDisposition == .escalate)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter repairUnfinishedEscalates --event-stream-output-path /tmp/rc-t3.jsonl`
Expected: FAIL to compile — `type 'DirectiveAttentionReason' has no member 'repairUnfinished'`.

- [ ] **Step 3: Add the case and its disposition**

Beside `dronesNotRecovered`:

```swift
    /// The service bots were still working when the repair deadline expired, so
    /// the fleet would otherwise depart mid-repair.
    case repairUnfinished
```

In `brainDisposition`, add `repairUnfinished` to the `.escalate` group. Retry cannot help: the bots are either too worn to work or the repair is genuinely longer than the deadline, and both want a human.

Add its display label wherever the other reasons carry one — follow whatever `dronesNotRecovered` does in the same file, and mirror its wording register.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter repairUnfinishedEscalates --event-stream-output-path /tmp/rc-t3b.jsonl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameModels/Sources/Directive.swift app/Modules/DirectiveEngine/Tests/SurveyRunTests.swift
git commit -m "feat(directives): a stall reason for repair that will not finish"
```

---

### Task 4: Deploy the bots on arrival

Two steps, dispatch split from poll. A `.simple` verb writes no `Operation` row, so a step that dispatches with `nextStep` equal to its own step re-issues the command every tick forever — see the `same-step-dispatch-needs-tracked-op` memory note. `deployingBots` dispatches one bot and hands off; `confirmingBotDeploy` reads the result and either loops back for the next bot or moves on.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/SurveyRun.swift` (the `Step` enum at `:34`, the `nextAction` switch at `:98`, and `travel`'s `nextStep` at `:482`)
- Test: `app/Modules/DirectiveEngine/Tests/SurveyRunRepairTests.swift` (create)

**Interfaces:**
- Consumes: `RepairFleet.bots(aboard:in:)` (Task 2).
- Produces: `SurveyRun.Step.deployingBots`, `SurveyRun.Step.confirmingBotDeploy`, `SurveyRun.botProbeDelay`, `SurveyRun.botProbeInterval`. `travelling` now advances to `deployingBots`, and `deployingBots` advances to `configuring`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func arrivalWithNoBotAboardSkipsStraightToConfiguring() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    let w = world(devices: [vessel])
    let d = directive(step: SurveyRun.Step.deployingBots, deviceCode: "VESSEL")
    #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.configuring))
}

@Test func arrivalDeploysTheFirstBotStillAboard() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    let a = device("BOT1", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
    let b = device("BOT2", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
    let w = world(devices: [vessel, a, b])
    let d = directive(step: SurveyRun.Step.deployingBots, deviceCode: "VESSEL")
    #expect(SurveyRun().nextAction(directive: d, world: w) == .dispatch(
        kind: .simple, deviceCode: "BOT1",
        params: CommandParams(command: "deploy"),
        nextStep: SurveyRun.Step.confirmingBotDeploy
    ))
}

@Test func theSecondBotIsDeployedAfterTheFirstLands() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    let out = device("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
    let aboard = device("BOT2", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
    let w = world(devices: [vessel, out, aboard])
    let d = directive(step: SurveyRun.Step.confirmingBotDeploy, deviceCode: "VESSEL", stepStartedAt: fixtureNow.addingTimeInterval(-60))
    #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.deployingBots))
}

@Test func everyBotDeployedAdvancesToConfiguring() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    let a = device("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
    let b = device("BOT2", type: "service_bot", location: "SOL-3", directives: ["service"])
    let w = world(devices: [vessel, a, b])
    let d = directive(step: SurveyRun.Step.confirmingBotDeploy, deviceCode: "VESSEL", stepStartedAt: fixtureNow.addingTimeInterval(-60))
    #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.configuring))
}

@Test func aFreshlyOrderedDeployIsNotJudgedYet() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    let aboard = device("BOT1", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
    let w = world(devices: [vessel, aboard])
    let d = directive(step: SurveyRun.Step.confirmingBotDeploy, deviceCode: "VESSEL", stepStartedAt: fixtureNow)
    #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
}
```

Copy `device(...)`, `world(...)` and `directive(...)` fixtures from `SurveyRunTests.swift` — they are `private` there — and extend `device` with `capacity: Double = 100`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter SurveyRunRepairTests --event-stream-output-path /tmp/rc-t4.jsonl`
Expected: FAIL to compile — no `Step.deployingBots`.

- [ ] **Step 3: Add the steps**

In `Step`, after `travelling`:

```swift
        /// Put the service bots into the system so they can repair as it works.
        public static let deployingBots = "deployingBots"
        /// Read whether the ordered deploy landed before ordering the next.
        public static let confirmingBotDeploy = "confirmingBotDeploy"
```

Constants beside `recallProbeDelay`:

```swift
    /// How long to let an ordered bot deploy or stow settle before the first read.
    public static let botProbeDelay: TimeInterval = 10

    /// Floor between bot-state probes, so an unmoving row is not re-read each tick.
    public static let botProbeInterval: TimeInterval = 30
```

Route both in `nextAction`, and change `travel`'s success path so arrival advances to `Step.deployingBots` instead of `Step.configuring`.

```swift
    /// Deploy the next service bot still aboard `vessel`, or move on when the
    /// system already has them all.
    private func deployBots(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let aboard = RepairFleet.bots(aboard: vessel, in: world)
        guard let next = aboard.first else { return .advanceStep(nextStep: Step.configuring) }
        return .dispatch(
            kind: .simple, deviceCode: next.deviceCode,
            params: CommandParams(command: "deploy"), nextStep: Step.confirmingBotDeploy
        )
    }

    /// Judge an ordered deploy, looping back for the next bot until none is aboard.
    private func confirmBotDeploy(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let elapsed = world.now.timeIntervalSince(directive.stepStartedAt)
        if elapsed < Self.botProbeDelay { return .wait }
        let aboard = RepairFleet.bots(aboard: vessel, in: world)
        if aboard.isEmpty { return .advanceStep(nextStep: Step.configuring) }
        // A row that has not been read since the deploy was ordered cannot yet
        // show it landing; buy the read rather than believing a stale claim.
        if aboard.contains(where: { $0.updatedAt < directive.stepStartedAt }) {
            let lastLook = aboard.map(\.updatedAt).min() ?? .distantPast
            if world.now.timeIntervalSince(lastLook) < Self.botProbeInterval { return .wait }
            return .refreshDevices(deviceCodes: aboard.map(\.deviceCode), thenStall: nil)
        }
        return .advanceStep(nextStep: Step.deployingBots)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter SurveyRunRepairTests --event-stream-output-path /tmp/rc-t4b.jsonl`
Expected: PASS, 5 tests. Then run the whole product — `travel`'s changed `nextStep` touches existing assertions:
Run: `cd app/Modules && swift test --filter DirectiveEngineTests --event-stream-output-path /tmp/rc-t4c.jsonl`
Expected: any failure is an existing test asserting `travelling → configuring`; update those to expect `deployingBots`. Do not weaken an assertion to make it pass.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/SurveyRun.swift app/Modules/DirectiveEngine/Tests/SurveyRunRepairTests.swift
git commit -m "feat(survey): deploy the service bots on arrival"
```

---

### Task 5: The repair gate before departure

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/SurveyRun.swift` (`Step`, `nextAction`, and `recover` at `:352` where it returns `.advanceTarget`)
- Test: `app/Modules/DirectiveEngine/Tests/SurveyRunRepairTests.swift`

**Interfaces:**
- Consumes: `RepairFleet.bots(deployedAt:in:)`, `RepairFleet.isRepairing(_:)`, `RepairFleet.needsRepair(_:)`, `RepairFleet.fleet(of:in:)` (Task 2); `DirectiveAttentionReason.repairUnfinished` (Task 3).
- Produces: `SurveyRun.Step.repairing`, `SurveyRun.repairDeadline`. `recover`'s three `.advanceTarget` returns become `.advanceStep(nextStep: Step.repairing)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aHealthyFleetLeavesWithoutWaiting() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    let bot = device("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
    let drone = device("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 100)
    let w = world(devices: [vessel, bot, drone])
    let d = directive(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: fixtureNow.addingTimeInterval(-60))
    #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.stowingBots))
}

@Test func aWorkingBotHoldsTheVessel() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    var bot = device("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
    bot.detail = .object([
        "available_directives": .array([.string("service")]),
        "repair": .object(["target_device_code": .string("DRONE1")]),
    ])
    let drone = device("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 30)
    let w = world(devices: [vessel, bot, drone])
    let d = directive(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: fixtureNow.addingTimeInterval(-60))
    #expect(SurveyRun().nextAction(directive: d, world: w) == .wait)
}

@Test func idleBotsReleaseTheVesselEvenWithADroneStillWorn() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    let bot = device("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
    let drone = device("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 30)
    let w = world(devices: [vessel, bot, drone])
    let d = directive(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: fixtureNow.addingTimeInterval(-60))
    #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.stowingBots))
}

@Test func noBotDeployedSkipsTheGate() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    let drone = device("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 30)
    let w = world(devices: [vessel, drone])
    let d = directive(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: fixtureNow.addingTimeInterval(-60))
    #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceStep(nextStep: SurveyRun.Step.stowingBots))
}

@Test func aBotStillWorkingAtTheDeadlineEscalates() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    var bot = device("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
    bot.detail = .object([
        "available_directives": .array([.string("service")]),
        "repair": .object(["target_device_code": .string("DRONE1")]),
    ])
    let drone = device("DRONE1", type: "survey_drone", location: nil, stowedIn: "VESSEL", capacity: 30)
    let w = world(devices: [vessel, bot, drone])
    let past = fixtureNow.addingTimeInterval(-(SurveyRun.repairDeadline + 1))
    let d = directive(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: past)
    #expect(SurveyRun().nextAction(directive: d, world: w) == .stall(.repairUnfinished))
}
```

`idleBotsReleaseTheVesselEvenWithADroneStillWorn` is the load-bearing one: it pins the decision that idleness, not a capacity threshold, ends the wait. Deleting it would let a future threshold gate slip in unnoticed.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter SurveyRunRepairTests --event-stream-output-path /tmp/rc-t5.jsonl`
Expected: FAIL to compile — no `Step.repairing`.

- [ ] **Step 3: Add the gate**

```swift
        /// Hold the vessel while the service bots finish what they are repairing.
        public static let repairing = "repairing"
```

```swift
    /// The cap on holding a vessel for repair before surfacing `repairUnfinished`.
    public static let repairDeadline: TimeInterval = 20 * 60
```

```swift
    /// Hold `vessel` while any deployed service bot is still repairing.
    ///
    /// Gates on the bots falling IDLE, never on a capacity threshold: `service`
    /// repairs to an unquantified level a threshold gate could wait on forever.
    private func awaitRepair(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let bots = RepairFleet.bots(deployedAt: vessel.location, in: world)
        if bots.isEmpty { return .advanceStep(nextStep: Step.stowingBots) }
        // A fleet nothing is worn enough to hold for leaves without paying the
        // probe delay or a single read.
        if !RepairFleet.needsRepair(RepairFleet.fleet(of: vessel, in: world)) {
            return .advanceStep(nextStep: Step.stowingBots)
        }

        let elapsed = world.now.timeIntervalSince(directive.stepStartedAt)
        if elapsed < Self.botProbeDelay { return .wait }
        if elapsed > Self.repairDeadline { return .stall(.repairUnfinished) }
        if !bots.contains(where: RepairFleet.isRepairing) {
            return .advanceStep(nextStep: Step.stowingBots)
        }
        let lastLook = bots.map(\.updatedAt).min() ?? .distantPast
        if world.now.timeIntervalSince(lastLook) < Self.botProbeInterval { return .wait }
        return .refreshDevices(deviceCodes: bots.map(\.deviceCode), thenStall: nil)
    }
```

Route `Step.repairing` in `nextAction`, and change every `.advanceTarget` in `recover` to `.advanceStep(nextStep: Step.repairing)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter SurveyRunRepairTests --event-stream-output-path /tmp/rc-t5b.jsonl`
Expected: PASS, 10 tests (Task 4's five plus these five).

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/SurveyRun.swift app/Modules/DirectiveEngine/Tests/SurveyRunRepairTests.swift
git commit -m "feat(survey): hold the vessel while the bots are still repairing"
```

---

### Task 6: Stow the bots before travelling on

Mirror of Task 4. Without it the bots are left standing in the surveyed system and the fleet loses them.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/SurveyRun.swift`
- Test: `app/Modules/DirectiveEngine/Tests/SurveyRunRepairTests.swift`

**Interfaces:**
- Consumes: `RepairFleet.bots(deployedAt:in:)` (Task 2).
- Produces: `SurveyRun.Step.stowingBots`, `SurveyRun.Step.confirmingBotStow`. `confirmingBotStow` returns `.advanceTarget`, restoring the exit `recover` used to own.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func departureStowsTheFirstBotStillOut() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    let bot = device("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"])
    let w = world(devices: [vessel, bot])
    let d = directive(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL")
    #expect(SurveyRun().nextAction(directive: d, world: w) == .dispatch(
        kind: .simple, deviceCode: "BOT1",
        params: CommandParams(command: "stow", target: "VESSEL"),
        nextStep: SurveyRun.Step.confirmingBotStow
    ))
}

@Test func everyBotAboardAdvancesTheTarget() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    let bot = device("BOT1", type: "service_bot", location: nil, stowedIn: "VESSEL", directives: ["service"])
    let w = world(devices: [vessel, bot])
    let d = directive(step: SurveyRun.Step.confirmingBotStow, deviceCode: "VESSEL", stepStartedAt: fixtureNow.addingTimeInterval(-60))
    #expect(SurveyRun().nextAction(directive: d, world: w) == .advanceTarget)
}

@Test func aBotThatNeverStowsDoesNotStrandTheRun() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    let bot = device("BOT1", type: "service_bot", location: "SOL-3", directives: ["service"], updatedAt: fixtureNow)
    let w = world(devices: [vessel, bot])
    let past = fixtureNow.addingTimeInterval(-(SurveyRun.recallDeadline + 1))
    let d = directive(step: SurveyRun.Step.confirmingBotStow, deviceCode: "VESSEL", stepStartedAt: past)
    #expect(SurveyRun().nextAction(directive: d, world: w) == .stall(.dronesNotRecovered))
}
```

The third test reuses `dronesNotRecovered` rather than inventing a reason: a bot left behind is the same failure the operator already knows that reason by, and the halt matrix stays as small as it can be.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter SurveyRunRepairTests --event-stream-output-path /tmp/rc-t6.jsonl`
Expected: FAIL to compile — no `Step.stowingBots`.

- [ ] **Step 3: Add the steps**

```swift
        /// Bring the service bots back aboard before the vessel travels on.
        public static let stowingBots = "stowingBots"
        /// Read whether the ordered stow landed before ordering the next.
        public static let confirmingBotStow = "confirmingBotStow"
```

```swift
    /// Stow the next service bot still standing in the system, or advance when
    /// none is left out.
    private func stowBots(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let out = RepairFleet.bots(deployedAt: vessel.location, in: world)
        guard let next = out.first else { return .advanceTarget }
        return .dispatch(
            kind: .simple, deviceCode: next.deviceCode,
            params: CommandParams(command: "stow", target: vessel.deviceCode),
            nextStep: Step.confirmingBotStow
        )
    }

    /// Judge an ordered stow, looping back for the next bot until none is out.
    private func confirmBotStow(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let elapsed = world.now.timeIntervalSince(directive.stepStartedAt)
        if elapsed < Self.botProbeDelay { return .wait }
        if elapsed > Self.recallDeadline { return .stall(.dronesNotRecovered) }
        let out = RepairFleet.bots(deployedAt: vessel.location, in: world)
        if out.isEmpty { return .advanceTarget }
        if out.contains(where: { $0.updatedAt < directive.stepStartedAt }) {
            let lastLook = out.map(\.updatedAt).min() ?? .distantPast
            if world.now.timeIntervalSince(lastLook) < Self.botProbeInterval { return .wait }
            return .refreshDevices(deviceCodes: out.map(\.deviceCode), thenStall: nil)
        }
        return .advanceStep(nextStep: Step.stowingBots)
    }
```

Verify `CommandParams`' stow parameter name against `CommandClient`'s stow body builder before running — the plan assumes `target:` carries the carrier, matching `repairBody`'s convention. If it differs, use the real one and adjust the Step-1 test to match.

Route both in `nextAction`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter SurveyRunRepairTests --event-stream-output-path /tmp/rc-t6b.jsonl`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/SurveyRun.swift app/Modules/DirectiveEngine/Tests/SurveyRunRepairTests.swift
git commit -m "feat(survey): bring the service bots back aboard before departure"
```

---

### Task 7: Whole-run regression pass

The three phases changed two existing transitions (`travelling`'s success step, `recover`'s exit). This task proves the run still works end to end and that a run carrying no bots behaves exactly as it did before.

**Files:**
- Test: `app/Modules/DirectiveEngine/Tests/SurveyRunRepairTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 4–6.

- [ ] **Step 1: Write the failing test**

```swift
@Test func aRunWithNoBotsWalksTheOriginalPath() {
    let vessel = device("VESSEL", type: "heaven_vessel", location: "SOL-3")
    let w = world(devices: [vessel])
    let run = SurveyRun()
    let deploy = directive(step: SurveyRun.Step.deployingBots, deviceCode: "VESSEL")
    #expect(run.nextAction(directive: deploy, world: w) == .advanceStep(nextStep: SurveyRun.Step.configuring))
    let repair = directive(step: SurveyRun.Step.repairing, deviceCode: "VESSEL", stepStartedAt: fixtureNow.addingTimeInterval(-60))
    #expect(run.nextAction(directive: repair, world: w) == .advanceStep(nextStep: SurveyRun.Step.stowingBots))
    let stow = directive(step: SurveyRun.Step.stowingBots, deviceCode: "VESSEL")
    #expect(run.nextAction(directive: stow, world: w) == .advanceTarget)
}
```

- [ ] **Step 2: Run it**

Run: `cd app/Modules && swift test --filter aRunWithNoBotsWalksTheOriginalPath --event-stream-output-path /tmp/rc-t7.jsonl`
Expected: PASS immediately if Tasks 4–6 are right. A failure here means a degradation path stalls where it should skip — fix the step, not the test.

- [ ] **Step 3: Run the whole product**

Run: `cd app/Modules && swift test --filter DirectiveEngineTests --event-stream-output-path /tmp/rc-t7b.jsonl`
Expected: zero failures. Read the count out of the event stream per the `swift-test-event-stream` skill, discriminating on the `test` record's `kind` field — `testStarted` fires for suites as well as functions.

Note: `theSupervisorAdoptsTheRowTheBrainLaunched` fails only under whole-package `--build-system native` runs and is pre-existing at `a2f200a`. Do not attribute it to this work.

- [ ] **Step 4: Verify the comment budget**

Run: `./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/SurveyRun.swift app/Modules/DirectiveEngine/Sources/RepairFleet.swift`
Expected: exit 0. Exit 0 is a floor, not proof — re-read each new `///` against the ≤3-line budget yourself.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Tests/SurveyRunRepairTests.swift
git commit -m "test(survey): a run carrying no bots walks the original path"
```

---

### Task 8: Directive log retention

Independent of repair; shipped in the same pass. `directiveLogEntries` has no retention policy while `WorldSnapshot.read` re-fetches a directive's whole log every 5-second tick. Live at time of writing: 9,442 rows, 8,394 of them on one running `haulRun`. Persistent runs never terminate, so it only grows.

`DirectiveLogEntry.directiveID` is **nullable** — a built-in AMI directive's entries key off `deviceCode` instead and have no owning row, so they carry no status to consult. Both families need pruning and they need different rules.

**Files:**
- Create: `app/Modules/GameSync/Sources/DirectiveLogRetention.swift`
- Modify: `app/Modules/GameSync/Sources/DeadlineScheduler.swift:127` (beside the existing `OperationRetention.sweep`)
- Create: `app/Modules/GameSync/Tests/DirectiveLogRetentionTests.swift`

**Interfaces:**
- Produces: `DirectiveLogRetention.window: TimeInterval`, `DirectiveLogRetention.sweep(_ database: any DatabaseWriter, now: Date) async -> Int`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils
@testable import GameSync

private let now = Date(timeIntervalSince1970: 10_000_000)

private func entry(_ id: String, directiveID: String?, occurredAt: Date, deviceCode: String? = nil) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: directiveID, deviceCode: deviceCode,
        kind: .stepStarted, summary: "step", step: "preflight",
        operationID: nil, eventID: nil, occurredAt: occurredAt
    )
}

private func seed(_ directives: [Directive], _ entries: [DirectiveLogEntry]) async throws -> any DatabaseWriter {
    let database = try GameDatabase.bootstrap()
    try await database.write { db in
        for d in directives { try Directive.insert { d }.execute(db) }
        for e in entries { try DirectiveLogEntry.insert { e }.execute(db) }
    }
    return database
}

private func remainingIDs(_ database: any DatabaseReader) async throws -> Set<String> {
    try await database.read { db in Set(try DirectiveLogEntry.all.fetchAll(db).map(\.id)) }
}

@Suite("Directive log retention")
struct DirectiveLogRetentionTests {
    @Test func dropsTheLogOfAFinishedRunPastTheWindow() async throws {
        let stale = now.addingTimeInterval(-DirectiveLogRetention.window - 60)
        let done = directiveFixture(id: "D1", status: .completed)
        let database = try await seed([done], [entry("old", directiveID: "D1", occurredAt: stale)])

        let deleted = await DirectiveLogRetention.sweep(database, now: now)

        #expect(deleted == 1)
        #expect(try await remainingIDs(database).isEmpty)
    }

    @Test func keepsAFinishedRunsRecentLog() async throws {
        let recent = now.addingTimeInterval(-60)
        let done = directiveFixture(id: "D1", status: .completed)
        let database = try await seed([done], [entry("new", directiveID: "D1", occurredAt: recent)])

        #expect(await DirectiveLogRetention.sweep(database, now: now) == 0)
        #expect(try await remainingIDs(database) == ["new"])
    }

    @Test func neverPrunesAnOpenRunsLog() async throws {
        let ancient = now.addingTimeInterval(-DirectiveLogRetention.window * 4)
        let live = directiveFixture(id: "D1", status: .running)
        let database = try await seed([live], [entry("ancient", directiveID: "D1", occurredAt: ancient)])

        #expect(await DirectiveLogRetention.sweep(database, now: now) == 0)
        #expect(try await remainingIDs(database) == ["ancient"])
    }

    @Test func agesOutBuiltInAMIEntriesThatOwnNoDirective() async throws {
        let stale = now.addingTimeInterval(-DirectiveLogRetention.window - 60)
        let database = try await seed([], [entry("ami", directiveID: nil, occurredAt: stale, deviceCode: "CTRL1")])

        #expect(await DirectiveLogRetention.sweep(database, now: now) == 1)
        #expect(try await remainingIDs(database).isEmpty)
    }
}
```

`directiveFixture` is whatever the GameSync suite already uses to build a `Directive`; if none exists, write a local one mirroring `OperationRetentionTests`'s `op(...)` helper.

`neverPrunesAnOpenRunsLog` is the load-bearing test. `WorldSnapshot.read` fetches a running directive's whole log every tick, so deleting under a live run is the one outcome that could break a mission mid-flight.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter DirectiveLogRetention --event-stream-output-path /tmp/rc-t8.jsonl`
Expected: FAIL to compile — `cannot find 'DirectiveLogRetention' in scope`.

- [ ] **Step 3: Write the sweep**

```swift
//
//  DirectiveLogRetention.swift
//  Replicould — GameSync
//
//  Retention over `directiveLogEntries`, which nothing pruned while
//  `WorldSnapshot.read` re-fetches a directive's whole log every tick.
//

import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "GameSync")

enum DirectiveLogRetention {
    /// How long a finished run's timeline stays browsable, matching
    /// `OperationRetention.window` so the two ledgers age together.
    static let window: TimeInterval = 7 * 24 * 60 * 60

    /// Delete stale log entries, returning how many went.
    ///
    /// An entry owned by a still-open directive is never pruned however old: a
    /// running mission re-reads its own log every tick. An entry with no owning
    /// directive is a built-in AMI line, which has no status to consult and ages
    /// on time alone.
    @discardableResult
    static func sweep(_ database: any DatabaseWriter, now: Date) async -> Int {
        let cutoff = now.addingTimeInterval(-window)
        do {
            let deleted = try await database.write { db in
                let openIDs = try Directive
                    .where { $0.status.in(DirectiveStatus.openCases) }
                    .fetchAll(db)
                    .map(\.id)
                let doomed = try DirectiveLogEntry
                    .where { $0.occurredAt < cutoff }
                    .fetchAll(db)
                    .filter { entry in
                        guard let owner = entry.directiveID else { return true }
                        return !openIDs.contains(owner)
                    }
                    .map(\.id)
                guard !doomed.isEmpty else { return 0 }
                try DirectiveLogEntry.where { $0.id.in(doomed) }.delete().execute(db)
                return doomed.count
            }
            if deleted > 0 {
                logger.info("retention: pruned \(deleted) directive log entr(ies) older than \(Int(Self.window / 86_400))d")
            }
            return deleted
        } catch {
            logger.error("directive log retention sweep failed: \(error)")
            return 0
        }
    }
}
```

If `DirectiveStatus.openCases` does not exist, add it beside `OperationStatus.openCases` covering `.running`, `.needsAttention` and `.paused` — a paused run resumes and wants its history intact.

Call it in `DeadlineScheduler` immediately after `OperationRetention.sweep(database, now: now)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter DirectiveLogRetention --event-stream-output-path /tmp/rc-t8b.jsonl`
Expected: PASS, 4 tests.

Then the product: `cd app/Modules && swift test --filter GameSyncTests --event-stream-output-path /tmp/rc-t8c.jsonl`
Expected: zero failures.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameSync/Sources/DirectiveLogRetention.swift app/Modules/GameSync/Sources/DeadlineScheduler.swift app/Modules/GameSync/Tests/DirectiveLogRetentionTests.swift
git commit -m "fix(directives): age out the logs of finished runs"
```

---

## What this plan does NOT cover

- **Mine and salvage repair.** Those fleets hold one location for the whole run, so they need the bots staged and nothing else. Built with those capabilities.
- **Brain-driven survey.** The brain today builds only `Goal(kind: .tendMesh)` (`Brain.swift:412`) and inserts only `.relayRun` / `.restockRun`. Adding a `survey` goal is its own plan.
- **Auto-printing bots.** Two exist; the survey fleet needs exactly two. Extending `restockRun` waits for the mine and salvage builds, which need four more.
- **Staging.** Survey Run never stows or adopts — putting two bots aboard the vessel stays the operator's job, exactly as it is for the controller and drones.

## Live preconditions before this runs for real

- The two bots (`0CABDA47`, `69F1D04C`) are at `AINALRAM-BELT-1` and **untagged**. Staging them aboard the survey vessel `F2908E6E` is a manual step.
- The bots' `service` directive already reads `active`. Nothing in this plan sets a directive; if a fresh bot ever reads inactive, that is a `set_directive` the plan does not currently issue.
- Confirm what a *working* bot looks like on the wire before trusting Task 2's `isRepairing`. Idle bots carry no `repair` block; the working shape is inferred from `RepairInfoSchema` and has not been observed live.
