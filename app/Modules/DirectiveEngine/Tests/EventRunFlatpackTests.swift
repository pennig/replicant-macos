//
//  EventRunFlatpackTests.swift
//  Replicould — DirectiveEngine
//
//  The event convoy's payload rides the carrier's attach grid, which takes a
//  modular device only compacted — so `printing` asks for it at the bench.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 10_000)
private let depot = "HUB-1"

/// A free autofactory at the depot, which is all `printing` needs to dispatch.
private func printer(_ code: String = "BENCH") -> Device {
    EventRunFixtures.device(code, type: "autofactory", location: depot, updatedAt: now)
}

/// The beacon already standing under this run's tag, so the only print left
/// wanting is the option's own device.
private func standingBeacon() -> Device {
    EventRunFixtures.device(
        "BEACON", type: EventPlan.beaconDeviceType, location: depot,
        tags: [EventRun.fleetTag(forTheatre: depot).string], updatedAt: now
    )
}

/// A world at the printing step wanting one `type`, with `modular` naming the
/// types the blueprint catalogue reports as modular.
private func worldWanting(_ type: String, modular: Set<String>) -> WorldSnapshot {
    EventRunFixtures.world(
        devices: [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            printer(), standingBeacon(),
        ],
        event: EventRunFixtures.event(devices: [(1, type)]),
        now: now,
        modularDeviceTypes: modular
    )
}

private func printingRow() -> Directive {
    EventRunFixtures.directive(step: EventRun.Step.printing.rawValue, now: now)
}

@Suite("EventRun — a modular payload is printed compacted")
struct EventRunFlatpackTests {

    /// The bug this exists for: a modular device printed unfurled cannot be
    /// attached to the surge carrier that delivers it, so the run loads nothing.
    @Test("a modular option device is printed flatpacked")
    func modularTypeIsFlatpacked() {
        let world = worldWanting("climate_processor", modular: ["climate_processor"])

        guard case let .dispatch(_, _, params, _) =
            EventRun().nextAction(directive: printingRow(), world: world)
        else { return #expect(Bool(false), "expected a dispatch") }
        #expect(params.deviceType == "climate_processor")
        #expect(params.flatpack == true)
    }

    /// A type the catalogue does not report modular cannot be compacted at all,
    /// and the flag stays off its print rather than being sent to be ignored.
    @Test("a non-modular option device is printed as it always was")
    func nonModularTypeIsNotFlatpacked() {
        let world = worldWanting("sensor_array", modular: ["climate_processor"])

        guard case let .dispatch(_, _, params, _) =
            EventRun().nextAction(directive: printingRow(), world: world)
        else { return #expect(Bool(false), "expected a dispatch") }
        #expect(params.deviceType == "sensor_array")
        #expect(params.flatpack == nil)
    }

    /// An empty modular set is what a snapshot built without the catalogue
    /// reports, and it must read as "flatpack nothing", never as "flatpack all".
    @Test("an unread catalogue flatpacks nothing")
    func unreadCatalogueFlatpacksNothing() {
        let world = worldWanting("climate_processor", modular: [])

        guard case let .dispatch(_, _, params, _) =
            EventRun().nextAction(directive: printingRow(), world: world)
        else { return #expect(Bool(false), "expected a dispatch") }
        #expect(params.flatpack == nil)
    }
}
