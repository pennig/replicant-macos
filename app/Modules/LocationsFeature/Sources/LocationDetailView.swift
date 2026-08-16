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
import GameModels
import GameServices
import SQLiteData
import SwiftUI
import TravelUI
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
                    SystemInspector(system: system, accessory: topAccessory, assayTotals: store.assayTotals)
                } else if let planet = system.planets.first(where: { $0.designation == id }) {
                    PlanetInspector(planet: planet, accessory: topAccessory, assayTotals: store.assayTotals)
                } else if let moon = system.planets.flatMap(\.moons).first(where: { $0.designation == id }) {
                    MoonInspector(moon: moon, accessory: topAccessory, assayTotals: store.assayTotals)
                } else if let belt = system.belts.first(where: { $0.designation == id }) {
                    BeltInspector(belt: belt, accessory: topAccessory, assayTotals: store.assayTotals)
                } else if let object = system.structures.first(where: { $0.designation == id }) {
                    ObjectInspector(site: object, accessory: topAccessory)
                } else if let n = LocationTree.lPointNumber(id),
                          let planet = system.planets.first(where: { id == "\($0.designation)-L\(n)" }) {
                    LagrangeInspector(
                        designation: id, point: n, planet: planet,
                        site: planet.lagrange.first { $0.designation == id },
                        accessory: topAccessory
                    )
                } else {
                    hydratingOrEmpty
                }
            } else if store.selection != nil {
                hydratingOrEmpty
            } else {
                RCContentUnavailableView(
                    "No Location Selected",
                    systemImage: "globe.americas",
                    description: Text("Select a system or body to inspect it.")
                )
            }
        }
        // Item-driven (not `isPresented:`) so back-to-back previews for different
        // locations re-present reliably — keyed on the preview's identity, SwiftUI
        // swaps sheets even when the change lands mid-dismiss-animation, which a
        // bool toggled off→on silently drops.
        .sheet(
            item: Binding(
                get: { store.travelPreview },
                set: { if $0 == nil { store.send(.travelPreviewDismissed) } }
            )
        ) { _ in
            TravelPlanSheet(
                preview: store.travelPreview,
                onConfirm: { store.send(.travelPreviewConfirmed) },
                onDismiss: { store.send(.travelPreviewDismissed) }
            )
        }
    }

    /// The right-aligned actions shown across from the inspector's title. Travel is
    /// offered for any location that isn't precisely the host's current one (if the
    /// vessel can `surge`) — including intra-system hops; Scan System is offered
    /// whenever the viewed location sits in the host's current system (if it can
    /// `system_scan`). The two aren't mutually exclusive: when both apply, Scan
    /// takes the secondary treatment and sits to the left of the primary Travel
    /// button. Nil when neither applies.
    private var topAccessory: AnyView? {
        guard let selection = store.selection, !selection.isEmpty else { return nil }
        let showScan = store.canScanSystem && store.selectedSystemID == store.activeCurrentStar
        // A system node (`SOL`) is "current" whenever the host sits anywhere inside
        // it, so its Travel button only shows for a different star system. A body
        // (`SOL-3`) compares against the host's exact location, so intra-system hops
        // stay travellable.
        let viewingSystem = selection == store.selectedSystemID
        let isCurrent = viewingSystem
            ? selection == store.activeCurrentStar
            : selection == store.activeCurrentLocation
        let travelCode = store.canSurge && !isCurrent
            ? store.activeHostDevice?.deviceCode : nil
        guard showScan || travelCode != nil else { return nil }
        return AnyView(
            HStack(spacing: Space.s) {
                if showScan {
                    Button {
                        store.send(.scanRequested)
                    } label: {
                        Label(store.isScanning ? "Scanning…" : "Scan System",
                              systemImage: "dot.radiowaves.left.and.right")
                    }
                    // Secondary when Travel is alongside it, otherwise the lone
                    // prominent action.
                    .buttonStyle(RCButtonStyle(travelCode != nil ? .secondary : .primary))
                    .disabled(store.isScanning)
                    .help("Scan reveals shops, megastructures, and outer-system objects here.")
                }
                if let travelCode {
                    Button {
                        store.send(.travelRequested(deviceCode: travelCode, destination: selection))
                    } label: {
                        Label("Travel", systemImage: "location.north.line")
                    }
                    .buttonStyle(RCButtonStyle(.primary))
                    .help("Plot a route to \(selection).")
                }
            }
        )
    }

    @ViewBuilder
    private var hydratingOrEmpty: some View {
        if let id = store.selectedSystemID, store.hydrating.contains(id) {
            ProgressView("Scanning \(id)…").controlSize(.small)
        } else {
            RCContentUnavailableView(
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
    let accessory: AnyView?
    let assayTotals: [String: [String: Double]]

    var body: some View {
        InspectorScroll(
            title: system.name ?? system.designation, code: system.designation,
            recon: system.recon, accessory: accessory,
            portrait: system.star.map { _ in AnyView(PortraitFrame { Color.clear }) },
            facts: system.star.map { BodyFacts.rows(star: $0) } ?? []
        ) {
            RCReadoutCard("System") {
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
                RCReadoutCard("Shops", count: system.shops.count) {
                    ForEach(system.shops) { shop in
                        BubbleRow(title: shop.shopName, code: shop.location,
                                  detail: shop.ownerName.map { "by \($0)" })
                    }
                }
            }

            let sites = system.allResourceSites
            if !sites.isEmpty {
                RCReadoutCard("Resource Sites", count: sites.count) {
                    ForEach(sites) { site in
                        SiteAmountsRow(
                            title: site.name ?? site.designation, code: site.designation,
                            amounts: SiteAmounts.amounts(
                                remainingPct: site.remaining, totals: assayTotals[site.designation]
                            ),
                            status: nil
                        )
                    }
                }
            }

            let salvage = system.remainingSalvageSites
            if !salvage.isEmpty {
                RCReadoutCard("Salvage", count: salvage.count) {
                    ForEach(salvage) { s in
                        SiteAmountsRow(
                            title: s.name ?? s.designation, code: s.designation,
                            amounts: SiteAmounts.amounts(for: s, totals: assayTotals[s.designation])
                        )
                    }
                }
            }

            let holdings = system.inventoryHoldings
            if !holdings.isEmpty {
                RCReadoutCard("Inventory", count: holdings.count) {
                    ForEach(holdings) { holding in
                        InventoryHoldingRow(holding: holding)
                    }
                }
            }

            if !system.structures.isEmpty {
                RCReadoutCard("Structures & Objects", count: system.structures.count) {
                    ForEach(system.structures) { site in
                        StructureRow(site: site)
                    }
                }
            }

            if !system.allEvents.isEmpty {
                RCReadoutCard("Events", count: system.allEvents.count) {
                    ForEach(system.allEvents) { event in
                        BubbleRow(title: event.title ?? event.eventType ?? event.designation,
                                  code: event.location ?? event.designation, detail: event.status?.capitalized)
                    }
                }
            }
        }
    }
}

private struct PlanetInspector: View {
    let planet: Planet
    let accessory: AnyView?
    let assayTotals: [String: [String: Double]]
    var body: some View {
        InspectorScroll(
            title: planet.name ?? planet.designation, code: planet.designation,
            recon: planet.recon, accessory: accessory,
            portrait: AnyView(PortraitFrame { Color.clear }),
            facts: BodyFacts.rows(planet: planet)
        ) {
            if let phys = planet.physical { PhysicalCard(phys) }
            SiteSalvageSections(sites: planet.sites, salvage: planet.remainingSalvage, assayTotals: assayTotals)
            // Roll up the planet's own stock plus any held on its moons, attributed
            // per body.
            let holdings = planet.inventoryHoldings
            if !holdings.isEmpty {
                RCReadoutCard("Inventory", count: holdings.count) {
                    ForEach(holdings) { InventoryHoldingRow(holding: $0) }
                }
            }
        }
    }
}

private struct MoonInspector: View {
    let moon: Moon
    let accessory: AnyView?
    let assayTotals: [String: [String: Double]]
    var body: some View {
        InspectorScroll(
            title: moon.name ?? moon.designation, code: moon.designation,
            recon: moon.recon, accessory: accessory,
            portrait: AnyView(PortraitFrame { Color.clear }),
            facts: BodyFacts.rows(moon: moon)
        ) {
            if let phys = moon.physical { PhysicalCard(phys, promoted: true) }
            SiteSalvageSections(sites: moon.sites, salvage: moon.remainingSalvage, assayTotals: assayTotals)
            InventoryCard(moon.inventory)
        }
    }
}

private struct BeltInspector: View {
    let belt: Belt
    let accessory: AnyView?
    let assayTotals: [String: [String: Double]]
    var body: some View {
        InspectorScroll(
            title: belt.designation, code: belt.designation,
            recon: .scanned, accessory: accessory,
            portrait: AnyView(PortraitFrame { Color.clear }),
            facts: BodyFacts.rows(belt: belt)
        ) {
            if !belt.richness.isEmpty {
                RCReadoutCard("Richness") {
                    ForEach(belt.richness.sorted(by: { $0.key < $1.key }), id: \.key) { name, level in
                        Readout(name.capitalized, level.capitalized)
                    }
                }
            }
            if !belt.sites.isEmpty {
                RCReadoutCard("Resource Sites", count: belt.sites.count) {
                    ForEach(belt.sites) { site in
                        SiteAmountsRow(
                            title: site.name ?? site.designation, code: site.designation,
                            amounts: SiteAmounts.amounts(
                                remainingPct: site.remaining, totals: assayTotals[site.designation]
                            ),
                            status: nil
                        )
                    }
                }
            }
            InventoryCard(belt.inventory)
        }
    }
}

private struct ObjectInspector: View {
    let site: SpecialSite
    let accessory: AnyView?
    var body: some View {
        InspectorScroll(
            title: site.title ?? site.name ?? site.designation, code: site.designation,
            recon: .scanned, accessory: accessory,
            portrait: AnyView(PortraitFrame { Color.clear }),
            facts: BodyFacts.rows(site: site)
        ) {
            if let p = site.progressPercentage {
                RCReadoutCard("Construction") {
                    ProgressView(value: min(max(p / 100, 0), 1)).tint(.rcAccent)
                    Text("\(Int(p))% complete").font(.rcCaption).foregroundStyle(.rcTextTertiary)
                }
            }
            if !site.requirements.isEmpty {
                RCReadoutCard("Requirements", count: site.requirements.count) {
                    ForEach(site.requirements) { req in
                        Readout(req.deviceType.replacingOccurrences(of: "_", with: " ").capitalized,
                                "\(req.current)/\(req.required)")
                    }
                }
            }
            InventoryCard(site.inventory)
        }
    }
}

/// A planet's Lagrange point. Renders from the synthesized designation alone (so
/// it works before hydration and stays a valid travel target); a hydrated
/// `SpecialSite` fills in the orbital distance and any stored inventory.
private struct LagrangeInspector: View {
    let designation: String
    let point: Int
    let planet: Planet
    let site: SpecialSite?
    let accessory: AnyView?
    var body: some View {
        InspectorScroll(
            title: "L\(point)", code: designation,
            recon: site != nil ? .scanned : .aware, accessory: accessory,
            portrait: AnyView(PortraitFrame { Color.clear }),
            facts: BodyFacts.rows(lagrangePoint: point, parent: planet, site: site)
        ) {
            InventoryCard(site?.inventory ?? [])
        }
    }
}

// MARK: - Building blocks

/// The stored-inventory card shared by every body inspector (belt, planet, moon,
/// object). Renders nothing when the body holds no inventory.
private struct InventoryCard: View {
    let items: [InventoryItem]
    init(_ items: [InventoryItem]) { self.items = items }
    var body: some View {
        if !items.isEmpty {
            RCReadoutCard("Inventory") {
                ForEach(items, id: \.resourceType) { item in
                    Readout(item.resourceType.capitalized, item.quantity.formatted(.number.precision(.fractionLength(0))))
                }
            }
        }
    }
}

/// One body's holdings in the system inspector's Inventory card: the body header
/// over its per-resource quantities.
private struct InventoryHoldingRow: View {
    let holding: InventoryHolding
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            VStack(alignment: .leading, spacing: 1) {
                Text(holding.displayName).font(.rcMono).foregroundStyle(.rcTextPrimary)
                Text(holding.designation).font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
            }
            ForEach(holding.inventory, id: \.resourceType) { item in
                HStack {
                    Text(item.resourceType.capitalized).font(.rcCaption).foregroundStyle(.rcTextSecondary)
                    Spacer()
                    Text(item.quantity.formatted(.number.precision(.fractionLength(0)))).font(.rcMonoSmall).foregroundStyle(.rcTextPrimary)
                }
            }
        }
    }
}

private struct SiteSalvageSections: View {
    let sites: [ResourceSite]
    let salvage: [SalvageSite]
    let assayTotals: [String: [String: Double]]
    var body: some View {
        if !sites.isEmpty {
            RCReadoutCard("Resource Sites", count: sites.count) {
                ForEach(sites) { site in
                    SiteAmountsRow(
                        title: site.name ?? site.designation, code: site.designation,
                        amounts: SiteAmounts.amounts(
                            remainingPct: site.remaining, totals: assayTotals[site.designation]
                        ),
                        status: nil
                    )
                }
            }
        }
        if !salvage.isEmpty {
            RCReadoutCard("Salvage", count: salvage.count) {
                ForEach(salvage) { s in
                    SiteAmountsRow(
                        title: s.name ?? s.designation, code: s.designation,
                        // `SiteAmounts.amounts(for:)` handles both salvage
                        // shapes: a hydrated site reads live (`132 / 331 40%`),
                        // and a site with names but no percentages — the
                        // `salvage[]` roster block, a scan body, a discovery
                        // event — still reports its assayed total as a
                        // discovered figure rather than a bare name.
                        amounts: SiteAmounts.amounts(for: s, totals: assayTotals[s.designation])
                    )
                }
            }
        }
    }
}

private struct PhysicalCard: View {
    let phys: BodyPhysical
    /// Radius, gravity, surface temp and atmosphere already sit in the header.
    let promoted: Bool
    init(_ phys: BodyPhysical, promoted: Bool = false) {
        self.phys = phys; self.promoted = promoted
    }
    var body: some View {
        RCReadoutCard("Physical") {
            if let m = phys.massEarth { Readout("Mass", String(format: "%.2f M⊕", m)) }
            if !promoted, let r = phys.radiusEarth { Readout("Radius", String(format: "%.2f R⊕", r)) }
            if let d = phys.densityGcc { Readout("Density", String(format: "%.2f g/cc", d)) }
            if !promoted, let g = phys.surfaceGravity { Readout("Gravity", String(format: "%.2f g", g)) }
            if !promoted, let t = phys.surfaceTempC { Readout("Surface", String(format: "%.0f °C", t)) }
            if !promoted, let a = phys.atmosphere { Readout("Atmosphere", a.capitalized) }
            if phys.tidallyLocked == true { Readout("Tidally locked", "Yes") }
            if phys.hasSubsurfaceOcean == true { Readout("Subsurface ocean", "Yes") }
            if !phys.tags.isEmpty { Readout("Tags", phys.tags.joined(separator: ", ")) }
        }
    }
}

/// The house chrome every 128pt header square shares: raised surface, hairline
/// border, card radius. Wraps whatever the location's rendering turns out to be.
private struct PortraitFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: TileSize.portrait, height: TileSize.portrait)
            .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

private struct InspectorScroll<Content: View>: View {
    let title: String
    let code: String
    let recon: Recon
    var accessory: AnyView? = nil
    /// The 128pt body rendering shown leading the header, when the location has one.
    var portrait: AnyView? = nil
    /// Key facts promoted beside the portrait to fill the header's height.
    var facts: [BodyFact] = []
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .top, spacing: Space.m) {
                    if let portrait {
                        portrait
                            .frame(width: TileSize.portrait, height: TileSize.portrait)
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(title).font(.rcTitleMono).foregroundStyle(.rcTextPrimary)
                            HStack(spacing: Space.s) {
                                Text(code).font(.rcMono).foregroundStyle(.rcTextTertiary)
                                ReconDot(recon: recon)
                                Text(recon.label).font(.rcCaption).foregroundStyle(.rcTextTertiary)
                            }
                        }
                        ForEach(facts, id: \.label) { fact in
                            Readout(fact.label, fact.value, mono: fact.mono)
                        }
                    }
                    if let accessory {
                        Spacer(minLength: 0)
                        accessory
                    }
                }
                .frame(height: portrait == nil ? nil : TileSize.portrait, alignment: .top)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.l)
        }
        .navigationTitle(title)
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
            Text(value).font(mono ? .rcBodyEmphMono : .rcBodyEmph).monospacedDigit().foregroundStyle(.rcTextPrimary)
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
                        .font(.rcMono).foregroundStyle(.rcTextPrimary)
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
                Text(title).font(.rcMono).foregroundStyle(.rcTextPrimary)
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
