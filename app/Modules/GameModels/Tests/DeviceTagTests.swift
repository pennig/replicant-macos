//
//  DeviceTagTests.swift
//  GameModelsTests
//
//  Device.hasTag / Device.normalizedTag — the one place a tag is compared.
//
//  The server NORMALISES tags to lowercase. Confirmed live on 2026-08-04: a
//  HEAVEN vessel tagged `auto:tendMesh` from the device inspector read back
//  `auto:tendmesh`, and the brain's exact-match carrier gate refused the very
//  vessel the operator had just opted in. `auto:haul` and `auto:salvage` were
//  only ever safe because they happen to be spelled in lowercase already.
//

import Foundation
import Testing
@testable import GameModels

private extension Device {
    static func tagged(_ tags: [String]) -> Device {
        Device(
            deviceCode: "V1", deviceType: "heaven_vessel", replicantCode: "R1",
            status: "idle", location: "SOL-3", locationName: nil,
            operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: tags,
            detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }
}

@Suite("Device tags are matched the way the server stores them")
struct DeviceTagTests {
    /// The live case, in both directions: the stored tag is lowercase and the
    /// constant asking for it may not be — or the other way round, for a row
    /// written from a local edit before the next sync normalised it.
    @Test("a tag matches regardless of the case on either side", arguments: [
        ("auto:tendmesh", "auto:tendMesh"),
        ("auto:tendMesh", "auto:tendmesh"),
        ("AUTO:TENDMESH", "auto:tendmesh"),
        ("auto:haul", "auto:haul"),
    ])
    func tagMatchingIsCaseInsensitive(stored: String, queried: String) {
        #expect(Device.tagged([stored]).hasTag(queried))
    }

    /// Case-insensitivity must not become "matches anything similar" — a
    /// different tag is still a different tag.
    @Test("a different tag does not match", arguments: [
        "auto:haul", "auto:salvage", "tendmesh", "auto:tendmesh2", "",
    ])
    func unrelatedTagsDoNotMatch(_ queried: String) {
        #expect(!Device.tagged(["auto:tendmesh"]).hasTag(queried))
    }

    @Test("an untagged device carries nothing")
    func untaggedDeviceHasNoTags() {
        #expect(!Device.tagged([]).hasTag("auto:tendmesh"))
    }

    /// One tag among several still resolves — the fleet wears `auto:salvage`
    /// and `auto:haul` alongside each other.
    @Test("one tag among several is found")
    func findsATagAmongOthers() {
        let device = Device.tagged(["auto:salvage", "AUTO:TendMesh", "scratch"])

        #expect(device.hasTag("auto:tendmesh"))
        #expect(device.hasTag("auto:salvage"))
        #expect(!device.hasTag("auto:haul"))
    }

    /// Normalisation is what the editor applies before SENDING, so the tag the
    /// operator sees after the next sync is the one they just typed.
    @Test("normalisation lowercases and trims", arguments: [
        ("  auto:tendMesh  ", "auto:tendmesh"),
        ("AUTO:HAUL", "auto:haul"),
        ("auto:salvage", "auto:salvage"),
        ("\tauto:Foo\n", "auto:foo"),
    ])
    func normalisationLowercasesAndTrims(raw: String, expected: String) {
        #expect(Device.normalizedTag(raw) == expected)
    }

    /// Whitespace around a STORED tag is tolerated too — the comparison
    /// normalises both sides, not just the constant.
    @Test("a stored tag with stray whitespace still matches")
    func storedWhitespaceIsTolerated() {
        #expect(Device.tagged([" auto:tendmesh "]).hasTag("auto:tendmesh"))
    }
}
