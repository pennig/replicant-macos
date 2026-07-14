//
//  PlanetType.swift
//  NewStarMapFeature
//
//  Classification of a planet's kind, mapped from the backend's free-form `type`
//  string. Drives the orrery's surface texturing (see `PlanetMaterial`). Whether the
//  classification is only an estimate is a separate concern — the caller passes the
//  body's `typeEstimated` flag through to the material lookup, so it isn't encoded
//  here. Kept in the module because it's a texture-facing presentation concern;
//  hoist to `UniverseModels` if another feature needs it.
//

/// A planet's kind. `unknown` carries the raw backend label so an unrecognized type
/// (including any new kind the game adds) is preserved rather than discarded — we can
/// still surface the string and fall back to a neutral texture.
enum PlanetType: Equatable, Sendable {
    case terrestrial
    case superEarth
    case oceanWorld
    case desertWorld
    case barren
    case volcanic
    case frozen
    case dwarfPlanet
    case gasGiant
    case iceGiant
    /// No recognizable type label — carries the raw backend string (empty when absent).
    case unknown(String)
}

extension PlanetType {

    /// Whether this kind is a giant, whose atmosphere is already conveyed by its
    /// banded/icy texture — so the orrery draws no separate atmosphere shell for it
    /// (see `PlanetMaterial.atmosphereShell`).
    var isGiant: Bool {
        switch self {
        case .gasGiant, .iceGiant: true
        default: false
        }
    }

    /// Classify the backend `type` label (the free-form string a scan returns).
    /// Order matters: the "… giant" checks precede the bare "ice"/"frozen" ones.
    init(apiType: String?) {
        let raw = apiType ?? ""
        let t = raw.lowercased()
        if t.isEmpty { self = .unknown("") }
        else if t.contains("ice giant") { self = .iceGiant }
        else if t.contains("gas giant") { self = .gasGiant }
        else if t.contains("ocean") { self = .oceanWorld }
        else if t.contains("desert") || t.contains("arid") { self = .desertWorld }
        else if t.contains("super earth") || t.contains("super-earth") { self = .superEarth }
        else if t.contains("terrestrial") || t.contains("terran") { self = .terrestrial }
        else if t.contains("dwarf") { self = .dwarfPlanet }
        else if t.contains("volcanic") || t.contains("lava") || t.contains("molten") { self = .volcanic }
        else if t.contains("frozen") || t.contains("icy") || t.contains("ice") { self = .frozen }
        else if t.contains("barren") || t.contains("rock") { self = .barren }
        else { self = .unknown(raw) }
    }
}

/// A body's atmospheric thickness, from the scan's `physical.atmosphere` string. This
/// is a dedicated backend field on a clean ordinal scale (`none` … `crushing`) — it is
/// NOT derivable from planet type or temperature (e.g. SOL-2, a Desert World, reads
/// `crushing`), so it must be read straight from the scan. `unknown` covers the empty
/// value a not-yet-scanned body carries, and any unrecognized label; it renders no
/// atmosphere shell (we only draw one for a confirmed reading).
enum Atmosphere: Equatable, Sendable {
    case none
    case thin
    case standard
    case dense
    case crushing
    /// Absent (unscanned) or an unrecognized label — no shell drawn.
    case unknown

    init(apiValue: String?) {
        switch (apiValue ?? "").lowercased() {
        case "none":     self = .none
        case "thin":     self = .thin
        case "standard": self = .standard
        case "dense":    self = .dense
        case "crushing": self = .crushing
        default:         self = .unknown
        }
    }
}
