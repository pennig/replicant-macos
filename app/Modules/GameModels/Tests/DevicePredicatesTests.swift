//
//  DevicePredicatesTests.swift
//  GameModelsTests
//
//  Device.isPrintHub / Device.isActiveRelay — thin capability predicates
//  consumed by the automation brain (WorldView, PrunePredicate, RelayRun).
//

import Foundation
import Testing
@testable import GameModels

/// A minimal device row, confined to this file — the repo's convention for a
/// device fixture is a private per-file builder (see
/// `DirectiveEngineTests/SalvageTargetPlannerTests.swift`'s `device(...)`),
/// not a shared production-visible constructor. `code`/`type`/`location` are
/// required arguments (never a guessed default); every other column takes an
/// inert placeholder that a test then overrides explicitly (e.g.
/// `availableCommands`, `features`, `status`) rather than relying on a
/// silently-plausible default to make an assertion pass — the same loud-
/// defaults spirit as a shared client's `testValue`.
private extension Device {
    static func fixture(code: String, type: String, location: String?) -> Device {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R1",
            status: "idle", location: location, locationName: nil,
            operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [],
            detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }
}

@Suite struct DevicePredicatesTests {
    @Test func printHubIsAnEnqueuePrintCapableDevice() {
        var hub = Device.fixture(code: "AF1", type: "autofactory", location: "SOL-3")
        hub.availableCommands = ["enqueue_print", "configure"]
        #expect(hub.isPrintHub)
        var vessel = Device.fixture(code: "V1", type: "heaven_vessel", location: "SOL-3")
        vessel.availableCommands = ["travel", "stow"]
        #expect(!vessel.isPrintHub)
    }

    @Test func activeRelayNeedsFeatureAndRelayingStatus() {
        var r = Device.fixture(code: "R1", type: "ftl_relay", location: "SOL-3-L4")
        r.features = ["relay"]; r.status = "relaying"
        #expect(r.isActiveRelay)
        r.status = "idle"
        #expect(!r.isActiveRelay)
    }

    /// The AND's other half: `statusBase == "relaying"` alone must not be
    /// enough — a device reporting a relaying-shaped status but missing the
    /// `relay` feature (e.g. a non-relay device, or a relay stripped of the
    /// feature) must not read as an active relay. Without this case a
    /// regression that dropped the `features` check entirely would still
    /// pass this suite.
    @Test func activeRelayIsFalseWithoutTheRelayFeatureEvenWhenStatusIsRelaying() {
        var r = Device.fixture(code: "R2", type: "ftl_relay", location: "SOL-3-L4")
        r.features = []; r.status = "relaying"
        #expect(!r.isActiveRelay)
        r.features = ["compute"]
        #expect(!r.isActiveRelay)
    }

    /// `statusBase` strips a parenthetical parameter before the comparison —
    /// pins that behaviour through `isActiveRelay` rather than by inspection.
    @Test func activeRelayReadsThroughAParentheticalStatusParameter() {
        var r = Device.fixture(code: "R3", type: "ftl_relay", location: "SOL-3-L4")
        r.features = ["relay"]; r.status = "relaying (mesh)"
        #expect(r.isActiveRelay)
    }

    /// The two live vessel classes share one feature set; both must qualify —
    /// the predicate is capability, so the type string never matters.
    @Test func carrierHullAcceptsBothVesselClassFeatureSets() {
        let vesselFeatures = ["surge", "cruise", "system_scan", "mine", "cradle", "print", "census"]
        var heaven = Device.fixture(code: "V1", type: "heaven_vessel", location: "SOL-3")
        heaven.features = vesselFeatures
        #expect(heaven.isCarrierHull)
        var racing = Device.fixture(code: "V2", type: "racing_vessel", location: "SOL-3")
        racing.features = vesselFeatures
        #expect(racing.isCarrierHull)
    }

    /// Cradle alone (matrix_container) or surge alone (cargo_freighter,
    /// surge_plate) must not read as a carrier hull.
    @Test func carrierHullNeedsBothCradleAndSurge() {
        var container = Device.fixture(code: "M1", type: "matrix_container", location: "SOL-3")
        container.features = ["cruise", "cradle"]
        #expect(!container.isCarrierHull)
        var freighter = Device.fixture(code: "F1", type: "cargo_freighter", location: "SOL-3")
        freighter.features = ["surge", "cruise", "transport"]
        #expect(!freighter.isCarrierHull)
        var plate = Device.fixture(code: "P1", type: "surge_plate", location: "SOL-3")
        plate.features = ["surge", "cruise", "attach", "stow", "taxi"]
        #expect(!plate.isCarrierHull)
    }
}
