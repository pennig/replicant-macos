//
//  BobnetClientMappingTests.swift
//  Replicould — Bobnet feature
//

import API
import Foundation
import Testing
@testable import BobnetFeature
import GameModels

@Suite struct BobnetClientMappingTests {
    @Test func messageItemMapsAllFields() throws {
        let item = Components.Schemas.AppSchemasDevicesBobnetMessageItemSchema(
            id: 5088,
            replicantName: "Bill",
            replicantCode: "A8F48B26",
            currentStar: "SOL",
            channel: "#general",
            message: "hello",
            time: "2026-07-22T14:52:32-05:00"
        )
        let message = try #require(BobnetMessage(item: item))
        #expect(message.id == 5088)
        #expect(message.replicantName == "Bill")
        #expect(message.replicantCode == "A8F48B26")
        #expect(message.currentStar == "SOL")
        #expect(message.channel == "#general")
        #expect(message.message == "hello")
        #expect(message.time == Date(timeIntervalSince1970: 1_784_749_952))
    }

    @Test func messageItemWithoutIDIsNil() {
        let item = Components.Schemas.AppSchemasDevicesBobnetMessageItemSchema(
            id: nil, channel: "#general", message: "x", time: nil
        )
        #expect(BobnetMessage(item: item) == nil)
    }

    @Test func sendResponseMapsToMessage() throws {
        let body = Components.Schemas.AppSchemasReplicantsReplicantMessageResponseSchema(
            status: "sent",
            id: 6001,
            relayCode: "3AFC718C",
            replicantName: "Matt",
            replicantCode: "99380EDF",
            currentStar: nil,
            channel: "#trade",
            message: "selling rocks",
            time: "2026-07-22T20:00:00.123456Z"
        )
        let message = try #require(BobnetMessage(sendResponse: body))
        #expect(message.id == 6001)
        #expect(message.channel == "#trade")
        #expect(message.currentStar == nil)
    }

    @Test func channelInfoParsesFractionalTimestamp() {
        let info = BobnetChannelInfo(
            name: "#general",
            lastActive: BobnetTimestamp.parse("2026-07-22T19:52:32.066645Z")
        )
        #expect(info.lastActive != nil)
        #expect(info.lastActive != Date(timeIntervalSince1970: 0))
    }

    @Test func unparseableTimestampFallsBackToEpoch() {
        #expect(BobnetTimestamp.parse("not-a-date") == Date(timeIntervalSince1970: 0))
        #expect(BobnetTimestamp.parse(nil) == Date(timeIntervalSince1970: 0))
    }
}
