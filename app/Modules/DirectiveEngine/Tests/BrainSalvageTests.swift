//
//  BrainSalvageTests.swift
//  Replicould — DirectiveEngine
//
//  `Brain.salvageReadiness` as a pure function table: every gate names why it
//  declined, an unstaged fleet idles rather than manufacturing a stall, and
//  unmeshed salvage is not this goal's to reach.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

private let salvageFixtureNow = Date(timeIntervalSince1970: 5_000)

/// A device for the readiness fixtures. `directives:` feeds
/// `available_directives`, which is what `AMIFleet.stowed(offering:)` reads.
private func salvageDevice(
    _ code: String,
    type: String,
    tags: [String] = [],
    location: String? = nil,
    stowedIn: String? = nil,
    controllerDeviceCode: String? = nil,
    directives: [String] = []
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: "idle",
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controllerDeviceCode,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: fixtureFeatures(for: type), tags: tags,
        detail: .object(detail),
        updatedAt: salvageFixtureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// A fully staged salvage vessel: tagged, a mining controller stowed aboard
/// offering `gather_salvage`, and one drone that controller has adopted.
/// `location` is what `Brain.owningTheatre` resolves the carrier through.
private func salvageStagedFleet(
    carrier: String = "V1", controller: String = "AMI1", drone: String = "DRONE1",
    location: String? = "AINALRAM-1", tags: [String] = [Brain.salvageCarrierTag.string]
) -> [Device] {
    [
        salvageDevice(carrier, type: "heaven_vessel", tags: tags, location: location),
        salvageDevice(
            controller, type: "ami_mining_controller", stowedIn: carrier, directives: ["gather_salvage"]
        ),
        salvageDevice(drone, type: "mining_drone", stowedIn: carrier, controllerDeviceCode: controller),
    ]
}

/// Two independent theatres in separate mesh components, each carrying the
/// given fleet's devices at its own system. Component separation makes
/// `owningTheatre` resolve each fleet to its own theatre unambiguously.
private func twoTheatreSalvageView(
    ainalramFleet: [Device], denebedFleet: [Device],
    meshSystems: Set<String> = ["AINALRAM", "DENEBED"],
    salvageUnits: [String: Double] = [:]
) -> (view: WorldView, ainalram: Theatre, denebed: Theatre) {
    let ainalram = Theatre(
        depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived, readiness: .operational, stock: 0
    )
    let denebed = Theatre(
        depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned, readiness: .operational, stock: 0
    )
    let devices = ainalramFleet + denebedFleet
    let view = WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: ["AINALRAM": Position(x: 0, y: 0, z: 0), "DENEBED": Position(x: 100, y: 100, z: 100)],
        meshSystems: meshSystems,
        salvageUnits: salvageUnits,
        eventSystems: [],
        theatres: [ainalram, denebed],
        components: ["AINALRAM": "AINALRAM", "DENEBED": "DENEBED"],
        now: salvageFixtureNow
    )
    return (view, ainalram, denebed)
}

/// The single-theatre fixtures' theatre — depot `AINALRAM-BELT-1`, matching
/// `salvageView(depot:)`'s default single-theatre setup.
private let ainalramTheatre = Theatre(
    depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived, readiness: .operational, stock: 0
)

private func salvageView(
    devices: [Device],
    depot: String? = "AINALRAM-BELT-1",
    starPositions: [String: Position] = ["AINALRAM": Position(x: 0, y: 0, z: 0)],
    meshSystems: Set<String> = ["AINALRAM", "ALPAHARD"],
    salvageUnits: [String: Double] = ["ALPAHARD": 900]
) -> WorldView {
    let theatre = singleOperationalTheatre(depot: depot)
    return WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: starPositions,
        meshSystems: meshSystems,
        salvageUnits: salvageUnits,
        eventSystems: [],
        theatres: theatre.theatres,
        components: theatre.components,
        now: salvageFixtureNow
    )
}

@Suite("Brain — the salvage readiness verdict")
struct BrainSalvageReadinessTests {
    @Test("a tagged, staged fleet with meshed salvage in reach is ready to launch")
    func readyToLaunch() {
        let view = salvageView(devices: salvageStagedFleet())
        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: ainalramTheatre)
                == .launch(carrier: "V1", roamCentre: "AINALRAM")
        )
    }

    /// The carrier gate is capability, not type: a staged `racing_vessel`
    /// wearing the fleet tag must be exactly as flyable as a HEAVEN vessel.
    @Test("a tagged, staged racing vessel is a salvage carrier")
    func racingVesselIsASalvageCarrier() {
        let view = salvageView(devices: [
            salvageDevice("V1", type: "racing_vessel", tags: [Brain.salvageCarrierTag.string], location: "AINALRAM-1"),
            salvageDevice(
                "AMI1", type: "ami_mining_controller", stowedIn: "V1", directives: ["gather_salvage"]
            ),
            salvageDevice("DRONE1", type: "mining_drone", stowedIn: "V1", controllerDeviceCode: "AMI1"),
        ])
        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: ainalramTheatre)
                == .launch(carrier: "V1", roamCentre: "AINALRAM")
        )
    }

    /// A tag on a hull that cannot carry the fleet is a misapplied opt-in —
    /// the idle reason names the device so the remedy reads as "move the tag".
    @Test("a tagged non-carrier is named in the idle reason")
    func taggedNonCarrierIsNamedInTheIdleReason() {
        let view = salvageView(devices: [
            salvageDevice("F1", type: "cargo_freighter", tags: [Brain.salvageCarrierTag.string])
        ])
        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: ainalramTheatre)
                == .idle(reason: "no \(Brain.salvageCarrierTag) vessel — F1 is tagged \(Brain.salvageCarrierTag) but is not a carrier hull")
        )
    }

    @Test("an untagged vessel is idle — there is no fallback to any free hull")
    func untaggedVesselIsIdle() {
        let view = salvageView(devices: [salvageDevice("V1", type: "heaven_vessel", tags: [])])
        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: ainalramTheatre)
                == .idle(reason: "no auto:salvage vessel")
        )
    }

    /// A stowed or mid-cruise vessel has `location: nil`, so `owningTheatre`
    /// resolves no theatre for it — but it IS tagged, and "no auto:salvage
    /// vessel" is false; the hull pool must stay fleet-wide, like `mistagged`.
    @Test("a tagged vessel with no placeable location is named, not reported untagged")
    func aTaggedStowedVesselIsNamedNotReportedUntagged() {
        let view = salvageView(devices: [
            salvageDevice("V1", type: "heaven_vessel", tags: [Brain.salvageCarrierTag.string], location: nil),
        ])
        guard case let .idle(reason) = Brain.salvageReadiness(view: view, directives: [], theatre: ainalramTheatre) else {
            Issue.record("expected idle")
            return
        }
        #expect(reason != "no \(Brain.salvageCarrierTag) vessel")
        #expect(reason.contains("V1"))
    }

    @Test("a carrier another kind of run already holds is idle, not contended for")
    func aReservedCarrierIsIdle() {
        let view = salvageView(devices: salvageStagedFleet())
        let holder = directiveFixture(id: "R1", kind: .relayRun, deviceCode: "V1")
        #expect(
            Brain.salvageReadiness(view: view, directives: [holder], theatre: ainalramTheatre)
                == .idle(reason: "no auto:salvage vessel")
        )
    }

    /// A theatre's own live run holding its bare-tagged sibling is nothing to
    /// re-tag for — the migration note must fire only for a CROSS-theatre
    /// hold, never one entirely inside the same theatre.
    @Test("a bare-tagged sibling held by this theatre's own live run gets no re-tag note")
    func sameTheatreHoldGetsNoUnmigratedNote() {
        let devices = [
            salvageDevice("VA", type: "heaven_vessel", tags: [Brain.salvageCarrierTag.string], location: "AINALRAM-1"),
            salvageDevice("VA2", type: "heaven_vessel", tags: [Brain.salvageCarrierTag.string], location: "AINALRAM-1"),
        ]
        let view = salvageView(devices: devices)
        let live = directiveFixture(
            id: "LIVE", kind: .salvageRun, deviceCode: "VA",
            fleetTag: Brain.salvageCarrierTag.string, theatreDepot: ainalramTheatre.depot
        )
        guard case let .idle(reason) = Brain.salvageReadiness(view: view, directives: [live], theatre: ainalramTheatre)
        else {
            Issue.record("expected idle — both bare-tagged carriers are reserved")
            return
        }
        #expect(!reason.contains("re-tag"))
    }

    @Test("a tagged carrier with no mining controller aboard is idle, never a stall")
    func noControllerIsIdle() {
        let view = salvageView(
            devices: [salvageDevice("V1", type: "heaven_vessel", tags: [Brain.salvageCarrierTag.string], location: "AINALRAM-1")]
        )
        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: ainalramTheatre)
                == .idle(reason: "V1 has no mining controller aboard")
        )
    }

    @Test("a controller with no adopted drone aboard is idle and names both codes")
    func noDroneIsIdle() {
        let view = salvageView(devices: [
            salvageDevice("V1", type: "heaven_vessel", tags: [Brain.salvageCarrierTag.string], location: "AINALRAM-1"),
            salvageDevice(
                "AMI1", type: "ami_mining_controller", stowedIn: "V1", directives: ["gather_salvage"]
            ),
        ])
        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: ainalramTheatre)
                == .idle(reason: "V1's controller AMI1 has adopted no drone aboard")
        )
    }

    /// `salvageReadiness` takes an arbitrary `Theatre` — one whose `system`
    /// disagrees with its own `depot`'s real system still resolves a carrier
    /// (matched on depot), so this seam can still reach the census guard.
    @Test("a roam centre the census does not know idles, naming it")
    func unknownRoamCentreIdles() {
        let view = salvageView(devices: salvageStagedFleet())
        let mismatchedTheatre = Theatre(
            depot: "AINALRAM-BELT-1", system: "GHOST", origin: .derived, readiness: .operational, stock: 0
        )
        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: mismatchedTheatre)
                == .idle(reason: "roam centre GHOST is not in the census")
        )
    }

    /// The coupling this design accepts: salvage waits on `tendMesh` rather
    /// than planting its own relay, and the idle must SAY so rather than
    /// presenting the wait as an absence of value.
    @Test("rich salvage in an unmeshed system is idle, named as a mesh wait")
    func unmeshedSalvageIsIdle() {
        let view = salvageView(
            devices: salvageStagedFleet(),
            meshSystems: ["AINALRAM"],
            salvageUnits: ["FARAWAY": 9_000]
        )
        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: ainalramTheatre)
                == .idle(reason: "no meshed salvage system with units left")
        )
    }

    @Test("a meshed system whose salvage is spent is idle")
    func depletedSalvageIsIdle() {
        let view = salvageView(devices: salvageStagedFleet(), salvageUnits: ["ALPAHARD": 0])
        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: ainalramTheatre)
                == .idle(reason: "no meshed salvage system with units left")
        )
    }

    @Test("the lowest-coded tagged vessel wins, so a tick is reproducible")
    func theLowestCodedCarrierWins() {
        var devices = salvageStagedFleet(carrier: "V1")
        devices.append(
            salvageDevice("A0", type: "heaven_vessel", tags: [Brain.salvageCarrierTag.string], location: "AINALRAM-2")
        )
        // `A0` sorts first but is unstaged, so the verdict names ITS blocker —
        // proving the carrier is chosen before staging is judged.
        let view = salvageView(devices: devices)
        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: ainalramTheatre)
                == .idle(reason: "A0 has no mining controller aboard")
        )
    }

    /// A theatre with no carrier of its own idles, and must not call
    /// AINALRAM's tagged, staged carrier untagged just because DENEBED
    /// can't see it.
    @Test("a theatre with no carrier of its own idles without consuming the other theatre's carrier")
    func theatreWithNoOwnCarrierIdlesWithoutConsumingTheOther() {
        let (view, ainalram, denebed) = twoTheatreSalvageView(
            ainalramFleet: salvageStagedFleet(carrier: "VA", location: "AINALRAM-1"),
            denebedFleet: [],
            salvageUnits: ["AINALRAM": 500]
        )

        guard case let .idle(reason) = Brain.salvageReadiness(view: view, directives: [], theatre: denebed) else {
            Issue.record("expected DENEBED to idle — it owns no carrier")
            return
        }
        #expect(reason == "no \(Brain.salvageCarrierTag) vessel")
        #expect(!reason.contains("VA"))
        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: ainalram)
                == .launch(carrier: "VA", roamCentre: "AINALRAM")
        )
    }

    /// The mistagged clause stays fleet-wide even where carrier selection is
    /// theatre-scoped — a stowed device has no location, so `owningTheatre`
    /// can't place it in ANY theatre's pool, AINALRAM's included.
    @Test("a location-less mistagged device is still named in a multi-theatre world")
    func locationlessMistaggedDeviceIsStillNamedAcrossTheatres() {
        let (view, ainalram, _) = twoTheatreSalvageView(
            ainalramFleet: [salvageDevice("F1", type: "cargo_freighter", tags: [Brain.salvageCarrierTag.string])],
            denebedFleet: []
        )

        guard case let .idle(reason) = Brain.salvageReadiness(view: view, directives: [], theatre: ainalram) else {
            Issue.record("expected idle")
            return
        }
        #expect(reason.contains("F1 is tagged \(Brain.salvageCarrierTag) but is not a carrier hull"))
    }

    // MARK: - Per-theatre fleet tags

    /// Two theatres, each with its own PER-THEATRE-tagged (already migrated)
    /// carrier, each launch on their own — never the bare tag.
    @Test("two theatres each with their own per-theatre-tagged carrier each launch their own")
    func twoTheatresEachWithAPerTheatreTaggedCarrierEachLaunchTheirOwn() {
        let (view, ainalram, denebed) = twoTheatreSalvageView(
            ainalramFleet: salvageStagedFleet(
                carrier: "VA", location: "AINALRAM-1", tags: ["auto:salvage:AINALRAM-BELT-1"]
            ),
            denebedFleet: salvageStagedFleet(
                carrier: "VB", controller: "AMIB", drone: "DRONEB", location: "DENEBED-1", tags: ["auto:salvage:DENEBED-BELT-1"]
            ),
            salvageUnits: ["AINALRAM": 900, "DENEBED": 900]
        )

        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: ainalram)
                == .launch(carrier: "VA", roamCentre: "AINALRAM")
        )
        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: denebed)
                == .launch(carrier: "VB", roamCentre: "DENEBED")
        )
    }

    /// Re-tagging is the operator's handover: a vessel standing in AINALRAM's
    /// own system, a long way from DENEBED's, is DENEBED's the moment it
    /// wears DENEBED's tag.
    @Test("a vessel re-tagged for another theatre changes hands without moving")
    func anExplicitTagMovesAVesselBetweenTheatres() {
        let (view, ainalram, denebed) = twoTheatreSalvageView(
            ainalramFleet: salvageStagedFleet(
                carrier: "VA", location: "AINALRAM-1",
                tags: ["auto:salvage:DENEBED-BELT-1"]
            ),
            denebedFleet: [],
            salvageUnits: ["AINALRAM": 900, "DENEBED": 900]
        )

        #expect(
            Brain.salvageReadiness(view: view, directives: [], theatre: denebed)
                == .launch(carrier: "VA", roamCentre: "DENEBED")
        )
        guard case let .idle(reason) = Brain.salvageReadiness(view: view, directives: [], theatre: ainalram) else {
            Issue.record("expected AINALRAM to idle — VA now wears DENEBED's tag")
            return
        }
        #expect(!reason.contains("VA"))
    }

    /// The tag says whose it is, but a theatre spends only what the census can
    /// place: launching on a vessel that is nowhere parks the theatre's slot on
    /// the first fault. The owning theatre names it; the other one must not.
    @Test("a scoped-tagged vessel the census cannot place is named, never launched on")
    func aTaggedUnplaceableVesselIsNamedNotLaunchedOn() {
        let (view, ainalram, denebed) = twoTheatreSalvageView(
            ainalramFleet: salvageStagedFleet(
                carrier: "VA", location: nil, tags: ["auto:salvage:DENEBED-BELT-1"]
            ),
            denebedFleet: [],
            salvageUnits: ["AINALRAM": 900, "DENEBED": 900]
        )

        guard case let .idle(denebedReason) = Brain.salvageReadiness(view: view, directives: [], theatre: denebed) else {
            Issue.record("expected DENEBED to idle — VA is its own, but nowhere")
            return
        }
        #expect(denebedReason == "VA is tagged \(Brain.salvageCarrierTag) but not placeable — stowed or mid-cruise")
        guard case let .idle(ainalramReason) = Brain.salvageReadiness(view: view, directives: [], theatre: ainalram) else {
            Issue.record("expected AINALRAM to idle — VA wears DENEBED's tag")
            return
        }
        #expect(!ainalramReason.contains("VA"))
    }

    /// A carrier tagged for AINALRAM alone is never a candidate for DENEBED.
    @Test("a device tagged for one theatre is not selected for another")
    func aDeviceTaggedForOneTheatreIsNotSelectedForAnother() {
        let (view, _, denebed) = twoTheatreSalvageView(
            ainalramFleet: salvageStagedFleet(
                carrier: "VA", location: "AINALRAM-1", tags: ["auto:salvage:AINALRAM-BELT-1"]
            ),
            denebedFleet: []
        )

        guard case let .idle(reason) = Brain.salvageReadiness(view: view, directives: [], theatre: denebed) else {
            Issue.record("expected DENEBED to idle — VA wears only AINALRAM's tag")
            return
        }
        #expect(!reason.contains("VA"))
    }

    /// Candidate SCOPING only — the two tags differ by construction and can
    /// never literally collide, so this proves nothing about `reservedDevices`
    /// itself; see the literal-collision tests below for that.
    @Test("a live directive naming a different theatre's tag does not disturb this theatre's own verdict")
    func aLiveDirectiveNamingAnotherTheatresTagDoesNotDisturbThisOne() {
        let (view, ainalram, denebed) = twoTheatreSalvageView(
            ainalramFleet: salvageStagedFleet(
                carrier: "VA", location: "AINALRAM-1", tags: ["auto:salvage:AINALRAM-BELT-1"]
            ),
            denebedFleet: salvageStagedFleet(
                carrier: "VB", controller: "AMIB", drone: "DRONEB", location: "DENEBED-1", tags: ["auto:salvage:DENEBED-BELT-1"]
            ),
            salvageUnits: ["AINALRAM": 900, "DENEBED": 900]
        )
        let live = directiveFixture(
            id: "LIVE", kind: .salvageRun, deviceCode: "VA",
            fleetTag: "auto:salvage:\(ainalram.depot)", theatreDepot: ainalram.depot
        )

        #expect(
            Brain.salvageReadiness(view: view, directives: [live], theatre: denebed)
                == .launch(carrier: "VB", roamCentre: "DENEBED")
        )
    }

    // MARK: - Literal tag-sweep collision (the actual `reservedDevices` mechanism)

    /// Two per-theatre tags can never literally collide, so a FRESH launch
    /// in one theatre cannot reserve another's per-theatre-tagged carrier —
    /// the property `reservedDevices`'s sweep actually guarantees.
    @Test("a freshly-stamped per-theatre tag cannot literally match another theatre's tag")
    func freshPerTheatreTagsCannotCollide() {
        let (view, ainalram, denebed) = twoTheatreSalvageView(
            ainalramFleet: salvageStagedFleet(
                carrier: "VA", location: "AINALRAM-1", tags: ["auto:salvage:AINALRAM-BELT-1"]
            ),
            denebedFleet: salvageStagedFleet(
                carrier: "VB", controller: "AMIB", drone: "DRONEB", location: "DENEBED-1", tags: ["auto:salvage:DENEBED-BELT-1"]
            ),
            salvageUnits: ["AINALRAM": 900, "DENEBED": 900]
        )
        let live = directiveFixture(
            id: "LIVE", kind: .salvageRun, deviceCode: "VA",
            fleetTag: SalvageRun.fleetTag(forTheatre: ainalram.depot).string, theatreDepot: ainalram.depot
        )
        let reserved = Brain.reservedDevices(directives: [live], devices: view.devices)
        #expect(!reserved.contains("VB"), "the literal tags differ by depot, so the sweep cannot reach VB")
    }

    /// A directive still carrying the LITERAL bare tag still sweeps another
    /// theatre's still-bare carrier — `reservedDevices` protects only the tag
    /// a FRESH launch stamps, permanently, since this run never relaunches.
    @Test("a legacy bare-tagged live directive still reserves another theatre's still-bare carrier")
    func legacyBareTagStillCollidesAcrossTheatres() {
        let (view, ainalram, denebed) = twoTheatreSalvageView(
            ainalramFleet: salvageStagedFleet(carrier: "VA", location: "AINALRAM-1"),
            denebedFleet: salvageStagedFleet(
                carrier: "VB", controller: "AMIB", drone: "DRONEB", location: "DENEBED-1"
            ),
            salvageUnits: ["AINALRAM": 900, "DENEBED": 900]
        )
        let live = directiveFixture(
            id: "LIVE", kind: .salvageRun, deviceCode: "VA",
            fleetTag: SalvageRun.defaultFleetTag.string, theatreDepot: ainalram.depot
        )

        guard case let .idle(reason) = Brain.salvageReadiness(view: view, directives: [live], theatre: denebed) else {
            Issue.record("VB is expected to be swept by LIVE's literal bare-tag reservation")
            return
        }
        #expect(reason.contains("VB"))
    }
}

// MARK: - `Brain.salvageStatus` — the why-view's verdict

@Suite("Brain — the salvage status for the why-view")
struct BrainSalvageStatusTests {
    @Test("no operational theatre reports idle, naming that")
    func noOperationalTheatreReportsIdle() {
        let view = salvageView(devices: [], depot: nil)
        #expect(Brain.salvageStatus(directives: [], view: view) == .idle(reason: "no operational theatre"))
    }

    /// A live run in one theatre must not mask another theatre's own idle
    /// state.
    @Test("a live run in one theatre does not mask another theatre's idle state")
    func aLiveRunInOneTheatreDoesNotMaskAnother() {
        let (view, ainalram, denebed) = twoTheatreSalvageView(
            ainalramFleet: salvageStagedFleet(carrier: "V1", location: "AINALRAM-1"), denebedFleet: []
        )
        let live = directiveFixture(
            id: "LIVE", kind: .salvageRun, deviceCode: "V1", theatreDepot: ainalram.depot
        )

        #expect(
            Brain.salvageStatus(directives: [live], view: view, theatre: ainalram)
                == .launched(vessel: "V1", focus: nil, status: .running)
        )
        guard case .idle = Brain.salvageStatus(directives: [live], view: view, theatre: denebed) else {
            Issue.record("DENEBED's own idle state must not read as AINALRAM's launch")
            return
        }
    }
}

// MARK: - ensureSalvage

private let salvageEnsureNow = Date(timeIntervalSince1970: 9_000)
private let salvageEnsureCarrier = "SALV1"
private let salvageEnsureHubSystem = "SOL"

private func seedSalvageEnsureDevice(
    _ db: Database, code: String, type: String, tags: [String] = [], location: String? = nil,
    stowedIn: String? = nil, controllerDeviceCode: String? = nil, directives: [String] = []
) throws {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    try Device.insert {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R1", status: "idle",
            location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: stowedIn, controllerDeviceCode: controllerDeviceCode,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: fixtureFeatures(for: type), tags: tags,
            detail: .object(detail),
            updatedAt: salvageEnsureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }.execute(db)
}

/// A fully staged, tagged salvage fleet standing at `location` — what
/// `owningTheatre` resolves the carrier through.
private func seedSalvageEnsureFleet(
    _ db: Database, carrier: String = salvageEnsureCarrier, location: String = growHubLocation
) throws {
    try seedSalvageEnsureDevice(
        db, code: carrier, type: "heaven_vessel", tags: [Brain.salvageCarrierTag.string], location: location
    )
    try seedSalvageEnsureDevice(
        db, code: "AMI1", type: "ami_mining_controller", stowedIn: carrier, directives: ["gather_salvage"]
    )
    try seedSalvageEnsureDevice(
        db, code: "DRONE1", type: "mining_drone", stowedIn: carrier, controllerDeviceCode: "AMI1"
    )
}

/// `seedGrowableWorld`'s meshed hub with no tendMesh carrier and no unmeshed
/// salvage, plus salvage assayed IN the meshed hub system and a staged fleet.
private func seedSalvageEnsureReadyWorld(_ db: Database) throws {
    try seedGrowableWorld(db, carriers: [], salvage: [:])
    try seedSalvageAssay(db, id: "SITE-SOL", system: salvageEnsureHubSystem, totals: ["metal": 900])
    try seedSalvageEnsureFleet(db)
}

private func salvageEnsureDirectives(_ database: any DatabaseWriter) async throws -> [Directive] {
    try await database.read { db in try Directive.all.fetchAll(db) }
}

private func salvageEnsureTick(_ database: any DatabaseWriter) async {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(salvageEnsureNow)
        $0.uuid = .incrementing
    } operation: {
        _ = await Brain(now: salvageEnsureNow).evaluateOnce()
    }
}

private let secondTheatreSystem = "VEGA"
private let secondTheatreHubLocation = "VEGA-3"
private let secondTheatreCarrier = "SALV2"

/// A second, independently meshed hub far enough from `SOL` to form its own
/// mesh component — `seedGrowableWorld`'s shape, reproduced at `VEGA` rather
/// than shared with it, so it derives its own operational theatre.
private func seedSecondTheatre(_ db: Database) throws {
    try seedRelay(db, code: "REL2", location: secondTheatreSystem)
    try seedStar(db, designation: secondTheatreSystem, x: 300, y: 300, z: 300)
    try seedPrintHub(db, code: "HUB2", location: secondTheatreHubLocation)
    try seedHubStockpile(db, location: secondTheatreHubLocation, resources: BrainCeiling.aggregateSpendFloor * 2)
}

@Suite("Brain — ensureSalvage")
struct BrainEnsureSalvageTests {
    @Test func readyFleetWithNoLiveSalvageInsertsExactlyOneRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedSalvageEnsureReadyWorld(db) }

        await salvageEnsureTick(database)

        let directives = try await salvageEnsureDirectives(database)
        let salvage = try #require(directives.first)
        #expect(directives.count == 1)
        #expect(salvage.kind == .salvageRun)
        #expect(salvage.deviceCode == salvageEnsureCarrier)
        #expect(salvage.fleetTag == SalvageRun.fleetTag(forTheatre: growHubLocation).string)
        #expect(salvage.roamCentre == salvageEnsureHubSystem)
        #expect(salvage.step == SalvageRun().firstStep)
        #expect(salvage.status == .running)
        // Claimed at preflight, never eager-written — an eager one goes stale.
        #expect(salvage.controllerCode == nil)
        #expect(salvage.returnToOrigin == false)
    }

    /// An idle theatre must `continue`, not `return`. Depot designations sort
    /// `SOL-3` before `VEGA-3`, so SOL (no salvage fleet) is visited first
    /// and must not suppress VEGA's (fully staged) launch.
    @Test func anIdleTheatreDoesNotSuppressAReadyOnesLaunch() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [], salvage: [:])
            try seedSecondTheatre(db)
            try seedSalvageAssay(db, id: "SITE-VEGA", system: secondTheatreSystem, totals: ["metal": 900])
            try seedSalvageEnsureFleet(db, carrier: secondTheatreCarrier, location: secondTheatreHubLocation)
        }

        await salvageEnsureTick(database)

        let directives = try await salvageEnsureDirectives(database)
        let salvage = try #require(directives.first)
        #expect(directives.count == 1)
        #expect(salvage.kind == .salvageRun)
        #expect(salvage.deviceCode == secondTheatreCarrier)
        #expect(salvage.roamCentre == secondTheatreSystem)
        #expect(salvage.theatreDepot == secondTheatreHubLocation)
    }

    @Test func aSecondTickWithTheLaunchedRowStillLiveInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedSalvageEnsureReadyWorld(db) }
        await salvageEnsureTick(database)
        let afterFirst = try await salvageEnsureDirectives(database)
        #expect(afterFirst.count == 1)

        await salvageEnsureTick(database)

        let afterSecond = try await salvageEnsureDirectives(database)
        #expect(afterSecond == afterFirst, "the row the first tick launched already owns the fleet")
    }

    /// A run the OPERATOR launched satisfies the goal exactly as one the brain
    /// launched does — membership is by kind, never provenance.
    @Test func anOperatorLaunchedRunIsAdoptedNotDuplicated() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSalvageEnsureReadyWorld(db)
            try seedDirective(
                db, id: "OPERATOR", kind: .salvageRun, status: .running,
                deviceCode: "OTHERVESSEL", fleetTag: SalvageRun.defaultFleetTag.string
            )
        }

        await salvageEnsureTick(database)

        let directives = try await salvageEnsureDirectives(database)
        #expect(directives.count == 1)
        #expect(directives.first?.id == "OPERATOR")
    }

    @Test(arguments: [DirectiveStatus.running, .needsAttention, .paused])
    func aLiveSalvageInAnyOwningStatusBlocksRelaunch(_ status: DirectiveStatus) async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSalvageEnsureReadyWorld(db)
            try seedDirective(
                db, id: "HELD", kind: .salvageRun, status: status,
                deviceCode: salvageEnsureCarrier, fleetTag: SalvageRun.defaultFleetTag.string
            )
        }

        await salvageEnsureTick(database)

        let directives = try await salvageEnsureDirectives(database)
        #expect(directives.count == 1)
        #expect(directives.first?.id == "HELD")
    }

    @Test(arguments: [DirectiveStatus.completed, .cancelled])
    func aFinishedSalvageDoesNotBlockAFreshRun(_ status: DirectiveStatus) async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSalvageEnsureReadyWorld(db)
            try seedDirective(
                db, id: "DONE", kind: .salvageRun, status: status,
                deviceCode: salvageEnsureCarrier, fleetTag: SalvageRun.defaultFleetTag.string
            )
        }

        await salvageEnsureTick(database)

        let directives = try await salvageEnsureDirectives(database)
        #expect(directives.count == 2)
        #expect(directives.contains { $0.id != "DONE" && $0.kind == .salvageRun })
    }

    /// The snapshot-level check cannot see a row written after the tick's own
    /// world read, so the guard INSIDE the write transaction is the only thing
    /// standing between two ticks and two rows. Driving `ensureOne` directly
    /// with a deliberately stale snapshot is the one way to reach it.
    @Test func theInTransactionRecheckIsWhatStopsTheSecondInsert() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedSalvageEnsureReadyWorld(db) }

        let stale = Brain.Snapshot(
            view: try await database.read { db in
                try WorldView.read(from: db, now: salvageEnsureNow)
            },
            directives: [],          // read BEFORE either insert, and never refreshed
            log: [:], hubFootprint: nil
        )
        let theatre = try #require(stale.view.theatres.first { $0.isOperational })
        // Each call names a DIFFERENT vessel. With one vessel the reservation
        // guard would refuse the second call and the liveness check would never
        // be reached — the two guards overlap, and only this separates them.
        let brain = Brain(now: salvageEnsureNow)
        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            for vessel in ["SALV1", "SALV2"] {
                await brain.ensureOne(.salvageRun, theatre: theatre, snapshot: stale, database: database) {
                    directiveFixture(
                        id: "ROW-\(vessel)", kind: .salvageRun,
                        deviceCode: vessel, fleetTag: nil, theatreDepot: theatre.depot
                    )
                }
            }
        }

        let rows = try await database.read { db in
            try Directive.where { $0.kind.eq(DirectiveKind.salvageRun) }.fetchAll(db)
        }
        #expect(rows.count == 1, "the second call must be refused inside the transaction")
        #expect(rows.first?.id == "ROW-SALV1")
    }

    /// Reaches the LIVENESS path rather than the reservation gate: the live row
    /// sits on another vessel and carries no fleet tag, so it reserves nothing
    /// the candidate carrier needs and `salvageReadiness` still says launch.
    @Test func aLiveUntaggedRunOnAnotherVesselStillBlocksBbyKind() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedSalvageEnsureReadyWorld(db)
            try seedDirective(
                db, id: "ELSEWHERE", kind: .salvageRun, status: .running,
                deviceCode: "UNRELATED", fleetTag: nil
            )
        }

        await salvageEnsureTick(database)

        let rows = try await salvageEnsureDirectives(database).filter { $0.kind == .salvageRun }
        #expect(rows.count == 1)
        #expect(rows.first?.id == "ELSEWHERE")
    }

    /// A vessel wearing two automation tags must not be committed twice in one
    /// tick. The survey launch lands first and the salvage launch must decline,
    /// even though the snapshot both read predates either row.
    @Test func aDoubleTaggedVesselIsCommittedOnlyOnce() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [], salvage: [:])
            try seedSalvageAssay(db, id: "SITE-SOL", system: salvageEnsureHubSystem, totals: ["metal": 900])
            // One hull, both opt-in tags, staged for both automations.
            try seedSalvageEnsureDevice(
                db, code: "BOTH", type: "heaven_vessel",
                tags: [Brain.salvageCarrierTag.string, Brain.surveyCarrierTag.string], location: growHubLocation
            )
            try seedSalvageEnsureDevice(
                db, code: "AMI1", type: "ami_mining_controller", stowedIn: "BOTH",
                directives: ["gather_salvage"]
            )
            try seedSalvageEnsureDevice(
                db, code: "DRONE1", type: "mining_drone", stowedIn: "BOTH", controllerDeviceCode: "AMI1"
            )
            try seedSalvageEnsureDevice(
                db, code: "SAMI", type: "ami_survey_controller", stowedIn: "BOTH",
                directives: ["survey_system"]
            )
            try seedSalvageEnsureDevice(
                db, code: "SDRONE", type: "survey_drone", stowedIn: "BOTH", controllerDeviceCode: "SAMI"
            )
        }

        await salvageEnsureTick(database)

        let owners = try await salvageEnsureDirectives(database).filter { $0.deviceCode == "BOTH" }
        #expect(owners.count == 1, "two directives owning one hull is a double commit")
    }

    @Test func anIdleVerdictInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        // The ready world minus the fleet: no tagged vessel, so no launch.
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [], salvage: [:])
            try seedSalvageAssay(db, id: "SITE-SOL", system: salvageEnsureHubSystem, totals: ["metal": 900])
        }

        await salvageEnsureTick(database)

        #expect(try await salvageEnsureDirectives(database).isEmpty)
    }
}

// MARK: - Reservation disjointness

/// One fleet: a tagged carrier with a controller and a drone stowed aboard.
private func taggedFleet(carrier: String, controller: String, drone: String, tag: FleetTag) -> [Device] {
    [
        salvageDevice(carrier, type: "heaven_vessel", tags: [tag.string]),
        salvageDevice(controller, type: "ami_mining_controller", tags: [tag.string], stowedIn: carrier),
        salvageDevice(drone, type: "mining_drone", tags: [tag.string], stowedIn: carrier, controllerDeviceCode: controller),
    ]
}

/// The three live automations each own a carrier. `reservedDevices` closes over
/// stow in BOTH directions and over adoption, so a cross-link would pull a
/// second carrier into a directive's set — and `salvageReadiness` would then
/// report "no auto:salvage vessel" while the vessel sat idle in front of it.
/// That failure reads exactly like the honest idle, so it is pinned here.
@Suite("Brain — the three carriers reserve disjointly")
struct BrainReservationDisjointnessTests {
    @Test func eachDirectiveReservesOnlyItsOwnCarrier() {
        let devices = (
            taggedFleet(carrier: "MESH1", controller: "MC", drone: "MD", tag: Brain.carrierTag)
                + taggedFleet(carrier: "SALV1", controller: "SC", drone: "SD", tag: Brain.salvageCarrierTag)
                + taggedFleet(carrier: "SURV1", controller: "QC", drone: "QD", tag: Brain.surveyCarrierTag)
        ).reduce(into: [String: Device]()) { $0[$1.deviceCode] = $1 }

        let carriers = ["MESH1", "SALV1", "SURV1"]
        let directives = [
            directiveFixture(id: "R", kind: .relayRun, deviceCode: "MESH1"),
            directiveFixture(
                id: "S", kind: .salvageRun, deviceCode: "SALV1", fleetTag: Brain.salvageCarrierTag.string
            ),
            directiveFixture(id: "Q", kind: .surveyRun, deviceCode: "SURV1"),
        ]

        for directive in directives {
            let reserved = Brain.reservedDevices(directives: [directive], devices: devices)
            #expect(
                carriers.filter { reserved.contains($0) } == [directive.deviceCode],
                "\(directive.id) reserved carriers beyond its own"
            )
        }
    }
}

// MARK: - The widened brain-managed stall set

/// A halted row of `kind` carrying `reason`, as `DirectiveExecutor.stall` leaves one.
private func stalledRow(
    id: String, kind: DirectiveKind, reason: DirectiveAttentionReason, step: String
) -> Directive {
    var directive = directiveFixture(id: id, kind: kind, status: .needsAttention, deviceCode: "V1")
    directive.attentionReason = reason
    directive.step = step
    return directive
}

@Suite("Brain — the stall set widens by kind")
struct BrainWidenedStallTests {
    @Test("a retryable salvage stall is retried on the first look")
    func aRetryableSalvageStallIsRetried() {
        let row = stalledRow(
            id: "S1", kind: .salvageRun, reason: .salvageBodyNotDepleted, step: "awaiting"
        )
        #expect(
            Brain.stallResponse(for: row, log: [], now: Date(timeIntervalSince1970: 10_000))
                == .retry(
                    directiveID: "S1", reason: .salvageBodyNotDepleted,
                    attempt: 1, lastAttemptAt: nil
                )
        )
    }

    @Test("a salvage stall that has spent its budget escalates")
    func anExhaustedSalvageBudgetEscalates() {
        let now = Date(timeIntervalSince1970: 100_000)
        let row = stalledRow(
            id: "S1", kind: .salvageRun, reason: .salvageBodyNotDepleted, step: "awaiting"
        )
        let spent = (0..<Brain.retryBudget).map { index in
            DirectiveLogEntry(
                id: "E\(index)", directiveID: "S1", deviceCode: nil, kind: .resolved,
                summary: "retry", step: "awaiting", operationID: nil, eventID: nil,
                occurredAt: now.addingTimeInterval(Double(-3_600 * (Brain.retryBudget - index)))
            )
        }
        #expect(
            Brain.stallResponse(for: row, log: spent, now: now)
                == .escalated(directiveID: "S1", reason: .salvageBodyNotDepleted)
        )
    }

    @Test("an escalate-classified salvage stall escalates on sight")
    func dronesNotRecoveredEscalatesImmediately() {
        let row = stalledRow(
            id: "S2", kind: .salvageRun, reason: .dronesNotRecovered, step: "verifying"
        )
        #expect(
            Brain.stallResponse(for: row, log: [], now: Date(timeIntervalSince1970: 0))
                == .escalated(directiveID: "S2", reason: .dronesNotRecovered)
        )
    }

    @Test("a haul stall is managed too")
    func haulStallsAreManaged() {
        let row = stalledRow(id: "H1", kind: .haulRun, reason: .commandRejected, step: "confirming")
        #expect(Brain.brainManagedStall(row) == .commandRejected)
    }

    /// Deliberately outside the set: a Survey Run's stalls stay the operator's,
    /// and a restock run's too.
    @Test(arguments: [DirectiveKind.surveyRun, .restockRun])
    func otherKindsStayTheOperators(_ kind: DirectiveKind) {
        let row = stalledRow(id: "Q1", kind: kind, reason: .commandRejected, step: "travelling")
        #expect(Brain.brainManagedStall(row) == nil)
        #expect(Brain.stallResponse(for: row, log: [], now: Date(timeIntervalSince1970: 0)) == nil)
    }

    @Test("a salvage row that is not halted is not a managed stall")
    func aRunningSalvageRowIsNotAStall() {
        let row = directiveFixture(id: "S3", kind: .salvageRun, status: .running, deviceCode: "V1")
        #expect(Brain.brainManagedStall(row) == nil)
    }
}

// MARK: - haulReadiness / ensureHaul

private func haulController(
    _ code: String, tags: [String], directives: [String] = ["ferry"], location: String? = nil
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    return Device(
        deviceCode: code, deviceType: "ami_transport_controller", replicantCode: "R1",
        status: "idle", location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [],
        tags: tags, detail: .object(detail),
        updatedAt: salvageEnsureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func haulView(devices: [Device], depot: String? = "SOL-3") -> WorldView {
    let theatre = singleOperationalTheatre(depot: depot)
    return WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: ["SOL": Position(x: 0, y: 0, z: 0)],
        meshSystems: ["SOL"], salvageUnits: [:], eventSystems: [],
        theatres: theatre.theatres, components: theatre.components, now: salvageEnsureNow
    )
}

/// The single-theatre fixtures' theatre — depot `SOL-3`, matching
/// `haulView(depot:)`'s default single-theatre setup.
private let solTheatre = Theatre(depot: "SOL-3", system: "SOL", origin: .derived, readiness: .operational, stock: 0)

/// Two independent theatres in separate mesh components, mirroring
/// `twoTheatreSalvageView` for haul controllers instead of salvage fleets.
private func twoTheatreHaulView(
    solControllers: [Device], vegaControllers: [Device]
) -> (view: WorldView, sol: Theatre, vega: Theatre) {
    let sol = Theatre(depot: "SOL-3", system: "SOL", origin: .derived, readiness: .operational, stock: 0)
    let vega = Theatre(depot: "VEGA-3", system: "VEGA", origin: .pinned, readiness: .operational, stock: 0)
    let devices = solControllers + vegaControllers
    let view = WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: ["SOL": Position(x: 0, y: 0, z: 0), "VEGA": Position(x: 300, y: 300, z: 300)],
        meshSystems: ["SOL", "VEGA"], salvageUnits: [:], eventSystems: [],
        theatres: [sol, vega], components: ["SOL": "SOL", "VEGA": "VEGA"], now: salvageEnsureNow
    )
    return (view, sol, vega)
}

@Suite("Brain — the haul readiness verdict")
struct BrainHaulReadinessTests {
    @Test("a tagged ferry controller with a hub launches on the lowest code")
    func theLowestCodedControllerLaunches() {
        let view = haulView(devices: [
            haulController("T2", tags: [HaulRun.defaultFleetTag.string], location: "SOL-1"),
            haulController("T1", tags: [HaulRun.defaultFleetTag.string], location: "SOL-1"),
        ])
        #expect(Brain.haulReadiness(view: view, directives: [], theatre: solTheatre) == .launch(controller: "T1"))
    }

    @Test("an untagged controller is idle — untagging is the operator's off-switch")
    func anUntaggedControllerIsIdle() {
        let view = haulView(devices: [haulController("T1", tags: [], location: "SOL-1")])
        #expect(
            Brain.haulReadiness(view: view, directives: [], theatre: solTheatre)
                == .idle(reason: "no free auto:haul controller offering ferry")
        )
    }

    @Test("a tagged device that does not offer ferry is not a haul controller")
    func aNonFerryDeviceIsIdle() {
        let view = haulView(devices: [
            haulController("T1", tags: [HaulRun.defaultFleetTag.string], directives: [], location: "SOL-1"),
        ])
        #expect(
            Brain.haulReadiness(view: view, directives: [], theatre: solTheatre)
                == .idle(reason: "no free auto:haul controller offering ferry")
        )
    }

    /// A theatre with no controller of its own idles, and must not call SOL's
    /// tagged, ferry-offering controller untagged just because VEGA can't see it.
    @Test("a theatre with no controller of its own idles without consuming the other theatre's controller")
    func theatreWithNoOwnControllerIdlesWithoutConsumingTheOther() {
        let (view, sol, vega) = twoTheatreHaulView(
            solControllers: [haulController("T1", tags: [HaulRun.defaultFleetTag.string], location: "SOL-1")],
            vegaControllers: []
        )
        guard case let .idle(reason) = Brain.haulReadiness(view: view, directives: [], theatre: vega) else {
            Issue.record("expected VEGA to idle — it owns no controller")
            return
        }
        #expect(reason == "no free \(HaulRun.defaultFleetTag) controller offering ferry")
        #expect(!reason.contains("T1"))
        #expect(Brain.haulReadiness(view: view, directives: [], theatre: sol) == .launch(controller: "T1"))
    }

    /// Two theatres, each with its own tagged, ferry-offering controller: each
    /// theatre's own verdict names its OWN controller, independent of the other.
    @Test("two theatres each with their own controller each launch their own")
    func twoTheatresEachWithTheirOwnControllerEachLaunchTheirOwn() {
        let (view, sol, vega) = twoTheatreHaulView(
            solControllers: [haulController("T1", tags: [HaulRun.defaultFleetTag.string], location: "SOL-1")],
            vegaControllers: [haulController("T2", tags: [HaulRun.defaultFleetTag.string], location: "VEGA-1")]
        )
        #expect(Brain.haulReadiness(view: view, directives: [], theatre: sol) == .launch(controller: "T1"))
        #expect(Brain.haulReadiness(view: view, directives: [], theatre: vega) == .launch(controller: "T2"))
    }

    /// The forward-shaping rule `mine` relies on. A liveness rule written over
    /// kind alone would make both of these read the same; a per-theatre
    /// general tag must still read as general, never as a per-site row.
    @Test("a per-site row is not the general drainer, and a general-family tag is")
    func perSiteRowsAreNotTheGeneralDrainer() {
        let perSite = directiveFixture(
            id: "PS", kind: .haulRun, deviceCode: "T9", fleetTag: "auto:mine:ALPAHARD"
        )
        let general = directiveFixture(
            id: "G", kind: .haulRun, deviceCode: "T1", fleetTag: HaulRun.defaultFleetTag.string
        )
        let perTheatre = directiveFixture(
            id: "PT", kind: .haulRun, deviceCode: "T2", fleetTag: "auto:haul:SOL-3"
        )
        let untagged = directiveFixture(id: "U", kind: .haulRun, deviceCode: "T1", fleetTag: nil)
        let drifted = directiveFixture(id: "D", kind: .haulRun, deviceCode: "T3", fleetTag: "Auto:Haul:SOL-3")
        #expect(Brain.isGeneralHaul(perSite) == false)
        #expect(Brain.isGeneralHaul(general) == true)
        #expect(Brain.isGeneralHaul(perTheatre) == true, "a theatre-scoped general tag is still general")
        #expect(Brain.isGeneralHaul(untagged) == true, "a nil tag falls back to the default")
        #expect(Brain.isGeneralHaul(drifted) == true, "case drift must not read as a per-site tag")
    }

    /// Retagging is the operator's handover, so the tag decides which theatre
    /// owns a controller — not the depot it happens to be parked nearest.
    @Test("a controller tagged for another theatre belongs to that theatre wherever it stands")
    func anExplicitTagMovesAControllerBetweenTheatres() {
        let (view, sol, vega) = twoTheatreHaulView(
            solControllers: [
                haulController("T1", tags: [HaulRun.defaultFleetTag.string], location: "SOL-1"),
                haulController("T2", tags: [HaulRun.defaultFleetTag.string, "auto:haul:vega-3"], location: "SOL-1"),
            ],
            vegaControllers: []
        )

        #expect(Brain.haulReadiness(view: view, directives: [], theatre: vega) == .launch(controller: "T2"))
        #expect(Brain.haulReadiness(view: view, directives: [], theatre: sol) == .launch(controller: "T1"))
    }
}

// MARK: - Re-homing a general drainer

/// A general drainer's `deviceCode` reserves a controller account-wide, so a
/// row still naming one that left its fleet locks it out of its new theatre.
@Suite("Brain — re-homing a general haul run")
struct BrainHaulRehomeTests {
    @Test("a row naming a controller that left its fleet is re-homed onto a member")
    func aRowNamingADepartedControllerIsRehomed() {
        let (view, sol, _) = twoTheatreHaulView(
            solControllers: [
                haulController("T1", tags: [HaulRun.defaultFleetTag.string, "auto:haul:sol-3"], location: "SOL-1"),
                haulController("T2", tags: [HaulRun.defaultFleetTag.string, "auto:haul:vega-3"], location: "SOL-1"),
            ],
            vegaControllers: []
        )
        let row = directiveFixture(
            id: "H1", kind: .haulRun, deviceCode: "T2",
            fleetTag: "auto:haul:SOL-3", theatreDepot: sol.depot
        )

        let rehomed = Brain.rehomedHaulRuns(directives: [row], view: view)

        #expect(rehomed.map(\.id) == ["H1"])
        #expect(rehomed.map(\.deviceCode) == ["T1"])
    }

    /// `controllerCode` reserves too, and `assigning` only re-stamps it on a
    /// repoint — so a settled run would hold the departed controller for good.
    @Test("a pinned controller that left the fleet is released even when deviceCode is sound")
    func aDepartedPinnedControllerIsReleased() {
        let (view, sol, _) = twoTheatreHaulView(
            solControllers: [
                haulController("T1", tags: [HaulRun.defaultFleetTag.string, "auto:haul:sol-3"], location: "SOL-1"),
                haulController("T2", tags: [HaulRun.defaultFleetTag.string, "auto:haul:vega-3"], location: "SOL-1"),
            ],
            vegaControllers: []
        )
        let row = directiveFixture(
            id: "H1", kind: .haulRun, deviceCode: "T1", controllerCode: "T2",
            fleetTag: "auto:haul:SOL-3", theatreDepot: sol.depot
        )

        let rehomed = Brain.rehomedHaulRuns(directives: [row], view: view)

        #expect(rehomed == [Brain.HaulRehome(id: "H1", deviceCode: nil, clearsController: true)])
    }

    @Test("a run whose two columns both name fleet members is left alone")
    func aSoundRowIsLeftAlone() {
        let view = haulView(devices: [
            haulController("T1", tags: [HaulRun.defaultFleetTag.string], location: "SOL-1"),
        ])
        let row = directiveFixture(
            id: "H1", kind: .haulRun, deviceCode: "T1", controllerCode: "T1",
            fleetTag: "auto:haul:SOL-3", theatreDepot: solTheatre.depot
        )

        #expect(Brain.rehomedHaulRuns(directives: [row], view: view).isEmpty)
    }

    @Test("a row whose controller is still in its fleet is left alone")
    func aRowStillNamingItsOwnControllerIsLeftAlone() {
        let view = haulView(devices: [
            haulController("T1", tags: [HaulRun.defaultFleetTag.string], location: "SOL-1"),
        ])
        let row = directiveFixture(
            id: "H1", kind: .haulRun, deviceCode: "T1",
            fleetTag: "auto:haul:SOL-3", theatreDepot: solTheatre.depot
        )

        #expect(Brain.rehomedHaulRuns(directives: [row], view: view).isEmpty)
    }

    /// With nothing left to name, the row keeps its stale code and stalls on its
    /// own `noHaulControllerTagged` path — blanking it would strand the reservation.
    @Test("an empty fleet leaves the row untouched rather than blanking it")
    func anEmptyFleetLeavesTheRowUntouched() {
        let view = haulView(devices: [
            haulController("T2", tags: [HaulRun.defaultFleetTag.string, "auto:haul:vega-3"], location: "SOL-1"),
        ])
        let row = directiveFixture(
            id: "H1", kind: .haulRun, deviceCode: "T2",
            fleetTag: "auto:haul:SOL-3", theatreDepot: solTheatre.depot
        )

        #expect(Brain.rehomedHaulRuns(directives: [row], view: view).isEmpty)
    }

    /// A pinned mine ferry drives exactly its own `deviceCode`; re-homing one
    /// would point the row at a controller that is not its belt's.
    @Test("a per-site ferry row is never re-homed")
    func aPerSiteFerryRowIsNeverRehomed() {
        let view = haulView(devices: [
            haulController("T1", tags: [HaulRun.defaultFleetTag.string], location: "SOL-1"),
        ])
        let row = directiveFixture(
            id: "PS", kind: .haulRun, deviceCode: "T9",
            fleetTag: "auto:mine:ALPAHARD", theatreDepot: solTheatre.depot
        )

        #expect(Brain.rehomedHaulRuns(directives: [row], view: view).isEmpty)
    }
}

// MARK: - `Brain.haulStatus` — the why-view's verdict

@Suite("Brain — the haul status for the why-view")
struct BrainHaulStatusTests {
    @Test("no operational theatre reports idle, naming that")
    func noOperationalTheatreReportsIdle() {
        let view = haulView(devices: [haulController("T1", tags: [HaulRun.defaultFleetTag.string])], depot: nil)
        #expect(Brain.haulStatus(directives: [], view: view) == .idle(reason: "no operational theatre"))
    }

    /// A live run in one theatre must not mask another theatre's own idle
    /// state.
    @Test("a live run in one theatre does not mask another theatre's idle state")
    func aLiveRunInOneTheatreDoesNotMaskAnother() {
        let (view, sol, vega) = twoTheatreHaulView(
            solControllers: [haulController("T1", tags: [HaulRun.defaultFleetTag.string], location: "SOL-1")],
            vegaControllers: []
        )
        let live = directiveFixture(
            id: "LIVE", kind: .haulRun, deviceCode: "T1",
            fleetTag: HaulRun.defaultFleetTag.string, theatreDepot: sol.depot
        )

        #expect(
            Brain.haulStatus(directives: [live], view: view, theatre: sol)
                == .launched(vessel: "T1", focus: sol.depot, status: .running)
        )
        guard case .idle = Brain.haulStatus(directives: [live], view: view, theatre: vega) else {
            Issue.record("VEGA's own idle state must not read as SOL's launch")
            return
        }
    }
}

@Suite("Brain — ensureHaul")
struct BrainEnsureHaulTests {
    private func seedHaulReadyWorld(_ db: Database) throws {
        try seedGrowableWorld(db, carriers: [], salvage: [:])
        try Device.insert {
            haulController("T1", tags: [HaulRun.defaultFleetTag.string], location: growHubLocation)
        }.execute(db)
    }

    @Test func aTaggedControllerAndAHubLaunchOneGeneralDrainer() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try self.seedHaulReadyWorld(db) }

        await salvageEnsureTick(database)

        let directives = try await salvageEnsureDirectives(database)
        let haul = try #require(directives.first { $0.kind == .haulRun })
        #expect(directives.count == 1)
        #expect(haul.deviceCode == "T1")
        #expect(haul.fleetTag == HaulRun.fleetTag(forTheatre: growHubLocation).string)
        #expect(haul.step == HaulRun().firstStep)
        #expect(haul.originDesignation == "SOL")
    }

    @Test func aSecondTickInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try self.seedHaulReadyWorld(db) }
        await salvageEnsureTick(database)
        let afterFirst = try await salvageEnsureDirectives(database)

        await salvageEnsureTick(database)

        #expect(try await salvageEnsureDirectives(database) == afterFirst)
    }

    /// The forward-shaping assertion, driven through the real tick: a live
    /// per-site row must NOT be mistaken for the general drainer.
    @Test func aPerSiteRowDoesNotSatisfyTheGeneralDrainersLiveness() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try self.seedHaulReadyWorld(db)
            try seedDirective(
                db, id: "PERSITE", kind: .haulRun, status: .running,
                deviceCode: "T9", fleetTag: "auto:mine:ALPAHARD"
            )
        }

        await salvageEnsureTick(database)

        let hauls = try await salvageEnsureDirectives(database).filter { $0.kind == .haulRun }
        #expect(hauls.count == 2)
        #expect(hauls.filter { $0.fleetTag == HaulRun.fleetTag(forTheatre: growHubLocation).string }.count == 1)
        #expect(hauls.contains { $0.id == "PERSITE" })
    }

    /// An idle theatre must `continue`, not `return`. Depot designations sort
    /// `SOL-3` before `VEGA-3`, so SOL (no haul controller) is visited first
    /// and must not suppress VEGA's (fully ready) launch.
    @Test func anIdleTheatreDoesNotSuppressAReadyOnesLaunch() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [], salvage: [:])
            try seedSecondTheatre(db)
            try Device.insert {
                haulController("T2", tags: [HaulRun.defaultFleetTag.string], location: secondTheatreHubLocation)
            }.execute(db)
        }

        await salvageEnsureTick(database)

        let hauls = try await salvageEnsureDirectives(database).filter { $0.kind == .haulRun }
        let haul = try #require(hauls.first)
        #expect(hauls.count == 1)
        #expect(haul.deviceCode == "T2")
        #expect(haul.theatreDepot == secondTheatreHubLocation)
    }

    /// The headline: two theatres, each with its own per-theatre-tagged
    /// controller, both launch in the SAME tick.
    @Test func twoTheatresEachWithAPerTheatreTaggedControllerBothLaunchInOneTick() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [], salvage: [:])
            try seedSecondTheatre(db)
            try Device.insert {
                haulController("T1", tags: ["auto:haul:\(growHubLocation)"], location: growHubLocation)
            }.execute(db)
            try Device.insert {
                haulController("T2", tags: ["auto:haul:\(secondTheatreHubLocation)"], location: secondTheatreHubLocation)
            }.execute(db)
        }

        await salvageEnsureTick(database)

        let hauls = try await salvageEnsureDirectives(database).filter { $0.kind == .haulRun }
        #expect(hauls.count == 2, "both theatres must launch in the same tick")
        #expect(hauls.contains { $0.deviceCode == "T1" })
        #expect(hauls.contains { $0.deviceCode == "T2" })
    }

    /// Candidate SCOPING only — SOL's per-theatre tag can never literally
    /// match VEGA's, so this proves nothing about `reservedDevices` itself;
    /// see the two BOTH-bare tests below for the actual sweep mechanism.
    @Test func aLiveTheatresOwnTagDoesNotDisturbAnotherTheatresLaunch() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [], salvage: [:])
            try seedSecondTheatre(db)
            try Device.insert {
                haulController("T2", tags: ["auto:haul:\(secondTheatreHubLocation)"], location: secondTheatreHubLocation)
            }.execute(db)
            try seedDirective(
                db, id: "LIVE-SOL", kind: .haulRun, status: .running, deviceCode: "T1",
                fleetTag: "auto:haul:\(growHubLocation)", theatreDepot: growHubLocation
            )
            try Device.insert {
                haulController("T1", tags: [HaulRun.defaultFleetTag.string], location: growHubLocation)
            }.execute(db)
        }

        await salvageEnsureTick(database)

        let hauls = try await salvageEnsureDirectives(database).filter { $0.kind == .haulRun }
        #expect(hauls.count == 2, "VEGA's own tagged controller must still launch")
        #expect(hauls.contains { $0.deviceCode == "T2" })
    }

    // MARK: - Literal tag-sweep collision (the actual `reservedDevices` mechanism)

    /// The real mechanism of the original bug, fixed for a FRESH launch: two
    /// theatres BOTH wearing the literal shared bare tag each launch in the
    /// SAME tick, since the row each writes stamps its own per-theatre tag.
    @Test func twoBareTaggedTheatresBothLaunchFreshInOneTick() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [], salvage: [:])
            try seedSecondTheatre(db)
            try Device.insert {
                haulController("T1", tags: [HaulRun.defaultFleetTag.string], location: growHubLocation)
            }.execute(db)
            try Device.insert {
                haulController("T2", tags: [HaulRun.defaultFleetTag.string], location: secondTheatreHubLocation)
            }.execute(db)
        }

        await salvageEnsureTick(database)

        let hauls = try await salvageEnsureDirectives(database).filter { $0.kind == .haulRun }
        #expect(hauls.count == 2, "neither theatre's literal bare tag may sweep the other's fresh row")
        #expect(hauls.first { $0.deviceCode == "T1" }?.fleetTag == HaulRun.fleetTag(forTheatre: growHubLocation).string)
        #expect(hauls.first { $0.deviceCode == "T2" }?.fleetTag == HaulRun.fleetTag(forTheatre: secondTheatreHubLocation).string)
    }

    /// Driven through a real tick: an ALREADY-RUNNING directive still
    /// carrying the literal bare tag still reserves a different theatre's
    /// still-bare controller — `reservedDevices` was left untouched.
    @Test func legacyBareTaggedLiveRunStillCollidesWithAnotherTheatresBareController() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [], salvage: [:])
            try seedSecondTheatre(db)
            try Device.insert {
                haulController("T1", tags: [HaulRun.defaultFleetTag.string], location: growHubLocation)
            }.execute(db)
            try Device.insert {
                haulController("T2", tags: [HaulRun.defaultFleetTag.string], location: secondTheatreHubLocation)
            }.execute(db)
            try seedDirective(
                db, id: "LIVE-SOL", kind: .haulRun, status: .running, deviceCode: "T1",
                fleetTag: HaulRun.defaultFleetTag.string, theatreDepot: growHubLocation
            )
        }

        await salvageEnsureTick(database)

        let hauls = try await salvageEnsureDirectives(database).filter { $0.kind == .haulRun }
        #expect(hauls.count == 1, "VEGA's T2 is swept by SOL's literal bare-tag reservation")
        #expect(hauls.first?.id == "LIVE-SOL")
    }
}
