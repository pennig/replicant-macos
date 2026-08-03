//
//  DevicePredicatesTests.swift
//  GameModelsTests
//
//  Device.isPrintHub / Device.isActiveRelay — thin capability predicates
//  consumed by the automation brain (WorldView, PrunePredicate, RelayRun).
//

import Testing
@testable import GameModels

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
}
