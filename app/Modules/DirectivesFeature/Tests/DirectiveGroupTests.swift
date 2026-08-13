//
//  DirectiveGroupTests.swift
//  Replicould — Directives feature
//
//  The list's grouping: which automation each row serves, and the order the
//  sections come out in.
//

import DirectiveEngine
import Foundation
import GameModels
import Testing
import Utils
@testable import DirectivesFeature

private func device(
    code: String,
    type: String,
    directive: String?,
    tags: [String] = [],
    location: String? = nil
) -> Device {
    var detail: [String: JSONValue] = [:]
    if let directive { detail["ami_directive"] = .object(["name": .string(directive)]) }
    return Device(
        deviceCode: code,
        deviceType: type,
        replicantCode: "R1",
        status: "idle",
        location: location,
        locationName: nil,
        operationalCapacity: 100,
        queueSize: 0,
        stowedInDeviceCode: nil,
        controllerDeviceCode: nil,
        attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [],
        features: [],
        tags: tags,
        detail: .object(detail),
        updatedAt: Date(timeIntervalSince1970: 0),
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func run(
    id: String,
    kind: DirectiveKind,
    status: DirectiveStatus = .running,
    deviceCode: String,
    controllerCode: String? = nil,
    targets: [String] = [],
    fleetTag: String? = nil
) -> Directive {
    Directive(
        id: id, kind: kind, status: status, deviceCode: deviceCode,
        controllerCode: controllerCode, roamCentre: nil, fleetTag: fleetTag,
        targets: targets, targetIndex: 0, step: "hauling",
        stepStartedAt: Date(timeIntervalSince1970: 0),
        returnToOrigin: false, originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

/// One installed belt: the mining controller is what makes the location read as
/// a mine, and the ferry stands at the delivery sink rather than the belt.
private enum Mine {
    static let belt = "ACHERNUR-BELT-1"
    static let sink = "AINALRAM-BELT-1"

    static let devices = [
        device(code: "SEARCH01", type: "ami_survey_controller", directive: "belt_search",
               tags: ["auto:mine"], location: belt),
        device(code: "MINER001", type: "ami_mining_controller", directive: "gather_evenly",
               tags: ["auto:mine"], location: belt),
        device(code: "SERVICE1", type: "service_bot", directive: "service",
               tags: ["auto:mine"], location: belt),
        device(code: "FERRY001", type: "ami_transport_controller", directive: "ferry",
               tags: ["auto:mine"], location: sink),
    ]

    static func haulRun(controllerCode: String? = nil) -> Directive {
        run(id: "haul-achernur", kind: .haulRun, deviceCode: "FERRY001",
            controllerCode: controllerCode, targets: [belt],
            fleetTag: "auto:mine:\(belt)")
    }
}

private func groups(_ devices: [Device], _ directives: [Directive]) -> [DirectiveGroup] {
    DirectiveGroup.group(DirectiveRow.merge(devices: devices, directives: directives))
}

@Suite("Directive grouping")
struct DirectiveGroupTests {
    @Test("a belt's four controllers and its Haul Run make one group")
    func mineIsOneGroup() {
        let result = groups(Mine.devices, [Mine.haulRun()])
        #expect(result.count == 1)
        #expect(result[0].key == .automation(name: "mine", site: Mine.belt))
        #expect(result[0].rows.count == 5)
        #expect(result[0].title == "Mine")
        #expect(result[0].designation == Mine.belt)
    }

    /// The ferry stands at the sink, so its own bare `auto:mine` tag names no
    /// belt — the run it serves is the only thing that knows which mine it is.
    @Test("a pinned ferry at the delivery sink joins its own belt's group")
    func ferryJoinsItsRun() {
        let rows = DirectiveRow.merge(devices: Mine.devices, directives: [Mine.haulRun()])
        let keys = DirectiveGroup.missionKeys(in: rows)
        let ferry = try! #require(rows.first { $0.id == "builtin:FERRY001" })
        #expect(
            DirectiveGroup.key(for: ferry, missionKeys: keys)
                == .automation(name: "mine", site: Mine.belt)
        )
    }

    /// The same row, reached the other way: with `controllerCode` stamped the
    /// ferry is mission-driven, and the mission id resolves it.
    @Test("a mission-driven built-in row joins the mission's group")
    func missionDrivenRowJoinsItsMission() {
        let directives = [Mine.haulRun(controllerCode: "FERRY001")]
        let rows = DirectiveRow.merge(devices: Mine.devices, directives: directives)
        let ferry = try! #require(rows.first { $0.id == "builtin:FERRY001" })
        guard case let .builtIn(builtIn) = ferry else { return #expect(Bool(false)) }
        #expect(builtIn.drivenBy?.holder == .mission(id: "haul-achernur"))
        #expect(
            DirectiveGroup.key(for: ferry, missionKeys: DirectiveGroup.missionKeys(in: rows))
                == .automation(name: "mine", site: Mine.belt)
        )
    }

    @Test("a finished run leaves its automation's group for Finished")
    func finishedRunDoesNotHoldItsGroupOpen() {
        let done = run(id: "haul-old", kind: .haulRun, status: .completed,
                       deviceCode: "FERRY001", targets: [Mine.belt],
                       fleetTag: "auto:mine:\(Mine.belt)")
        let result = groups(Mine.devices, [Mine.haulRun(), done])
        #expect(result.map(\.key) == [.automation(name: "mine", site: Mine.belt), .finished])
        #expect(result[0].rows.count == 5)
        #expect(result[1].rows.count == 1)
    }

    /// An un-migrated device wears both tag forms. The bare one names no site,
    /// so taking it would strand the fleet in its own siteless group.
    @Test("a device wearing both tag forms joins its run, not a siteless group")
    func perSiteTagBeatsTheBareOne() {
        let theatre = "AINALRAM-BELT-1"
        let bots = (1...2).map {
            device(code: "SALVBOT\($0)", type: "service_bot", directive: "service",
                   tags: ["auto:salvage", "auto:salvage:\(theatre)"], location: "PAPOLTR-6-L4")
        }
        let salvage = run(id: "salvage-1", kind: .salvageRun, deviceCode: "VESSEL01",
                          fleetTag: "auto:salvage:\(theatre)")
        let result = groups(bots, [salvage])
        #expect(result.map(\.key) == [.automation(name: "salvage", site: theatre)])
        #expect(result[0].rows.count == 3)
    }

    @Test("the bare tag still groups a device that wears only that")
    func bareTagAloneStillGroups() {
        let bot = device(code: "SALVBOT1", type: "service_bot", directive: "service",
                         tags: ["auto:salvage"], location: "PAPOLTR-6-L4")
        #expect(groups([bot], []).map(\.key) == [.automation(name: "salvage", site: nil)])
    }

    @Test("a run with no fleet tag is Mesh")
    func untaggedRunIsMesh() {
        let relay = run(id: "relay-1", kind: .relayRun, deviceCode: "CARRIER1", targets: ["KRIOSAN"])
        let result = groups([], [relay])
        #expect(result.map(\.key) == [.mesh])
    }

    @Test("an untagged built-in row is Unassigned")
    func untaggedBuiltInIsUnassigned() {
        let stray = device(code: "STRAY001", type: "ami_survey_controller",
                           directive: "survey_system", location: "TABAT-6-L4")
        let result = groups([stray], [])
        #expect(result.map(\.key) == [.unassigned])
    }

    @Test("groups sort attention first and Finished last")
    func orderPutsAttentionFirstAndFinishedLast() {
        let stalled = run(id: "salvage-1", kind: .salvageRun, status: .needsAttention,
                          deviceCode: "VESSEL01", fleetTag: "auto:salvage:PAPOLTR-6-L4")
        let done = run(id: "relay-old", kind: .relayRun, status: .completed, deviceCode: "CARRIER1")
        let live = run(id: "relay-1", kind: .relayRun, deviceCode: "CARRIER1")
        let result = groups(Mine.devices, [Mine.haulRun(), stalled, done, live])
        #expect(
            result.map(\.key) == [
                .automation(name: "salvage", site: "PAPOLTR-6-L4"),
                .automation(name: "mine", site: Mine.belt),
                .mesh,
                .finished,
            ]
        )
        #expect(result[0].attention == .needsAttention)
        #expect(result[1].attention == .working)
    }

    @Test("a paused run raises its group above a working one but below a stall")
    func pausedSortsBetween() {
        let paused = run(id: "haul-2", kind: .haulRun, status: .paused,
                         deviceCode: "FERRY002", fleetTag: "auto:haul:\(Mine.sink)")
        let stalled = run(id: "salvage-1", kind: .salvageRun, status: .needsAttention,
                          deviceCode: "VESSEL01", fleetTag: "auto:salvage:PAPOLTR-6-L4")
        let result = groups(Mine.devices, [Mine.haulRun(), paused, stalled])
        #expect(result.map(\.attention) == [.needsAttention, .paused, .working])
    }
}

@Suite("Fleet tag parsing")
struct AutomationKeyTests {
    @Test("a per-site tag names its own site")
    func perSiteTag() {
        #expect(
            DirectiveGroup.automationKey("auto:mine:GRAZ-BELT-1")
                == .automation(name: "mine", site: "GRAZ-BELT-1")
        )
    }

    @Test("a bare tag takes the site it was given")
    func bareTagTakesSite() {
        #expect(
            DirectiveGroup.automationKey("auto:mine", site: "GRAZ-BELT-1")
                == .automation(name: "mine", site: "GRAZ-BELT-1")
        )
        #expect(DirectiveGroup.automationKey("auto:mine") == .automation(name: "mine", site: nil))
    }

    /// A device's tag is stored lowercased while a directive's is not, and the
    /// two must land in the same group.
    @Test("case drift on either side resolves to one key")
    func caseDriftResolves() {
        #expect(
            DirectiveGroup.automationKey("auto:mine:graz-belt-1")
                == DirectiveGroup.automationKey("AUTO:MINE:GRAZ-BELT-1")
        )
    }

    @Test("a per-site tag wins over the site it was given")
    func perSiteTagWinsOverSite() {
        #expect(
            DirectiveGroup.automationKey("auto:mine:GRAZ-BELT-1", site: "ACHERNUR-BELT-1")
                == .automation(name: "mine", site: "GRAZ-BELT-1")
        )
    }

    @Test("anything that is not a fleet tag is refused", arguments: ["mine", "auto:", "auto", ""])
    func nonFleetTagsRefused(_ tag: String) {
        #expect(DirectiveGroup.automationKey(tag) == nil)
    }
}
