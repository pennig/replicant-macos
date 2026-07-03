//
//  PrintingSnapshotTests.swift
//  Replicould — GameServices
//
//  `PrintingSnapshot(printingBlock:)` maps a printer's `printing` block to the
//  active-job readout, and the `Device` extensions surface the queue
//  (`print_queue`), the resources a job is blocked on (`waiting_for`), and the
//  `isPrintingOrQueued` gate the Print Queue list filters on. The `printing`
//  block here is a real payload captured from a live heaven vessel.
//

import Foundation
import GameModels
import Testing
import Utils
@testable import GameServices

@Suite struct PrintingSnapshotTests {

    /// A real `printing` block from a heaven vessel fabricating an autofactory.
    private var printingBlock: JSONValue {
        .object([
            "eta_seconds": .number(1983.5),
            "progress_percent": .number(17.4),
            "completes_at": .string("2026-07-02T08:38:25-05:00"),
            "started_at": .string("2026-07-02T07:58:25-05:00"),
            "device_type": .string("autofactory"),
        ])
    }

    @Test func parsesEveryField() throws {
        let p = try #require(PrintingSnapshot(printingBlock: printingBlock))
        #expect(p.deviceType == "autofactory")
        #expect(p.progressPercent == 17.4)
        #expect(p.etaSeconds == 1983.5)
    }

    @Test func parsesTimestampsAsOffset() throws {
        let p = try #require(PrintingSnapshot(printingBlock: printingBlock))
        #expect(p.startedAt == (try Date("2026-07-02T12:58:25Z", strategy: .iso8601)))
        #expect(p.completesAt == (try Date("2026-07-02T13:38:25Z", strategy: .iso8601)))
    }

    @Test func returnsNilForNonObject() {
        #expect(PrintingSnapshot(printingBlock: nil) == nil)
        #expect(PrintingSnapshot(printingBlock: .string("nope")) == nil)
    }

    @Test func deviceReadsPrintingBlock() throws {
        let device = makeDevice(detail: .object(["printing": printingBlock]))
        #expect(device.printingSnapshot?.deviceType == "autofactory")
    }

    // MARK: Queue

    @Test func parsesPrintQueueItemsInOrder() throws {
        let device = makeDevice(detail: .object([
            "print_queue": .array([
                .object(["device_type": .string("mining_drone"), "tags": .array([.string("alpha")])]),
                .object(["device_type": .string("survey_drone"), "controller": .string("CTRL1234")]),
            ]),
        ]))
        let items = device.printQueueItems
        #expect(items.count == 2)
        #expect(items[0].index == 0)
        #expect(items[0].deviceType == "mining_drone")
        #expect(items[0].tags == ["alpha"])
        #expect(items[1].index == 1)
        #expect(items[1].deviceType == "survey_drone")
        #expect(items[1].controller == "CTRL1234")
    }

    @Test func emptyQueueWhenNoBlock() {
        #expect(makeDevice(detail: .object([:])).printQueueItems.isEmpty)
    }

    // MARK: Waiting-for resources

    @Test func parsesWaitingForResourcesSortedByName() throws {
        let device = makeDevice(detail: .object([
            "waiting_for": .object([
                "structural": .object(["need": .number(10), "have": .number(4)]),
                "conductive": .object(["need": .number(2), "have": .number(2)]),
            ]),
        ]))
        let resources = device.waitingForResources
        #expect(resources.map(\.resource) == ["conductive", "structural"])
        #expect(resources[0].isMet)          // have 2 ≥ need 2
        #expect(resources[1].isMet == false) // have 4 < need 10
    }

    // MARK: isPrintingOrQueued gate

    @Test func gateRequiresPrintFeature() {
        // Printing block present but no `print` feature → excluded.
        let device = makeDevice(detail: .object(["printing": printingBlock]), features: [])
        #expect(device.isPrintingOrQueued == false)
    }

    @Test func gateIncludesActivePrinter() {
        let device = makeDevice(detail: .object(["printing": printingBlock]), features: ["print"])
        #expect(device.isPrintingOrQueued)
    }

    @Test func gateIncludesQueuedButIdlePrinter() {
        let device = makeDevice(detail: .object([:]), features: ["print"], queueSize: 3)
        #expect(device.isPrintingOrQueued)
    }

    @Test func gateExcludesIdleEmptyPrinter() {
        let device = makeDevice(detail: .object([:]), features: ["print"], queueSize: 0)
        #expect(device.isPrintingOrQueued == false)
    }

    private func makeDevice(
        detail: JSONValue,
        features: [String] = ["print"],
        queueSize: Int = 0
    ) -> Device {
        Device(
            deviceCode: "965AC2C3", deviceType: "heaven_vessel", replicantCode: "R1",
            status: "printing (autofactory)", location: "ATIANFU-1", locationName: nil,
            operationalCapacity: 100, queueSize: queueSize, stowedInDeviceCode: nil,
            controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: features,
            tags: [], detail: detail, updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
