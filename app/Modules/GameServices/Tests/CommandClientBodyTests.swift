//
//  CommandClientBodyTests.swift
//  Replicould — GameServices tests
//

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
