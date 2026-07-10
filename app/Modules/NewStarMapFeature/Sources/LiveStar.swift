import Foundation
import UniverseModels
import simd

// Bridges the app's live, persisted `UniverseModels.Star` rows (the surveyed
// galaxy, observed via @FetchAll) into this module's render-domain `Star`.
//
// The DB row is the source of truth for what the game actually knows: position
// (light years, Sol at origin — the same unit this map's world uses), spectral
// type, exploration state, and a coarse life flag. The richer per-system data
// this renderer's `Star` can express (resource abundances, an FTL relay, stored
// inventory, precise temperature/age) isn't in the star table yet, so it's
// derived or left at a neutral stand-in — exactly the fields the HANDOFF marks
// as "the game supplies real values." Wire them through as the backend exposes
// them; nothing downstream needs to change.

extension Star {
    /// Projects a persisted survey row into the render domain.
    init(surveyed row: UniverseModels.Star) {
        let stellarClass = StellarClass(spectralType: row.spectralType)
        self.init(
            name: row.designation,
            position: SIMD3<Float>(Float(row.positionX),
                                   Float(row.positionY),
                                   Float(row.positionZ)),
            temperature: stellarClass.representativeTemperature,
            stellarClass: stellarClass,
            ageMyr: stellarClass.stableAge(seed: row.designation),
            // Relay membership isn't a property of the star row — it's player
            // state (which systems hold one of your relay devices). The view sets
            // it from the live `Device` roster; the census row can't know it.
            hasFTLRelay: false,
            // The row only knows presence/absence of life, not its tier.
            life: row.hasLife == true ? .complex : .none,
            // Resource abundances aren't surveyed into the star table yet.
            resources: Resources(minerals: 0, gas: 0, rare: 0),
            scan: row.scanState,
            hasInventory: false
        )
    }
}

private extension UniverseModels.Star {
    /// Survey progress, from the row's exploration lifecycle: a fully-scanned
    /// system reads as `.full`, a merely-explored one as `.partial`, otherwise
    /// `.unexplored`.
    var scanState: ScanState {
        if fullyScannedAt != nil { return .full }
        if explored { return .partial }
        return .unexplored
    }
}

extension StellarClass {
    /// Parses a Morgan–Keenan spectral string (e.g. "G2 V") to its class by first
    /// letter; anything unrecognized falls back to a Sun-like G.
    init(spectralType: String) {
        switch spectralType.uppercased().first {
        case "O": self = .O
        case "B": self = .B
        case "A": self = .A
        case "F": self = .F
        case "G": self = .G
        case "K": self = .K
        case "M": self = .M
        default:  self = .G
        }
    }

    /// A representative surface temperature (band midpoint). On-screen color is
    /// derived from temperature, so this keeps the class↔color relationship the
    /// same fit the procedural galaxy uses.
    var representativeTemperature: Float {
        (temperatureRange.lowerBound + temperatureRange.upperBound) / 2
    }

    /// A deterministic, per-system age within this class's lifetime cap — a
    /// cosmetic stand-in (the row carries no age) that's stable across launches
    /// because it's hashed from the designation, not randomized.
    func stableAge(seed: String) -> Float {
        // FNV-1a over the designation → a stable 0…1, then into [1, maxAge].
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let unit = Float(hash % 10_000) / 10_000
        return max(1, unit * maxAgeMyr)
    }
}
