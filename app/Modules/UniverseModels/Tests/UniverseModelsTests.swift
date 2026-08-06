//
//  UniverseModelsTests.swift
//  UniverseModels
//
//  Decodes captured live `locations/{designation}` payloads through the catalog
//  DTO layer to lock the snake_case field mapping (convertFromSnakeCase) and the
//  DTO → domain assembly against the real server shapes.
//

import API
import Foundation
import Testing
@testable import UniverseModels

@Suite struct UniverseModelsTests {
    @Test func positionDistanceIsEuclidean() {
        let a = Position(x: 0, y: 0, z: 0)
        let b = Position(x: 3, y: 4, z: 0)
        #expect(a.distance(to: b) == 5)
    }

    // MARK: - Location decode (captured live payloads)

    private func decode(_ json: String) throws -> RawLocation {
        try LocationDecoding.decoder.decode(RawLocation.self, from: Data(json.utf8))
    }

    @Test func starLevelDecodesRosterBeltsAndCounts() throws {
        let raw = try decode(Self.solStarJSON)
        let system = try #require(raw.starSystem())

        #expect(system.designation == "SOL")
        #expect(system.star?.stellarClass == "G2")
        #expect(system.star?.miningBonusPct == 20)
        #expect(system.systemScanned == true)
        #expect(system.planetsTotal == 8)
        // `asteroid_belt` (star-level key) must map, not fall on the floor.
        #expect(system.belts.count == 1)
        #expect(system.belts.first?.designation == "SOL-BELT-1")
        #expect(system.belts.first?.richness["silicates"] == "high")
        // Roster planet: scanned SOL-3 in the habitable zone with one moon.
        let earth = try #require(system.planets.first { $0.designation == "SOL-3" })
        #expect(earth.type == "Terrestrial")
        #expect(earth.recon == .scanned)
        #expect(earth.moonCount == 1)
        // All planets scanned + systemScanned ⇒ system reads as fully scanned.
        #expect(system.recon == .scanned)
    }

    @Test func scanStarDecodesTemperatureMassLuminosityAndHabitableZone() throws {
        // These come only from the full scan (`RawScan`); the `locations` GET omits
        // them, so `SystemStar` carries them as optionals.
        let json = """
        {"star": {"designation": "AINALRAM", "stellar_class": "M2", "color": "Red",
                  "temperature_k": 3411, "mass_solar": 0.37, "luminosity_solar": 0.06,
                  "habitable_zone": {"inner_au": 0.24, "outer_au": 0.42}},
         "planets": []}
        """
        let raw = try LocationDecoding.decoder.decode(RawScan.self, from: Data(json.utf8))
        let star = try #require(raw.system()?.star)
        #expect(star.temperatureK == 3411)
        #expect(star.massSolar == 0.37)
        #expect(star.luminositySolar == 0.06)
        #expect(star.habitableZoneInnerAu == 0.24)
        #expect(star.habitableZoneOuterAu == 0.42)
    }

    @Test func generatedLocationDecodeToleratesStarAsteroidBelt() throws {
        // Regression for openapi drift: the location schema omitted `asteroid_belt`
        // with additionalProperties:false, so the GENERATED strict decode
        // (`ok.body.json`) threw on every star location — silently killing GET
        // hydration. Our other tests decode `RawLocation` directly and so missed
        // it. This one goes through the generated type + reinterpret, the real
        // production path. Must not throw, and belts/planets must survive.
        let json = """
        {"location":"TEST","location_type":"star","system_scanned":true,
         "planets_total":2,"planets_scanned":2,
         "star":{"designation":"TEST","stellar_class":"G2","color":"Yellow","position":{"x":1,"y":2,"z":3}},
         "planets":[
           {"designation":"TEST-1","type":"Barren","orbital_distance_au":0.4,"in_habitable_zone":false,"scanned":true,"moon_count":0},
           {"designation":"TEST-2","type":"Ocean World","orbital_distance_au":1.0,"in_habitable_zone":true,"scanned":true,"moon_count":1}],
         "asteroid_belt":{"present":true,"belts":[
           {"designation":"TEST-BELT-1","inner_radius_au":2.0,"outer_radius_au":2.5,"density":"moderate","resources":{"iron":"rich"}}]}}
        """
        let generated = try JSONDecoder().decode(
            Components.Schemas.AppSchemasLocationsLocationResponseSchema.self, from: Data(json.utf8))
        let raw = try LocationDecoding.reinterpret(generated, as: RawLocation.self)
        let system = try #require(raw.starSystem())
        #expect(system.planets.count == 2)
        #expect(system.belts.count == 1)
        #expect(system.belts.first?.designation == "TEST-BELT-1")
    }

    @Test func beltLevelDecodesSitesRemainingAndInventory() throws {
        let raw = try decode(Self.beltJSON)
        let detail = try #require(raw.bodyDetail())
        guard case .belt(let belt) = detail else { Issue.record("expected belt"); return }

        #expect(belt.designation == "SOL-BELT-1")
        #expect(belt.sites.count == 2)
        // `resources_remaining_pct` map must survive snake→camel.
        #expect(belt.sites.first?.remaining["carbon"] == 100)
        #expect(belt.sites.first?.siteIndex == 0)
        // Accumulated stock is distinct from sites.
        #expect(belt.inventory.contains { $0.resourceType == "rares" && $0.quantity == 153 })
        // Devices at a belt come through per-location detail (not the scan blob).
        #expect(belt.devices.count == 1)
        #expect(belt.devices.first?.deviceCode == "AB12CD34")
    }

    @Test func unscannedPlanetBodyDetailStaysVisited() throws {
        // The location endpoint is presence-gated, so it returns a body we're
        // sitting in even when `scanned: false` (estimated type, no physical
        // block). The mapped body must stay `.visited` — marking it `.scanned`
        // made unscanned planets read as "Scanned" in the inspector.
        let raw = try decode(Self.unscannedPlanetJSON)
        let detail = try #require(raw.bodyDetail())
        guard case .planet(let planet) = detail else { Issue.record("expected planet"); return }
        #expect(planet.recon == .visited)
        #expect(planet.typeEstimated == true)
        #expect(planet.physical == nil)          // no physical block until scanned
    }

    @Test func unscannedMoonBodyDetailStaysVisited() throws {
        let raw = try decode(Self.unscannedMoonJSON)
        let detail = try #require(raw.bodyDetail())
        guard case .moon(let moon) = detail else { Issue.record("expected moon"); return }
        #expect(moon.recon == .visited)
        #expect(moon.physical == nil)
    }

    @Test func scannedMoonOmittingFlagStaysScanned() throws {
        // A scanned moon OMITS `scanned` (the endpoint only sends `scanned: false`
        // for unscanned bodies) but carries a full physical block. A missing flag
        // must read as scanned — `scanned ?? false` would wrongly demote it.
        let raw = try decode(Self.scannedMoonNoFlagJSON)
        let detail = try #require(raw.bodyDetail())
        guard case .moon(let moon) = detail else { Issue.record("expected moon"); return }
        #expect(moon.recon == .scanned)
        #expect(moon.physical?.massEarth == 0.003169)   // physical block preserved
    }

    @Test func scannedMoonDecodesItsOrbit() throws {
        // A moon's orbit comes as `orbital_period_hours` — moons never report
        // `orbital_period_days` the way planets do, so this is the ONLY real orbit
        // speed a moon has. It had no DTO field and was silently dropped, which left
        // every moon in the orrery orbiting on a synthetic ladder.
        let raw = try decode(Self.scannedMoonNoFlagJSON)
        let detail = try #require(raw.bodyDetail())
        guard case .moon(let moon) = detail else { Issue.record("expected moon"); return }
        #expect(moon.physical?.orbitalPeriodHours == 165.19)
        // The sibling moon-only fields must keep decoding alongside it.
        #expect(moon.physical?.orbitalDistanceKm == 174286.7)
        #expect(moon.physical?.tidallyLocked == true)
    }

    @Test func planetRefetchKeepsPreviouslyScannedMoonDetail() {
        // A moon fetched individually carries salvage (a `-SAL-` site) + physical.
        // The planet-level response lists that moon as a bare stub — merging the
        // planet must NOT wipe the richer moon detail (the bug behind salvage
        // badges intermittently disappearing after a planet re-fetch).
        let richMoon = Moon(
            designation: "SAFANA-7-15", type: "Rocky", recon: .scanned,
            physical: BodyPhysical(massEarth: 0.0115),
            salvage: [SalvageSite(designation: "SAFANA-7-15-SAL-1", name: "Orbital Debris Field")]
        )
        let system = StarSystem(
            designation: "SAFANA",
            planets: [Planet(designation: "SAFANA-7", recon: .scanned, moons: [richMoon])]
        )
        // Planet-level re-fetch: the moon comes back as a stub with no salvage.
        let stubPlanet = Planet(
            designation: "SAFANA-7", recon: .scanned,
            moons: [Moon(designation: "SAFANA-7-15", type: "Rocky", recon: .scanned)]
        )

        let merged = system.applying(.planet(stubPlanet))
        let moon = try! #require(merged.planets.first?.moons.first { $0.designation == "SAFANA-7-15" })
        #expect(moon.salvage.map(\.designation) == ["SAFANA-7-15-SAL-1"])
        #expect(moon.physical?.massEarth == 0.0115)
        // And it still bubbles up to the system-level salvage roll-up.
        #expect(merged.allSalvageSites.contains { $0.designation == "SAFANA-7-15-SAL-1" })
    }

    @Test func starRefreshDepletesASiteOnAnAlreadyHydratedBody() {
        // A richer cached body is kept wholesale, so its salvage roster must be
        // reconciled site by site or a fresh `depleted` never lands.
        let cached = StarSystem(
            designation: "INIKAWAIY",
            planets: [Planet(
                designation: "INIKAWAIY-4", recon: .scanned,
                physical: BodyPhysical(massEarth: 1.2),
                salvage: [SalvageSite(designation: "INIKAWAIY-4-SAL-1", name: "Derelict Freighter")]
            )]
        )
        let fresh = StarSystem(
            designation: "INIKAWAIY",
            planets: [Planet(
                designation: "INIKAWAIY-4", recon: .visited,
                salvage: [SalvageSite(
                    designation: "INIKAWAIY-4-SAL-1", name: "Derelict Freighter", depleted: true
                )]
            )]
        )

        let merged = cached.mergingSystemDetail(fresh)
        let planet = try! #require(merged.planets.first)
        #expect(planet.physical?.massEarth == 1.2)
        #expect(planet.salvage.map(\.depleted) == [true])
        // What a Salvage Run reads: the body stops being offered.
        #expect(merged.salvageBodies.isEmpty)
    }

    @Test func starRefreshKeepsASiteTheFreshRosterOmits() {
        let cached = StarSystem(
            designation: "INIKAWAIY",
            planets: [Planet(
                designation: "INIKAWAIY-4", recon: .scanned,
                physical: BodyPhysical(massEarth: 1.2),
                salvage: [SalvageSite(designation: "INIKAWAIY-4-SAL-1", name: "Derelict Freighter")]
            )]
        )
        let fresh = StarSystem(
            designation: "INIKAWAIY",
            planets: [Planet(designation: "INIKAWAIY-4", recon: .visited)]
        )

        let merged = cached.mergingSystemDetail(fresh)
        #expect(merged.planets.first?.salvage.map(\.designation) == ["INIKAWAIY-4-SAL-1"])
    }

    @Test func aDepletedSiteStaysDepleted() {
        // Salvage never replenishes, so the flag is sticky — a stale `false` on any
        // later read would put a worked-out body back on offer.
        let cached = StarSystem(
            designation: "INIKAWAIY",
            planets: [Planet(
                designation: "INIKAWAIY-4", recon: .scanned,
                physical: BodyPhysical(massEarth: 1.2),
                salvage: [SalvageSite(designation: "INIKAWAIY-4-SAL-1", depleted: true)]
            )]
        )
        let fresh = StarSystem(
            designation: "INIKAWAIY",
            planets: [Planet(
                designation: "INIKAWAIY-4", recon: .visited,
                salvage: [SalvageSite(designation: "INIKAWAIY-4-SAL-1", depleted: false)]
            )]
        )

        let merged = cached.mergingSystemDetail(fresh)
        #expect(merged.planets.first?.salvage.map(\.depleted) == [true])
    }

    @Test func planetRefetchDepletesASiteOnAnAlreadyScannedMoon() {
        let richMoon = Moon(
            designation: "INIKAWAIY-4-1", recon: .scanned,
            physical: BodyPhysical(massEarth: 0.01),
            salvage: [SalvageSite(designation: "INIKAWAIY-4-1-SAL-1", name: "Wreck")]
        )
        let system = StarSystem(
            designation: "INIKAWAIY",
            planets: [Planet(designation: "INIKAWAIY-4", recon: .scanned, moons: [richMoon])]
        )
        let freshPlanet = Planet(
            designation: "INIKAWAIY-4", recon: .scanned,
            moons: [Moon(
                designation: "INIKAWAIY-4-1", recon: .scanned,
                salvage: [SalvageSite(
                    designation: "INIKAWAIY-4-1-SAL-1", name: "Wreck", depleted: true
                )]
            )]
        )

        let merged = system.applying(.planet(freshPlanet))
        let moon = try! #require(merged.planets.first?.moons.first)
        #expect(moon.physical?.massEarth == 0.01)
        #expect(moon.salvage.map(\.depleted) == [true])
    }

    @Test func planetSalvageDecodesAsOwnType() throws {
        // BETSU-3 roster entry carries a salvage site (research station).
        let raw = try decode(Self.betsuStarJSON)
        let system = try #require(raw.starSystem())
        let b3 = try #require(system.planets.first { $0.designation == "BETSU-3" })
        let salvage = try #require(b3.salvage.first)
        #expect(salvage.designation == "BETSU-3-SAL-1")
        #expect(salvage.salvageType == "research_station")
        #expect(salvage.resourcesAvailable.contains("conductive"))
        #expect(salvage.depleted == false)
        // Salvage bubbles up to the system roll-up.
        #expect(system.allSalvageSites.contains { $0.designation == "BETSU-3-SAL-1" })
    }

    @Test func moonSalvageInResourceSitesMapsToSalvage() throws {
        // The live API returns salvage wreckage inside `resource_sites` tagged
        // `site_type: "salvage"` (not a dedicated `salvage` block). It must land
        // in the salvage roster, not among mining sites.
        let raw = try decode(Self.salvageMoonJSON)
        let detail = try #require(raw.bodyDetail())
        guard case .moon(let moon) = detail else { Issue.record("expected moon"); return }
        // The mining site stays a site; the salvage-typed one becomes salvage.
        #expect(moon.sites.map(\.designation) == ["SHERATANON-6-1-SITE-0"])
        let salvage = try #require(moon.salvage.first)
        #expect(salvage.designation == "SHERATANON-6-1-SAL-1")
        #expect(salvage.name == "Abandoned Habitat Module")
        // And it surfaces through the system-level salvage accessor used by the
        // gather_salvage picker.
        let system = StarSystem(
            designation: "SHERATANON",
            planets: [Planet(designation: "SHERATANON-6", recon: .scanned,
                             moons: [Moon(designation: "SHERATANON-6-1")])]
        ).applying(detail)
        #expect(system.knownSalvageSites.contains { $0.designation == "SHERATANON-6-1-SAL-1" })
    }

    @Test func knownSalvageSitesRecoversLegacyResourceSiteSalvage() {
        // A catalog blob persisted before salvage was split out still holds the
        // salvage row among `sites` (a plain ResourceSite). `knownSalvageSites`
        // recovers it by its `…-SAL-N` designation, so the picker isn't empty.
        let system = StarSystem(
            designation: "SHERATANON",
            planets: [Planet(
                designation: "SHERATANON-6", recon: .scanned,
                moons: [Moon(
                    designation: "SHERATANON-6-26", recon: .scanned,
                    sites: [ResourceSite(designation: "SHERATANON-6-26-SAL-1", name: "Crashed Vessel")]
                )]
            )]
        )
        #expect(system.allSalvageSites.isEmpty)
        #expect(system.knownSalvageSites.map(\.designation) == ["SHERATANON-6-26-SAL-1"])
    }

    @Test func scanCompleteResultDecodesMoonSalvage() throws {
        // A `scan.completed` stream event's `result` folds salvage inside the body
        // and keys it by `resources_remaining` — it must still decode to a moon
        // BodyDetail with its salvage.
        let raw = try LocationDecoding.decoder.decode(RawScanEventResult.self, from: Data(Self.scanResultJSON.utf8))
        let detail = try #require(raw.bodyDetail())
        guard case .moon(let moon) = detail else { Issue.record("expected moon"); return }
        #expect(moon.designation == "SHERATANON-6-26")
        #expect(moon.physical?.massEarth == 0.0185)  // physical block came along
        let salvage = try #require(moon.salvage.first)
        #expect(salvage.designation == "SHERATANON-6-26-SAL-1")
        #expect(salvage.name == "Crashed Vessel")
        #expect(salvage.salvageType == "crashed_vessel")
        // `resources_remaining` keys become the available-resource list.
        #expect(salvage.resourcesAvailable == ["carbon", "conductive", "structural"])
    }

    @Test func seedingParentFoldsScanResultIntoUnhydratedSystem() throws {
        // Ingesting a scan result for a system we've never hydrated must not drop
        // the moon for lack of a parent planet: seed the parent, then attach.
        let raw = try LocationDecoding.decoder.decode(RawScanEventResult.self, from: Data(Self.scanResultJSON.utf8))
        let detail = try #require(raw.bodyDetail())
        let system = StarSystem(designation: "SHERATANON")
            .seedingParent(of: detail)
            .applying(detail)
        #expect(system.knownSalvageSites.map(\.designation) == ["SHERATANON-6-26-SAL-1"])
    }

    @Test func restoringSalvagePercentagesSurvivesAScanMerge() throws {
        // `applying(_:)` replaces a body's salvage wholesale, and a
        // `scan.completed` body carries `resources_remaining` but never
        // `resources_remaining_pct` — so a scan would silently wipe percentages
        // a hydrate had established. Restore them across the merge.
        let hydrated = StarSystem(
            designation: "SHERATANON",
            planets: [Planet(
                designation: "SHERATANON-6",
                moons: [Moon(
                    designation: "SHERATANON-6-26",
                    salvage: [SalvageSite(
                        designation: "SHERATANON-6-26-SAL-1",
                        resourcesAvailable: ["carbon", "conductive", "structural"],
                        remainingPct: ["structural": 30, "conductive": 100]
                    )]
                )]
            )]
        )
        let knownPct = hydrated.knownSalvageSites.reduce(into: [String: [String: Double]]()) {
            $0[$1.designation] = $1.remainingPct
        }

        let raw = try LocationDecoding.decoder.decode(RawScanEventResult.self, from: Data(Self.scanResultJSON.utf8))
        let detail = try #require(raw.bodyDetail())
        let clobbered = hydrated.seedingParent(of: detail).applying(detail)
        // Precondition: the merge really does drop them.
        #expect(clobbered.knownSalvageSites.first?.remainingPct.isEmpty == true)

        let restored = clobbered.restoringSalvagePercentages(knownPct)
        let site = try #require(restored.knownSalvageSites.first)
        #expect(site.designation == "SHERATANON-6-26-SAL-1")
        #expect(site.remainingPct == ["structural": 30, "conductive": 100])
        // The scan's own contribution is still there.
        #expect(site.name == "Crashed Vessel")
    }

    @Test func restoringSalvagePercentagesLeavesFresherDataAlone() {
        // Fresher wins: a merged site that already carries percentages keeps
        // them, and a site with no remembered percentage is left untouched
        // rather than zero-filled.
        let system = StarSystem(
            designation: "TAANSI",
            planets: [Planet(
                designation: "TAANSI-6",
                salvage: [
                    SalvageSite(designation: "TAANSI-6-SAL-1", remainingPct: ["conductive": 12]),
                    SalvageSite(designation: "TAANSI-6-SAL-2"),
                ]
            )]
        )
        let restored = system.restoringSalvagePercentages([
            "TAANSI-6-SAL-1": ["conductive": 100],   // stale — must not win
            "TAANSI-6-SAL-3": ["rares": 50],         // not on the tree — ignored
        ])
        let sites = Dictionary(uniqueKeysWithValues: restored.knownSalvageSites.map { ($0.designation, $0) })
        #expect(sites["TAANSI-6-SAL-1"]?.remainingPct == ["conductive": 12])
        #expect(sites["TAANSI-6-SAL-2"]?.remainingPct.isEmpty == true)
        #expect(sites.count == 2)
    }

    /// A scan that newly flags a site depleted must not have its remembered
    /// percentages restored — they describe a site that no longer holds
    /// anything, and the inspector would read "Depleted · ~339 units", claiming
    /// live tonnage at a spent site.
    @Test func restoringSalvagePercentagesSkipsDepletedSites() {
        let system = StarSystem(
            designation: "TAANSI",
            planets: [Planet(
                designation: "TAANSI-6",
                moons: [Moon(
                    designation: "TAANSI-6-1",
                    salvage: [SalvageSite(designation: "TAANSI-6-1-SAL-1", depleted: true)]
                )],
                salvage: [
                    SalvageSite(designation: "TAANSI-6-SAL-1", depleted: true),
                    SalvageSite(designation: "TAANSI-6-SAL-2", depleted: false),
                ]
            )]
        )
        let restored = system.restoringSalvagePercentages([
            "TAANSI-6-SAL-1": ["structural": 60],     // depleted — must stay empty
            "TAANSI-6-SAL-2": ["structural": 60],     // live — must be restored
            "TAANSI-6-1-SAL-1": ["carbon": 40],       // depleted, on a moon — must stay empty
        ])
        let sites = Dictionary(uniqueKeysWithValues: restored.knownSalvageSites.map { ($0.designation, $0) })
        #expect(sites["TAANSI-6-SAL-1"]?.remainingPct.isEmpty == true)
        #expect(sites["TAANSI-6-SAL-2"]?.remainingPct == ["structural": 60])
        #expect(sites["TAANSI-6-1-SAL-1"]?.remainingPct.isEmpty == true)
    }

    @Test func updatingSalvageMarksBodySiteDepleted() {
        // `updatingSalvage(at:)` is the body-keyed *primitive*: it hands the
        // transform every salvage site on the named body. Depletion no longer
        // uses it that way — `salvage.depleted` names ONE site, and
        // `LocationsClient.mutateSalvage(atSite:)` filters to that designation
        // inside the transform — but the primitive still visits by body, which
        // is what this exercises.
        let system = StarSystem(
            designation: "SHERATANON",
            planets: [Planet(
                designation: "SHERATANON-7", recon: .scanned,
                moons: [Moon(
                    designation: "SHERATANON-7-4", recon: .scanned,
                    salvage: [SalvageSite(designation: "SHERATANON-7-4-SAL-1",
                                          resourcesAvailable: ["rares", "silicates"])]
                )]
            )]
        )
        let updated = system.updatingSalvage(at: "SHERATANON-7-4") { $0.depleted = true; $0.resourcesAvailable = [] }
        let site = updated.knownSalvageSites.first { $0.designation == "SHERATANON-7-4-SAL-1" }
        #expect(site?.depleted == true)
        #expect(site?.resourcesAvailable.isEmpty == true)
        // A body with no matching salvage is returned unchanged.
        #expect(system.updatingSalvage(at: "SHERATANON-9-1") { $0.depleted = true } == system)
    }

    @Test func updatingSalvageDropsOneResource() {
        // A `salvage_resource_depleted` event prunes just the named resource.
        let system = StarSystem(
            designation: "SHERATANON",
            planets: [Planet(
                designation: "SHERATANON-7", recon: .scanned,
                moons: [Moon(
                    designation: "SHERATANON-7-4", recon: .scanned,
                    salvage: [SalvageSite(designation: "SHERATANON-7-4-SAL-1",
                                          resourcesAvailable: ["rares", "silicates"])]
                )]
            )]
        )
        let updated = system.updatingSalvage(at: "SHERATANON-7-4") { $0.resourcesAvailable.removeAll { $0 == "rares" } }
        let site = updated.knownSalvageSites.first { $0.designation == "SHERATANON-7-4-SAL-1" }
        #expect(site?.resourcesAvailable == ["silicates"])
        #expect(site?.depleted == false)
    }

    @Test func salvageBodiesGroupSitesAndSkipDepleted() {
        // gather_salvage targets a body; the picker groups sites by body, counts
        // them, and drops bodies whose salvage is all depleted.
        let system = StarSystem(
            designation: "SHERATANON",
            planets: [Planet(
                designation: "SHERATANON-7", recon: .scanned,
                moons: [
                    Moon(designation: "SHERATANON-7-4", name: "Wreckyard", recon: .scanned,
                         salvage: [
                            SalvageSite(designation: "SHERATANON-7-4-SAL-1"),
                            SalvageSite(designation: "SHERATANON-7-4-SAL-2"),
                         ]),
                    Moon(designation: "SHERATANON-7-9", recon: .scanned,
                         salvage: [SalvageSite(designation: "SHERATANON-7-9-SAL-1", depleted: true)]),
                ]
            )]
        )
        let bodies = system.salvageBodies
        // Only the body with live salvage; the all-depleted one drops out.
        #expect(bodies.map(\.designation) == ["SHERATANON-7-4"])
        let body = try! #require(bodies.first)
        #expect(body.siteCount == 2)
        #expect(body.displayName == "Wreckyard")  // uses the body name when present
    }

    @Test func salvageBodyDesignationDerivesFromSiteWhenLocationMissing() {
        // A site recovered from resource_sites carries no `location`; the body is
        // still derived by stripping the trailing "-SAL-N".
        let site = SalvageSite(designation: "SHERATANON-6-26-SAL-1")
        #expect(site.bodyDesignation == "SHERATANON-6-26")
    }

    @Test func applyingMoonDetailPreservesSiblingMoons() {
        // A planet already hydrated with two moons; scanning one must not drop
        // the other (regression: the reducer used to rebuild from the moonless
        // star roster and clobber the sibling).
        let system = StarSystem(
            designation: "SOL",
            planets: [
                Planet(
                    designation: "SOL-3", recon: .scanned,
                    moons: [Moon(designation: "SOL-3-1"), Moon(designation: "SOL-3-2")]
                )
            ]
        )
        let detailed = BodyDetail.moon(
            Moon(designation: "SOL-3-1", type: "Rocky", recon: .scanned,
                 physical: BodyPhysical(massEarth: 0.0123))
        )
        let merged = system.applying(detailed)
        let planet = merged.planets.first { $0.designation == "SOL-3" }
        #expect(planet?.moons.map(\.designation) == ["SOL-3-1", "SOL-3-2"])
        #expect(planet?.moons.first { $0.designation == "SOL-3-1" }?.physical?.massEarth == 0.0123)
    }

    @Test func footprintDecodesCounts() throws {
        let raw = try LocationDecoding.decoder.decode(RawFootprint.self, from: Data(Self.footprintJSON.utf8))
        let counts = (raw.locations ?? [:]).mapValues(\.domain)
        #expect(counts["SOL-3"]?.devices == 1)
        #expect(counts["ATIANFU-BELT-1"]?.resources == 1577)
    }
}

// MARK: - Captured fixtures (trimmed from live `replicant raw GET`)

extension UniverseModelsTests {
    static let solStarJSON = """
    {
      "planets_scanned": 8, "moons_scanned": 28, "system_scanned": true,
      "location": "SOL", "location_type": "star", "planets_total": 8, "moons_total": 28,
      "moons_total_estimated": false, "entry_point": "SOL-5-L4",
      "star": { "age_my": 4600, "color": "yellow-white", "stellar_class": "G2",
                "distance_from_sol": 0, "mining_bonus_pct": 20, "designation": "SOL",
                "position": { "x": 0, "y": 0, "z": 0 } },
      "planets": [
        { "scanned": true, "type": "Barren", "type_estimated": false, "moon_count": 0,
          "designation": "SOL-1", "orbital_distance_au": 0.387, "inventory": [] },
        { "scanned": true, "type": "Terrestrial", "type_estimated": false, "moon_count": 1,
          "designation": "SOL-3", "orbital_distance_au": 1, "in_habitable_zone": true, "inventory": [] }
      ],
      "asteroid_belt": { "present": true, "belts": [
        { "density": "moderate", "inner_radius_au": 2.1, "outer_radius_au": 3.3,
          "designation": "SOL-BELT-1",
          "resources": { "carbon": "moderate", "silicates": "high", "structural": "moderate" } }
      ] }
    }
    """

    static let beltJSON = """
    {
      "location": "SOL-BELT-1", "location_type": "belt",
      "resource_sites": [
        { "site_index": 0, "designation": "SOL-BELT-1-SITE-0", "name": "SOL-BELT-1 Primary Site",
          "resources_remaining_pct": { "carbon": 100, "silicates": 100, "rares": 100 } },
        { "site_index": 3, "designation": "SOL-BELT-1-SITE-3", "name": "SOL-BELT-1 Site 3",
          "resources_remaining_pct": { "carbon": 100 } }
      ],
      "devices": [ { "device_code": "AB12CD34", "device_type": "mining_rig", "status": "idle" } ],
      "inventory": [ { "quantity": 153, "resource_type": "rares" } ],
      "belt": { "density": "moderate", "inner_radius_au": 2.1, "outer_radius_au": 3.3,
                "designation": "SOL-BELT-1", "resources": { "carbon": "moderate" } }
    }
    """

    // Captured live `locations/SAFANA-1`: a planet we're present in but haven't
    // scanned (`scanned: false`, estimated type, no physical fields).
    static let unscannedPlanetJSON = """
    {
      "location": "SAFANA-1", "location_type": "planet", "scanned": false,
      "planet": { "scanned": false, "type": "Desert World", "location_type": "Desert World",
                  "moon_count": 1, "moon_count_estimated": true, "designation": "SAFANA-1",
                  "orbital_distance_au": 0.312, "name": null, "in_habitable_zone": false },
      "resource_sites": [], "devices": [], "inventory": []
    }
    """

    static let unscannedMoonJSON = """
    {
      "location": "SAFANA-1-1", "location_type": "moon", "scanned": false,
      "moon": { "scanned": false, "type": "Rocky", "designation": "SAFANA-1-1", "name": null },
      "resource_sites": [], "devices": [], "inventory": []
    }
    """

    // Captured live `locations/SAFANA-5-2`: a scanned moon that OMITS `scanned`
    // yet carries a full physical block.
    static let scannedMoonNoFlagJSON = """
    {
      "location": "SAFANA-5-2", "location_type": "moon",
      "moon": { "designation": "SAFANA-5-2", "type": "Icy", "location_type": "Icy", "name": null,
                "mass_earth": 0.003169, "radius_earth": 0.1194, "density_gcc": 10.26,
                "surface_gravity": 0.2222, "surface_temp_c": -80, "surface_temp_k": 193,
                "orbital_distance_km": 174286.7, "orbital_period_hours": 165.19,
                "tidally_locked": true, "has_atmosphere": false, "has_subsurface_ocean": false,
                "life_stage": "none", "tags": ["frozen_surface", "icy"] },
      "resource_sites": [], "devices": [], "inventory": []
    }
    """

    static let betsuStarJSON = """
    {
      "location": "BETSU", "location_type": "star", "system_scanned": true,
      "planets_scanned": 10, "planets_total": 10,
      "star": { "stellar_class": "K2", "color": "Orange", "designation": "BETSU",
                "distance_from_sol": 37.47, "position": { "x": -8.7, "y": -36.4, "z": -1.5 } },
      "planets": [
        { "scanned": true, "type": "Desert World", "type_estimated": false, "moon_count": 1,
          "designation": "BETSU-3", "orbital_distance_au": 0.37, "inventory": [],
          "salvage": [ { "resources_available": ["conductive", "silicates", "rares"],
                         "depleted": false, "salvage_type": "research_station",
                         "designation": "BETSU-3-SAL-1", "location": "BETSU-3",
                         "name": "Abandoned Research Station" } ] }
      ]
    }
    """

    static let salvageMoonJSON = """
    {
      "location": "SHERATANON-6-1", "location_type": "moon",
      "moon": { "designation": "SHERATANON-6-1", "type": "Rocky" },
      "resource_sites": [
        { "site_index": 0, "designation": "SHERATANON-6-1-SITE-0", "name": "Primary Site",
          "site_type": "mining", "resources_remaining_pct": { "silicates": 80 } },
        { "site_index": 1, "designation": "SHERATANON-6-1-SAL-1", "name": "Abandoned Habitat Module",
          "site_type": "salvage", "resources_remaining_pct": { "conductive": 40, "rares": 12 } }
      ],
      "devices": [], "inventory": []
    }
    """

    /// The `result` block of a real `scan.completed` stream event (moon scan).
    static let scanResultJSON = """
    {
      "moon": {
        "designation": "SHERATANON-6-26", "name": null, "type": "Rocky",
        "orbital_distance_km": 840622.6, "orbital_period_hours": 361.88,
        "mass_earth": 0.0185, "radius_earth": 0.3088, "density_gcc": 3.46,
        "surface_gravity": 0.194, "surface_temp_k": 129, "surface_temp_c": -144,
        "has_atmosphere": false, "tidally_locked": true, "has_subsurface_ocean": false,
        "life_stage": "none", "tags": ["cratered", "rocky"],
        "salvage": [
          { "designation": "SHERATANON-6-26-SAL-1", "salvage_type": "crashed_vessel",
            "name": "Crashed Vessel", "location": "SHERATANON-6-26",
            "resources_remaining": { "structural": 339, "conductive": 226, "carbon": 113 },
            "depleted": false }
        ]
      }
    }
    """

    static let footprintJSON = """
    {
      "locations": {
        "SOL-3": { "location_events": 1, "devices": 1, "resource_sites": 0, "resources": 0, "replicants": 1 },
        "ATIANFU-BELT-1": { "location_events": 0, "devices": 1, "resource_sites": 0, "resources": 1577, "replicants": 0 }
      }
    }
    """
}
