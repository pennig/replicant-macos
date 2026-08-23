//
//  OwnershipTests.swift
//  Replicould — DirectiveEngine
//
//  The lease derivation and the theatre rule, both now single implementations.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

/// `Ownership.resolve(...).reserved` over a fleet with no theatres — the shape
/// every ported `Brain.reservedDevices` case asserts.
private func reserved(_ directives: [Directive], _ devices: [String: Device]) -> Set<String> {
    Ownership.resolve(directives: directives, devices: devices, theatres: []).reserved
}

private func fleet(_ devices: [Device]) -> [String: Device] {
    Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { first, _ in first })
}

private func theatreFixture(
    _ depot: String, system: String, readiness: Theatre.Readiness = .operational
) -> Theatre {
    Theatre(depot: depot, system: system, origin: .derived, readiness: readiness, stock: 1_000)
}

// MARK: - Ported: the reserved set must not move

@Suite("Ownership — the ported reserved set")
struct OwnershipPortedReservationTests {
    /// Rules 1 and 2: the mission's carrier, and everything transitively stowed
    /// inside it — a one-level walk would leave the drone allocatable.
    @Test func reservesTheCarrierAndEverythingTransitivelyStowedInside() {
        let devices = fleet([
            deviceFixture(code: "V1", location: "SOL-3"),
            deviceFixture(code: "CTRL", type: "ami_controller", stowedIn: "V1"),
            deviceFixture(code: "DRONE", type: "survey_drone", stowedIn: "CTRL"),
            deviceFixture(code: "FREE", location: "SOL-3"),
            deviceFixture(code: "ELSEWHERE", type: "survey_drone", stowedIn: "OTHERVESSEL"),
        ])
        #expect(reserved([directiveFixture(id: "D1", deviceCode: "V1")], devices) == ["V1", "CTRL", "DRONE"])
    }

    /// The UPWARD closure: an owned device reserves the hull it rides in, and
    /// everything else that hull carries.
    @Test func anOwnedDeviceReservesTheHullItRidesInAndItsOtherCargo() {
        let devices = fleet([
            deviceFixture(code: "V", location: "SOL-3"),
            deviceFixture(code: "X", type: "mining_drone", stowedIn: "V"),
            deviceFixture(code: "SIBLING", type: "survey_drone", stowedIn: "V"),
            deviceFixture(code: "UNRELATED", location: "SOL-3"),
        ])
        #expect(reserved([directiveFixture(id: "D1", deviceCode: "X")], devices) == ["X", "V", "SIBLING"])
    }

    /// Adoption from BOTH ends — the drone's own column and the controller's
    /// blob list. A DEPLOYED drone is invisible to the stow walk and still owned.
    @Test func aReservedControllerReservesTheDronesItHasAdopted() {
        var controller = deviceFixture(code: "AMI1", type: "ami_controller", location: "SOL-3")
        controller.detail = .object(["controlled_devices": .array([.object(["device_code": .string("BLOB-ONLY")])])])
        var adopted = deviceFixture(code: "DEPLOYED", type: "survey_drone", location: "SOL-3-1")
        adopted.controllerDeviceCode = "AMI1"
        let devices = fleet([
            deviceFixture(code: "V1", location: "SOL-3"),
            controller,
            adopted,
            deviceFixture(code: "BLOB-ONLY", type: "survey_drone", location: "SOL-3-2"),
            deviceFixture(code: "SOMEONE-ELSES", type: "survey_drone", location: "SOL-3-3"),
        ])
        let directives = [directiveFixture(id: "D1", deviceCode: "V1", controllerCode: "AMI1")]
        #expect(reserved(directives, devices) == ["V1", "AMI1", "DEPLOYED", "BLOB-ONLY"])
    }

    /// Rules 3 and 4: the controller the mission drives, and every device
    /// wearing its fleet tag — a stowed wearer included.
    @Test func reservesTheControllerAndEveryDeviceWearingTheFleetTag() {
        let devices = fleet([
            deviceFixture(code: "V1", location: "SOL-3"),
            deviceFixture(code: "AMI1", type: "ami_controller", location: "SOL-3"),
            deviceFixture(code: "HAULER", type: "transport_drone", tags: ["auto:haul"]),
            deviceFixture(code: "STOWED-HAULER", type: "transport_drone", tags: ["auto:haul"], stowedIn: "SOMEWHERE"),
            deviceFixture(code: "UNTAGGED", type: "transport_drone", tags: ["auto:salvage"]),
        ])
        let directives = [
            directiveFixture(id: "D1", deviceCode: "V1", controllerCode: "AMI1", fleetTag: "auto:haul"),
        ]
        #expect(reserved(directives, devices) == ["V1", "AMI1", "HAULER", "STOWED-HAULER"])
    }

    /// Only an IN-FORCE row owns anything: `paused` and `needsAttention` still
    /// do, `completed`/`cancelled` release everything.
    @Test func onlyInForceDirectivesReserveAnything() {
        let devices = fleet(["PAUSED", "STALLED", "RUNNING", "DONE", "CANCELLED"].map {
            deviceFixture(code: $0, location: "SOL-3")
        })
        let directives = [
            directiveFixture(id: "P", status: .paused, deviceCode: "PAUSED"),
            directiveFixture(id: "S", status: .needsAttention, deviceCode: "STALLED"),
            directiveFixture(id: "R", status: .running, deviceCode: "RUNNING"),
            directiveFixture(id: "C", status: .completed, deviceCode: "DONE"),
            directiveFixture(id: "X", status: .cancelled, deviceCode: "CANCELLED"),
        ]
        #expect(reserved(directives, devices) == ["PAUSED", "STALLED", "RUNNING"])
    }

    /// A stow cycle — arbitrarily possible in rows synced from a server we do
    /// not control — must terminate rather than hang the suite.
    @Test func aCorruptStowCycleTerminates() {
        let devices = fleet([
            deviceFixture(code: "A", stowedIn: "B"),
            deviceFixture(code: "B", stowedIn: "A"),
        ])
        #expect(reserved([directiveFixture(id: "D1", deviceCode: "A")], devices) == ["A", "B"])
    }

    @Test func anEmptyLedgerReservesNothing() {
        #expect(reserved([], fleet([deviceFixture(code: "V1", location: "SOL-3")])).isEmpty)
    }

    @Test("a device attached to a leased carrier is reserved")
    func attachedDownward() {
        let devices = fleet([
            attachFixture("CARRIER"),
            attachFixture("COURIER", attachedTo: "CARRIER"),
            attachFixture("BEACON", attachedTo: "CARRIER"),
            attachFixture("LOOSE"),
        ])
        #expect(reserved([attachRun(on: "CARRIER")], devices) == ["CARRIER", "COURIER", "BEACON"])
    }

    @Test("leasing an attached device reserves the hull carrying it")
    func attachedUpward() {
        let devices = fleet([attachFixture("CARRIER"), attachFixture("COURIER", attachedTo: "CARRIER")])
        #expect(reserved([attachRun(on: "COURIER")], devices) == ["COURIER", "CARRIER"])
    }

    @Test("an attach edge naming a device the fleet lacks reserves nothing extra")
    func attachedDangling() {
        let devices = fleet([attachFixture("COURIER", attachedTo: "GHOST")])
        #expect(reserved([attachRun(on: "COURIER")], devices) == ["COURIER"])
    }

    /// The event convoy's freighter is a seed of its own: no stow or attach
    /// edge reaches it from the carrier.
    @Test("a live run's freighter is reserved beside its carrier, a finished one's is not")
    func freighterIsSeeded() {
        let devices = fleet([
            deviceFixture(code: "CARRIER-A", type: "surge_carrier"),
            deviceFixture(code: "FREIGHT-A", type: "cargo_freighter"),
        ])
        var live = directiveFixture(id: "d1", kind: .eventRun, deviceCode: "CARRIER-A")
        live.freighterCodes = ["FREIGHT-A"]
        var finished = live
        finished.status = .completed
        #expect(reserved([live], devices) == ["CARRIER-A", "FREIGHT-A"])
        #expect(reserved([finished], devices).isEmpty)
    }

    /// A nil `fleetTag` skips the sweep entirely; a stamped bare tag sweeps the
    /// sibling exactly as before.
    @Test("a nil fleetTag leaves bare-tagged fleet siblings unprotected")
    func nilFleetTagSweepsNothing() {
        let devices = fleet([
            deviceFixture(code: "V1", type: "heaven_vessel", tags: [SurveyRun.defaultFleetTag.string]),
            deviceFixture(code: "BOT1", type: "service_bot", tags: [SurveyRun.defaultFleetTag.string]),
        ])
        let nilTagged = directiveFixture(id: "NIL", kind: .surveyRun, deviceCode: "V1", fleetTag: nil)
        #expect(!reserved([nilTagged], devices).contains("BOT1"))

        let bareTagged = directiveFixture(
            id: "BARE", kind: .surveyRun, deviceCode: "V1", fleetTag: SurveyRun.defaultFleetTag.string
        )
        #expect(reserved([bareTagged], devices).contains("BOT1"))
    }

    /// Two per-theatre tags can never literally collide, so one theatre's run
    /// cannot sweep another's per-theatre-tagged carrier.
    @Test("a per-theatre tag cannot match another theatre's tag")
    func perTheatreTagsCannotCollide() {
        let devices = fleet([
            deviceFixture(code: "VA", location: "AINALRAM-1", tags: ["auto:salvage:AINALRAM-BELT-1"]),
            deviceFixture(code: "VB", location: "DENEBED-1", tags: ["auto:salvage:DENEBED-BELT-1"]),
        ])
        let live = directiveFixture(
            id: "LIVE", kind: .salvageRun, deviceCode: "VA",
            fleetTag: "auto:salvage:AINALRAM-BELT-1", theatreDepot: "AINALRAM-BELT-1"
        )
        #expect(!reserved([live], devices).contains("VB"))
    }

    /// Three fleets, three carriers: a cross-link would pull a second carrier
    /// into a directive's set and read exactly like an honest idle.
    @Test func eachDirectiveReservesOnlyItsOwnCarrier() {
        let devices = fleet(
            [Brain.carrierTag, Brain.salvageCarrierTag, Brain.surveyCarrierTag].enumerated().flatMap {
                index, tag -> [Device] in
                let suffix = index
                return [
                    deviceFixture(code: "CARRIER\(suffix)", location: "SOL-3", tags: [tag.string]),
                    deviceFixture(code: "CTRL\(suffix)", type: "ami_controller", stowedIn: "CARRIER\(suffix)"),
                ]
            }
        )
        let carriers = ["CARRIER0", "CARRIER1", "CARRIER2"]
        let directives = [
            directiveFixture(id: "R", kind: .relayRun, deviceCode: "CARRIER0"),
            directiveFixture(
                id: "S", kind: .salvageRun, deviceCode: "CARRIER1",
                fleetTag: Brain.salvageCarrierTag.string
            ),
            directiveFixture(id: "Q", kind: .surveyRun, deviceCode: "CARRIER2"),
        ]
        for directive in directives {
            let held = reserved([directive], devices)
            #expect(carriers.filter { held.contains($0) } == [directive.deviceCode])
        }
    }
}

// MARK: - Ported fixtures

private func attachFixture(_ code: String, attachedTo: String? = nil) -> Device {
    var device = deviceFixture(code: code, type: "surge_carrier", location: "HUB-1")
    device.attachedToDeviceCode = attachedTo
    return device
}

private func attachRun(on code: String) -> Directive {
    directiveFixture(id: "d1", kind: .eventRun, deviceCode: code)
}

// MARK: - New: where a lease binds

@Suite("Ownership — where a lease binds")
struct OwnershipTheatreBindingTests {
    private let depotA = "DEPOT-A"
    private let depotB = "DEPOT-B"
    private var theatreA: Theatre { theatreFixture(depotA, system: "A") }
    private var theatreB: Theatre { theatreFixture(depotB, system: "B") }

    private func resolve(_ directives: [Directive], _ devices: [Device]) -> Ownership {
        Ownership.resolve(
            directives: directives, devices: fleet(devices), theatres: [theatreA, theatreB]
        )
    }

    @Test func scopedTagLeaseBindsOnlyItsTheatre() {
        let row = directiveFixture(
            id: "A", kind: .haulRun, deviceCode: "CTRL-A",
            fleetTag: "auto:haul:\(depotA)", theatreDepot: depotA
        )
        let ownership = resolve([row], [deviceFixture(code: "H1", type: "transport_drone", tags: ["auto:haul:\(depotA)"])])
        #expect(ownership.reserved(in: theatreA).contains("H1"))
        #expect(!ownership.reserved(in: theatreB).contains("H1"))
        #expect(ownership.reserved.contains("H1"))
    }

    @Test func unscopedTagLeaseBindsEverywhereAndIsReported() {
        let row = directiveFixture(
            id: "A", kind: .haulRun, deviceCode: "CTRL-A", fleetTag: "auto:haul", theatreDepot: depotA
        )
        let ownership = resolve([row], [deviceFixture(code: "H1", type: "transport_drone", tags: ["auto:haul"])])
        #expect(ownership.reserved(in: theatreA).contains("H1"))
        #expect(ownership.reserved(in: theatreB).contains("H1"))
        #expect(ownership.accountWideLeases == [row])
    }

    @Test func deviceCodeLeaseBindsEverywhere() {
        let row = directiveFixture(id: "A", deviceCode: "V1", theatreDepot: depotA)
        let ownership = resolve([row], [deviceFixture(code: "V1", location: "A-1")])
        #expect(ownership.reserved(in: theatreA).contains("V1"))
        #expect(ownership.reserved(in: theatreB).contains("V1"))
        #expect(ownership.holder(of: "V1")?.via == .deviceCode)
        #expect(ownership.holder(of: "V1")?.theatreDepot == depotA)
    }

    @Test func stowClosureFollowsTheCarrier() {
        let row = directiveFixture(id: "A", deviceCode: "V1", theatreDepot: depotA)
        let ownership = resolve(
            [row],
            [
                deviceFixture(code: "V1", location: "A-1"),
                deviceFixture(code: "D1", type: "survey_drone", stowedIn: "V1"),
            ]
        )
        #expect(ownership.holder(of: "D1")?.via == .stow)
        #expect(ownership.holder(of: "D1")?.directiveID == "A")
        #expect(ownership.reserved(in: theatreB).contains("D1"))
    }

    /// A scoped lease on an UNSTAMPED row still places itself when its tag
    /// names a recognised depot — the only thing `theatres` is read for.
    @Test func anUnstampedScopedLeaseIsPlacedByItsTag() {
        let row = directiveFixture(
            id: "A", kind: .haulRun, deviceCode: "CTRL-A", fleetTag: "auto:haul:\(depotA)"
        )
        let ownership = resolve([row], [deviceFixture(code: "H1", type: "transport_drone", tags: ["auto:haul:\(depotA)"])])
        #expect(ownership.reserved(in: theatreA).contains("H1"))
        #expect(!ownership.reserved(in: theatreB).contains("H1"))
    }

    /// A mine ferry's tag names a BELT, so only the row's own stamp can place
    /// its sweep — and an unstamped one must bind everywhere rather than
    /// nowhere, since no theatre answers to a belt designation.
    @Test func aBeltScopedLeaseFallsBackToItsRowStamp() {
        let ferry = directiveFixture(
            id: "M", kind: .haulRun, deviceCode: "TC1",
            fleetTag: "auto:mine:A-BELT-1", theatreDepot: depotA
        )
        // MINER is the device the SWEEP reaches; TC1 is held by `deviceCode`,
        // which binds everywhere and so can prove nothing about placement.
        let devices = [
            deviceFixture(code: "TC1", type: "ami_transport_controller", location: "A-1"),
            deviceFixture(code: "MINER", type: "mining_drone", tags: ["auto:mine:A-BELT-1"]),
        ]
        #expect(resolve([ferry], devices).reserved(in: theatreA).contains("MINER"))
        #expect(!resolve([ferry], devices).reserved(in: theatreB).contains("MINER"))

        var unstamped = ferry
        unstamped.theatreDepot = nil
        #expect(resolve([unstamped], devices).reserved(in: theatreA).contains("MINER"))
        #expect(resolve([unstamped], devices).reserved(in: theatreB).contains("MINER"))
    }

    /// A pinned ferry row names one device as BOTH its carrier and its
    /// controller, and holds it both ways — the join the built-in row's lock
    /// reads is the controller one, and it must survive.
    @Test func aRowNamingOneDeviceTwiceHoldsItBothWays() {
        var pinned = directiveFixture(id: "H2", kind: .haulRun, deviceCode: "FERRY1")
        pinned.controllerCode = "FERRY1"
        let ownership = resolve([pinned], [deviceFixture(code: "FERRY1", type: "ami_transport_controller")])
        #expect(ownership.holders(of: "FERRY1").map(\.via) == [.deviceCode, .controllerCode])
        #expect(ownership.holder(of: "FERRY1")?.via == .deviceCode)
    }

    /// Lowest id first, so a device two rows hold names the same holder every
    /// tick — the property `Brain.holdingDirective` depends on.
    @Test func theLowestIdHolderWins() {
        let devices = [deviceFixture(code: "V1", location: "A-1")]
        let ownership = resolve(
            [
                directiveFixture(id: "ZZ", deviceCode: "V1"),
                directiveFixture(id: "AA", deviceCode: "V1"),
            ],
            devices
        )
        #expect(ownership.holder(of: "V1")?.directiveID == "AA")
        #expect(ownership.holders(of: "V1").map(\.directiveID) == ["AA", "ZZ"])
    }
}

// MARK: - The owning-status set

@Suite("Ownership — the owning statuses")
struct OwningStatusTests {
    /// The set every lease derivation scopes to. Frozen because three
    /// hand-copies of it existed until this ticket folded them into one.
    @Test func openCasesAreTheThreeOwningStatuses() {
        #expect(Set(DirectiveStatus.openCases) == [.running, .needsAttention, .paused])
        #expect(
            Set(DirectiveStatus.allCases).subtracting(DirectiveStatus.openCases)
                == Set(DirectiveStatus.finishedCases)
        )
    }
}

// MARK: - TheatreResolver

@Suite("TheatreResolver — the one theatre rule")
struct TheatreResolverRuleTests {
    private let resolver = TheatreResolver(
        theatres: [theatreFixture("DEPOT-A", system: "A"), theatreFixture("DEPOT-B", system: "B")],
        starPositions: [
            "A": Position(x: 0, y: 0, z: 0),
            "B": Position(x: 100, y: 0, z: 0),
        ],
        components: ["A": "A", "B": "B"]
    )

    @Test("a scoped tag outranks the location the vessel stands at")
    func scopedTagOutranksLocation() {
        let vessel = deviceFixture(code: "V1", location: "A-1", tags: ["auto:survey:DEPOT-B"])
        #expect(resolver.owningTheatre(of: vessel, goal: .survey)?.depot == "DEPOT-B")
        // The same vessel, asked without a goal, is placed by where it stands.
        #expect(resolver.owningTheatre(of: vessel, goal: nil)?.depot == "DEPOT-A")
    }

    @Test("an unscoped vessel is placed by where it stands")
    func unscopedVesselIsPlacedByLocation() {
        let vessel = deviceFixture(code: "V1", location: "A-1", tags: ["auto:survey"])
        #expect(resolver.owningTheatre(of: vessel, goal: .survey)?.depot == "DEPOT-A")
    }

    @Test("a stowed vessel resolves no theatre")
    func stowedVesselResolvesNothing() {
        let vessel = deviceFixture(code: "V1", tags: ["auto:survey"], stowedIn: "HULL")
        #expect(resolver.owningTheatre(of: vessel, goal: .survey) == nil)
        #expect(resolver.owningTheatre(of: vessel, goal: nil) == nil)
    }

    /// A tag naming a depot no theatre answers to falls through to location
    /// rather than resolving nothing.
    @Test func anUnknownDepotFallsThroughToLocation() {
        let vessel = deviceFixture(code: "V1", location: "A-1", tags: ["auto:survey:GONE-1"])
        #expect(resolver.owningTheatre(of: vessel, goal: .survey)?.depot == "DEPOT-A")
    }

    /// A tag naming a theatre that has gone `.claimed` falls through the same
    /// way — an unusable theatre must not strand the device that named it.
    @Test func aClaimedDepotFallsThroughToLocation() {
        let mixed = TheatreResolver(
            theatres: [
                theatreFixture("DEPOT-A", system: "A"),
                theatreFixture("DEPOT-B", system: "B", readiness: .claimed(missing: [.noStock])),
            ],
            starPositions: ["A": Position(x: 0, y: 0, z: 0), "B": Position(x: 100, y: 0, z: 0)],
            components: ["A": "A", "B": "B"]
        )
        let vessel = deviceFixture(code: "V1", location: "A-1", tags: ["auto:survey:DEPOT-B"])
        #expect(mixed.owningTheatre(of: vessel, goal: .survey)?.depot == "DEPOT-A")
    }

    @Test("servicing filters by mesh component; nearest does not")
    func servicingAndNearestDiffer() {
        let stranded = TheatreResolver(
            theatres: [theatreFixture("DEPOT-A", system: "A")],
            starPositions: ["A": Position(x: 0, y: 0, z: 0), "C": Position(x: 5, y: 0, z: 0)],
            components: ["A": "A"]
        )
        #expect(stranded.theatre(servicing: "C") == nil)
        #expect(stranded.theatre(nearest: "C")?.depot == "DEPOT-A")
        #expect(stranded.owningTheatre(ofSystem: "C")?.depot == "DEPOT-A")
    }
}

// MARK: - The payload lease

@Suite("Ownership — the payload lease")
struct OwnershipPayloadTests {
    private func plateAndPayload() -> [String: Device] {
        fleet([
            deviceFixture(code: "PLATE1", type: "surge_plate", location: "SOL-3", tags: ["fetch"]),
            deviceFixture(code: "PAYLOAD1", type: "autofactory", location: "VEGA-2"),
            deviceFixture(code: "OTHER", type: "autofactory", location: "VEGA-2"),
        ])
    }

    private func fetchRun(payload: String?) -> Directive {
        var run = directiveFixture(id: "D1", kind: .fetchRun, deviceCode: "PLATE1")
        run.payloadCode = payload
        return run
    }

    /// Leased from launch. Before the attach lands nothing drags the payload
    /// in, so the seed is all that stands between it and a re-tasking.
    @Test func aFetchRunReservesItsPayloadBeforeAnythingIsAttached() {
        #expect(reserved([fetchRun(payload: "PAYLOAD1")], plateAndPayload()) == ["PLATE1", "PAYLOAD1"])
    }

    /// Cleared at detach, and the lease must end with it — otherwise a device
    /// standing finished at its destination is invisible for the flight home.
    @Test func clearingThePayloadCodeReleasesTheDevice() {
        #expect(reserved([fetchRun(payload: nil)], plateAndPayload()) == ["PLATE1"])
    }

    /// The join is named, so "why is this held?" has an answer.
    @Test func thePayloadsHolderNamesThePayloadJoin() {
        let ownership = Ownership.resolve(
            directives: [fetchRun(payload: "PAYLOAD1")], devices: plateAndPayload(), theatres: []
        )
        #expect(ownership.holder(of: "PAYLOAD1")?.via == .payload)
    }
}
