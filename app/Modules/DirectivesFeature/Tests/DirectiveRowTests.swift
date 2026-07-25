//
//  DirectiveRowTests.swift
//  Replicould — Directives feature
//
//  The unified list's merge: built-in rows derived from Device state (never
//  persisted) beside custom rows from the Directive table, in one stable order.
//

import Foundation
import GameModels
import Testing
import Utils
@testable import DirectivesFeature

/// A device fixture. `detail` carries the in-force `ami_directive` block when
/// `directive` is set, mirroring what the backend sends.
private func device(
    code: String,
    type: String = "ami_survey_controller",
    directive: String? = nil,
    config: JSONValue? = nil,
    controlled: [JSONValue] = []
) -> Device {
    var detail: [String: JSONValue] = [:]
    if let directive {
        var block: [String: JSONValue] = ["name": .string(directive)]
        if let config { block["config"] = config }
        detail["ami_directive"] = .object(block)
    }
    if !controlled.isEmpty { detail["controlled_devices"] = .array(controlled) }
    return Device(
        deviceCode: code,
        deviceType: type,
        replicantCode: "R1",
        status: "idle",
        location: "ATIANFU-3",
        locationName: nil,
        operationalCapacity: 100,
        queueSize: 0,
        stowedInDeviceCode: nil,
        controllerDeviceCode: nil,
        attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [],
        features: [],
        tags: [],
        detail: .object(detail),
        updatedAt: Date(timeIntervalSince1970: 0),
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func mission(id: String, kind: DirectiveKind = .surveyRun) -> Directive {
    Directive(
        id: id, kind: kind, status: .running, deviceCode: "VESSEL1",
        targets: ["TAU", "SHERATANON"], targetIndex: 1, step: "surveying",
        returnToOrigin: false, originDesignation: "SOL", attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("Directive rows")
struct DirectiveRowTests {
    /// Only devices with a directive in force become built-in rows.
    @Test func derivesBuiltInRowsFromDevicesWithADirective() {
        let rows = DirectiveRow.merge(
            devices: [
                device(code: "AMI1", directive: "survey_system"),
                device(code: "AMI2"),
                device(code: "AMI3", directive: "gather_salvage"),
            ],
            directives: []
        )
        #expect(rows.count == 2)
        #expect(rows.map(\.deviceCode) == ["AMI1", "AMI3"])
    }

    /// A built-in row carries the config and controlled devices the detail pane
    /// renders, straight off the Device row.
    @Test func builtInRowCarriesConfigAndControlledDevices() {
        let rows = DirectiveRow.merge(
            devices: [device(
                code: "AMI1",
                directive: "survey_system",
                config: .object(["planets": .string("all"), "moons": .string("all")]),
                controlled: [.object([
                    "device_code": .string("DRONE1"),
                    "device_type": .string("survey_drone"),
                    "status": .string("tracking"),
                ])]
            )],
            directives: []
        )
        guard case let .builtIn(builtIn)? = rows.first else {
            Issue.record("expected a built-in row")
            return
        }
        #expect(builtIn.directive == "survey_system")
        #expect(builtIn.config?["planets"]?.stringValue == "all")
        #expect(builtIn.controlledDevices.map(\.deviceCode) == ["DRONE1"])
    }

    /// Custom rows and built-in rows coexist; custom rows sort first so an
    /// actively-running mission is never buried under the standing set.
    @Test func customRowsSortAheadOfBuiltIns() {
        let rows = DirectiveRow.merge(
            devices: [device(code: "AMI1", directive: "survey_system")],
            directives: [mission(id: "D1")]
        )
        #expect(rows.count == 2)
        #expect(rows.first?.id == "custom:D1")
        #expect(rows.last?.id == "builtin:AMI1")
    }

    /// Row ids are stable and namespaced, so a device code and a directive id
    /// can never collide in the selection.
    @Test func rowIDsAreNamespaced() {
        let rows = DirectiveRow.merge(
            devices: [device(code: "X", directive: "patrol")],
            directives: [mission(id: "X")]
        )
        #expect(Set(rows.map(\.id)) == ["custom:X", "builtin:X"])
    }

    /// A custom row's title names the mission and its current target.
    @Test func customRowTitleNamesKindAndTarget() {
        let rows = DirectiveRow.merge(devices: [], directives: [mission(id: "D1")])
        #expect(rows.first?.title == "Survey Run → SHERATANON")
    }
}
