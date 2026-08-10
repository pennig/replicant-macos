//
//  LocationsFeatureTests.swift
//  LocationsFeature
//

import ComposableArchitecture
import GameDatabase
import SQLiteData
import Testing
import UniverseModels
@testable import LocationsFeature

@Suite struct LocationsFeatureTests {
    /// Composes the tree the way the feature does — rows from stored summaries,
    /// a system's children built from its blob only once it is expanded — so
    /// these assertions read against the whole thing rather than half of it.
    private func tree(
        stars: [Star],
        systems: [String: StarSystem],
        footprints: [String: LocationCounts] = [:],
        myPosition: Position? = nil,
        filter: LocationFilter = .all,
        sort: LocationSort = .alphabetical
    ) -> [LocationNode] {
        let index = LocationInventoryIndex(footprints: footprints)
        return LocationTree.forest(
            stars: stars,
            summaries: systems.mapValues(SystemSummary.init),
            footprints: footprints,
            myPosition: myPosition,
            filter: filter,
            sort: sort
        ).map { node in
            guard let system = systems[node.id] else { return node }
            var expanded = node
            expanded.children = LocationTree.children(of: system, index: index)
            return expanded
        }
    }

    @Test func forestFiltersUnexploredAndBuildsHierarchy() {
        let sol = Star(
            designation: "SOL", spectralType: "G2", color: "yellow-white",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 8,
            explored: true, hasLife: true, entryPoint: "SOL-5-L4", createdAt: .distantPast
        )
        let dabah = Star(
            designation: "DABAH", spectralType: "M9", color: "Red",
            positionX: 5, positionY: 0, positionZ: 0, estimatedPlanets: 6,
            explored: false, hasLife: nil, entryPoint: nil, createdAt: .distantPast
        )
        let system = StarSystem(
            designation: "SOL", systemScanned: true, planetsScanned: 1, planetsTotal: 1,
            belts: [Belt(designation: "SOL-BELT-1", sites: [ResourceSite(designation: "SOL-BELT-1-SITE-0")])],
            planets: [Planet(designation: "SOL-3", type: "Terrestrial", recon: .scanned,
                             moons: [Moon(designation: "SOL-3-1")])]
        )

        let all = tree(
            stars: [sol, dabah], systems: ["SOL": system], footprints: [:],
            myPosition: nil, filter: .all, sort: .alphabetical
        )
        #expect(all.map(\.id) == ["DABAH", "SOL"])
        let solNode = try! #require(all.first { $0.id == "SOL" })
        // Belt + planet as children; the planet lists its moon followed by its five
        // Lagrange points.
        #expect(solNode.children?.map(\.id) == ["SOL-BELT-1", "SOL-3"])
        #expect(solNode.children?.first(where: { $0.id == "SOL-3" })?.children?.map(\.id)
            == ["SOL-3-1", "SOL-3-L1", "SOL-3-L2", "SOL-3-L3", "SOL-3-L4", "SOL-3-L5"])

        let explored = tree(
            stars: [sol, dabah], systems: [:], footprints: [:],
            myPosition: nil, filter: .explored, sort: .alphabetical
        )
        #expect(explored.map(\.id) == ["SOL"])
    }

    /// Every planet lists its five Lagrange points after its moons, even before
    /// hydration; a hydrated point flags its stored inventory and stationed devices
    /// (which also roll up onto the parent planet), while an empty point is bare.
    @Test func planetListsLagrangePointsAfterMoons() {
        let star = Star(
            designation: "SOL", spectralType: "G2", color: "yellow-white",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 8,
            explored: true, hasLife: nil, entryPoint: nil, createdAt: .distantPast
        )
        // SOL-5's L4 has been hydrated with a stored resource and a stationed device.
        let l4 = SpecialSite(
            designation: "SOL-5-L4", kind: .lagrange, parentBody: "SOL-5",
            inventory: [InventoryItem(resourceType: "iron", quantity: 42)],
            devices: [LocatedDevice(deviceCode: "AB12", deviceType: "miner")]
        )
        let system = StarSystem(
            designation: "SOL", systemScanned: true,
            planets: [Planet(designation: "SOL-5", type: "Gas Giant", recon: .scanned,
                             lagrange: [l4])]
        )

        let forest = tree(
            stars: [star], systems: ["SOL": system], footprints: [:],
            myPosition: nil, filter: .all, sort: .alphabetical
        )
        let planet = try! #require(forest.first?.children?.first { $0.id == "SOL-5" })
        // Moonless planet still gets L1–L5, in order.
        #expect(planet.children?.map(\.id)
            == ["SOL-5-L1", "SOL-5-L2", "SOL-5-L3", "SOL-5-L4", "SOL-5-L5"])
        #expect(planet.children?.allSatisfy { $0.kind == .lagrange } == true)

        let l4Node = try! #require(planet.children?.first { $0.id == "SOL-5-L4" })
        #expect(l4Node.badges.contains { $0.symbol == "shippingbox" })
        #expect(l4Node.badges.contains { $0.symbol == "circle.hexagongrid" && $0.count == 1 })

        let l1Node = try! #require(planet.children?.first { $0.id == "SOL-5-L1" })
        #expect(l1Node.badges.isEmpty)

        // The planet rolls up its Lagrange holdings while collapsed.
        #expect(planet.badges.contains { $0.symbol == "shippingbox" })
        #expect(planet.badges.contains { $0.symbol == "circle.hexagongrid" })
    }

    /// System objects (megastructures, outer-system objects) appear as system
    /// children, and a body holding stored inventory flags an (unnumbered)
    /// inventory badge that bubbles up to its system row.
    @Test func systemObjectsAsChildrenAndInventoryBadgesBubble() {
        let vega = Star(
            designation: "VEGA", spectralType: "A0", color: "blue",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 2,
            explored: true, hasLife: nil, entryPoint: nil, createdAt: .distantPast
        )
        let system = StarSystem(
            designation: "VEGA", systemScanned: true,
            belts: [Belt(designation: "VEGA-BELT-1", inventory: [InventoryItem(resourceType: "iron", quantity: 50)])],
            planets: [Planet(designation: "VEGA-3")],
            structures: [SpecialSite(designation: "VEGA-MEGA-1", kind: .megastructure)]
        )

        let forest = tree(
            stars: [vega], systems: ["VEGA": system], footprints: [:],
            myPosition: nil, filter: .all, sort: .alphabetical
        )
        let node = try! #require(forest.first)
        // Belt + planet + object as children, in that order.
        #expect(node.children?.map(\.id) == ["VEGA-BELT-1", "VEGA-3", "VEGA-MEGA-1"])
        #expect(node.children?.first { $0.id == "VEGA-MEGA-1" }?.kind == .object)

        // The belt holds inventory → an unnumbered inventory badge on its row…
        let belt = try! #require(node.children?.first { $0.id == "VEGA-BELT-1" })
        #expect(belt.badges.contains { $0.symbol == "shippingbox" && $0.count == nil })
        // …that also bubbles up to the system row.
        #expect(node.badges.contains { $0.symbol == "shippingbox" })
        // The planet holds none, so no inventory badge.
        let planet = try! #require(node.children?.first { $0.id == "VEGA-3" })
        #expect(!planet.badges.contains { $0.symbol == "shippingbox" })
    }

    /// A salvage site on a moon flags the salvage badge on the moon, its parent
    /// planet, and the system row (the roll-up the planet badge was missing).
    @Test func salvageBadgeRollsUpFromMoon() {
        let safana = Star(
            designation: "SAFANA", spectralType: "G5", color: "yellow",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 8,
            explored: true, hasLife: nil, entryPoint: nil, createdAt: .distantPast
        )
        let system = StarSystem(
            designation: "SAFANA", systemScanned: true,
            planets: [Planet(designation: "SAFANA-7", recon: .scanned, moons: [
                Moon(designation: "SAFANA-7-15", recon: .scanned,
                     salvage: [SalvageSite(designation: "SAFANA-7-15-SAL-1", name: "Orbital Debris Field")])
            ])]
        )

        let forest = tree(
            stars: [safana], systems: ["SAFANA": system], footprints: [:],
            myPosition: nil, filter: .all, sort: .alphabetical
        )
        let salvage = "wrench.and.screwdriver"
        let systemNode = try! #require(forest.first)
        #expect(systemNode.badges.contains { $0.symbol == salvage })
        let planet = try! #require(systemNode.children?.first { $0.id == "SAFANA-7" })
        #expect(planet.badges.contains { $0.symbol == salvage })
        let moon = try! #require(planet.children?.first { $0.id == "SAFANA-7-15" })
        #expect(moon.badges.contains { $0.symbol == salvage })
    }

    /// A census-only (unhydrated) system with no detail still flags inventory when
    /// the footprint overlay reports resources anywhere beneath it.
    @Test func inventoryBadgeFromFootprintOnCensusLeaf() {
        let rigel = Star(
            designation: "RIGEL", spectralType: "B8", color: "blue",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 4,
            explored: true, hasLife: nil, entryPoint: nil, createdAt: .distantPast
        )
        let footprints = ["RIGEL-2": LocationCounts(resources: 3)]

        let forest = tree(
            stars: [rigel], systems: [:], footprints: footprints,
            myPosition: nil, filter: .all, sort: .alphabetical
        )
        let node = try! #require(forest.first)
        #expect(node.children == nil)      // census leaf, not hydrated
        #expect(node.badges.contains { $0.symbol == "shippingbox" })
    }

    /// A system scanned while the app was closed reads `explored == false` in the
    /// stale bulk census, but its hydrated detail shows it's scanned. It must still
    /// land in the Explored filter (and out of Uncharted), matching its row's
    /// "N/N scanned" subtitle.
    @Test func hydratedScanOverridesStaleCensusExploredFlag() {
        let krios = Star(
            designation: "KRIOS", spectralType: "M6", color: "Red",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 2,
            explored: false, hasLife: true, entryPoint: "KRIOS-3-L4", createdAt: .distantPast
        )
        let scanned = StarSystem(
            designation: "KRIOS", systemScanned: true, planetsScanned: 3, planetsTotal: 3,
            planets: [Planet(designation: "KRIOS-3", type: "Terrestrial", recon: .scanned)]
        )
        let details = ["KRIOS": scanned]

        let explored = tree(
            stars: [krios], systems: details, footprints: [:],
            myPosition: nil, filter: .explored, sort: .alphabetical
        )
        #expect(explored.map(\.id) == ["KRIOS"])

        let uncharted = tree(
            stars: [krios], systems: details, footprints: [:],
            myPosition: nil, filter: .unexplored, sort: .alphabetical
        )
        #expect(uncharted.isEmpty)
    }

    /// Refreshing a cached system via the star-level `system(_:)` endpoint takes the
    /// fresh scan counts but must keep scanned-only detail the star-level response
    /// never carries — shops, megastructures, and richer per-body detail.
    @Test func mergingSystemDetailKeepsScannedOnlyDetail() {
        let cached = StarSystem(
            designation: "KRIOS", systemScanned: true, planetsScanned: 2, planetsTotal: 3,
            planets: [Planet(designation: "KRIOS-2", type: "Ocean World", recon: .scanned,
                             moons: [Moon(designation: "KRIOS-2-1")])],
            structures: [SpecialSite(designation: "KRIOS-MEGA-1", kind: .megastructure)],
            shops: [Shop(controllerCode: "SHOP1", shopName: "Outfitter", location: "KRIOS-2")]
        )
        // Star-level refresh: newer counts, fuller roster, but no shops/structures.
        let fresh = StarSystem(
            designation: "KRIOS", systemScanned: true, planetsScanned: 3, planetsTotal: 3,
            planets: [Planet(designation: "KRIOS-2", type: "Ocean World", recon: .visited),
                      Planet(designation: "KRIOS-3", type: "Super Earth", recon: .visited)]
        )

        let merged = cached.mergingSystemDetail(fresh)
        #expect(merged.planetsScanned == 3)                      // fresh counts win
        #expect(merged.planets.map(\.designation) == ["KRIOS-2", "KRIOS-3"])
        #expect(merged.shops.map(\.id) == ["SHOP1"])             // scanned-only, preserved
        #expect(merged.structures.map(\.designation) == ["KRIOS-MEGA-1"])
        // Richer body (scanned, with a moon) kept over the fresh estimated stub.
        let krios2 = try! #require(merged.planets.first { $0.designation == "KRIOS-2" })
        #expect(krios2.recon == .scanned)
        #expect(krios2.moons.map(\.designation) == ["KRIOS-2-1"])
    }

    // MARK: - Flatten (visible-row projection)

    /// Collapsed: every system contributes exactly one row; children are withheld.
    @Test func flattenCollapsedEmitsSystemsOnly() {
        let forest = [
            node("A", children: [node("A-1"), node("A-2")]),
            node("B"),
        ]
        let rows = LocationTree.flatten(forest, expanded: [])
        #expect(rows.map(\.id) == ["A", "B"])
        #expect(rows.map(\.depth) == [0, 0])
        #expect(rows[0].hasChildren == true)
        #expect(rows[0].isExpanded == false)
        #expect(rows[1].hasChildren == false)
    }

    /// Expanding a system splices its children in at depth 1, in order.
    @Test func flattenExpandedEmitsChildrenInOrder() {
        let forest = [node("A", children: [node("A-1"), node("A-2")])]
        let rows = LocationTree.flatten(forest, expanded: ["A"])
        #expect(rows.map(\.id) == ["A", "A-1", "A-2"])
        #expect(rows.map(\.depth) == [0, 1, 1])
        #expect(rows[0].isExpanded == true)
    }

    /// Expansion is per-node: a system can be open while its child stays closed,
    /// and a grandchild only appears once both ancestors are expanded.
    @Test func flattenNestedExpansionIsIndependent() {
        let forest = [node("A", children: [node("A-1", children: [node("A-1-a")])])]

        let systemOnly = LocationTree.flatten(forest, expanded: ["A"])
        #expect(systemOnly.map(\.id) == ["A", "A-1"])
        #expect(systemOnly.last?.hasChildren == true)
        #expect(systemOnly.last?.isExpanded == false)

        let both = LocationTree.flatten(forest, expanded: ["A", "A-1"])
        #expect(both.map(\.id) == ["A", "A-1", "A-1-a"])
        #expect(both.map(\.depth) == [0, 1, 2])
    }

    /// A childless node whose id is in `expanded` stays a leaf — `hasChildren`
    /// guards it, so it never reports expanded and reveals nothing.
    @Test func flattenIgnoresExpandedLeaves() {
        let rows = LocationTree.flatten([node("A")], expanded: ["A"])
        #expect(rows.map(\.id) == ["A"])
        #expect(rows[0].isExpanded == false)
    }

    @Test func flattenEmptyForest() {
        #expect(LocationTree.flatten([], expanded: []).isEmpty)
    }

    // MARK: - Reducer

    /// `toggleExpansion` flips a node's id in the expansion set — insert then
    /// remove — leaving other expanded nodes untouched.
    @MainActor
    @Test func toggleExpansionInsertsThenRemoves() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: LocationsFeature.State()) {
            LocationsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }

        await store.send(.toggleExpansion("SOL")) { $0.expanded = ["SOL"] }
        await store.send(.toggleExpansion("SOL-3")) { $0.expanded = ["SOL", "SOL-3"] }
        await store.send(.toggleExpansion("SOL")) { $0.expanded = ["SOL-3"] }
    }
}

// MARK: - Helpers

private func node(_ id: String, children: [LocationNode]? = nil) -> LocationNode {
    LocationNode(
        id: id, kind: .system, title: id, subtitle: nil,
        recon: .aware, badges: [], children: children
    )
}
