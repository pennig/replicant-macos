//
//  SalvageRunHubAnchorTests.swift
//  Replicould — DirectiveEngine
//
//  A Salvage Run with no roam centre anchors on the hub's SYSTEM. A location in
//  that slot would aim the census read at a site rather than a star.
//

import Foundation
import GameModels
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

private let anchorNow = Date(timeIntervalSince1970: 20_000)

private func anchorDevice(
    _ code: String, type: String, location: String?,
    status: String = "idle", features: [String] = [], availableCommands: [String] = []
) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: availableCommands,
        features: features, tags: [], detail: .object([:]),
        updatedAt: anchorNow, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// A world holding a recognised hub at `hub`, plus a vessel with no location of
/// its own so the roam centre must fall through to the hub.
private func anchorWorld(hub: String?) -> WorldSnapshot {
    var devices = [anchorDevice("V1", type: "heaven_vessel", location: nil)]
    var footprints: [LocationFootprint] = []
    if let hub {
        let system = SiteAssay.system(of: hub)
        devices.append(
            anchorDevice(
                "HUB1", type: "autofactory", location: hub, availableCommands: ["enqueue_print"]
            )
        )
        devices.append(
            anchorDevice(
                "RLY1", type: "ftl_relay", location: "\(system)-5-L4",
                status: "relaying", features: ["relay"]
            )
        )
        footprints.append(
            LocationFootprint(
                location: hub, devices: 1, resources: 50_000, resourceSites: 0,
                locationEvents: 0, replicants: 0, fetchedAt: anchorNow
            )
        )
    }
    let footprintsByLocation = Dictionary(footprints.map { ($0.location, $0) }, uniquingKeysWith: { _, last in last })
    let mesh = SalvageTargetPlanner.meshSystems(in: devices)
    let components = Dictionary(uniqueKeysWithValues: mesh.map { ($0, $0) })
    let theatres = TheatreRegistry.recognise(
        devices: devices, pins: [], meshSystems: mesh,
        components: components, stockByLocation: footprintsByLocation.mapValues(\.resources)
    )
    return WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: [:],
        footprints: footprintsByLocation,
        theatres: theatres,
        now: anchorNow
    )
}

private func anchorDirective(theatreDepot: String? = nil) -> Directive {
    Directive(
        id: "S1", kind: .salvageRun, status: .running, deviceCode: "V1",
        controllerCode: nil, roamCentre: nil, fleetTag: SalvageRun.defaultFleetTag.string,
        sourceRelayCode: nil, targets: [], targetIndex: 0,
        step: SalvageRun.Step.preflight.rawValue, stepStartedAt: anchorNow,
        returnToOrigin: false, originDesignation: nil, attentionReason: nil,
        createdAt: anchorNow, updatedAt: anchorNow, theatreDepot: theatreDepot
    )
}

@Suite("Salvage Run — the roam anchor is derived")
struct SalvageRunHubAnchorTests {
    /// `SOL`, never `SOL-3-1`. The two differ by exactly the projection this
    /// test exists to pin.
    @Test("a row with no roam centre anchors on the hub's system")
    func theAnchorIsTheHubsSystem() {
        let action = SalvageRun().nextAction(
            directive: anchorDirective(theatreDepot: "SOL-3-1"), world: anchorWorld(hub: "SOL-3-1")
        )
        #expect(action == .extendQueue(centre: "SOL"))
    }

    /// With no hub recognised there is nothing to derive, and the shipped
    /// constant is still the last resort rather than a crash or a nil centre.
    @Test("no hub falls through to the base system")
    func noHubFallsThroughToTheConstant() {
        let action = SalvageRun().nextAction(
            directive: anchorDirective(), world: anchorWorld(hub: nil)
        )
        #expect(action == .extendQueue(centre: SalvageRun.baseSystem))
    }

    /// The vessel's own system still wins over the hub — a run already out in
    /// the field extends its queue from where it stands.
    @Test("a vessel with a location outranks the hub")
    func theVesselsOwnSystemWins() {
        var world = anchorWorld(hub: "SOL-3-1")
        var devices = world.devices
        devices["V1"] = anchorDevice("V1", type: "heaven_vessel", location: "ALPAHARD-7")
        world = WorldSnapshot(
            devices: devices, openOperations: [:], footprints: world.footprints,
            theatres: world.theatres, now: anchorNow
        )
        let action = SalvageRun().nextAction(
            directive: anchorDirective(theatreDepot: "SOL-3-1"), world: world
        )
        #expect(action == .extendQueue(centre: "ALPAHARD"))
    }
}
