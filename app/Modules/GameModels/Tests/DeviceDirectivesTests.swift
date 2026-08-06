//
//  DeviceDirectivesTests.swift
//  GameModelsTests
//
//  Device.availableDirectives — the runtime list vs the per-type fallback.
//

import Foundation
import Testing
import Utils
@testable import GameModels

private extension Device {
    static func ofType(_ deviceType: String, detail: [String: JSONValue] = [:]) -> Device {
        Device(
            deviceCode: "BOT1", deviceType: deviceType, replicantCode: "R1",
            status: "idle", location: "SOL-3", locationName: nil,
            operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [],
            detail: .object(detail),
            updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }
}

@Suite("Device.availableDirectives")
struct DeviceDirectivesTests {
    @Test func aServiceBotOffersServiceEvenWhenTheRowAdvertisesNothing() {
        let bot = Device.ofType("service_bot", detail: [:])
        #expect(bot.availableDirectives == ["patrol", "service"])
    }

    @Test func aRuntimeDirectiveListStillWins() {
        let bot = Device.ofType(
            "service_bot",
            detail: ["available_directives": .array([.string("patrol")])]
        )
        #expect(bot.availableDirectives == ["patrol"])
    }
}
