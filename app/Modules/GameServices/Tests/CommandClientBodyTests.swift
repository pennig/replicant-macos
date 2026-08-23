//
//  CommandClientBodyTests.swift
//  Replicould — GameServices tests
//

import API
import Testing
import Utils
@testable import GameServices

@Suite("enqueue_print body")
struct EnqueuePrintBodyTests {
    @Test("quantity and tags ride the enqueue body when set")
    func quantityAndTags() throws {
        let params = CommandParams(deviceType: "mining_drone", quantity: 3, printTags: ["auto:mine"])
        #expect(params.json["quantity"]?.numberValue == 3)
        #expect(params.json["tags"]?.arrayValue?.compactMap(\.stringValue) == ["auto:mine"])
    }

    @Test("absent quantity and tags stay off the wire")
    func defaultsOmitted() throws {
        let params = CommandParams(deviceType: "ftl_relay")
        #expect(params.json["quantity"] == nil)
        #expect(params.json["tags"] == nil)
    }
}

@Suite("enqueue_print flatpack")
struct EnqueuePrintFlatpackTests {
    @Test("a flatpacked print carries the flag and reaches the enqueue body")
    func flatpackRidesTheBody() throws {
        let params = CommandParams(deviceType: "climate_processor", quantity: 2, flatpack: true)
        #expect(params.json["flatpack"]?.boolValue == true)

        guard case let .json(payload) = try CommandClient.printBody(params),
              case let .enqueuePrint(schema) = payload
        else { return #expect(Bool(false), "expected an enqueue_print body") }
        #expect(schema.flatpack == true)
    }

    @Test("an ordinary print leaves flatpack off the wire entirely")
    func flatpackOmittedWhenUnset() throws {
        let params = CommandParams(deviceType: "ftl_beacon", quantity: 1)
        #expect(params.json["flatpack"] == nil)

        guard case let .json(payload) = try CommandClient.printBody(params),
              case let .enqueuePrint(schema) = payload
        else { return #expect(Bool(false), "expected an enqueue_print body") }
        #expect(schema.flatpack == nil)
    }
}
