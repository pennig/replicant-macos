//
//  PrintRail.swift
//  Replicould — DirectiveEngine
//
//  The reserve rail every print site checks before it spends: whether the
//  stockpile census is fresh enough to decide against, whether the stock at
//  one location clears the floor, and which of those vetoed when one does.
//

import Foundation

/// The reserve floor one print decision is checked against, as a pure value.
struct PrintRail: Equatable, Sendable {
    /// How stale the TABLE-WIDE census may be before a print site buys a refresh
    /// rather than trusting it — not the more generous `hubFreshness`, which is
    /// `printStockIsShort`'s separate read-time veto.
    static let pollInterval: TimeInterval = 60

    /// How old a location's own census row may be and still be believed.
    static let hubFreshness: TimeInterval = 5 * 60

    /// Total-stock floor the print step checks before spending; nil leaves the rail
    /// unarmed. A PROXY for `BrainCeiling`'s per-type reserve, since
    /// `LocationFootprint` carries only a total — and NOT the sum of the six
    /// per-type floors, which undershoots badly.
    let reserveFloor: Int?

    init(reserveFloor: Int? = BrainCeiling.aggregateSpendFloor) {
        self.reserveFloor = reserveFloor
    }

    /// Whether the stockpile census is too old to trust. **The whole
    /// `LocationFootprint` table, never the hub row alone** — one request upserts
    /// every location, so gating on the table's max turns "refreshed and still no
    /// hub row" into positive evidence that falls through to a veto. A per-location
    /// gate self-loops instead, re-requesting every tick forever.
    func footprintCensusIsStale(_ world: WorldSnapshot) -> Bool {
        guard let newest = world.footprints.values.map(\.fetchedAt).max() else { return true }
        return world.now.timeIntervalSince(newest) > Self.pollInterval
    }

    /// Whether the reserve rail vetoes a print at `location`. **Fails CLOSED on
    /// unreadable stock once armed** — a missing census row is evidence nobody told
    /// us, not evidence the stock is fine, and a print is irreversible. A
    /// present-but-old row is caught separately on `hubFreshness`, because the
    /// table-wide gate proves the census refreshed SOMEWHERE, never that this
    /// location did. Reads TOTAL holdings; the rail is specified per resource type.
    func printStockIsShort(at location: String, _ world: WorldSnapshot) -> Bool {
        guard let floor = reserveFloor else { return false }
        guard let footprint = world.footprints[location] else { return true }
        if world.now.timeIntervalSince(footprint.fetchedAt) > Self.hubFreshness { return true }
        return footprint.resources < floor
    }

    /// WHICH of `printStockIsShort`'s three conditions vetoed a print at
    /// `location` in `world`, for the one log line the stall emits — in the same
    /// branch order that function tests them, so the two can only ever agree.
    ///
    /// A single "stock below floor" line would be FALSE on two of the three
    /// branches: a missing census row has no reading to be below anything, and a
    /// stale row's reading may sit comfortably ABOVE the floor and still veto on
    /// its AGE alone — sending an operator after a shortage that does not exist
    /// instead of at a census that stopped listing the hub.
    func printStockShortDiagnosis(at location: String, _ world: WorldSnapshot) -> String {
        let floorText = reserveFloor.map(String.init) ?? "unarmed"
        guard let footprint = world.footprints[location] else {
            return "no census row for it at all (floor \(floorText))"
        }
        // Unrounded, matching `printStockIsShort` — rounding first would disagree
        // with it inside the half-second either side of the bound.
        let age = world.now.timeIntervalSince(footprint.fetchedAt)
        if age > Self.hubFreshness {
            return """
                its census row is \(Int(age.rounded()))s old, past the \(Int(Self.hubFreshness))s freshness bound \
                — the reading it carries (\(footprint.resources)) is not trusted, whatever it says
                """
        }
        return "stock \(footprint.resources) below floor \(floorText)"
    }
}
