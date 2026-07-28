//
//  SurveyScanTests.swift
//  UniverseModels
//
//  `ami.survey.digest` → `report.scans[]` (API v2.3.3): decoding the survey's
//  per-body scan reports, and folding them into a cached `StarSystem` without
//  destroying what the scan doesn't carry.
//
//  Every fixture here is a verbatim capture from the live event log on
//  2026-07-27 (the UDKUDUA survey), not a hand-written approximation.
//

import Foundation
import Testing
import Utils
@testable import UniverseModels

@Suite struct SurveyScanTests {

    // MARK: - Fixtures (verbatim live captures)

    /// A planet scan: physical block plus the sibling `moons` roster.
    static let planetScanDigest = """
    { "directive": "survey_system",
      "report": {
        "assigned_this_tick": 1, "busy": 6, "idle": 0,
        "progress": { "remaining": 8, "scanned": 1, "total": 9 },
        "scans": [
          { "device_code": "A1D08194", "scan_target": "UDKUDUA-7", "scan_type": "planet",
            "report": {
              "planet": {
                "designation": "UDKUDUA-7", "name": null, "type": "Super Earth",
                "atmosphere": "none", "axial_tilt_deg": 45.2, "density_gcc": 5.24,
                "in_habitable_zone": false, "life_stage": "none", "magnetic_field": true,
                "mass_earth": 8.4084, "orbital_distance_au": 1.525,
                "orbital_period_days": 1025.39, "radius_earth": 2.0678, "rings": false,
                "rotation_period_hours": 75, "species_name": null,
                "surface_gravity": 1.97, "surface_temp_c": -140, "surface_temp_k": 133,
                "tags": ["high_gravity", "potential_habitable", "rocky"]
              },
              "moons": [
                { "designation": "UDKUDUA-7-1", "name": null, "scanned": false, "type": "Icy" },
                { "designation": "UDKUDUA-7-2", "name": null, "scanned": false, "type": "Rocky" }
              ]
            } }
        ] } }
    """

    /// A moon scan: physical block with the moon-only fields.
    static let moonScanDigest = """
    { "directive": "survey_system",
      "report": { "scans": [
        { "device_code": "A1D08194", "scan_target": "UDKUDUA-3-2", "scan_type": "moon",
          "report": { "moon": {
            "designation": "UDKUDUA-3-2", "name": null, "type": "Rocky",
            "density_gcc": 1.08, "has_atmosphere": false, "has_subsurface_ocean": false,
            "life_stage": "none", "mass_earth": 0.008208, "orbital_distance_km": 528629.7,
            "orbital_period_hours": 765.94, "radius_earth": 0.3468, "species_name": null,
            "surface_gravity": 0.0682, "surface_temp_c": 65, "surface_temp_k": 338,
            "tags": ["cratered", "rocky"], "tidally_locked": false
          } } }
      ] } }
    """

    /// A moon scan carrying salvage with absolute remaining amounts.
    static let salvageScanDigest = """
    { "report": { "scans": [
      { "device_code": "A697D0E8", "scan_target": "UDKUDUA-4-1", "scan_type": "moon",
        "report": { "moon": {
          "designation": "UDKUDUA-4-1", "type": "Icy", "tidally_locked": true,
          "salvage": [
            { "designation": "UDKUDUA-4-1-SAL-1", "location": "UDKUDUA-4-1",
              "name": "Derelict Survey Probe", "salvage_type": "derelict_probe",
              "depleted": false,
              "resources_remaining": { "conductive": 214, "rares": 64, "silicates": 161 } }
          ] } } }
    ] } }
    """

    private func scans(_ json: String) throws -> SurveyScans {
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try LocationDecoding.surveyScans(from: payload)
    }

    /// The single scan report in each fixture. Separate one-line helpers rather
    /// than an inline `#require` chain: nesting `#require` inside `#require`
    /// makes the macro expand into itself.
    private func planetReport() throws -> SurveyScanReport {
        try #require(scans(Self.planetScanDigest).reports.first)
    }

    private func moonReport() throws -> SurveyScanReport {
        try #require(scans(Self.moonScanDigest).reports.first)
    }

    private func salvageReport() throws -> SurveyScanReport {
        try #require(scans(Self.salvageScanDigest).reports.first)
    }

    // MARK: - Decoding

    @Test func planetScanDecodesEveryPhysicalField() throws {
        let report = try planetReport()
        #expect(report.deviceCode == "A1D08194")

        let body = report.body
        #expect(body.kind == .planet)
        #expect(body.designation == "UDKUDUA-7")
        #expect(body.type == "Super Earth")
        #expect(body.lifeStage == "none")
        #expect(body.inHabitableZone == false)
        #expect(body.orbitalDistanceAu == 1.525)
        #expect(body.systemDesignation == "UDKUDUA")

        let physical = body.physical
        #expect(physical.atmosphere == "none")
        #expect(physical.axialTiltDeg == 45.2)
        #expect(physical.densityGcc == 5.24)
        #expect(physical.magneticField == true)
        #expect(physical.massEarth == 8.4084)
        #expect(physical.orbitalPeriodDays == 1025.39)
        #expect(physical.radiusEarth == 2.0678)
        #expect(physical.rings == false)
        #expect(physical.rotationPeriodHours == 75)
        #expect(physical.surfaceGravity == 1.97)
        #expect(physical.surfaceTempC == -140)
        #expect(physical.surfaceTempK == 133)
        #expect(physical.tags == ["high_gravity", "potential_habitable", "rocky"])
        #expect(physical.speciesName == nil)
    }

    /// The roster hangs off the *report*, beside `planet` — not inside it, the
    /// way a `scan.completed` result nests it. Getting this wrong loses every
    /// moon silently.
    @Test func planetScanDecodesTheSiblingMoonRoster() throws {
        let body = try planetReport().body
        #expect(body.moons.map(\.designation) == ["UDKUDUA-7-1", "UDKUDUA-7-2"])
        #expect(body.moons.map(\.type) == ["Icy", "Rocky"])
        // Seeing that a moon exists is not scanning it.
        #expect(body.moons.allSatisfy { $0.recon == .visited })
    }

    @Test func moonScanDecodesTheMoonOnlyFields() throws {
        let body = try moonReport().body
        #expect(body.kind == .moon)
        #expect(body.designation == "UDKUDUA-3-2")
        #expect(body.type == "Rocky")
        #expect(body.lifeStage == "none")

        let physical = body.physical
        #expect(physical.hasAtmosphere == false)
        #expect(physical.hasSubsurfaceOcean == false)
        #expect(physical.tidallyLocked == false)
        #expect(physical.orbitalDistanceKm == 528629.7)
        #expect(physical.orbitalPeriodHours == 765.94)
        #expect(physical.densityGcc == 1.08)
        #expect(physical.massEarth == 0.008208)
        #expect(physical.radiusEarth == 0.3468)
        #expect(physical.surfaceGravity == 0.0682)
        #expect(physical.surfaceTempC == 65)
        #expect(physical.surfaceTempK == 338)
        #expect(physical.tags == ["cratered", "rocky"])
    }

    @Test func moonScanDecodesSalvageAndItsAbsoluteAmounts() throws {
        let report = try salvageReport()
        let site = try #require(report.body.salvage.first)
        #expect(site.designation == "UDKUDUA-4-1-SAL-1")
        #expect(site.salvageType == "derelict_probe")
        #expect(site.depleted == false)

        let observation = try #require(report.salvage.first)
        #expect(observation.body == "UDKUDUA-4-1")
        #expect(observation.resourcesRemaining == ["conductive": 214, "rares": 64, "silicates": 161])
    }

    @Test func aDigestWithNoScansYieldsNothing() throws {
        let empty = try scans("""
        { "report": { "belt": "ATIANFU-BELT-1", "scans": [], "searching": 2 } }
        """)
        #expect(empty.isEmpty)
        #expect(try scans("{ \"report\": { \"idle\": 0 } }").isEmpty)
        #expect(try scans("{ \"activity\": { \"event_count\": 1 } }").isEmpty)
    }

    /// An unreadable entry must be *counted*, not silently dropped — that count
    /// is what surfaces a `scan_type` this build doesn't handle yet.
    @Test func anUnknownScanTypeIsCountedNotSwallowed() throws {
        let result = try scans("""
        { "report": { "scans": [
          { "device_code": "X", "scan_target": "SOL-BELT-1", "scan_type": "belt",
            "report": { "belt": { "designation": "SOL-BELT-1" } } }
        ] } }
        """)
        #expect(result.reports.isEmpty)
        // Named, not merely counted — the log has to say what to implement.
        #expect(result.unreadable == ["belt"])
        #expect(!result.isEmpty)
    }

    // MARK: - Folding into the tree

    /// The whole reason `BodyObservation` exists rather than reusing
    /// `BodyDetail`: a survey scan carries no devices, sites, or inventory, so
    /// merging one must not read that absence as emptiness.
    @Test func observingAPlanetKeepsWhatTheScanDoesNotCarry() throws {
        let system = StarSystem(
            designation: "UDKUDUA",
            planets: [
                Planet(
                    designation: "UDKUDUA-7", type: "Rocky", typeEstimated: true,
                    recon: .visited,
                    sites: [ResourceSite(designation: "UDKUDUA-7-SITE-0", remaining: ["ferrous": 80])],
                    devices: [LocatedDevice(deviceCode: "ABCD1234", deviceType: "survey_drone")],
                    inventory: [InventoryItem(resourceType: "ferrous", quantity: 42)],
                    lagrange: [SpecialSite(designation: "UDKUDUA-7-L4", kind: .lagrange)]
                )
            ]
        )
        let observation = try planetReport().body
        let merged = system.observing(observation)
        let planet = try #require(merged.planets.first)

        // Untouched by the scan.
        #expect(planet.sites.map(\.designation) == ["UDKUDUA-7-SITE-0"])
        #expect(planet.devices.map(\.deviceCode) == ["ABCD1234"])
        #expect(planet.inventory.map(\.resourceType) == ["ferrous"])
        #expect(planet.lagrange.map(\.designation) == ["UDKUDUA-7-L4"])

        // Written by the scan.
        #expect(planet.type == "Super Earth")
        #expect(planet.typeEstimated == false)
        #expect(planet.recon == .scanned)
        #expect(planet.physical?.axialTiltDeg == 45.2)
        #expect(planet.moonCount == 2)
        #expect(planet.moonCountEstimated == false)
    }

    /// A planet scan lists its moons as stubs. Taking them verbatim would flatten
    /// a moon a previous per-moon scan had fully hydrated.
    @Test func observingAPlanetDoesNotDowngradeAnAlreadyScannedMoon() throws {
        let system = StarSystem(
            designation: "UDKUDUA",
            planets: [
                Planet(
                    designation: "UDKUDUA-7", recon: .visited,
                    moons: [
                        Moon(
                            designation: "UDKUDUA-7-1", type: "Icy", recon: .scanned,
                            physical: BodyPhysical(orbitalPeriodHours: 599.03, tidallyLocked: true),
                            sites: [ResourceSite(designation: "UDKUDUA-7-1-SITE-0")]
                        )
                    ]
                )
            ]
        )
        let observation = try planetReport().body
        let merged = system.observing(observation)
        let moons = try #require(merged.planets.first).moons

        let hydrated = try #require(moons.first { $0.designation == "UDKUDUA-7-1" })
        #expect(hydrated.recon == .scanned)
        #expect(hydrated.physical?.orbitalPeriodHours == 599.03)
        #expect(hydrated.sites.count == 1)

        // …while the moon we hadn't heard of is added.
        #expect(moons.contains { $0.designation == "UDKUDUA-7-2" })
        #expect(moons.count == 2)
    }

    @Test func observingAMoonSeedsItsParentPlanetWhenTheRosterLacksIt() throws {
        let observation = try moonReport().body
        let merged = StarSystem(designation: "UDKUDUA").observing(observation)

        let planet = try #require(merged.planets.first { $0.designation == "UDKUDUA-3" })
        #expect(planet.recon == .aware)   // seeded, not claimed as scanned
        let moon = try #require(planet.moons.first)
        #expect(moon.designation == "UDKUDUA-3-2")
        #expect(moon.recon == .scanned)
        #expect(moon.lifeStage == "none")
        #expect(moon.physical?.tidallyLocked == false)
        #expect(moon.physical?.orbitalPeriodHours == 765.94)
        // A moon we've just met raises the parent's count to what we know of.
        #expect(planet.moonCount == 1)
    }

    @Test func observingAMoonKeepsItsExistingSitesAndDevices() throws {
        let system = StarSystem(
            designation: "UDKUDUA",
            planets: [
                Planet(
                    designation: "UDKUDUA-3", recon: .visited, moonCount: 4,
                    moons: [
                        Moon(
                            designation: "UDKUDUA-3-2", recon: .visited,
                            sites: [ResourceSite(designation: "UDKUDUA-3-2-SITE-0")],
                            devices: [LocatedDevice(deviceCode: "FEED0001", deviceType: "miner")],
                            inventory: [InventoryItem(resourceType: "rares", quantity: 9)]
                        )
                    ]
                )
            ]
        )
        let observation = try moonReport().body
        let merged = system.observing(observation)
        let planet = try #require(merged.planets.first)
        let moon = try #require(planet.moons.first)

        #expect(moon.sites.count == 1)
        #expect(moon.devices.count == 1)
        #expect(moon.inventory.count == 1)
        #expect(moon.recon == .scanned)
        // A known-larger roster count is never reduced by scanning one moon.
        #expect(planet.moonCount == 4)
    }

    /// A scan carries no percentages, so folding one in must not wipe the only
    /// live figures we hold — but `depleted` *is* an observation, so it applies.
    @Test func observingSalvagePreservesPercentagesAndTakesDepletion() throws {
        let system = StarSystem(
            designation: "UDKUDUA",
            planets: [
                Planet(
                    designation: "UDKUDUA-4", recon: .visited,
                    moons: [
                        Moon(
                            designation: "UDKUDUA-4-1", recon: .visited,
                            salvage: [
                                SalvageSite(
                                    designation: "UDKUDUA-4-1-SAL-1", depleted: true,
                                    remainingPct: ["conductive": 30]
                                )
                            ]
                        )
                    ]
                )
            ]
        )
        let observation = try salvageReport().body
        let merged = system.observing(observation)
        let planet = try #require(merged.planets.first)
        let moon = try #require(planet.moons.first)
        let site = try #require(moon.salvage.first)

        #expect(site.remainingPct == ["conductive": 30])   // preserved
        #expect(site.depleted == false)                    // fresh observation wins
        #expect(site.name == "Derelict Survey Probe")      // enriched
    }

    @Test func observingSeedsAPlanetInASystemWeHaveNeverHydrated() throws {
        let observation = try planetReport().body
        let merged = StarSystem(designation: "UDKUDUA", recon: .visited).observing(observation)
        #expect(merged.planets.map(\.designation) == ["UDKUDUA-7"])
        #expect(merged.planets.first?.recon == .scanned)
    }

    // MARK: - Blob compatibility

    /// `speciesName` and `Moon.lifeStage` are new. A `StarSystem` blob written
    /// before they existed must still decode, or every cached system in the
    /// catalog goes unreadable at once.
    @Test func aBlobWithoutTheNewFieldsStillDecodes() throws {
        let legacy = """
        { "designation": "SOL", "recon": "scanned", "systemScanned": true,
          "moonsTotalEstimated": false, "belts": [], "structures": [], "shops": [],
          "events": [],
          "planets": [ { "designation": "SOL-3", "typeEstimated": false,
            "inHabitableZone": true, "recon": "scanned", "moonCountEstimated": false,
            "moons": [ { "designation": "SOL-3-1", "recon": "scanned",
              "sites": [], "salvage": [], "devices": [], "inventory": [],
              "physical": { "tags": [], "orbitalPeriodHours": 655.7 } } ],
            "sites": [], "salvage": [], "devices": [], "inventory": [],
            "lagrange": [], "events": [] } ] }
        """
        let system = try JSONDecoder().decode(StarSystem.self, from: Data(legacy.utf8))
        let moon = try #require(system.planets.first?.moons.first)
        #expect(moon.designation == "SOL-3-1")
        #expect(moon.lifeStage == nil)
        #expect(moon.physical?.orbitalPeriodHours == 655.7)
        #expect(moon.physical?.speciesName == nil)
    }
}
