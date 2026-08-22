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

/// The reserve-floor rail. `printPermitted(hubStock:floors:)` vetoes a print
/// whenever ANY resource type at the printing depot would drop below `K`
/// relays' worth of that type's blueprint bill. `PrintRail` is its one
/// production caller.
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

    // MARK: - The true per-type check

    /// Whether printing is permitted given `hubStock`, the printing depot's
    /// per-type stock reading, against `floors` (the rail's own by default).
    /// **Fails CLOSED**: an absent type reads as zero and vetoes, which is the
    /// opposite of this codebase's display convention. See
    /// `brain-relay-reserve-floor`.
    public static func printPermitted(
        hubStock: [String: Double], floors: [String: Double] = reserveFloors
    ) -> Bool {
        shortTypes(hubStock: hubStock, floors: floors).isEmpty
    }

    /// WHICH types sit under their floor, sorted — the diagnosis behind a
    /// `printPermitted` refusal. Empty exactly when the print is permitted, so
    /// the two cannot disagree about whether stock is short.
    public static func shortTypes(
        hubStock: [String: Double], floors: [String: Double] = reserveFloors
    ) -> [String] {
        floors.filter { type, floor in hubStock[type, default: 0] < floor }.keys.sorted()
    }
}
