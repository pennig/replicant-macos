//
//  ScanDTOs.swift
//  UniverseModels
//
//  Decode + mapping for the system scan response
//  (`POST /v1/replicants/{code}/scan`). The scan is the ONLY source of a
//  system's shops, `system_objects` (megastructures + threats like incoming
//  asteroids), and `outer_system` (Kuiper/Oort) — the `locations/{star}`
//  endpoint returns none of them. It's also a full re-scan of the current
//  system, so it doubles as an authoritative refresh of the star/roster/belts.
//
//  Same round-trip strategy as `LocationDTOs`: re-encode the generated body to
//  JSON and decode with `.convertFromSnakeCase` into these all-optional DTOs.
//

import Foundation

struct RawScan: Decodable {
    var star: RawStar?
    var entryPoint: String?
    var planets: [RawPlanet]?
    var asteroidBelt: RawBeltContainer?
    var shops: [RawShop]?
    var systemObjects: [RawSystemObject]?
    var outerSystem: RawOuterSystem?
    var activeLocationEvents: [RawEvent]?
    var miningBonusPct: Double?
}

struct RawShop: Decodable {
    var controllerCode: String?
    var shopName: String?
    var description: String?
    var location: String?
    var locationName: String?
    var ownerName: String?
    var ownerReplicantCode: String?
    var trades: [RawTrade]?
}

struct RawTrade: Decodable {
    var tradeCode: String?
    var name: String?
    var currentStock: Int?
    var criteria: RawTradeCriteria?
    var rewards: RawTradeRewards?
}

struct RawTradeCriteria: Decodable {
    var resources: [String: Double]?
}

struct RawTradeRewards: Decodable {
    var devices: [String: Int]?
}

struct RawSystemObject: Decodable {
    var designation: String?
    var objectType: String?
    var megastructureType: String?
    var title: String?
    var description: String?
    var status: String?
    var stage: String?
    var location: String?
    var starDesignation: String?
    var orbitalDistanceAu: Double?
    var progressPercentage: Double?
    var deadline: String?
    var requirements: [String: RawRequirement]?
}

struct RawOuterSystem: Decodable {
    var kuiper: RawOuterRegion?
    var oort: RawOuterRegion?
}

struct RawOuterRegion: Decodable {
    var designation: String?
    var distanceAu: Double?
}

// MARK: - Mapping

extension RawShop {
    var domain: Shop? {
        guard let controllerCode, let location else { return nil }
        return Shop(
            controllerCode: controllerCode, shopName: shopName ?? "Shop",
            shopDescription: description, location: location, locationName: locationName,
            ownerReplicantCode: ownerReplicantCode, ownerName: ownerName,
            trades: (trades ?? []).compactMap(\.domain)
        )
    }
}

extension RawTrade {
    var domain: ShopTrade? {
        guard let tradeCode else { return nil }
        return ShopTrade(
            tradeCode: tradeCode, name: name ?? tradeCode, currentStock: currentStock,
            criteria: criteria?.resources ?? [:], rewards: rewards?.devices ?? [:]
        )
    }
}

extension RawSystemObject {
    var domain: SpecialSite? {
        guard let designation else { return nil }
        let kind: SpecialSiteKind = objectType == "megastructure" ? .megastructure : .object
        return SpecialSite(
            designation: designation, kind: kind, objectType: objectType,
            name: megastructureType, title: title, siteDescription: description,
            status: status, stage: stage, parentBody: nil, orbitalDistanceAu: orbitalDistanceAu,
            progressPercentage: progressPercentage, deadline: deadline,
            requirements: (requirements ?? [:]).domain
        )
    }
}

extension RawOuterRegion {
    func domain(kind: SpecialSiteKind) -> SpecialSite? {
        guard let designation else { return nil }
        return SpecialSite(
            designation: designation, kind: kind, label: kind.label,
            orbitalDistanceAu: distanceAu
        )
    }
}

extension RawScan {
    /// Build a `StarSystem` from a full system scan. The scan implies we're
    /// present and scanning, so the system reads as `.scanned` when every
    /// rostered planet is scanned, else `.visited`.
    func system() -> StarSystem? {
        guard let designation = star?.designation else { return nil }
        let planetDomains = (planets ?? []).compactMap { raw -> Planet? in
            guard var p = raw.domain else { return nil }
            p.salvage = raw.salvageSites
            return p
        }
        let scannedAll = !planetDomains.isEmpty && planetDomains.allSatisfy { $0.recon == .scanned }

        var structures = (systemObjects ?? []).compactMap(\.domain)
        if let k = outerSystem?.kuiper?.domain(kind: .kuiper) { structures.append(k) }
        if let o = outerSystem?.oort?.domain(kind: .oort) { structures.append(o) }

        return StarSystem(
            designation: designation,
            name: star?.name,
            star: star.map {
                SystemStar(
                    designation: $0.designation ?? designation, name: $0.name,
                    stellarClass: $0.stellarClass, color: $0.color, ageMy: $0.ageMy,
                    miningBonusPct: $0.miningBonusPct ?? miningBonusPct,
                    distanceFromSol: $0.distanceFromSol, position: $0.position
                )
            },
            recon: scannedAll ? .scanned : .visited,
            systemScanned: true,
            entryPoint: entryPoint,
            planetsScanned: planetDomains.filter { $0.recon == .scanned }.count,
            planetsTotal: planetDomains.count,
            belts: (asteroidBelt?.belts ?? []).compactMap { $0.domain() },
            planets: planetDomains,
            structures: structures,
            shops: (shops ?? []).compactMap(\.domain),
            events: (activeLocationEvents ?? []).compactMap(\.domain)
        )
    }
}

// MARK: - Merge (preserve hydrated per-body detail)

extension StarSystem {
    /// Overlay a fresh scan onto this (possibly already-hydrated) system. The
    /// scan is authoritative for shops / structures / events / counts and the
    /// planet & belt rosters, but we keep any richer per-body detail (physical,
    /// moons, sites) we'd previously fetched via `body(_:)`.
    public func mergingScan(_ scanned: StarSystem) -> StarSystem {
        var result = scanned
        result.planets = scanned.planets.map { fresh in
            guard let existing = planets.first(where: { $0.designation == fresh.designation }) else {
                return fresh
            }
            let existingIsRicher = existing.physical != nil || !existing.moons.isEmpty
                || !existing.sites.isEmpty || existing.recon == .scanned
            // Keep the richer body, but always take the fresh salvage roster.
            var kept = existingIsRicher ? existing : fresh
            if kept.salvage.isEmpty { kept.salvage = fresh.salvage }
            return kept
        }
        result.belts = scanned.belts.map { fresh in
            guard let existing = belts.first(where: { $0.designation == fresh.designation }) else {
                return fresh
            }
            return existing.sites.isEmpty && existing.inventory.isEmpty ? fresh : existing
        }
        // Preserve moon/site counts we may have known.
        if result.moonsTotal == nil { result.moonsTotal = moonsTotal }
        if result.moonsScanned == nil { result.moonsScanned = moonsScanned }
        return result
    }
}
