//
//  BrainWhyEventChoiceTests.swift
//  Replicould — Directives feature
//
//  The decisions section: what the brain is waiting on an operator to pick.
//

import DirectiveEngine
import Foundation
import GameModels
import Testing
import Utils
@testable import DirectivesFeature

@Suite("The why-view's pending event choices")
struct BrainWhyEventChoiceTests {
    private static let epoch = Date(timeIntervalSince1970: 0)

    private static func event(
        _ designation: String, location: String, tier: Int, options: [JSONValue]
    ) -> LocationEvent {
        LocationEvent(
            designation: designation, location: location, tier: tier, status: "active",
            detail: .object([
                "criteria": .array(options),
                "rewards": .object(["xp": .number(1500)]),
            ]),
            firstSeenAt: epoch, updatedAt: epoch
        )
    }

    private static func option(
        _ name: String, devices: [(Int, String)] = [], resources: [String: Int] = [:]
    ) -> JSONValue {
        .object([
            "name": .string(name),
            "devices": .array(devices.map {
                .object(["count": .number(Double($0.0)), "device_type": .string($0.1)])
            }),
            "resources": .object(resources.mapValues { .number(Double($0)) }),
        ])
    }

    private static func device(_ code: String, type: String) -> Device {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R1", status: "idle",
            location: "SOL-3", locationName: nil, operationalCapacity: 1, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: epoch, availableCommands: [], features: [], tags: [],
            detail: .object([:]), updatedAt: epoch, firstSeenAt: epoch
        )
    }

    private static func report(choices: [BrainEventChoice]) -> BrainReport {
        BrainReport(
            decision: .idle(reason: "nothing"),
            ranked: [],
            theatres: [Theatre(depot: "SOL-3", system: "SOL", origin: .derived, readiness: .operational, stock: 0)],
            limits: BrainLimits(
                actionsRemaining: 54, actionsLimit: 60, actionsFloor: 6,
                readsRemaining: 108, readsLimit: 120, readsFloor: 12,
                hubStock: 41_000, hubStockFetchedAt: epoch,
                spendFloor: 35_078, rateLimitedAt: nil
            ),
            survey: .idle(reason: "none"),
            observedAt: epoch,
            pendingEventChoices: choices
        )
    }

    /// The whole chain the operator sees: two undecided events and one that
    /// needs no pick, priced against a fleet holding one of the device types.
    @Test("each pending event lists its options, priced and stock-checked")
    func listsPricedOptions() {
        let choices = BrainReport.eventChoices(
            events: [
                Self.event("Y-2-EVT-009", location: "Y-2", tier: 1, options: [
                    Self.option("only", resources: ["conductive": 50]),
                ]),
                Self.event("X-1-EVT-001", location: "X-1", tier: 2, options: [
                    Self.option("satellite", devices: [(2, "comm_satellite")], resources: ["conductive": 150]),
                    Self.option("booster", devices: [(1, "signal_booster")]),
                ]),
                Self.event("Z-3-EVT-004", location: "Z-3", tier: 3, options: [
                    Self.option("bulk", resources: ["carbon": 900]),
                    Self.option("light", resources: ["carbon": 100]),
                ]),
            ],
            bills: [
                "comm_satellite": ResourceCost(conductive: 350),
                "signal_booster": ResourceCost(conductive: 400),
            ],
            devices: ["BOOST": Self.device("BOOST", type: "signal_booster")]
        )
        let why = BrainWhy.from(report: Self.report(choices: choices))

        #expect(why.eventChoices.map(\.designation) == ["X-1-EVT-001", "Z-3-EVT-004"])
        let first = why.eventChoices[0]
        #expect(first.location == "X-1")
        #expect(first.tier == 2)
        #expect(first.options.map(\.name) == ["satellite", "booster"])
        #expect(first.options[0].fact == "700 units to build · 150 to ship")
        #expect(first.options[1].fact == "400 units to build")
        #expect(first.options[0].stock == "needs Comm Satellite")
        #expect(first.options[1].stock == "every device in stock")
        #expect(first.options[0].holdsEveryDevice == false)
        #expect(first.options[1].holdsEveryDevice)
    }

    /// A device type the blueprint catalogue cannot price must not read as a
    /// free option — "nothing to deliver" beside "needs Signal Booster" is one
    /// line contradicting itself.
    @Test("an unpriced device option says so instead of reading as free")
    func namesAnUnpricedBuild() {
        let choices = BrainReport.eventChoices(
            events: [
                Self.event("X-1-EVT-001", location: "X-1", tier: 2, options: [
                    Self.option("booster", devices: [(1, "signal_booster")]),
                    Self.option("satellite", devices: [(1, "comm_satellite")], resources: ["carbon": 150]),
                ]),
            ],
            bills: [:], devices: [:]
        )
        let why = BrainWhy.from(report: Self.report(choices: choices))

        #expect(why.eventChoices[0].options[0].fact == "build cost unpriced")
        #expect(why.eventChoices[0].options[1].fact == "build cost unpriced · 150 to ship")
        #expect(why.eventChoices[0].options[0].stock == "needs Signal Booster")
    }

    /// A pick the operator must make is not a fault, so the section carries no
    /// escalation — the card stays calm.
    @Test("a pending choice never escalates the card")
    func neverEscalates() {
        let choices = BrainReport.eventChoices(
            events: [
                Self.event("X-1-EVT-001", location: "X-1", tier: 2, options: [
                    Self.option("a", resources: ["carbon": 10]),
                    Self.option("b", resources: ["carbon": 20]),
                ]),
            ],
            bills: [:], devices: [:]
        )
        let why = BrainWhy.from(report: Self.report(choices: choices))

        #expect(why.eventChoices.count == 1)
        #expect(why.isEscalated == false)
    }

    /// Nothing to decide renders nothing at all — the section is omitted rather
    /// than showing an empty-state line.
    @Test("no pending choice leaves the section empty")
    func emptyWhenNothingIsPending() {
        let why = BrainWhy.from(report: Self.report(choices: []))
        #expect(why.eventChoices.isEmpty)
    }

    /// An option that outgrows one freighter load is flagged, and its sibling
    /// under the same event is not.
    @Test("an over-capacity option is flagged and its sibling is not")
    func flagsTheOverCapacityOption() {
        let choices = BrainReport.eventChoices(
            events: [
                Self.event("X-1-EVT-001", location: "X-1", tier: 2, options: [
                    Self.option("bulk", resources: ["carbon": 900]),
                    Self.option("light", resources: ["carbon": 100]),
                ]),
            ],
            bills: [:], devices: [:]
        )
        let why = BrainWhy.from(report: Self.report(choices: choices))

        #expect(why.eventChoices[0].options[0].exceedsOneFreighterLoad)
        #expect(why.eventChoices[0].options[1].exceedsOneFreighterLoad == false)
        #expect(why.eventChoices[0].options[0].fact == "900 units to ship")
        // A resource-only option holds no devices to be short OF, and must not
        // claim a stock reading it never took.
        #expect(why.eventChoices[0].options[0].stock == "no devices needed")
    }
}
