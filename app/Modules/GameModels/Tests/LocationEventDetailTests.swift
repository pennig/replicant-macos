import Foundation
import Testing
import Utils
@testable import GameModels

@Suite("LocationEventDetail criteria fallback")
struct LocationEventDetailCriteriaTests {
    /// A discovery payload: criteria + rewards, no progress block.
    private var discovered: JSONValue {
        .object([
            "criteria": .array([
                .object([
                    "name": .string("default"),
                    "devices": .array([
                        .object(["count": .number(2), "device_type": .string("comm_satellite")])
                    ]),
                    "resources": .object(["conductive": .number(150)]),
                ])
            ]),
            "rewards": .object(["xp": .number(1500)]),
        ])
    }

    @Test("criteria populate options when progress is absent")
    func criteriaFallback() throws {
        let detail = try #require(LocationEventDetail(discovered))
        #expect(detail.optionsAreFromCriteria)
        #expect(detail.options.count == 1)
        let option = try #require(detail.options.first)
        #expect(option.name == "default")
        #expect(option.met == false)
        #expect(option.resources == [
            .init(resourceType: "conductive", current: 0, required: 150, met: false)
        ])
        #expect(option.devices == [
            .init(deviceType: "comm_satellite", current: 0, required: 2, met: false)
        ])
    }

    @Test("progress still wins when both blocks are present")
    func progressWins() throws {
        let json = discovered.adding("progress", .object([
            "met": .bool(false),
            "replicant_present": .bool(true),
            "options": .array([
                .object([
                    "name": .string("default"),
                    "met": .bool(false),
                    "devices": .array([]),
                    "resources": .array([
                        .object([
                            "resource_type": .string("conductive"),
                            "current": .number(90),
                            "required": .number(150),
                            "met": .bool(false),
                        ])
                    ]),
                ])
            ]),
        ]))
        let detail = try #require(LocationEventDetail(json))
        #expect(detail.optionsAreFromCriteria == false)
        #expect(detail.replicantPresent)
        #expect(detail.options.first?.resources.first?.current == 90)
    }
}
