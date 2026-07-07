import simd

// The charted sphere: the ~10k stars the player has actually mapped, arranged as
// a rough ball of *known* space — NOT a whole galaxy. The true galaxy's shape is
// unknown (spiral? elliptical? who knows); all we render is the surveyed bubble
// around the player, which happens to read as roughly spherical. Density is
// highest at the core and fades smoothly to nothing at the fringe — there is no
// hard edge, because the edge is just "as far as we've explored." You discover
// more by pushing into that fade.
//
// A little large-scale structure (loose stellar associations + a smooth field)
// so the depth cues (parallax, atmospheric dimming, the tone-mapped core) and the
// voids between clusters have something real to reveal.

enum Galaxy {

    static func generate(starCount: Int = 10_000, seed: UInt64 = 0xC0FFEE) -> [Star] {
        var rng = SplitMix64(seed: seed)
        // Names and per-system data draw from SEPARATE streams so adding them
        // doesn't shift the position/class/relay draws — the galaxy shape stays
        // identical per seed.
        var nameRng = SplitMix64(seed: seed ^ 0x9E3779B97F4A7C15)
        var dataRng = SplitMix64(seed: seed &* 0xD1B54A32D192ED03)
        var stars: [Star] = []
        stars.reserveCapacity(starCount)

        // Isotropic 3D-gaussian cloud, positions in LIGHT YEARS with Sol at the
        // origin: dense core, soft edgeless fringe, no galactic plane. `coreSigma`
        // (ly) sets the bubble's scale; the bulk of the survey sits within ~3σ
        // (~90 ly), with a light natural tail of frontier outliers.
        let coreSigma: Float = 30

        // Fraction of systems with an FTL relay installed (stand-in for the game's
        // per-system state). Uniform per star, so relays are denser where stars
        // are denser — the core wires up, the fringe leaves orphans.
        let relayFraction: Float = 0.06

        // A handful of loose associations sitting inside the bubble. These are
        // what make the voids between them read as voids rather than noise.
        struct Cluster { var center: SIMD3<Float>; var sigma: Float }
        let clusterFraction: Float = 0.30
        let clusterCount = 12
        var clusters: [Cluster] = []
        for _ in 0..<clusterCount {
            clusters.append(Cluster(center: rng.gaussian3() * (coreSigma * 0.7),
                                    sigma: 4 + rng.unit() * 8))
        }

        for _ in 0..<starCount {
            let inCluster = rng.unit() < clusterFraction
            let position: SIMD3<Float>
            if inCluster {
                // Member of a loose association: a small gaussian blob around one
                // cluster center.
                let c = clusters[rng.int(clusterCount)]
                position = c.center + rng.gaussian3() * c.sigma
            } else {
                // Smooth field star, isotropic — dense core, soft fading fringe.
                position = rng.gaussian3() * coreSigma
            }

            // Physical data. Class drives temperature and the (class-capped) age;
            // color is derived from temperature at render time, not stored here.
            let stellarClass = StellarClass.weightedRandom(&rng)

            // Per-system data (stand-in distributions; the game supplies real values).
            // Life is mostly absent, teeming is rare; resources skew poor (rich is
            // rare); most systems are unexplored.
            let lifeRoll = dataRng.unit()
            let life: LifeLevel = lifeRoll < 0.70 ? .none
                                : lifeRoll < 0.90 ? .microbial
                                : lifeRoll < 0.98 ? .complex : .teeming
            let resources = Resources(minerals: powf(dataRng.unit(), 2.2),
                                      gas:      powf(dataRng.unit(), 2.2),
                                      rare:     powf(dataRng.unit(), 3.5))
            let scanRoll = dataRng.unit()
            let scan: ScanState = scanRoll < 0.55 ? .unexplored
                                : scanRoll < 0.85 ? .partial : .full

            stars.append(Star(
                name: makeName(&nameRng),
                position: position,
                temperature: stellarClass.randomTemperature(&rng),
                stellarClass: stellarClass,
                ageMyr: stellarClass.randomAge(&rng),
                hasFTLRelay: rng.unit() < relayFraction,
                life: life,
                resources: resources,
                scan: scan,
                hasInventory: dataRng.unit() < 0.15
            ))
        }
        return stars
    }

    // Pronounceable procedural system names — onset + vowel syllables, an optional
    // coda, and an occasional catalog number. A stand-in for real names.
    private static let onsets = ["b", "d", "f", "k", "l", "m", "n", "r", "s", "t",
                                 "v", "z", "br", "dr", "kr", "th", "st", "vl", "gl", "tr"]
    private static let vowels = ["a", "e", "i", "o", "u", "ae", "ia", "io", "ou", "yr", "ea"]
    private static let codas  = ["", "n", "r", "s", "l", "x", "th", "rn", "ss", "k", "m"]

    static func makeName(_ rng: inout SplitMix64) -> String {
        let syllables = 2 + rng.int(2)   // 2 or 3
        var s = ""
        for _ in 0..<syllables {
            s += onsets[rng.int(onsets.count)] + vowels[rng.int(vowels.count)]
        }
        s += codas[rng.int(codas.count)]
        var name = s.prefix(1).uppercased() + s.dropFirst()
        if rng.unit() < 0.22 { name += " " + String(100 + rng.int(900)) }
        return name
    }
}

// Small, fast, deterministic RNG so galaxies are reproducible per seed.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Float {           // [0,1)
        Float(next() >> 40) * (1.0 / Float(1 << 24))
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func gaussian() -> Float {       // Box–Muller
        let u1 = max(unit(), 1e-6), u2 = unit()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
    mutating func gaussian3() -> SIMD3<Float> {   // isotropic gaussian vector
        SIMD3<Float>(gaussian(), gaussian(), gaussian())
    }
    mutating func unitSphere() -> SIMD3<Float> {
        let z = unit() * 2 - 1
        let a = unit() * 2 * .pi
        let r = sqrt(max(0, 1 - z * z))
        return SIMD3<Float>(r * cos(a), z, r * sin(a))
    }
}
