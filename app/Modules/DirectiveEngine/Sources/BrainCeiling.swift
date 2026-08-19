//
//  BrainCeiling.swift
//  Replicould — DirectiveEngine
//
//  The `R` reserve-floor rail: the ceiling on the brain's relay-print spending.
//  Printing an FTL relay draws real resources from the hub stock the rest of the
//  fleet shares, so this rail vetoes a print that would leave the hub short.
//
//  Pure by contract, like every mission primitive: no I/O, no clock, nothing
//  but a table lookup and a comparison, so its behaviour is provable under
//  test without a live account. The full record — the probed bill, the
//  binding-type analysis and `K`'s calibration — is
//  `app/.claude/memory/brain-relay-reserve-floor.md`.
//

/// The reserve-floor rail. `printPermitted(hubStock:)` is the true per-type `R`
/// check — it vetoes a print whenever ANY resource type at the hub would drop
/// below `K` relays' worth of that type's blueprint bill. `aggregateSpendFloor`
/// is the conservative TOTAL-only proxy `RelayRun` arms in its place, having no
/// per-type stock reading to feed the real check.
public enum BrainCeiling {
    /// The FTL relay's per-type blueprint bill (`GET blueprints`,
    /// `device_type: ftl_relay`). It sums to 370 units TOTAL across all six
    /// types; reading it as 370 PER type, and flooring on that, vetoes on
    /// volatiles — 37× its real bill — long before conductive, 3× its own,
    /// ever binds.
    public static let relayBill: [String: Double] = [
        "carbon": 20, "conductive": 120, "rares": 40,
        "silicates": 100, "structural": 80, "volatiles": 10,
    ]

    /// The six resource types the rail speaks in, DERIVED from `relayBill`'s
    /// own keys and sorted for a stable order.
    ///
    /// Never restate this as a second, parallel literal: a type billed above
    /// with no matching entry here floors to zero in `reserveFloor(for:)`, and
    /// `printPermitted` then silently PERMITS that type at any stock level — a
    /// fail-open hole inside a fail-closed predicate.
    public static let resourceTypes: [String] = relayBill.keys.sorted()

    /// **CALIBRATE.** How many relays' worth of each resource type the hub must
    /// keep in reserve before a print may touch it — the one knob on this type;
    /// every other constant here is a verified game fact.
    ///
    /// Anchored on conductive, the type `relaysUntilBindingTypeFloors` finds
    /// binds first: a `K` calibrated against any other type guards a floor that
    /// never fires. Recalibrating means re-deriving the two-sided trade recorded
    /// in `brain-relay-reserve-floor`, not picking a percentage.
    public static let reserveRelays: Double = 5 // CALIBRATE: surfaced in why-view

    /// The reserve floor for one resource type: `reserveRelays` relays' worth of
    /// `type`'s bill. A type absent from `relayBill` floors to zero rather than
    /// trapping, and cannot occur while `resourceTypes` derives from those keys.
    public static func reserveFloor(for type: String) -> Double {
        (relayBill[type] ?? 0) * reserveRelays
    }

    /// Every type's floor, keyed the way `printPermitted(hubStock:)` keys its
    /// stock reading. `printPermitted` reads this rather than recomputing per
    /// type, so the two cannot disagree.
    public static var reserveFloors: [String: Double] {
        Dictionary(uniqueKeysWithValues: resourceTypes.map { ($0, reserveFloor(for: $0)) })
    }

    // MARK: - The aggregate proxy `RelayRun` actually arms

    /// The measured hub-stock snapshot `aggregateSpendFloor` is calibrated
    /// against, and the only per-type mix this type knows.
    ///
    /// Never read at check time: `RelayRun`'s live signal is a single TOTAL
    /// count carrying no mix to compare against. `aggregateSpendFloor`
    /// recomputes from whatever stands here, so refreshing the snapshot moves
    /// the floor.
    static let referenceHubStock: [String: Double] = [
        "carbon": 11368, "conductive": 13434, "rares": 5069,
        "silicates": 13225, "structural": 27436, "volatiles": 4117,
    ]

    /// How many relays, billed at `relayBill` against `referenceHubStock`, the
    /// FIRST type to reach its own `reserveFloor(for:)` survives — the reference
    /// mix's binding-type headroom. Computed rather than hand-picked, so
    /// recalibrating `reserveRelays` or refreshing `referenceHubStock` moves it.
    ///
    /// Never shortcut this by naming a type. Which one binds is neither the
    /// cheapest line in the bill nor the scarcest stock but the smallest ratio
    /// of the two, and reading it off either alone picks the wrong type.
    static var relaysUntilBindingTypeFloors: Double {
        resourceTypes.compactMap { type -> Double? in
            guard let bill = relayBill[type], bill > 0 else { return nil }
            let stock = referenceHubStock[type] ?? 0
            return (stock - reserveFloor(for: type)) / bill
        }.min() ?? 0
    }

    /// The single number the print rail arms `reserveFloor: Int?` with: the TOTAL
    /// hub reading at which `referenceHubStock`'s binding type sits exactly at
    /// its own floor, rounded UP. It is the only shape `LocationFootprint` can
    /// be checked against, that row carrying one total holdings count and no
    /// per-type breakdown; once the per-type stockpile record lands
    /// (brain-resource-hub-model), `PrintRail.printStockIsShort` calls
    /// `printPermitted(hubStock:)` directly and this retires.
    ///
    /// **Never redefine this as `reserveFloors.values.reduce(0, +)`.** The bill
    /// spends in fixed, skewed proportions while hub stock is skewed the OTHER
    /// way, so a flat sum of the six per-type floors cannot fire until the
    /// binding type is already exhausted: it undershoots by more than an order
    /// of magnitude, leaving the rail nominally armed and never firing.
    ///
    /// Rounding UP is the conservative direction — a higher floor vetoes
    /// SOONER, at more stock remaining. Total stock drains by exactly
    /// `totalBill` per print whatever the mix, so the coarse rail fires no LATER
    /// than the true per-type rail does under the reference snapshot, and only
    /// under it: a live mix drifting far from that snapshot weakens the
    /// guarantee. This is a proxy for `R`, never `R` itself.
    public static var aggregateSpendFloor: Int {
        let totalReferenceStock = referenceHubStock.values.reduce(0, +)
        let totalBill = relayBill.values.reduce(0, +)
        let floor = totalReferenceStock - relaysUntilBindingTypeFloors * totalBill
        return Int(floor.rounded(.up))
    }

    // MARK: - The true per-type check

    /// Whether printing a relay is permitted given `hubStock`, the hub's
    /// per-type stock reading. This is `R` as specified
    /// (brain-resource-hub-model): the true per-type check, which
    /// `aggregateSpendFloor` stands in for only until `RelayRun` can supply
    /// per-type data.
    ///
    /// **Fails CLOSED on unreadable stock.** A resource type absent from
    /// `hubStock` — including every type, for a wholly empty or unfetched
    /// reading — reads as zero, which sits below every floor and vetoes. The
    /// "unknown is never zero" convention elsewhere in this codebase (salvage
    /// percentages, scan completeness) governs DISPLAY, where the hazard is
    /// overstating depletion; here the print is an irreversible resource
    /// commitment, and "we could not read the stock" must never be spent as
    /// permission.
    public static func printPermitted(hubStock: [String: Double]) -> Bool {
        reserveFloors.allSatisfy { type, floor in hubStock[type, default: 0] >= floor }
    }
}
