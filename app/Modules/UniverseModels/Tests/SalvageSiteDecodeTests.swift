//
//  SalvageSiteDecodeTests.swift
//  UniverseModels
//
//  `SalvageSite` is persisted inside the `StarSystem` blob in `systemDetails`,
//  so adding a stored property is a data-compatibility change: synthesized
//  Decodable ignores property defaults and throws `keyNotFound`, which would
//  make every blob written before this change undecodable.
//

import Foundation
import Testing
@testable import UniverseModels

@Suite struct SalvageSiteDecodeTests {
    /// A blob written before `remainingPct` existed must still decode.
    @Test func decodesABlobWrittenWithoutRemainingPct() throws {
        let json = """
        { "designation": "TAANSI-6-SAL-1", "name": "Derelict Survey Probe",
          "salvageType": "derelict_probe", "location": "TAANSI-6",
          "resourcesAvailable": ["conductive", "rares"], "depleted": false }
        """
        let site = try JSONDecoder().decode(SalvageSite.self, from: Data(json.utf8))
        #expect(site.designation == "TAANSI-6-SAL-1")
        #expect(site.resourcesAvailable == ["conductive", "rares"])
        #expect(site.remainingPct == [:])
    }

    @Test func decodesABlobCarryingRemainingPct() throws {
        let json = """
        { "designation": "TAANSI-6-SAL-1", "resourcesAvailable": ["conductive"],
          "depleted": false, "remainingPct": { "conductive": 40 } }
        """
        let site = try JSONDecoder().decode(SalvageSite.self, from: Data(json.utf8))
        #expect(site.remainingPct == ["conductive": 40])
    }

    @Test func roundTripsThroughEncodeAndDecode() throws {
        let site = SalvageSite(
            designation: "TAANSI-6-SAL-1", name: "Derelict Survey Probe",
            salvageType: "derelict_probe", location: "TAANSI-6",
            resourcesAvailable: ["conductive"], depleted: false,
            remainingPct: ["conductive": 40]
        )
        let data = try JSONEncoder().encode(site)
        #expect(try JSONDecoder().decode(SalvageSite.self, from: data) == site)
    }

    /// The live API returns salvage inside `resource_sites` with
    /// `site_type: "salvage"`; the percentages must survive, not just the keys.
    @Test func salvageTypedResourceSiteKeepsItsPercentages() throws {
        let json = """
        {
          "location": "SHERATANON-6-1", "location_type": "moon",
          "moon": { "designation": "SHERATANON-6-1", "type": "Rocky" },
          "resource_sites": [
            { "site_index": 1, "designation": "SHERATANON-6-1-SAL-1",
              "name": "Abandoned Habitat Module", "site_type": "salvage",
              "resources_remaining_pct": { "conductive": 40, "rares": 12 } }
          ],
          "devices": [], "inventory": []
        }
        """
        let raw = try LocationDecoding.decoder.decode(RawLocation.self, from: Data(json.utf8))
        let detail = try #require(raw.bodyDetail())
        guard case .moon(let moon) = detail else { Issue.record("expected a moon"); return }
        let site = try #require(moon.salvage.first)
        #expect(site.designation == "SHERATANON-6-1-SAL-1")
        #expect(site.remainingPct == ["conductive": 40, "rares": 12])
        #expect(site.resourcesAvailable == ["conductive", "rares"])
        #expect(site.depleted == false)
    }
}
