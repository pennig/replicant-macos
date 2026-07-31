# Salvage Run — vessel site tour + smart await backstop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a Salvage Run fly the *vessel* to each salvage body (drones deploy locally) instead of parking and ferrying drones, and stop it false-stalling `dronesNotRecovered` when a mine cycle runs past ten minutes.

**Architecture:** Two independent edits to one pure `MissionStepMachine`, `SalvageRun`. Part A inserts a `positioning` step ahead of `configuring` so the vessel tours the system's sites. Part B rewrites `awaitCompletion` into a state-driven wait that only advances to `verify` once mining is actually done. Everything stays pure (WorldSnapshot in, MissionAction out); no schema, client, or new MissionAction.

**Tech Stack:** Swift, Swift Testing (`@Test`/`#expect`), SwiftPM package at `app/Modules`.

**Spec:** `docs/superpowers/specs/2026-07-31-salvage-run-site-tour-and-backstop-design.md`

## Global Constraints

- **Logging:** `os.Logger` only, never `print`; subsystem `name.pennig.replicould`, category `DirectiveEngine` (the file's existing `logger`). No new logging is required by this plan.
- **Purity:** `SalvageRun` reads no clock and does no I/O — time is `world.now`, every effect is the returned `MissionAction`. Do not introduce `Date()`.
- **Tests read the JSON event stream, never console text.** Use the `swift-test-event-stream` skill for the invocation and to gate pass/fail. The `swift test --filter …` commands below are the runs; parse their results via that skill, not by grepping stdout.
- **LSP is only as fresh as your last build.** After editing, `cd app/Modules && swift build --build-tests` before trusting any `findReferences`. If in a fresh worktree, run `swift build --build-tests` then `./scripts/link-index-store.sh` first.
- **Never edit a shipped migration / no new accent colors etc.** — not exercised here (engine-only change), listed for completeness.

## File Structure

- Modify: `app/Modules/DirectiveEngine/Sources/SalvageRun.swift` — the step machine. Part A adds `Step.positioning`, a `position(_:_:_:)` method, a `nextAction` switch arm, and flips six `Step.configuring` transition targets to `Step.positioning`. Part B rewrites `awaitCompletion`, adds `reconcileInterval` + `recallArrival`, deletes `backstopInterval`, and updates the one call site.
- Modify: `app/Modules/DirectiveEngine/Tests/SalvageRunTests.swift` — extend the `device()` fixture with an `arrivesAt:` travel-block parameter; update the eleven existing assertions that expect a transition *to* `configuring`; add the new `positioning` and `awaitCompletion` tests.

No files are created. The two tasks are independent — Part A and Part B touch disjoint steps — and can be reviewed and committed separately.

---

### Task 1: `positioning` step — the vessel tours the sites (Part A)

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/SalvageRun.swift`
- Test: `app/Modules/DirectiveEngine/Tests/SalvageRunTests.swift`

**Interfaces:**
- Consumes (existing, unchanged): `SalvageRun.nextBody(in:world:) -> NextBodyResolution`, `unresolvedSystem(_:_:target:) -> MissionAction`, `WorldSnapshot.openOperation(for:)`, `Directive.currentTarget`.
- Produces: a new step string `SalvageRun.Step.positioning == "positioning"` and a `private func position(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction`. The mining loop becomes `[entry] → positioning → configuring → launching → awaiting → verifying → positioning`.

- [ ] **Step 1: Extend existing assertions and add the failing `positioning` tests**

In `SalvageRunTests.swift`, first flip every assertion that expects a transition **to** `configuring` (the `nextStep`/`advanceStep` *value*, NOT `running(step: "configuring")` inputs and NOT `configure`'s own tests that output `"launching"`). Exactly eleven, by test name:

- `SalvageRunTravelTests.skipsStraightToMiningWhenTheSystemIsAlreadyMeshed` — `.advanceStep(nextStep: "configuring")` → `"positioning"`
- `SalvageRunEmplacementTests.advancesToConfiguringOnceTheRelayIsRelaying` — `.advanceStep(nextStep: "configuring")` → `"positioning"`
- `SalvageRunEmplacementTests.untagsTheRelayOnceItStartsRelaying` — `.setDeviceTags(deviceCode: "RELAY", tags: [], nextStep: "configuring")` → `nextStep: "positioning"`
- `SalvageRunEmplacementTests.preservesTheRelaysOtherTagsWhenUntagging` — `nextStep: "configuring"` → `"positioning"`
- `SalvageRunEmplacementTests.untagsAgainstTheRowsOwnFleetTagRatherThanTheDefault` — `nextStep: "configuring"` → `"positioning"`
- `SalvageRunEmplacementTests.advancesPlainlyWhenTheRelayNoLongerCarriesTheFleetTag` — `.advanceStep(nextStep: "configuring")` → `"positioning"`
- `SalvageRunEmplacementTests.acceptsARelayingStatusCarryingAParameter` — `.advanceStep(nextStep: "configuring")` → `"positioning"`
- `SalvageRunEmplacementTests.minesUnmeshedWhenTheSystemHasNoLagrangePoint` — `.advanceStep(nextStep: "configuring")` → `"positioning"`
- `SalvageRunVerificationTests.advancesToConfiguringWhenDronesAreHomeAndBodiesRemain` — `.advanceStep(nextStep: "configuring")` → `"positioning"`
- `SalvageRunLoopProgressTests.continuesWhenTheNextBodyIsADifferentOne` — `.advanceStep(nextStep: "configuring")` → `"positioning"`
- `SalvageRunLoopProgressTests.proceedsWhenTheControllerNamesNoWorkedBody` — `.advanceStep(nextStep: "configuring")` → `"positioning"`

Then add a new suite for the step itself:

```swift
// MARK: - Positioning

/// The vessel — not the drones — travels to each salvage body, so the drones
/// deploy locally instead of ferrying from a parked vessel. Keyed off
/// `nextBody` (deterministic) rather than the controller's in-force config,
/// which is written only on command-confirm and would name the previous body
/// right after `configure` re-issues.
@Suite("Salvage Run — positioning")
struct SalvageRunPositioningTests {
    /// The vessel is in the system but not yet at the richest body: fly it there.
    @Test func travelsTheVesselToTheRichestBody() {
        let world = world(devices: [atSystem, controller, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: world)
            == .dispatch(kind: .travel, deviceCode: "VESSEL",
                         params: CommandParams(destination: "TOSLIT-6-5"), nextStep: "positioning"))
    }

    /// Mid-trip is a wait, never a second travel stacked on the one in flight.
    @Test func waitsWhileTheVesselIsUnderway() {
        let world = world(devices: [atSystem, controller, drone],
                          openOperations: ["VESSEL": operation(kind: .travel)],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: world) == .wait)
    }

    /// Arrived at the body: hand to `configuring` to set the directive and launch
    /// locally.
    @Test func configuresOnceTheVesselIsAtTheBody() {
        let atBody = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-6-5")
        let world = world(devices: [atBody, controller, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: world)
            == .advanceStep(nextStep: "configuring"))
    }

    /// No live body left in the system: this target is done. `positioning` owns
    /// the first look now, so it inherits `configure`'s finished handling.
    @Test func advancesTheTargetWhenNoBodyIsLeft() {
        let drained = StarSystem(designation: "TOSLIT", planets: [])
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": drained])
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: world)
            == .advanceTarget)
    }

    /// An uncached system blob must NOT read as "nothing to mine" — wait for it,
    /// same backstop as `configure`/`emplace`/`verify`.
    @Test func waitsWhenTheSystemIsntCachedYet() {
        let world = world(devices: [atSystem, controller, drone]) // no "TOSLIT" entry
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: world) == .wait)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app/Modules && swift test --filter SalvageRun
```

Expected: compile failure (`Step.positioning` / `position` not yet defined) or, once those exist, the eleven flipped assertions and the new suite FAIL. Use the `swift-test-event-stream` skill to confirm the failures are exactly these tests.

- [ ] **Step 3: Add the `positioning` step to the source**

In `SalvageRun.swift`, add the step constant to the `Step` enum, immediately after `confirmingRelay`:

```swift
        /// Fly the VESSEL to the salvage body it is about to work, so the drones
        /// deploy locally rather than ferrying from a parked vessel. Runs BEFORE
        /// `configuring` — see `position(_:_:_:)` for why the order and the
        /// `nextBody` keying both matter.
        public static let positioning = "positioning"
```

Add the dispatch arm to `nextAction`, next to the other mining steps:

```swift
        case Step.positioning: return position(directive, vessel, world)
```

Add the method (place it just above `configure`, in the mining-loop section):

```swift
    /// Fly the VESSEL to the salvage body it is about to work (spec §Part A), so
    /// the drones deploy locally instead of ferrying from a parked vessel.
    ///
    /// Keyed off `nextBody` — the same deterministic ranking `configure` uses —
    /// NOT the controller's in-force `gather_salvage` config: nothing writes
    /// `currentDirectiveConfig` optimistically, so right after `configure`
    /// re-issues `set_directive` the controller row still names the PREVIOUS body
    /// until the command lands, and a config-keyed position would mis-target on
    /// every transition. Running BEFORE `configure` and off `nextBody` also makes
    /// a body draining mid-flight simply re-target the vessel to the next-richest
    /// one — correct, because `configure` hasn't issued anything yet.
    ///
    /// Owns the first look at the target system, so it inherits `configure`'s
    /// `.finished` / `.unresolved` handling verbatim.
    private func position(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        switch Self.nextBody(in: directive, world: world) {
        case .finished:
            return .advanceTarget
        case .unresolved:
            guard let target = directive.currentTarget else { return .advanceTarget }
            return unresolvedSystem(directive, world, target: target)
        case let .body(body):
            if vessel.location == body { return .advanceStep(nextStep: Step.configuring) }
            // `.travel` is a tracked op kind (creates an `Operation` row), so this
            // guard fires and the same-step re-dispatch is the safe shape
            // (see the same-step-dispatch-needs-tracked-op note) — like `emplace`
            // and `restock`.
            if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
            return .dispatch(
                kind: .travel, deviceCode: vessel.deviceCode,
                params: CommandParams(destination: body), nextStep: Step.positioning
            )
        }
    }
```

- [ ] **Step 4: Flip the six `configuring` transition targets to `positioning`**

In `SalvageRun.swift`, change the `nextStep` value from `Step.configuring` to `Step.positioning` at exactly these six sites (verify by line context, not line number, since earlier edits shift them). Do NOT touch `nextAction`'s `case Step.configuring:` dispatch arm or `configure`'s own body.

1. `travel(...)`, arrival arm: `return .advanceStep(nextStep: meshed ? Step.configuring : Step.emplacing)` → `meshed ? Step.positioning : Step.emplacing`.
2. `emplace(...)`, the `guard let target = directive.currentTarget else { … }` arm → `.advanceStep(nextStep: Step.positioning)`.
3. `emplace(...)`, the `guard let point = Self.lagrangePoint(in: system) else { … }` arm → `.advanceStep(nextStep: Step.positioning)`.
4. `settle(...)`, the `guard relay.tags.contains(tag) else { return .advanceStep(nextStep: Step.configuring) }` arm → `Step.positioning`.
5. `settle(...)`, the `.setDeviceTags(deviceCode:…, tags:…, nextStep: Step.configuring)` return → `nextStep: Step.positioning`.
6. `verify(...)`, the `.body` arm's `return .advanceStep(nextStep: Step.configuring)` → `Step.positioning`.

Update the two doc comments that describe these hand-offs if they name `configuring` (e.g. `settle`'s and `travel`'s), so the prose matches. `configure`'s own doc note that says "this is also the seam Task 8's `verifying` step will hand back into" stays accurate (verify now hands into `positioning`, which hands into `configuring`).

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd app/Modules && swift build --build-tests && swift test --filter SalvageRun
```

Expected: the whole `SalvageRun` suite PASSES (the eleven flipped assertions, the new `positioning` suite, and every untouched test). Confirm via the `swift-test-event-stream` skill.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/SalvageRun.swift app/Modules/DirectiveEngine/Tests/SalvageRunTests.swift
git commit -m "Salvage Run: fly the vessel to each salvage body before launching

Insert a positioning step ahead of configuring so the vessel tours the
system's sites and the drones deploy locally, instead of parking at the
entry point / Lagrange and ferrying drones to each site and back.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Smart await backstop — no more false `dronesNotRecovered` (Part B)

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/SalvageRun.swift`
- Test: `app/Modules/DirectiveEngine/Tests/SalvageRunTests.swift`

**Interfaces:**
- Consumes (existing, unchanged): `SalvageRun.completionSeen(_:_:)`, `emptyLaunchSeen(_:_:)`, `claimedController(_:_:_:)`, `fleetTag(_:)`, `AMIFleet.adoptedDrones(of:in:)` (the WIDE query), `Device.activityDeadline`, `Device.currentDirective`.
- Produces: `SalvageRun.reconcileInterval: TimeInterval`, `static func recallArrival(_:) -> Date?`, and a new signature `awaitCompletion(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot)`. `verify` is **unchanged** and remains the only source of `.dronesNotRecovered`. `backstopInterval` is deleted.

- [ ] **Step 1: Add the `arrivesAt:` fixture parameter and write the failing await tests**

In `SalvageRunTests.swift`, extend the `device()` helper with an `arrivesAt:` parameter that writes a `travel` block (mirroring `SurveyRunTests`). Add the parameter to the signature (after `updatedAt`) and this block at the top of the body, before the `controlled_devices` block:

```swift
    arrivesAt: Date? = nil
```
```swift
    if let arrivesAt {
        // A drone flying home under recall — a single in-system hop, so both
        // timing fields agree. Gives the row an `activityDeadline`.
        detail["travel"] = .object([
            "arrives_at": .string(arrivesAt.ISO8601Format()),
            "final_arrives_at": .string(arrivesAt.ISO8601Format()),
        ])
    }
```

Set the device `status` to reflect it, matching `SurveyRunTests`: change `status: String = "idle"` handling so a travelling drone reports `"travelling"` — replace the `status` default usage in the `Device(...)` init with `status: arrivesAt == nil ? status : "travelling"`.

Replace the existing `SalvageRunMiningTests.waitsForCompletionThenVerifies` (its fixture has the drone aboard, which now reads as "recovered") and add the rest. In `SalvageRunMiningTests`:

```swift
    /// A controller actively mining (`gather_salvage` in force) with a drone
    /// deployed, well past ten minutes: the run WAITS. This is the core
    /// regression — the old blind ten-minute backstop dumped into `verify` here
    /// and false-stalled `dronesNotRecovered` every long cycle.
    @Test func waitsWhileMiningEvenPastTenMinutes() {
        let mining = device(
            "CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
            controlled: ["DRONE"], directives: ["gather_salvage"],
            currentDirective: "gather_salvage",
            currentDirectiveConfig: ["location": .string("TOSLIT-6-5"), "recall": .bool(true)]
        )
        let deployed = device("DRONE", type: "mining_drone", location: "TOSLIT-6-5", controlledBy: "CTRL")
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-11 * 60))
        let world = world(devices: [atSystem, mining, deployed], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world) == .wait)
    }

    /// A dropped completion frame: the drones are already home, nothing said so.
    /// A fresh (post-launch) read showing all aboard hands off to `verify`.
    @Test func verifiesWhenAllDronesAreHomeWithoutACompletionFrame() {
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-60))
        // controller + drone are `fixtureNow`, which is >= stepStartedAt: fresh
        // since launch, and the drone is stowed aboard.
        let world = world(devices: [atSystem, controller, drone], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .advanceStep(nextStep: "verifying"))
    }

    /// Rows not read since launch (pre-launch `updatedAt`) can't be trusted — a
    /// pre-launch drone still shows aboard. Force one fresh read first.
    @Test func readsTheFleetWhenEvidencePredatesLaunch() {
        let staleCtrl = device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
                               controlled: ["DRONE"], directives: ["gather_salvage"],
                               updatedAt: now.addingTimeInterval(-SalvageRun.reconcileInterval - 1))
        let staleDrone = device("DRONE", type: "mining_drone", stowedIn: "VESSEL", controlledBy: "CTRL",
                                updatedAt: now.addingTimeInterval(-SalvageRun.reconcileInterval - 1))
        let directive = running(step: "awaiting", stepStartedAt: now) // launch just now; rows older
        let world = world(devices: [atSystem, staleCtrl, staleDrone], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshFleet(tag: "auto:salvage", thenStall: nil))
    }

    /// The throttle guard: pre-launch rows read within `reconcileInterval` wait
    /// rather than re-reading every tick, so a failing read can't loop.
    @Test func waitsRatherThanReReadingWithinTheReconcileInterval() {
        let recentCtrl = device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
                                controlled: ["DRONE"], directives: ["gather_salvage"],
                                updatedAt: now.addingTimeInterval(-30))
        let recentDrone = device("DRONE", type: "mining_drone", stowedIn: "VESSEL", controlledBy: "CTRL",
                                 updatedAt: now.addingTimeInterval(-30))
        let directive = running(step: "awaiting", stepStartedAt: now) // rows (-30s) predate launch (now)
        let world = world(devices: [atSystem, recentCtrl, recentDrone], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world) == .wait)
    }

    /// Mining done (controller idle), a straggler still flying home with a future
    /// ETA: wait it out rather than handing to `verify`'s single-read stall.
    @Test func waitsForAStragglerStillFlyingHome() {
        let idle = device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
                          controlled: ["DRONE"], directives: ["gather_salvage"]) // no currentDirective
        let flying = device("DRONE", type: "mining_drone", controlledBy: "CTRL",
                            arrivesAt: now.addingTimeInterval(30))
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-60))
        let world = world(devices: [atSystem, idle, flying], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world) == .wait)
    }

    /// Mining done, a drone not aboard and NOT travelling (no ETA): it isn't
    /// coming on its own. Hand to `verify`, which refreshes once and raises
    /// `dronesNotRecovered` if the fresh rows agree.
    @Test func handsToVerifyWhenAStrandedDroneIsntComing() {
        let idle = device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
                          controlled: ["DRONE"], directives: ["gather_salvage"])
        let stuck = device("DRONE", type: "mining_drone", location: "TOSLIT-6-5", controlledBy: "CTRL")
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-60))
        let world = world(devices: [atSystem, idle, stuck], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .advanceStep(nextStep: "verifying"))
    }
```

Keep `advancesToVerifyingWhenCompletionLands` and `stallsWhenALaunchDeployedNothing` — both still hold (completion / empty-launch are checked first). Leave the entire `SalvageRunVerificationTests` suite as-is (`verify` is unchanged).

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app/Modules && swift test --filter SalvageRun
```

Expected: compile failure (`reconcileInterval` undefined, or `awaitCompletion` arity) or the new await tests FAIL. Confirm via the `swift-test-event-stream` skill.

- [ ] **Step 3: Rewrite `awaitCompletion` and add its helpers**

In `SalvageRun.swift`, delete the `backstopInterval` declaration and its doc comment:

```swift
    /// How long to wait on the `directive.completed` fast path before moving on
    /// to verify anyway. Same value and reasoning as `SurveyRun.backstopInterval`
    /// — a dropped SSE frame must not strand a run forever.
    public static let backstopInterval: TimeInterval = 10 * 60
```

In the doc comment of `systemResolutionDeadline`, change "Same scale as `activationDeadline` / `backstopInterval`." to "Same scale as `activationDeadline`." (drop the dangling reference).

Add these two members near `backstopInterval`'s old home (above `awaitCompletion`):

```swift
    /// How long between reconciling reads while `awaiting` waits on mining. Long
    /// enough that a multi-minute mine cycle costs only a read every couple of
    /// minutes; short enough to notice a DROPPED `directive.completed` frame
    /// promptly. The throttle is also what stops a failing read looping every
    /// tick (see the confirm-steps-need-fresh-evidence note).
    public static let reconcileInterval: TimeInterval = 2 * 60

    /// The soonest a still-out drone is due back, if any reports a trip — mirrors
    /// `SurveyRun.recallArrival`. `activityDeadline` resolves the travel block's
    /// leg-vs-route pair, so a recall hop yields its real arrival.
    static func recallArrival(_ stranded: [Device]) -> Date? {
        stranded.compactMap(\.activityDeadline).max()
    }
```

Replace the whole `awaitCompletion` method with:

```swift
    /// Wait until the mining cycle is actually done, THEN hand to `verify` —
    /// never stall here. `directive.completed` is authoritative (held until the
    /// recall lands since v2.3.3, so it means "drones home"), and the only real
    /// failure is a dropped frame, so every fallback is a reconciling read, not a
    /// blind timer.
    ///
    /// The prior blind `backstopInterval` advance was the operator-visible bug:
    /// mine cycles routinely run past ten minutes, so a fixed ten-minute advance
    /// dumped into `verify` mid-mining — where the drones are legitimately still
    /// out — and `verify` stalled `dronesNotRecovered` every cycle. The
    /// still-mining gate below is the fix: while the controller reports
    /// `gather_salvage`, this waits however long it takes.
    ///
    /// `verify` is unchanged and remains the ONE place that raises
    /// `dronesNotRecovered`: this step advances there only once the drones aren't
    /// travelling (all aboard, or mining finished with none en route), so
    /// `verify`'s single authoritative refresh can't false-stall a straggler
    /// mid-hop.
    private func awaitCompletion(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        if Self.completionSeen(directive, world) {
            return .advanceStep(nextStep: Step.verifying)
        }
        // The controller told us this launch deployed nothing — no completion is
        // ever coming, so surface it now rather than reconciling forever.
        if Self.emptyLaunchSeen(directive, world) { return .stall(.launchDeployedNothing) }

        guard let controller = claimedController(directive, vessel, world) else { return .wait }
        let drones = AMIFleet.adoptedDrones(of: controller, in: world)
        let evidence = [controller] + drones
        let lastLook = evidence.map(\.updatedAt).max() ?? .distantPast
        let canRead = world.now.timeIntervalSince(lastLook) >= Self.reconcileInterval

        // Never believe a row read BEFORE this step began (before launch): a
        // pre-launch drone row still shows it stowed aboard, which would read as
        // "recovered" the instant the step starts. Force a post-launch read
        // first — throttled, so a failing one can't loop every tick.
        guard lastLook >= directive.stepStartedAt else {
            return canRead ? .refreshFleet(tag: Self.fleetTag(directive), thenStall: nil) : .wait
        }

        let stranded = drones.filter { $0.stowedInDeviceCode != vessel.deviceCode }
        // A dropped completion frame: the drones are already home, nothing said so.
        if stranded.isEmpty { return .advanceStep(nextStep: Step.verifying) }
        // Still mining — the drones are out by design. Reconcile on a cadence to
        // catch completion (or the controller going idle); never stall, however
        // long the cycle runs.
        if controller.currentDirective == "gather_salvage" {
            return canRead ? .refreshFleet(tag: Self.fleetTag(directive), thenStall: nil) : .wait
        }
        // Mining done, drones still out: a post-mining recall (near-instant now
        // the vessel sits at the body). Wait out any traveller's own ETA; re-read
        // the stragglers on the cadence otherwise.
        if stranded.contains(where: { $0.activityDeadline != nil }) {
            if let arrival = Self.recallArrival(stranded), arrival > world.now { return .wait }
            return canRead
                ? .refreshDevices(deviceCodes: stranded.map(\.deviceCode), thenStall: nil)
                : .wait
        }
        // None travelling, none aboard, mining finished — they aren't coming on
        // their own. Hand to `verify`, which refreshes once and raises
        // `dronesNotRecovered` if the fresh rows agree.
        return .advanceStep(nextStep: Step.verifying)
    }
```

Update the one call site in `nextAction`: `case Step.awaiting: return awaitCompletion(directive, vessel, world)`.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd app/Modules && swift build --build-tests && swift test --filter SalvageRun
```

Expected: the whole `SalvageRun` suite PASSES, including the new await tests and the untouched `verify` suite. Confirm via the `swift-test-event-stream` skill.

- [ ] **Step 5: Full-suite regression run**

```bash
cd app/Modules && swift test --filter DirectiveEngine
```

Expected: the full `DirectiveEngine` test target is green (no cross-step regression from the loop reshape or the signature change). Confirm via the `swift-test-event-stream` skill.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/SalvageRun.swift app/Modules/DirectiveEngine/Tests/SalvageRunTests.swift
git commit -m "Salvage Run: wait out mining instead of false-stalling dronesNotRecovered

Replace awaitCompletion's blind ten-minute backstop with a state-driven
wait: while the controller reports gather_salvage the run waits however
long the cycle takes, reconciling on a cadence to catch a dropped
completion frame, and only hands to verify once the drones aren't
travelling. verify still owns the one dronesNotRecovered stall.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage.**
- Part A `positioning` before `configuring`, `nextBody`-keyed, six call-site flips, configure unchanged → Task 1. ✓
- Part A `.finished`/`.unresolved` inheritance → Task 1 Step 3 (position method) + tests `advancesTheTargetWhenNoBodyIsLeft`, `waitsWhenTheSystemIsntCachedYet`. ✓
- Part B `awaitCompletion` rewrite, still-mining gate, fresh-evidence gate + throttle, recall/ETA branch, verify unchanged, delete `backstopInterval`, add `reconcileInterval`/`recallArrival`, signature+call-site → Task 2. ✓
- Fixture `arrivesAt:` extension → Task 2 Step 1. ✓
- All spec test bullets have a matching `@Test`. ✓

**2. Placeholder scan.** No TBD/TODO; every code and test step carries full source. The eleven assertion flips are enumerated by exact test name and old→new value (mechanical, unambiguous), not "similar to". ✓

**3. Type consistency.** `position(_:_:_:)` returns `MissionAction`; `nextBody(in:world:)` returns `NextBodyResolution` with cases `.finished`/`.unresolved`/`.body(String)` (matches the source enum). `awaitCompletion(_:_:_:)` new arity matches the updated call site. `recallArrival(_:) -> Date?` matches SurveyRun's shape. `AMIFleet.adoptedDrones(of:in:)` is the wide query (confirmed signature). `Device.activityDeadline: Date?`, `Device.currentDirective: String?`, `Device.stowedInDeviceCode: String?` all match. Step string `"positioning"` is used consistently in source (`Step.positioning`) and tests (literal). ✓

**4. Ordering / determinism.** `nextBody` ranks by assayed units then designation (deterministic); `miningToslitAssays` makes `TOSLIT-6-5` (500) the pick over `TOSLIT-3-2` (100), so `travelsTheVesselToTheRichestBody` and `configuresOnceTheVesselIsAtTheBody` target `TOSLIT-6-5` unambiguously. ✓
