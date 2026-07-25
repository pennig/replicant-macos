//
//  SalvageEventPayloadTests.swift
//  GameServices
//
//  Salvage events are targeted by their PAYLOAD, never the envelope: the
//  envelope's `location` is the acting device's position. Captured from live
//  `salvage.discovered` events on 2026-07-25.
//

import API
import Foundation
import Testing
import Utils
@testable import GameServices

@Suite struct SalvageEventPayloadTests {
    private func payload(_ json: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        guard case .object(let object) = value else {
            Issue.record("expected an object"); return [:]
        }
        return object
    }

    /// A real `salvage.discovered` payload. Note `location` is the BODY
    /// (`TAANSI-6`) — the envelope on this event said `TAANSI-5-L4`.
    @Test func discoveryParsesTheLivePayload() throws {
        let p = try payload("""
        { "salvage_type": "derelict_probe",
          "resources": { "conductive": 331, "rares": 99, "silicates": 248 },
          "designation": "TAANSI-6-SAL-1", "location": "TAANSI-6",
          "name": "Derelict Survey Probe" }
        """)
        let d = try #require(SalvageEventPayload.discovery(from: p))
        #expect(d.designation == "TAANSI-6-SAL-1")
        #expect(d.body == "TAANSI-6")
        #expect(d.name == "Derelict Survey Probe")
        #expect(d.salvageType == "derelict_probe")
        #expect(d.resources == ["conductive": 331, "rares": 99, "silicates": 248])
    }

    /// Without an explicit `location`, the body is derived by dropping `-SAL-N`.
    @Test func discoveryDerivesTheBodyFromTheDesignation() throws {
        let p = try payload("""
        { "designation": "TAANSI-6-5-SAL-1", "resources": { "carbon": 119 } }
        """)
        let d = try #require(SalvageEventPayload.discovery(from: p))
        #expect(d.body == "TAANSI-6-5")
    }

    @Test func discoveryIsNilWithoutADesignation() throws {
        let p = try payload(#"{ "resources": { "carbon": 119 } }"#)
        #expect(SalvageEventPayload.discovery(from: p) == nil)
    }

    @Test func discoveryToleratesAMissingResourcesMap() throws {
        let p = try payload(#"{ "designation": "TAANSI-6-SAL-1", "location": "TAANSI-6" }"#)
        let d = try #require(SalvageEventPayload.discovery(from: p))
        #expect(d.resources.isEmpty)
    }

    /// The documented key is `site`.
    @Test func depletedSiteReadsTheSiteKey() throws {
        let p = try payload(#"{ "site": "TAANSI-6-SAL-1" }"#)
        #expect(SalvageEventPayload.depletedSite(from: p) == "TAANSI-6-SAL-1")
    }

    /// Tolerant, because that key came from the docs catalogue rather than a
    /// live probe: accept `designation` and `location` as fallbacks, in order.
    @Test func depletedSiteFallsBackToDesignationThenLocation() throws {
        #expect(SalvageEventPayload.depletedSite(
            from: try payload(#"{ "designation": "TAANSI-6-SAL-1" }"#)) == "TAANSI-6-SAL-1")
        #expect(SalvageEventPayload.depletedSite(
            from: try payload(#"{ "location": "TAANSI-6-SAL-1" }"#)) == "TAANSI-6-SAL-1")
        #expect(SalvageEventPayload.depletedSite(from: try payload("{}")) == nil)
    }

    @Test func depletedSitePrefersSiteOverTheOtherKeys() throws {
        let p = try payload("""
        { "site": "TAANSI-6-SAL-1", "designation": "WRONG", "location": "TAANSI-5-L4" }
        """)
        #expect(SalvageEventPayload.depletedSite(from: p) == "TAANSI-6-SAL-1")
    }
}
