//
//  Brain.swift
//  Replicould — DirectiveEngine
//
//  The automation brain's evaluation entry point. `DirectiveEngineCore` ticks
//  a `Brain` alongside its existing supervisor (`tickBrain()` in
//  `DirectiveEngine.swift`) — this is the real seam every later brain task
//  (stall response, the confirm-read gate, prune) tests end-to-end through
//  (`brain-executor-seam`).
//
//  Task 16 is where the brain stops observing and starts acting: a tick that
//  finds unmeshed value, a print hub on the mesh, and a free carrier LAUNCHES
//  a Relay Run. That is the brain's whole enactment vocabulary on the grow
//  side — ONE `Directive.insert`, which the executor then picks up and runs.
//  It remains a PURE SELECTOR (`brain-robustness-bar` clause 1): it never
//  hand-edits a running directive's step/target/status, never issues a command
//  outside the executor → `CommandGovernor` path, and never drives
//  `skipTarget`/`pause`/`resume`, which are operator-only, permanently.
//
//  STATELESS between ticks (clause 2). A tick is a pure function of
//  `(WorldView, directive rows)`: no lease table, no cache, no memory. The
//  ranking, the path-union behind it, and the reservation set are all
//  recomputed from scratch every 5 seconds, which is why a relaunch mid-plan
//  costs nothing and why nothing here can drift out of step with the fleet.
//  `Directive.sourceRelayCode` is a plan hint on the ROW, not brain memory.
//
//  Not an actor, and deliberately so: a plain, non-actor-isolated type's
//  `async` methods are nonisolated by default, so calling `evaluateOnce()`
//  from `DirectiveEngineCore.tickBrain()` (actor-isolated) hops the ranking
//  work off `DirectiveEngineCore`'s serial executor rather than running it
//  inline — the ranking pass can never block the executor-reconciliation loop
//  ticking alongside it.
//

import Dependencies
import Foundation
import GameModels
import OSLog
import SQLiteData
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Brain")

/// One tick's worth of brain evaluation. Stateless between ticks by design
/// (`brain-robustness-bar` clause 2): every field here is an input to THIS
/// evaluation, never state carried over from the last one.
struct Brain: Sendable {
    /// The tick's clock reading, bridged in by the caller via
    /// `@Dependency(\.date)` rather than sampled here — keeps `WorldView`'s
    /// snapshot, and every test built on `TestClock`, deterministic. Never
    /// `Date()` directly.
    let now: Date

    /// The device type this build's grow launch flies. The composition
    /// (`RelayRun`'s file header, ticket 05) is autofactory + co-located
    /// HEAVEN vessel: the relay is printed at the hub and taken aboard a
    /// vessel already standing there.
    static let carrierDeviceType = "heaven_vessel"

    /// The statuses in which a directive still OWNS its devices.
    ///
    /// `paused` and `needsAttention` keep ownership: the mission is still in
    /// force, its devices are still where it left them, and a stall the
    /// operator is about to resolve must find its fleet intact. Only a
    /// finished mission (`completed`/`cancelled`) gives its devices back.
    ///
    /// `DirectiveRow.owningStatuses` (DirectivesFeature) states the same rule
    /// for the list row's display join. It is deliberately NOT imported here
    /// and this one is not exported there: `DirectivesFeature` depends on
    /// `DirectiveEngine`, so the dependency can only run one way, and lifting
    /// the set into `GameModels` would be a schema-module change this task is
    /// not scoped to make. If a third caller ever needs it, that lift is the
    /// right move — two copies of a three-case set is the ceiling.
    static let owningStatuses: Set<DirectiveStatus> = [.running, .needsAttention, .paused]

    /// Read the world, decide what — if anything — is worth doing, and launch
    /// it. One `database.read` (a consistent snapshot of the galaxy AND the
    /// directive rows that reserve it), one pure decision, and at most one
    /// `database.write`.
    func evaluateOnce() async -> BrainDecision {
        @Dependency(\.defaultDatabase) var database

        let snapshot: Snapshot
        do {
            snapshot = try await database.read { db in
                Snapshot(
                    view: try WorldView.read(from: db, now: now),
                    directives: try Directive.all.fetchAll(db)
                )
            }
        } catch {
            logger.error("world read failed: \(error)")
            return .idle(reason: "world unavailable")
        }

        switch Self.plan(view: snapshot.view, directives: snapshot.directives) {
        case let .idle(reason):
            // Per-tick, so `.debug` — a 5-second heartbeat at any louder level
            // would bury the launches this file exists to make visible.
            logger.debug("idle — \(reason, privacy: .public)")
            return .idle(reason: reason)

        case let .grow(goal, ranked, carrier, origin):
            return await launch(
                goal: goal, ranked: ranked, carrier: carrier, origin: origin, database: database
            )
        }
    }

    /// One consistent read: the galaxy the brain ranks over, and the directive
    /// rows that say which of it is already spoken for. Read in ONE
    /// transaction on purpose — a carrier freed between two separate reads
    /// would look free to the ranking and reserved to the reservation pass (or
    /// worse, the reverse).
    ///
    /// `Directive.all`, not a status-filtered query, deliberately: which
    /// statuses own their devices is a RULE (`owningStatuses`), and splitting
    /// it between a SQL predicate here and the pure pass below is how the two
    /// halves drift. The table is a mission ledger — tens of rows, not the
    /// unbounded `operations` log — so reading it whole every tick is cheap.
    private struct Snapshot: Sendable {
        let view: WorldView
        let directives: [Directive]
    }

    // MARK: - The greedy pass

    /// What a tick decided to do, before anything is written. Split from
    /// `evaluateOnce` so the whole judgement is a PURE function of the
    /// snapshot — no clock, no database, no dependencies.
    enum Plan {
        case idle(reason: String)
        /// Launch a Relay Run for `goal` on `carrier`, which sets off from
        /// `origin` (the hub's system). `ranked` is the whole field the choice
        /// was made against, carried through for the why-view.
        case grow(goal: Goal, ranked: [GrowCandidate], carrier: String, origin: String)
    }

    /// The greedy pass, grow-only.
    ///
    /// **One launch per tick, deliberately.** The pass takes the single
    /// best still-available candidate and stops; the next tick, five seconds
    /// later, re-ranks from scratch against a world that now contains the row
    /// it just wrote. That makes in-tick double allocation structurally
    /// impossible rather than merely guarded — there is no second allocation
    /// within a pass to double-book with — and it keeps the whole tick a pure
    /// function of its snapshot. (It is also the shape the task brief
    /// specifies. A multi-launch pass would have to thread a growing reserved
    /// set through each allocation; when prune lands and a tick can allocate
    /// twice, that threading is what must be added, and this doc is the note
    /// saying so.)
    ///
    /// Order of the gates is chosen for the why-view's sake: "nothing worth
    /// reaching" and "nothing free to send" are genuinely different states and
    /// an operator needs to be told which one they are in.
    static func plan(view: WorldView, directives: [Directive]) -> Plan {
        guard !view.meshSystems.isEmpty else { return .idle(reason: "no mesh yet") }

        let graph = MeshGraph(positions: view.starPositions)
        let ranked = GrowRanking.rank(view: view, graph: graph)
        guard !ranked.isEmpty else {
            // Prune is a later task, so "no grow work" is the whole of it.
            return .idle(reason: "no grow or prune work")
        }

        // A hop another Relay Run is already flying to is not a candidate.
        // Reserving the CARRIER alone does not cover this: with two free
        // carriers, every tick between launch and arrival would print a
        // second relay (370 units, ~800 s) for a system already being
        // meshed, and the loser's `travel` step would then find the target
        // meshed on arrival and hand a spare relay back to nobody.
        let inFlight = Set(
            directives
                .filter { $0.kind == .relayRun && owningStatuses.contains($0.status) }
                .flatMap(\.targets)
        )
        guard let candidate = ranked.first(where: { !inFlight.contains($0.firstHop) }) else {
            return .idle(reason: "every grow candidate is already in flight")
        }

        // The relay has to come from somewhere. `WorldView.hubLocation` is
        // already nil for an OFF-MESH hub, so this one guard covers both "no
        // printer" and "a printer we cannot reach".
        guard let hub = view.hubLocation else { return .idle(reason: "no print hub on the mesh") }

        let reserved = reservedDevices(directives: directives, devices: view.devices)
        guard let carrier = freeCarrier(at: hub, devices: view.devices, reserved: reserved) else {
            return .idle(reason: "no free carrier at \(hub)")
        }

        return .grow(
            goal: Goal(kind: .tendMesh, target: candidate.firstHop, rationale: rationale(for: candidate)),
            ranked: ranked,
            carrier: carrier.deviceCode,
            origin: SiteAssay.system(of: hub)
        )
    }

    // MARK: - Reservation

    /// Every device code an in-force directive owns — the set a launch must
    /// not allocate out of.
    ///
    /// The running directive ROWS are the lease ledger (`brain-executor-seam`,
    /// ticket 04); there is no separate lease table and this task deliberately
    /// does not add one. Four rules from that ticket seed the set:
    ///
    ///   1. `deviceCode` — the mission's carrier.
    ///   2. Everything transitively stowed inside it (see the closure below).
    ///   3. `controllerCode` — the AMI the mission is driving.
    ///   4. `fleetTag` — every device wearing it, because a tag is how a Haul
    ///      Run names a working set no column points at. This is why the
    ///      caller must pass an UNFILTERED fleet: a tagged device is usually
    ///      stowed, and `WorldView.read`'s `Device.all` is what makes it
    ///      visible here at all.
    ///
    /// Then a **closure** to a fixpoint over three containment relations. The
    /// seed alone is not "every device an in-force directive owns", which is
    /// what this function claims and what its one consumer needs:
    ///
    ///   - **Stow, downward** (`parent → children`). A relay aboard a carrier,
    ///     a drone aboard a controller aboard a carrier: the whole subtree
    ///     travels with the mission.
    ///   - **Stow, upward** (`child → its hull`). The one review found, and
    ///     the reachable one: directive D owns device X, X is stowed inside
    ///     vessel V, and V is named by no directive. Without this edge V reads
    ///     as free, `freeCarrier` picks it, and the Relay Run flies away with
    ///     another mission's device in the hold. The hull is as reserved as
    ///     its cargo. (Reserving V then re-reserves V's other contents through
    ///     the downward edge, which is correct for the same reason: they all
    ///     go where V goes.)
    ///   - **Adoption** (`controller → adopted drones`), read from BOTH ends
    ///     exactly as `AMIFleet.adoptedDrones(of:in:)` does — the drone's
    ///     `controllerDeviceCode` column AND the controller's
    ///     `controlledDeviceCodes`. The two-ended read is not belt-and-braces:
    ///     `controlled_devices` ships only in the single-device payload and a
    ///     routine fleet sync ERASES it (`controlled-devices-detail-only`), so
    ///     the column is the reliable end and the blob is the bonus. A
    ///     deployed drone adopted by a reserved controller is owned even
    ///     though it is stowed nowhere.
    ///
    /// Every stow read is through the CHILD's own `stowedInDeviceCode` column,
    /// never the parent's `stowed_devices` blob — the blob is not a reliable
    /// inverse (a live vessel's listed one unrelated device while six drones
    /// claimed to be aboard), the same reason `RelayRun.confirmStow` reads the
    /// child end.
    ///
    /// **Deliberately over-reserving rather than under-.** The closure spreads
    /// through a containment component, so one owned drone can reserve a hull
    /// and its other contents. That direction of error costs a tick of
    /// patience; the other direction strands somebody's fleet.
    ///
    /// **Terminates** on any input, including corrupt ones: a code joins the
    /// frontier only on the pass that first inserts it into `reserved`, so a
    /// stow cycle (A aboard B aboard A) closes instead of looping.
    ///
    /// Nothing existing computed this: `DirectiveRow.owningStatuses`
    /// (DirectivesFeature) is a display-side join over `controllerCode` only,
    /// covers neither the carrier, the stow tree, nor the tag, and lives in
    /// a module that depends on this one — so reusing it is impossible in the
    /// only direction that matters, and widening it would leave the display
    /// join answering a question it was not asked. This is the one place the
    /// rules are spelled out.
    static func reservedDevices(directives: [Directive], devices: [String: Device]) -> Set<String> {
        let owning = directives.filter { owningStatuses.contains($0.status) }
        guard !owning.isEmpty else { return [] }

        var reserved = Set<String>()
        for directive in owning {
            reserved.insert(directive.deviceCode)
            if let controller = directive.controllerCode { reserved.insert(controller) }
            if let tag = directive.fleetTag {
                for device in devices.values where device.tags.contains(tag) {
                    reserved.insert(device.deviceCode)
                }
            }
        }

        // `code → everything reserving `code` also reserves`. Built once over
        // the whole fleet rather than once per directive, and walked once from
        // the whole seed set.
        //
        // Every edge TARGET is required to be a device the fleet actually
        // holds. A dangling reference — a hull we have no row for, an adoption
        // list naming a device a sync has not brought in — names nothing this
        // brain could allocate anyway, and admitting it would put phantom
        // codes in a set whose whole meaning is "real devices, spoken for".
        var drags: [String: [String]] = [:]
        func link(_ from: String, _ to: String) {
            guard devices[to] != nil else { return }
            drags[from, default: []].append(to)
        }
        for device in devices.values {
            if let hull = device.stowedInDeviceCode {
                link(hull, device.deviceCode)   // downward: the cargo aboard it
                link(device.deviceCode, hull)   // upward: the hull it rides in
            }
            if let controller = device.controllerDeviceCode {
                link(controller, device.deviceCode)
            }
            for adopted in device.controlledDeviceCodes {
                link(device.deviceCode, adopted)
            }
        }

        var frontier = Array(reserved)
        while let code = frontier.popLast() {
            for next in drags[code] ?? [] where reserved.insert(next).inserted {
                frontier.append(next)
            }
        }
        return reserved
    }

    /// A carrier this tick may spend: the right type, standing WITH the print
    /// hub, at rest, and owned by nobody.
    ///
    /// Co-location is the composition, not a preference — `RelayRun.acquire`
    /// looks for a print-capable device at the CARRIER's own location because
    /// the printed clone materialises at the printer, so a vessel anywhere
    /// else would stall `unreachableDevice` on its first evaluation. Launching
    /// a run that cannot possibly proceed is worse than idling: it burns the
    /// operator's attention on a stall the brain created.
    ///
    /// `isBusy` is the shared fleet predicate (`Device.isBusy`), not a
    /// bespoke status list: a vessel mid-travel belongs to no directive, so
    /// reservation cannot see it, but it is just as unavailable.
    ///
    /// `min(by:)` on the code, matching `RelayRun.hub(near:)`: dictionary
    /// iteration order is not guaranteed, and a stateless brain that re-ranks
    /// every tick must pick the SAME carrier every tick or its own decisions
    /// stop being reproducible.
    static func freeCarrier(
        at hub: String, devices: [String: Device], reserved: Set<String>
    ) -> Device? {
        devices.values
            .filter {
                $0.deviceType == carrierDeviceType
                    && $0.location == hub
                    && !$0.isBusy
                    && !reserved.contains($0.deviceCode)
            }
            .min { $0.deviceCode < $1.deviceCode }
    }

    // MARK: - The rationale

    /// Why this hop, in terms an operator can check against the map.
    ///
    /// A GRAPH FACT, never a scalar — "meshing VEGA — 3,200 units, 1 hop", not
    /// "score 0.82". `Goal.rationale` is read by a human (it is the why-view's
    /// headline and the launch log line), and the whole point of
    /// `GrowRanking`'s field-by-field key is that a choice stays explainable;
    /// collapsing it back into a number here would throw that away.
    ///
    /// The served-systems clause names where the VALUE is when it is not at
    /// the hop itself. Without it a two-hop grow reads as "meshing POLARISUM"
    /// — a hop toward nothing, at a system with no value of its own.
    static func rationale(for candidate: GrowCandidate) -> String {
        let hops = "\(candidate.relaysRemaining) hop\(candidate.relaysRemaining == 1 ? "" : "s")"
        let beyond = candidate.servedTargets.filter { $0 != candidate.firstHop }
        let served = beyond.isEmpty ? "" : " at \(list(beyond))"
        return "meshing \(candidate.firstHop) — \(magnitude(of: candidate))\(served), \(hops)"
    }

    /// The winning tier's magnitude in ITS OWN units — belts as belts, events
    /// as events, salvage as units. `GrowRanking.magnitude(at:over:)` defines
    /// each of these; rendering a belt count as "units" would be a fact the
    /// operator could not check.
    private static func magnitude(of candidate: GrowCandidate) -> String {
        switch candidate.bestTier {
        case .salvage: return counted(candidate.magnitudeAtTier, "unit")
        case .event: return counted(candidate.magnitudeAtTier, "live event")
        case .richBelt: return counted(candidate.magnitudeAtTier, "rich belt")
        case .moderateBelt: return counted(candidate.magnitudeAtTier, "moderate belt")
        case .sparseBelt: return counted(candidate.magnitudeAtTier, "sparse belt")
        }
    }

    /// `3200, "unit"` → `"3,200 units"`. Grouping is pinned to `en_US` rather
    /// than taken from the current locale: the surrounding sentence is a
    /// hard-coded English string, and a locale-dependent separator would make
    /// this line — and its test — read differently on different machines for
    /// no gain.
    private static func counted(_ value: Double, _ noun: String) -> String {
        // `Int(_: Double)` TRAPS on NaN, infinity, and anything past `Int.max`,
        // and this value is summed straight out of server-supplied assay
        // totals. A trap here would take the whole process down from inside a
        // 5-second background loop, over a log line — so a nonsense magnitude
        // degrades to a nonsense-looking number instead.
        let rounded = value.rounded()
        let whole = rounded.isFinite && rounded.magnitude < Double(Int.max) ? Int(rounded) : Int.max
        return "\(whole.formatted(.number.locale(Locale(identifier: "en_US")))) \(noun)\(whole == 1 ? "" : "s")"
    }

    /// Names the first two and counts the rest. A hop can serve a large group
    /// (one relay unlocking a whole pocket of the census), and an unbounded
    /// list in a log line and a UI headline helps nobody.
    private static func list(_ names: [String]) -> String {
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return "\(names[0]), \(names[1]) +\(names.count - 2) more"
    }

    // MARK: - The launch

    /// Create the Relay Run row. The brain's ONE enactment on the grow side.
    ///
    /// Everything downstream is already built: the supervisor spawns an
    /// executor for a `.running` row within a tick, and `RelayRun` takes it
    /// from `acquire` (print at the hub) to `settling` (the target system
    /// reads as meshed). So the fields below are the whole interface between
    /// the brain and the mission, and each is a decision:
    ///
    ///   - `sourceRelayCode: nil` — print a fresh relay. Non-nil is the
    ///     reclaim branch, which `acquire` deliberately does not implement yet
    ///     (Tasks 22–23); setting it here would park the run on `.wait`
    ///     forever.
    ///   - `fleetTag: nil` / `controllerCode: nil` — ownership is the carrier
    ///     and nothing else (ticket 05). The relay is held by transitive stow;
    ///     a committed-devices lease field was proposed and rejected.
    ///   - `roamCentre: nil` — a Relay Run is one-shot (`RelayRun.plan`
    ///     answers `.exhausted`); the brain launches a fresh directive per
    ///     target rather than asking one run to roam.
    ///   - `targets: [goal.target]` — the first HOP, not the value system. The
    ///     chain beyond it is re-derived next tick from the grown mesh, which
    ///     is what keeps the brain stateless.
    ///
    /// A failed write degrades to `.idle`, never to `.dispatch`: the decision
    /// reports what the tick DID, and claiming a launch that did not land
    /// would put a lie in the why-view and in the log.
    private func launch(
        goal: Goal, ranked: [GrowCandidate], carrier: String, origin: String,
        database: any DatabaseWriter
    ) async -> BrainDecision {
        @Dependency(\.uuid) var uuid

        let directive = Directive(
            id: uuid().uuidString,
            kind: .relayRun,
            status: .running,
            deviceCode: carrier,
            controllerCode: nil,
            roamCentre: nil,
            fleetTag: nil,
            sourceRelayCode: nil,
            targets: [goal.target],
            targetIndex: 0,
            step: RelayRun().firstStep,
            stepStartedAt: now,
            returnToOrigin: false,
            // Where the run set off from, for the row's own record. Read off
            // the same snapshot the carrier was chosen from rather than a
            // second database read, which would open a gap between the two.
            // `returnToOrigin` is false — a Relay Run chains onward rather
            // than coming home — so nothing steers off this; it exists so the
            // row reads honestly in the UI and the timeline.
            originDesignation: origin,
            attentionReason: nil,
            createdAt: now,
            updatedAt: now
        )
        do {
            try await database.write { db in
                try Directive.insert { directive }.execute(db)
            }
        } catch {
            logger.error("launch of \(directive.id, privacy: .public) failed: \(error)")
            return .idle(reason: "launch failed")
        }
        // `.notice`, unlike every other line in this file: a launch is rare,
        // irreversible in resource terms (it ends in a 370-unit print), and
        // the one brain event an operator reading the log after the fact needs
        // to find. The rationale rides along so the line explains itself
        // without a second lookup.
        logger.notice(
            """
            launched relay run \(directive.id, privacy: .public) on \(carrier, privacy: .public) \
            — \(goal.rationale, privacy: .public)
            """
        )
        return .dispatch(goal, ranked: ranked)
    }
}
