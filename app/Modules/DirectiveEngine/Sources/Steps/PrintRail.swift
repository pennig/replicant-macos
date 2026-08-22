//
//  PrintRail.swift
//  Replicould — DirectiveEngine
//
//  The reserve rail every print site checks before it spends: whether the
//  per-type stock census is fresh enough to decide against, whether the stock
//  at one location clears every floor, and which type vetoed when one does.
//

import Foundation

/// The reserve floors one print decision is checked against, as a pure value.
struct PrintRail: Equatable, Sendable {
    /// How stale the TABLE-WIDE census may be before a print site buys a refresh
    /// rather than trusting it — not the more generous `hubFreshness`, which is
    /// `printStockIsShort`'s separate read-time veto.
    static let pollInterval: TimeInterval = 60

    /// How old a location's own stock reading may be and still be believed.
    static let hubFreshness: TimeInterval = 5 * 60

    /// Per-type floors a print is checked against, nil to disarm the rail
    /// entirely. `BrainCeiling.printPermitted` is what applies them.
    let reserveFloors: [String: Double]?

    init(reserveFloors: [String: Double]? = BrainCeiling.reserveFloors) {
        self.reserveFloors = reserveFloors
    }

    /// Whether the per-type stock census is too old to trust. **The whole
    /// `LocationInventory` table, never one depot's rows** — a per-location gate
    /// self-loops forever. See `brain-relay-reserve-floor`.
    func stockCensusIsStale(_ world: WorldSnapshot) -> Bool {
        guard let newest = world.inventories.values.map(\.fetchedAt).max() else { return true }
        return world.now.timeIntervalSince(newest) > Self.pollInterval
    }

    /// Whether the reserve rail vetoes a print at `location`. **Fails CLOSED on
    /// unreadable stock once armed**; an old-but-present reading vetoes
    /// separately on `hubFreshness`. See `brain-relay-reserve-floor`.
    func printStockIsShort(at location: String, _ world: WorldSnapshot) -> Bool {
        guard let reserveFloors else { return false }
        guard let stock = world.inventories[location] else { return true }
        if world.now.timeIntervalSince(stock.fetchedAt) > Self.hubFreshness { return true }
        return !BrainCeiling.printPermitted(hubStock: stock.quantities, floors: reserveFloors)
    }

    /// WHICH of `printStockIsShort`'s three conditions vetoed a print at
    /// `location`, in the same branch order that function tests them so the two
    /// can only ever agree. See `brain-relay-reserve-floor`.
    func printStockShortDiagnosis(at location: String, _ world: WorldSnapshot) -> String {
        guard let reserveFloors else { return "the rail is unarmed" }
        guard let stock = world.inventories[location] else {
            return "no per-type stock reading for it at all"
        }
        // Unrounded, matching `printStockIsShort` — rounding first would disagree
        // with it inside the half-second either side of the bound.
        let age = world.now.timeIntervalSince(stock.fetchedAt)
        if age > Self.hubFreshness {
            return """
                its stock reading is \(Int(age.rounded()))s old, past the \(Int(Self.hubFreshness))s \
                freshness bound — whatever it says is not trusted
                """
        }
        let short = BrainCeiling.shortTypes(hubStock: stock.quantities, floors: reserveFloors)
        guard !short.isEmpty else { return "stock clears every reserve floor" }
        return short.map { type in
            let held = Int(stock.quantities[type, default: 0].rounded(.down))
            let floor = Int((reserveFloors[type] ?? 0).rounded(.up))
            return "\(type) \(held) below floor \(floor)"
        }.joined(separator: ", ")
    }
}
