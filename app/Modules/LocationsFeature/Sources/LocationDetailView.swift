//
//  LocationDetailView.swift
//  LocationsFeature
//
//  The catalog's inspector pane. Resolves the current selection against the
//  hydrated `StarSystem` blob and renders whichever body was picked. A system
//  bubbles up everything beneath it — shops, resource sites, salvage — so the
//  interesting holdings are visible without drilling in.
//

import ComposableArchitecture
import DependencyClients
import SQLiteData
import SwiftUI
import UI
import UniverseModels

public struct LocationDetailView: View {
    let store: StoreOf<LocationsFeature>

    public init(store: StoreOf<LocationsFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if let id = store.selection, let system = store.selectedSystem {
                if id == system.designation {
                    SystemInspector(
                        system: system,
                        isCurrentSystem: system.designation == store.currentStar,
                        isScanning: store.isScanning,
                        onScan: { store.send(.scanRequested) }
                    )
                } else if let planet = system.planets.first(where: { $0.designation == id }) {
                    PlanetInspector(planet: planet)
                } else if let moon = system.planets.flatMap(\.moons).first(where: { $0.designation == id }) {
                    MoonInspector(moon: moon)
                } else if let belt = system.belts.first(where: { $0.designation == id }) {
                    BeltInspector(belt: belt)
                } else {
                    hydratingOrEmpty
                }
            } else if store.selection != nil {
                hydratingOrEmpty
            } else {
                ContentUnavailableView(
                    "No Location Selected",
                    systemImage: "globe.americas",
                    description: Text("Select a system or body to inspect it.")
                )
            }
        }
    }

    @ViewBuilder
    private var hydratingOrEmpty: some View {
        if let id = store.selectedSystemID, store.hydrating.contains(id) {
            ProgressView("Scanning \(id)…").controlSize(.small)
        } else {
            ContentUnavailableView(
                "Uncharted",
                systemImage: "sparkles",
                description: Text("Travel to this system and scan it to reveal its bodies.")
            )
        }
    }
}

// MARK: - Inspectors

private struct SystemInspector: View {
    let system: StarSystem
    let isCurrentSystem: Bool
    let isScanning: Bool
    let onScan: () -> Void

    var body: some View {
        InspectorScroll(title: system.name ?? system.designation, code: system.designation, recon: system.recon) {
            if isCurrentSystem {
                Button(action: onScan) {
                    Label(isScanning ? "Scanning…" : "Scan System", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.rcAccent)
                .disabled(isScanning)
                .help("Scan reveals shops, megastructures, and outer-system objects here.")
            }

            if let star = system.star {
                ReadoutCard("Star") {
                    Readout("Class", star.stellarClass ?? "—")
                    Readout("Color", star.color?.capitalized ?? "—")
                    if let age = star.ageMy { Readout("Age", String(format: "%.0f My", age)) }
                    if let bonus = star.miningBonusPct, bonus != 0 { Readout("Mining bonus", "+\(Int(bonus))%") }
                    if let d = star.distanceFromSol { Readout("From Sol", String(format: "%.1f ly", d)) }
                }
            }

            ReadoutCard("System") {
                if let s = system.planetsScanned, let t = system.planetsTotal {
                    Readout("Planets", "\(s)/\(t) scanned")
                }
                if let s = system.moonsScanned, let t = system.moonsTotal {
                    Readout("Moons", "\(s)/\(t) scanned")
                }
                Readout("Belts", "\(system.belts.count)")
                if let entry = system.entryPoint { Readout("Entry point", entry, mono: true) }
            }

            if !system.shops.isEmpty {
                SectionCard("Shops", count: system.shops.count) {
                    ForEach(system.shops) { shop in
                        BubbleRow(title: shop.shopName, code: shop.location,
                                  detail: shop.ownerName.map { "by \($0)" })
                    }
                }
            }

            let sites = system.allResourceSites
            if !sites.isEmpty {
                SectionCard("Resource Sites", count: sites.count) {
                    ForEach(sites) { site in
                        BubbleRow(title: site.name ?? site.designation, code: site.designation,
                                  detail: remainingSummary(site.remaining))
                    }
                }
            }

            let salvage = system.allSalvageSites
            if !salvage.isEmpty {
                SectionCard("Salvage", count: salvage.count) {
                    ForEach(salvage) { s in
                        BubbleRow(title: s.name ?? s.designation, code: s.designation,
                                  detail: (s.depleted ? "Depleted · " : "") + s.resourcesAvailable.joined(separator: ", "))
                    }
                }
            }

            if !system.structures.isEmpty {
                SectionCard("Structures & Objects", count: system.structures.count) {
                    ForEach(system.structures) { site in
                        StructureRow(site: site)
                    }
                }
            }

            if !system.allEvents.isEmpty {
                SectionCard("Events", count: system.allEvents.count) {
                    ForEach(system.allEvents) { event in
                        BubbleRow(title: event.title ?? event.eventType ?? event.designation,
                                  code: event.location ?? event.designation, detail: event.status?.capitalized)
                    }
                }
            }
        }
    }

    private func remainingSummary(_ remaining: [String: Double]) -> String? {
        guard !remaining.isEmpty else { return nil }
        let avg = remaining.values.reduce(0, +) / Double(remaining.count)
        return String(format: "%.0f%% remaining", avg)
    }
}

private struct PlanetInspector: View {
    let planet: Planet
    var body: some View {
        InspectorScroll(title: planet.name ?? planet.designation, code: planet.designation, recon: planet.recon) {
            ReadoutCard("Planet") {
                Readout("Type", (planet.type ?? "—") + (planet.typeEstimated ? " (est.)" : ""))
                if let au = planet.orbitalDistanceAu { Readout("Orbit", String(format: "%.2f AU", au)) }
                Readout("Habitable zone", planet.inHabitableZone ? "Yes" : "No")
                if let life = planet.lifeStage, life != "none" { Readout("Life", life.capitalized) }
                if let n = planet.moonCount { Readout("Moons", "\(n)") }
            }
            if let phys = planet.physical { PhysicalCard(phys) }
            SiteSalvageSections(sites: planet.sites, salvage: planet.salvage)
        }
    }
}

private struct MoonInspector: View {
    let moon: Moon
    var body: some View {
        InspectorScroll(title: moon.name ?? moon.designation, code: moon.designation, recon: moon.recon) {
            ReadoutCard("Moon") {
                Readout("Type", moon.type ?? "—")
            }
            if let phys = moon.physical { PhysicalCard(phys) }
            SiteSalvageSections(sites: moon.sites, salvage: moon.salvage)
        }
    }
}

private struct BeltInspector: View {
    let belt: Belt
    var body: some View {
        InspectorScroll(title: belt.designation, code: belt.designation, recon: .scanned) {
            ReadoutCard("Belt") {
                if let d = belt.density { Readout("Density", d.capitalized) }
                if let inner = belt.innerRadiusAu, let outer = belt.outerRadiusAu {
                    Readout("Radius", String(format: "%.1f–%.1f AU", inner, outer))
                }
            }
            if !belt.richness.isEmpty {
                SectionCard("Richness", count: belt.richness.count) {
                    ForEach(belt.richness.sorted(by: { $0.key < $1.key }), id: \.key) { name, level in
                        Readout(name.capitalized, level.capitalized)
                    }
                }
            }
            if !belt.sites.isEmpty {
                SectionCard("Resource Sites", count: belt.sites.count) {
                    ForEach(belt.sites) { site in
                        BubbleRow(title: site.name ?? site.designation, code: site.designation,
                                  detail: site.remaining.isEmpty ? nil
                                      : "\(Int(site.remaining.values.reduce(0, +) / Double(site.remaining.count)))% remaining")
                    }
                }
            }
            if !belt.inventory.isEmpty {
                SectionCard("Stock", count: belt.inventory.count) {
                    ForEach(belt.inventory, id: \.resourceType) { item in
                        Readout(item.resourceType.capitalized, String(format: "%.0f", item.quantity))
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct SiteSalvageSections: View {
    let sites: [ResourceSite]
    let salvage: [SalvageSite]
    var body: some View {
        if !sites.isEmpty {
            SectionCard("Resource Sites", count: sites.count) {
                ForEach(sites) { site in
                    BubbleRow(title: site.name ?? site.designation, code: site.designation, detail: nil)
                }
            }
        }
        if !salvage.isEmpty {
            SectionCard("Salvage", count: salvage.count) {
                ForEach(salvage) { s in
                    BubbleRow(title: s.name ?? s.designation, code: s.designation,
                              detail: (s.depleted ? "Depleted · " : "") + s.resourcesAvailable.joined(separator: ", "))
                }
            }
        }
    }
}

private struct PhysicalCard: View {
    let phys: BodyPhysical
    init(_ phys: BodyPhysical) { self.phys = phys }
    var body: some View {
        ReadoutCard("Physical") {
            if let m = phys.massEarth { Readout("Mass", String(format: "%.2f M⊕", m)) }
            if let r = phys.radiusEarth { Readout("Radius", String(format: "%.2f R⊕", r)) }
            if let g = phys.surfaceGravity { Readout("Gravity", String(format: "%.2f g", g)) }
            if let t = phys.surfaceTempC { Readout("Surface", String(format: "%.0f °C", t)) }
            if let a = phys.atmosphere { Readout("Atmosphere", a.capitalized) }
            if phys.tidallyLocked == true { Readout("Tidally locked", "Yes") }
            if phys.hasSubsurfaceOcean == true { Readout("Subsurface ocean", "Yes") }
            if !phys.tags.isEmpty { Readout("Tags", phys.tags.joined(separator: ", ")) }
        }
    }
}

private struct InspectorScroll<Content: View>: View {
    let title: String
    let code: String
    let recon: Recon
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(title).font(.rcTitle).foregroundStyle(.rcTextPrimary)
                    HStack(spacing: Space.s) {
                        Text(code).font(.rcMono).foregroundStyle(.rcTextTertiary)
                        ReconDot(recon: recon)
                        Text(recon.label).font(.rcCaption).foregroundStyle(.rcTextTertiary)
                    }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.l)
        }
        .navigationTitle(title)
    }
}

private struct ReadoutCard<Content: View>: View {
    let heading: String
    @ViewBuilder let content: Content
    init(_ heading: String, @ViewBuilder content: () -> Content) {
        self.heading = heading; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(heading.uppercased()).font(.rcSectionLabel).foregroundStyle(.rcTextTertiary)
            VStack(alignment: .leading, spacing: Space.xs) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card))
    }
}

private struct SectionCard<Content: View>: View {
    let heading: String
    let count: Int
    @ViewBuilder let content: Content
    init(_ heading: String, count: Int, @ViewBuilder content: () -> Content) {
        self.heading = heading; self.count = count; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text(heading.uppercased()).font(.rcSectionLabel).foregroundStyle(.rcTextTertiary)
                Text("\(count)").font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
            }
            VStack(alignment: .leading, spacing: Space.xs) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card))
    }
}

private struct Readout: View {
    let label: String
    let value: String
    let mono: Bool
    init(_ label: String, _ value: String, mono: Bool = false) {
        self.label = label; self.value = value; self.mono = mono
    }
    var body: some View {
        HStack {
            Text(label).font(.rcBody).foregroundStyle(.rcTextSecondary)
            Spacer()
            Text(value).font(mono ? .rcMono : .rcBodyEmph).foregroundStyle(.rcTextPrimary)
        }
    }
}

private struct StructureRow: View {
    let site: SpecialSite

    private var isThreat: Bool { site.objectType == "incoming_asteroid" }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(site.title ?? site.name ?? site.designation)
                        .font(.rcBody).foregroundStyle(.rcTextPrimary)
                    Text(site.designation).font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
                }
                Spacer()
                Text((site.objectType ?? site.kind.rawValue).replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.rcCaption)
                    .foregroundStyle(isThreat ? .rcDanger : .rcTextSecondary)
            }
            if let p = site.progressPercentage {
                ProgressView(value: min(max(p / 100, 0), 1)).tint(.rcAccent)
                Text("\(Int(p))% complete").font(.rcCaption).foregroundStyle(.rcTextTertiary)
            }
            if let deadline = site.deadline {
                Label(deadline, systemImage: "clock")
                    .font(.rcCaption).foregroundStyle(isThreat ? .rcDanger : .rcWarning)
            }
        }
    }
}

private struct BubbleRow: View {
    let title: String
    let code: String
    let detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.rcBody).foregroundStyle(.rcTextPrimary)
                Text(code).font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
            }
            Spacer()
            if let detail {
                Text(detail).font(.rcCaption).foregroundStyle(.rcTextSecondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
