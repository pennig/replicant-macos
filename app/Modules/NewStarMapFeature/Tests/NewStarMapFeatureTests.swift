import GameModels
import Testing
import simd
import Metal
@testable import NewStarMapFeature

// These suites replace the ad-hoc print-checks used while building the galaxy
// model and the camera choreography. The camera is deterministic because it
// takes an injected `now` (seconds) — no sleeping, no wall clock.
//
// The suites are @MainActor because the app module defaults to MainActor
// isolation (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor), so its types are too.

// MARK: - Galaxy generation

@MainActor
@Suite struct GalaxyTests {

    @Test func generatesRequestedCount() {
        #expect(Galaxy.generate(starCount: 10_000).count == 10_000)
        #expect(Galaxy.generate(starCount: 500).count == 500)
    }

    @Test func temperatureAndAgeStayWithinClassBounds() {
        for star in Galaxy.generate() {
            #expect(star.stellarClass.temperatureRange.contains(star.temperature))
            // Hot massive stars die young; cool dwarfs are capped at the galaxy age.
            #expect(star.ageMyr >= 1)
            #expect(star.ageMyr <= star.stellarClass.maxAgeMyr)
        }
    }

    @Test func positionsAreFinite() {
        for star in Galaxy.generate() {
            #expect(star.position.x.isFinite && star.position.y.isFinite && star.position.z.isFinite)
        }
    }

    @Test func classDistributionOrdersByAbundance() {
        var counts: [StellarClass: Int] = [:]
        for star in Galaxy.generate() { counts[star.stellarClass, default: 0] += 1 }
        func n(_ c: StellarClass) -> Int { counts[c] ?? 0 }
        // Weighted to skew cool: M > K > G > F > A > B > O across 10k samples.
        #expect(n(.M) > n(.K))
        #expect(n(.K) > n(.G))
        #expect(n(.G) > n(.F))
        #expect(n(.F) > n(.A))
        #expect(n(.A) > n(.B))
        #expect(n(.B) > n(.O))
        #expect(n(.M) > 4_000)   // M is the clear plurality (~50%)
    }

    @Test func isDeterministicForASeed() {
        let a = Galaxy.generate(seed: 42)
        let b = Galaxy.generate(seed: 42)
        let c = Galaxy.generate(seed: 43)
        #expect(a.first?.position == b.first?.position)
        #expect(a.first?.temperature == b.first?.temperature)
        #expect(a.first?.stellarClass == b.first?.stellarClass)
        #expect(a.first?.position != c.first?.position)   // different seed differs
    }

    @Test func someButNotAllSystemsHaveRelays() {
        let relays = Galaxy.generate().filter(\.hasFTLRelay).count
        #expect(relays > 0)
        #expect(relays < 10_000)
    }

    @Test func systemsHaveDeterministicVariedNames() {
        let a = Galaxy.generate(seed: 7)
        let b = Galaxy.generate(seed: 7)
        #expect(a.allSatisfy { !$0.name.isEmpty })
        #expect(a.prefix(50).map(\.name) == b.prefix(50).map(\.name))   // deterministic
        #expect(Set(a.prefix(200).map(\.name)).count > 100)             // varied
    }

    @Test func systemsCarryDataInRangeWithVariety() {
        let stars = Galaxy.generate()
        for s in stars {
            #expect((0...1).contains(s.resources.minerals))
            #expect((0...1).contains(s.resources.gas))
            #expect((0...1).contains(s.resources.rare))
        }
        #expect(stars.contains { $0.life == .none } && stars.contains { $0.life == .teeming })
        #expect(stars.contains { $0.scan == .unexplored } && stars.contains { $0.scan == .full })
    }

    @Test func isCentredOnSol() {
        // Sol is the origin: the bubble is roughly balanced around it and dense at
        // the core (bulk within ~90 ly of a 30 ly-sigma cloud).
        let stars = Galaxy.generate()
        var centroid = SIMD3<Float>.zero
        for s in stars { centroid += s.position }
        centroid /= Float(stars.count)
        #expect(simd_length(centroid) < 5)

        let radii = stars.map { simd_length($0.position) }.sorted()
        #expect(radii[radii.count / 2] < 60)   // median star is near home
    }
}

// MARK: - Temperature → color

@MainActor
@Suite struct StarColorTests {

    @Test func coolStarsAreReddish() {
        let c = Star.color(forTemperature: 3_000)
        #expect(c.x > c.z)   // red channel dominates blue
    }

    @Test func hotStarsAreBluish() {
        let c = Star.color(forTemperature: 30_000)
        #expect(c.z > c.x)   // blue channel dominates red
    }

    @Test func sunLikeIsRoughlyWhite() {
        let c = Star.color(forTemperature: 5_800)
        #expect(abs(c.x - c.z) < 0.25)      // fairly balanced
        #expect(c.x > 0.7 && c.y > 0.7)     // and bright
    }

    @Test func channelsStayInUnitRange() {
        for t in stride(from: Float(1_500), through: 40_000, by: 500) {
            let c = Star.color(forTemperature: t)
            #expect(c.x >= 0 && c.x <= 1)
            #expect(c.y >= 0 && c.y <= 1)
            #expect(c.z >= 0 && c.z <= 1)
        }
    }
}

// MARK: - Camera choreography

@MainActor
@Suite struct TurntableCameraTests {

    /// Force a framing move to completion by advancing well past the max duration.
    private func settle(_ cam: inout TurntableCamera) {
        _ = cam.step(now: 1.0)
    }

    @Test func nearbyReaimHoldsTheEyeFixed() {
        var cam = TurntableCamera()
        let anchor = cam.eye
        let near = anchor + SIMD3<Float>(15, 4, 8)   // ~17.5 ly, within the 45 cap
        cam.focus(on: near, now: 0)
        settle(&cam)
        #expect(simd_length(cam.eye - anchor) < 1e-3)     // position unchanged
        #expect(simd_length(cam.target - near) < 1e-3)    // now pivots on the star
    }

    @Test func nearbyReaimHoldsEyeThroughACompleteWideSwing() {
        // Regression: a nearby star off to the side used to yank the eye 100+ ly
        // mid-transition (cap re-applied every frame). The cap is now baked into
        // the goal eye once, so the eye must stay pinned at every sampled instant.
        var cam = TurntableCamera()
        let anchor = cam.eye
        cam.focus(on: anchor + SIMD3<Float>(20, 5, 10), now: 0)
        var maxDrift: Float = 0
        for i in 0...40 {
            _ = cam.step(now: Double(i) * 0.02)   // 0 … 0.8 s
            maxDrift = max(maxDrift, simd_length(cam.eye - anchor))
        }
        #expect(maxDrift < 1e-3)
    }

    @Test func distantReaimZoomsToTheCap() {
        var cam = TurntableCamera()
        let anchor = cam.eye
        cam.focus(on: .zero, now: 0)   // origin is ~180 ly away, beyond the cap
        settle(&cam)
        #expect(abs(cam.radius - cam.maxFocusRadius) < 1e-3)
        #expect(abs(simd_length(cam.eye) - cam.maxFocusRadius) < 1e-2)
        #expect(simd_length(cam.eye - anchor) > 1)   // the eye did move in
    }

    @Test func diveLandsAtFixedDistanceKeepingOrientation() {
        var cam = TurntableCamera()
        let star = SIMD3<Float>.zero
        let dirBefore = simd_normalize(cam.eye - star)
        cam.dive(on: star, radius: 12, now: 0)
        settle(&cam)
        #expect(abs(simd_length(cam.eye - star) - 12) < 1e-3)
        #expect(simd_dot(dirBefore, simd_normalize(cam.eye - star)) > 0.999)   // same look direction
    }

    @Test func divePullsBackWhenAlreadyCloserThanTheDiveDistance() {
        var cam = TurntableCamera()
        cam.dolly(3.7)                 // zoom in so the radius is well under 12
        #expect(cam.radius < 12)
        let star = cam.target
        cam.dive(on: star, radius: 12, now: 0)
        settle(&cam)
        #expect(abs(simd_length(cam.eye - star) - 12) < 1e-3)   // pulled back out to 12
    }

    @Test func focusPullsBackToTheFloorWhenTooClose() {
        // Dollied in past where the star stops growing, THEN focus → the eye pulls
        // back out to the focus floor (a focused star can't over-fill the view).
        var cam = TurntableCamera()
        let star = SIMD3<Float>.zero
        cam.dolly(200)                     // slam all the way in, well under the floor
        #expect(cam.radius < 8)
        cam.focusFloor = 8                 // this star's angular-size limit sits at 8 ly
        cam.focus(on: star, now: 0)
        _ = cam.step(now: 1.0)
        #expect(abs(simd_length(cam.eye - star) - 8) < 1e-3)   // pulled back out to the floor
    }

    @Test func settleImmediatelyFramesWithoutAnimating() {
        var cam = TurntableCamera()
        let star = SIMD3<Float>(10, 0, 0)
        cam.settle(on: star, radius: 6)
        #expect(cam.step(now: 0) == false)                     // already settled — nothing to animate
        #expect(simd_length(cam.target - star) < 1e-3)
        #expect(abs(cam.radius - 6) < 1e-3)
        #expect(abs(simd_length(cam.eye - star) - 6) < 1e-3)   // eye sits the dive distance from the star
    }

    @Test func cancelFramingHoldsThePoseMidFlight() {
        var cam = TurntableCamera()
        cam.focus(on: .zero, now: 0)          // start an eased move (origin is beyond the cap)
        _ = cam.step(now: 0.1)                // advance partway
        let held = cam.eye
        cam.cancelFraming()
        #expect(cam.step(now: 0.2) == false)  // move dropped, not resumed
        #expect(simd_length(cam.eye - held) < 1e-3)   // holds exactly where it was
    }

    @Test func homeEasesBackToOverview() {
        var cam = TurntableCamera()
        cam.dolly(2.0)
        cam.overview(target: .zero, radius: 180, now: 0)
        settle(&cam)
        #expect(abs(cam.radius - 180) < 1e-2)
        #expect(simd_length(cam.target) < 1e-3)
    }

    @Test func elevationStaysWithinTheClamp() {
        var cam = TurntableCamera()
        cam.focus(on: cam.eye + SIMD3<Float>(0, 30, 0), now: 0)   // straight up → past the pole
        settle(&cam)
        let limit: Float = 80 * .pi / 180 + 1e-4
        #expect(cam.elevation <= limit && cam.elevation >= -limit)
    }

    @Test func durationScalesWithChangeAndClampsTo300To750ms() {
        // Tiny move: already zoomed in, re-aim onto the current pivot → ~min (0.30 s).
        var small = TurntableCamera()
        small.dolly(3.0)                        // radius well under the cap
        small.focus(on: small.target, now: 0)   // negligible change
        #expect(small.step(now: 0.29) == true)    // still animating just before 0.30
        #expect(small.step(now: 0.31) == false)   // settled by ~0.30

        // Big move: overview → zoom-toward the origin (large eye reposition) → ~max (0.75 s).
        var big = TurntableCamera()
        big.focus(on: .zero, now: 0)
        #expect(big.step(now: 0.60) == true)      // not settled yet
        #expect(big.step(now: 0.76) == false)     // settled by ~0.75
    }

    @Test func manualGestureCancelsInFlightFraming() {
        var cam = TurntableCamera()
        cam.focus(on: .zero, now: 0)
        cam.orbit(dAzimuth: 0.1, dElevation: 0)   // taking manual control cancels the move
        #expect(cam.step(now: 0.1) == false)      // nothing left to animate
    }

    @Test func zoomFractionSpansFullyOutToFullyIn() {
        var cam = TurntableCamera()
        cam.dolly(-100)                            // clamp to maxRadius (fully out)
        #expect(cam.zoomedInFraction < 0.001)
        cam.dolly(100)                             // clamp to minRadius (fully in)
        #expect(cam.zoomedInFraction > 0.999)
    }

    @Test func focusFloorLimitsHowCloseTheDollyGoes() {
        var cam = TurntableCamera()
        cam.focusFloor = 5                    // focused on a star that caps at 5 ly
        cam.dolly(100)                        // try to zoom all the way in
        #expect(abs(cam.radius - 5) < 1e-3)   // stops at the focus floor, not minRadius

        cam.focusFloor = nil                  // cleared → back to the plain floor
        cam.dolly(100)
        #expect(cam.radius < 5)               // now goes closer (toward minRadius)
    }

    @Test func orbitIsLessSensitiveFurtherOut() {
        var near = TurntableCamera(); near.dolly(3)   // zoom in → radius well inside the reference
        var far = TurntableCamera()                   // overview radius (180)
        #expect(near.orbitSensitivity == 1)           // full sensitivity when close
        #expect(far.orbitSensitivity < 1)

        let n0 = near.azimuth, f0 = far.azimuth
        near.orbit(dAzimuth: 0.1, dElevation: 0)
        far.orbit(dAzimuth: 0.1, dElevation: 0)
        #expect((near.azimuth - n0) > (far.azimuth - f0))   // same input moves less far out
    }
}

// MARK: - FTL mesh

@MainActor
@Suite struct FTLMeshTests {

    /// Distinct designations of the relay-bearing systems in a generated galaxy.
    private func relayNames(_ stars: [Star]) -> [String] {
        var seen: Set<String> = []
        return stars.indices
            .filter { stars[$0].hasFTLRelay }
            .map { stars[$0].name }
            .filter { seen.insert($0).inserted }
    }

    @Test func nodesAreExactlyTheRelaySystems() {
        let stars = Galaxy.generate()
        let mesh = FTLMesh.build(stars: stars, links: [])
        #expect(!mesh.nodes.isEmpty)
        #expect(mesh.nodes.allSatisfy { stars[$0].hasFTLRelay })
        #expect(mesh.nodes.count == stars.indices.filter { stars[$0].hasFTLRelay }.count)
    }

    @Test func edgesResolveLinksToRelayIndices() throws {
        let stars = Galaxy.generate()
        let relays = relayNames(stars)
        try #require(relays.count >= 2)
        let mesh = FTLMesh.build(stars: stars, links: [FTLLink(relays[0], relays[1])])
        #expect(mesh.edges.count == 1)
        let e = try #require(mesh.edges.first)
        #expect(e.a < e.b)                                              // canonical, no self-loops
        #expect(Set([stars[e.a].name, stars[e.b].name]) == Set([relays[0], relays[1]]))
    }

    @Test func reciprocalLinksDeduplicate() throws {
        // Both relays report the same connection; the two directions collapse to one.
        let stars = Galaxy.generate()
        let relays = relayNames(stars)
        try #require(relays.count >= 2)
        let mesh = FTLMesh.build(
            stars: stars, links: [FTLLink(relays[0], relays[1]), FTLLink(relays[1], relays[0])])
        #expect(mesh.edges.count == 1)
    }

    @Test func unknownEndpointsAreDropped() throws {
        let stars = Galaxy.generate()
        let relays = relayNames(stars)
        try #require(!relays.isEmpty)
        let mesh = FTLMesh.build(stars: stars, links: [FTLLink(relays[0], "NOWHERE")])
        #expect(mesh.edges.isEmpty)
    }

    @Test func allowsOrphanRelays() {
        // No links → no edges, but the nodes (relays) still exist as markers.
        let mesh = FTLMesh.build(stars: Galaxy.generate(), links: [])
        #expect(mesh.edges.isEmpty)
        #expect(!mesh.nodes.isEmpty)
    }

    @Test func relevancePinsNodesAndStaysInRange() {
        let stars = Galaxy.generate()
        let floor: Float = 0.04
        let mesh = FTLMesh.build(stars: stars, links: [])
        let rel = mesh.relevance(for: stars, floor: floor, falloffRadius: 35)
        #expect(rel.count == stars.count)
        for n in mesh.nodes { #expect(rel[n] == 1) }
        for v in rel { #expect(v >= floor - 1e-6 && v <= 1 + 1e-6) }
    }

    @Test func geometryCountsMatch() throws {
        let stars = Galaxy.generate()
        let relays = relayNames(stars)
        try #require(relays.count >= 2)
        let mesh = FTLMesh.build(stars: stars, links: [FTLLink(relays[0], relays[1])])
        #expect(mesh.lineVertices(for: stars).count == mesh.edges.count * 6)   // quad = 6 verts
        #expect(mesh.nodePositions(for: stars).count == mesh.nodes.count)
    }
}

// MARK: - Relevance max-combine

@MainActor
@Suite struct RelevanceCombineTests {

    @Test func noConcernIsPlainTerrain() {
        #expect(RelevanceField.combined([], count: 4) == [1, 1, 1, 1])
    }

    @Test func singleConcernPassesThrough() {
        let c: [Float] = [0.04, 0.5, 1, 0.2]
        #expect(RelevanceField.combined([c], count: 4) == c)
    }

    @Test func multipleConcernsTakePerStarMax() {
        let focus: [Float] = [1.0, 0.04, 0.04, 0.3]
        let mesh:  [Float] = [0.04, 1.0, 0.5, 0.1]
        #expect(RelevanceField.combined([focus, mesh], count: 4) == [1.0, 1.0, 0.5, 0.3])
    }
}

// MARK: - State-tier clamp (Invariant 2)

@MainActor
@Suite struct RelevanceFieldStateTests {

    private func settled(_ field: RelevanceField, count: Int) -> [Float] {
        for _ in 0..<500 where field.step() {}
        let p = field.buffer.contents().bindMemory(to: Float.self, capacity: count)
        return (0..<count).map { p[$0] }
    }

    @Test func stateClampPinsStarsThroughAnOverlay() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let positions = (0..<5).map { SIMD3<Float>(Float($0) * 100, 0, 0) }
        let field = try #require(RelevanceField(device: device, positions: positions))

        var contrib = [Float](repeating: field.floor, count: 5)   // an overlay dimming everyone…
        contrib[0] = 1                                            // …except star 0
        field.write(.mesh, contrib)
        field.setStateClamp([3])                                  // star 3 is state-tier

        let v = settled(field, count: 5)
        #expect(abs(v[0] - 1) < 1e-3)   // overlay's own star stays lit
        #expect(abs(v[3] - 1) < 1e-3)   // state-clamped star pinned to full despite the overlay
        #expect(v[1] < 0.2)             // an unrelated star recedes toward the floor
    }

    @Test func filterTakesPrecedenceOverFocus() throws {
        // A focus lights a star and its neighbours; a filter that only star 0
        // matches must still dim the (focused) neighbour — the filter masks.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let positions = (0..<4).map { SIMD3<Float>(Float($0), 0, 0) }
        let field = try #require(RelevanceField(device: device, positions: positions))

        field.focus(on: 0, falloffRadius: 10)          // lights 0 and its neighbours
        var filter = [Float](repeating: field.floor, count: 4)
        filter[0] = 1                                  // only star 0 matches
        field.write(.filter, filter)

        let v = settled(field, count: 4)
        #expect(abs(v[0] - 1) < 1e-3)   // matches filter and focused → lit
        #expect(v[1] < 0.2)             // focused neighbour, but filtered out → dimmed
    }

    @Test func stateClampDoesNotDimTheFieldWhenItIsTheOnlyConcern() throws {
        // The clamp is NOT a max-combine writer: with no overlay active, the field
        // must stay full terrain everywhere (a writer's "0 elsewhere" would darken it).
        let device = try #require(MTLCreateSystemDefaultDevice())
        let positions = (0..<5).map { SIMD3<Float>(Float($0), 0, 0) }
        let field = try #require(RelevanceField(device: device, positions: positions))

        field.setStateClamp([2])
        let v = settled(field, count: 5)
        for i in 0..<5 { #expect(abs(v[i] - 1) < 1e-3) }
    }
}

// MARK: - Ships

@MainActor
@Suite struct ShipTests {

    @Test func progressClampsToTheTripWindow() {
        let ship = Ship(deviceCode: "D", fromStar: 0, toStar: 1, departedMedia: 100, arrivesMedia: 110, legs: [])
        #expect(ship.progress(at: 90) == 0)             // before departure → held at origin
        #expect(ship.progress(at: 100) == 0)
        #expect(abs(ship.progress(at: 105) - 0.5) < 1e-4)
        #expect(ship.progress(at: 110) == 1)            // arrival
        #expect(ship.progress(at: 130) == 1)            // past arrival → held at destination
    }

    @Test func positionInterpolatesBetweenSystems() {
        let stars = Galaxy.generate()
        let a = stars[0].position, b = stars[1].position
        let ship = Ship(deviceCode: "D", fromStar: 0, toStar: 1, departedMedia: 100, arrivesMedia: 110, legs: [])
        #expect(simd_length(ship.position(at: 100, stars: stars) - a) < 1e-4)
        #expect(simd_length(ship.position(at: 105, stars: stars) - (a + (b - a) * 0.5)) < 1e-3)
    }

    private func star(_ name: String, _ pos: SIMD3<Float>) -> Star {
        Star(name: name, position: pos, temperature: 5000, stellarClass: .G, ageMyr: 1000,
             hasFTLRelay: false, life: .none,
             resources: Resources(minerals: 0, gas: 0, rare: 0),
             scan: .unexplored, hasInventory: false)
    }

    @Test func multiLegShipParksThenMovesThenParks() {
        // Two systems (A at origin, B at x=10); a 3-leg trip — cruise in A, jump A→B,
        // cruise in B — so the head parks at A, crosses to B, then parks at B.
        let stars = [star("A", SIMD3(0, 0, 0)), star("B", SIMD3(10, 0, 0))]
        let legs = [
            Ship.Leg(fromStar: 0, toStar: 0, fromCode: "A-1", toCode: "A-2", startMedia: 100, endMedia: 110),  // cruise in A
            Ship.Leg(fromStar: 0, toStar: 1, fromCode: "A", toCode: "B", startMedia: 110, endMedia: 120),       // jump A→B
            Ship.Leg(fromStar: 1, toStar: 1, fromCode: "B-1", toCode: "B-2", startMedia: 120, endMedia: 130),   // cruise in B
        ]
        let ship = Ship(deviceCode: "S1", fromStar: 0, toStar: 1,
                        departedMedia: 100, arrivesMedia: 130, legs: legs)

        #expect(ship.position(at: 90, stars: stars) == SIMD3(0, 0, 0))    // before start → at A
        #expect(ship.position(at: 105, stars: stars) == SIMD3(0, 0, 0))   // cruise in A → parked
        #expect(ship.position(at: 115, stars: stars) == SIMD3(5, 0, 0))   // mid jump → halfway
        #expect(ship.position(at: 125, stars: stars) == SIMD3(10, 0, 0))  // cruise in B → parked
        #expect(ship.position(at: 200, stars: stars) == SIMD3(10, 0, 0))  // arrived → at B

        // The ribbon tail tracks the head's fraction along A→B.
        #expect(ship.ribbonProgress(at: 105, stars: stars) == 0)
        #expect(abs(ship.ribbonProgress(at: 115, stars: stars) - 0.5) < 1e-4)
        #expect(ship.ribbonProgress(at: 125, stars: stars) == 1)
    }

    @Test func noLegsFallsBackToStraightLine() {
        let stars = [star("A", SIMD3(0, 0, 0)), star("B", SIMD3(10, 0, 0))]
        let ship = Ship(deviceCode: "S1", fromStar: 0, toStar: 1,
                        departedMedia: 100, arrivesMedia: 130, legs: [])
        #expect(ship.position(at: 115, stars: stars) == SIMD3(5, 0, 0))   // linear over the window
        #expect(abs(ship.progress(at: 115) - 0.5) < 1e-4)
    }

    @Test func orreryPositionResolvesOnlyIntraSystemLegs() {
        // Cruise leg wholly within system A resolves against a location→world map; the
        // jump leg (endpoint B unknown to A's orrery) does not, so the ship isn't placed.
        let legs = [
            Ship.Leg(fromStar: 0, toStar: 0, fromCode: "A-1", toCode: "A-2", startMedia: 100, endMedia: 110),
            Ship.Leg(fromStar: 0, toStar: 1, fromCode: "A", toCode: "B", startMedia: 110, endMedia: 120),
        ]
        let ship = Ship(deviceCode: "S", fromStar: 0, toStar: 1,
                        departedMedia: 100, arrivesMedia: 120, legs: legs)
        let known: [String: SIMD3<Float>] = ["A-1": SIMD3(0, 0, 0), "A-2": SIMD3(4, 0, 0)]
        let resolve: (String) -> SIMD3<Float>? = { known[$0] }
        #expect(ship.orreryPosition(at: 105, resolve: resolve) == SIMD3(2, 0, 0))  // mid cruise
        #expect(ship.orreryPosition(at: 115, resolve: resolve) == nil)             // jump leg → not in A
    }
}

// MARK: - Data filters

@MainActor
@Suite struct DataFilterTests {

    private func star(life: LifeLevel = .none, minerals: Float = 0, gas: Float = 0,
                      rare: Float = 0, scan: ScanState = .unexplored) -> Star {
        Star(name: "X", position: .zero, temperature: 5000, stellarClass: .G, ageMyr: 1000,
             hasFTLRelay: false, life: life,
             resources: Resources(minerals: minerals, gas: gas, rare: rare),
             scan: scan, hasInventory: false)
    }

    @Test func lifeFilterLightsLivingSystems() {
        let r = DataFilter.life.relevance(for: [star(life: .none), star(life: .teeming)], floor: 0.04)
        #expect(abs(r[0] - 0.04) < 1e-6)   // lifeless → floor
        #expect(abs(r[1] - 1.0) < 1e-6)    // teeming → full
    }

    @Test func resourceFilterIsGraded() {
        let r = DataFilter.minerals.relevance(
            for: [star(minerals: 0), star(minerals: 0.5), star(minerals: 1)], floor: 0.04)
        #expect(r[0] < r[1] && r[1] < r[2])
        #expect(abs(r[2] - 1) < 1e-6)
    }

    @Test func unexploredFilterIsBinary() {
        let r = DataFilter.unexplored.relevance(
            for: [star(scan: .unexplored), star(scan: .full)], floor: 0.04)
        #expect(abs(r[0] - 1) < 1e-6)
        #expect(abs(r[1] - 0.04) < 1e-6)
    }

    @Test func everyFilterStaysInRange() {
        let stars = Galaxy.generate()
        for f in DataFilter.allCases {
            for v in f.relevance(for: stars, floor: 0.04) {
                #expect(v >= 0.04 - 1e-6 && v <= 1 + 1e-6)
            }
        }
    }
}

// MARK: - Status symbols

@MainActor
@Suite struct StatusSymbolTests {

    private func star(scan: ScanState, life: LifeLevel = .none, minerals: Float = 0,
                      hasInventory: Bool = false) -> Star {
        Star(name: "X", position: .zero, temperature: 5000, stellarClass: .G, ageMyr: 1000,
             hasFTLRelay: false, life: life,
             resources: Resources(minerals: minerals, gas: 0, rare: 0),
             scan: scan, hasInventory: hasInventory)
    }

    @Test func unexploredShowsOnlyTheOpenCircle() {
        // No surveyed data is reported for an unexplored system.
        #expect(star(scan: .unexplored, life: .teeming, minerals: 1, hasInventory: true)
            .statusSymbols == [StatusSymbol(name: "circle", value: nil)])
    }

    @Test func exploredReportsSurveyedData() {
        let s = star(scan: .full, life: .complex, minerals: 1, hasInventory: true)
        #expect(s.statusSymbols == [
            StatusSymbol(name: "circle.fill", value: nil),
            StatusSymbol(name: "leaf.fill", value: nil),
            StatusSymbol(name: "dollarsign.gauge.chart.leftthird.topthird.rightthird", value: 1),
            StatusSymbol(name: "shippingbox.fill", value: nil),
        ])
    }

    @Test func partialScanUsesHalfCircleAndOmitsAbsentData() {
        // Half circle, no life (none), a resource gauge at its value, no package.
        #expect(star(scan: .partial, life: .none, minerals: 0.3).statusSymbols == [
            StatusSymbol(name: "circle.lefthalf.filled", value: nil),
            StatusSymbol(name: "dollarsign.gauge.chart.leftthird.topthird.rightthird", value: 0.3),
        ])
    }
}

// MARK: - Label layout (screen-space collision)

@MainActor
@Suite struct LabelEngineTests {

    private func candidate(_ id: Int, _ anchor: SIMD2<Float>, _ size: SIMD2<Float>,
                           _ priority: Float) -> LabelEngine.Candidate {
        .init(id: id, anchor: anchor, size: size, priority: priority)
    }

    @Test func placesBothWhenSeparated() {
        let out = LabelEngine.layout([
            candidate(1, SIMD2(0, 0), SIMD2(40, 14), 1),
            candidate(2, SIMD2(500, 500), SIMD2(40, 14), 2),
        ])
        #expect(out.count == 2)
    }

    @Test func centersHorizontallyUnderTheAnchor() {
        let out = LabelEngine.layout([candidate(1, SIMD2(100, 50), SIMD2(40, 14), 1)])
        let p = try! #require(out.first)
        #expect(p.origin.x == 80)   // 100 - 40/2, centred on the anchor
        #expect(p.origin.y == 50)   // top at the anchor (renderer already offset it below the star)
    }

    @Test func higherPriorityWinsAContestedSpot() {
        // Two labels that would overlap → only the higher-priority one is placed.
        let out = LabelEngine.layout([
            candidate(1, SIMD2(100, 100), SIMD2(60, 16), 5),
            candidate(2, SIMD2(104, 103), SIMD2(60, 16), 9),
        ])
        #expect(out.count == 1)
        #expect(out.first?.id == 2)
    }

    @Test func selectedLikePriorityIsNeverDropped() {
        // A pile of overlapping labels → exactly one survives, the max priority.
        let cands = (0..<6).map { candidate($0, SIMD2(20, 20), SIMD2(50, 16), Float($0)) }
        let out = LabelEngine.layout(cands)
        #expect(out.count == 1)
        #expect(out.first?.id == 5)
    }

    @Test func placedLabelsAreMutuallyNonOverlapping() {
        var cands: [LabelEngine.Candidate] = []
        for i in 0..<40 {
            let x = Float((i % 8) * 28), y = Float((i / 8) * 12)
            cands.append(candidate(i, SIMD2(x, y), SIMD2(50, 16), Float(i)))
        }
        let out = LabelEngine.layout(cands)
        #expect(out.count > 1)
        for i in 0..<out.count {
            for j in (i + 1)..<out.count {
                #expect(!LabelEngine.overlaps(out[i], out[j], padding: 0))
            }
        }
    }
}
