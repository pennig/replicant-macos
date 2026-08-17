//
//  TheatreRegistry.swift
//  Replicould — DirectiveEngine
//
//  Theatre recognition: a pin, else a system_hub, else derivation — sticky per system.
//

import Foundation
import GameModels
import UniverseModels

public enum TheatreRegistry {
    /// Every recognised theatre, ordered by depot designation. Ordering and
    /// tie-breaks are total, so two ticks over one world produce one answer.
    public static func recognise(
        devices: [Device],
        pins: [TheatrePin],
        records: [TheatreRecord],
        meshSystems: Set<String>,
        components: [String: String],
        stockByLocation: [String: Int]
    ) -> [Theatre] {
        let printLocations = Set(devices.filter(\.isPrintHub).compactMap(\.location))

        func readiness(of depot: String) -> Theatre.Readiness {
            var missing: Set<Theatre.Shortfall> = []
            if !printLocations.contains(depot) { missing.insert(.noPrintCapableDevice) }
            if (stockByLocation[depot] ?? 0) <= 0 { missing.insert(.noStock) }
            if !meshSystems.contains(SiteAssay.system(of: depot)) { missing.insert(.offMesh) }
            return missing.isEmpty ? .operational : .claimed(missing: missing)
        }

        func theatre(depot: String, origin: Theatre.Origin) -> Theatre {
            Theatre(
                depot: depot, system: SiteAssay.system(of: depot), origin: origin,
                readiness: readiness(of: depot), stock: stockByLocation[depot] ?? 0
            )
        }

        let established = Dictionary(
            records.map { ($0.system, $0.depot) }, uniquingKeysWith: { first, _ in first }
        )
        /// `system`'s persisted depot when it still holds a print-capable
        /// device, else nil.
        func persistedDepot(of system: String) -> String? {
            established[system].flatMap { printLocations.contains($0) ? $0 : nil }
        }

        /// Richest stocked print location among `candidates`, designation as the
        /// tie-break — a TOTAL order, so recognition names the same depot every tick.
        func richest(among candidates: Set<String>) -> String? {
            candidates
                .filter { printLocations.contains($0) && (stockByLocation[$0] ?? 0) > 0 }
                .max {
                    let (left, right) = (stockByLocation[$0] ?? 0, stockByLocation[$1] ?? 0)
                    return left == right ? $0 > $1 : left < right
                }
        }

        var claimedSystems: Set<String> = []
        var result: [Theatre] = []

        for pin in pins {
            result.append(theatre(depot: pin.location, origin: .pinned))
            claimedSystems.insert(SiteAssay.system(of: pin.location))
        }

        for hub in devices.filter({ $0.deviceType == "system_hub" }).sorted(by: { $0.deviceCode < $1.deviceCode }) {
            guard let hubLocation = hub.location else { continue }
            let system = SiteAssay.system(of: hubLocation)
            guard !claimedSystems.contains(system) else { continue }
            let inSystem = Set(printLocations.filter { SiteAssay.system(of: $0) == system })
            let depot = persistedDepot(of: system) ?? richest(among: inSystem) ?? hubLocation
            result.append(theatre(depot: depot, origin: .systemHub(hub.deviceCode)))
            claimedSystems.insert(system)
        }

        let servedComponents = Set(
            result.filter(\.isOperational).compactMap { components[$0.system] }
        )
        var byComponent: [String: Set<String>] = [:]
        for location in printLocations {
            guard let component = components[SiteAssay.system(of: location)] else { continue }
            byComponent[component, default: []].insert(location)
        }
        for (component, candidates) in byComponent.sorted(by: { $0.key < $1.key }) {
            guard !servedComponents.contains(component) else { continue }
            let unclaimed = candidates.filter { !claimedSystems.contains(SiteAssay.system(of: $0)) }
            let sticky = unclaimed.filter { persistedDepot(of: SiteAssay.system(of: $0)) == $0 }.min()
            guard let depot = sticky ?? richest(among: unclaimed) else { continue }
            result.append(theatre(depot: depot, origin: .derived))
        }

        return result.sorted { $0.depot < $1.depot }
    }
}
