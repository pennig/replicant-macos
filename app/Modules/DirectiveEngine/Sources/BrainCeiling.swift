//
//  BrainCeiling.swift
//  Replicould — DirectiveEngine
//
//  The `R` reserve-floor rail: the hard limit on the brain's spending. Printing
//  an FTL relay consumes real resources from the hub's shared stock — the same
//  pool the rest of the fleet draws from — so this is the single most
//  safety-relevant constant in the whole capability (brain-goal-decision-policy,
//  ticket 03's spend ceiling; brain-resource-hub-model, ticket 06's `R`).
//
//  Pure by contract, like every mission primitive: no I/O, no clock, nothing
//  but a table lookup and a comparison, so its behaviour is provable under
//  test without a live account.
//

/// The reserve-floor rail. Vetoes a print whenever ANY resource type at the
/// hub would drop below `K` relays' worth of that type's real blueprint bill.
public enum BrainCeiling {
    /// The six resource types the game actually speaks in, verified live
    /// 2026-08-03 three separate ways (a fresh `GET blueprints` bill, a fresh
    /// `GET locations/<hub>` inventory read, and `belt-value-vocabulary`'s
    /// independent 141-system aggregate). **Not** `metal`/`silicon` — those
    /// never appeared in any live response and must not be encoded anywhere
    /// near this rail.
    public static let resourceTypes: [String] = [
        "carbon", "conductive", "rares", "silicates", "structural", "volatiles",
    ]

    /// The FTL relay's real per-type blueprint bill (`GET blueprints`,
    /// `device_type: ftl_relay`, verified live 2026-08-03). Sums to 370
    /// **total across all six types** — this is NOT 370 per type, and a flat
    /// per-type floor of 370 would be incoherent: 37× the volatiles bill and
    /// only 3× the conductive bill, so it would veto on volatiles long before
    /// conductive ever mattered, for no principled reason. `print_time` was
    /// 800s, irrelevant here.
    public static let relayBill: [String: Double] = [
        "carbon": 20, "conductive": 120, "rares": 40,
        "silicates": 100, "structural": 80, "volatiles": 10,
    ]

    /// **CALIBRATE.** How many relays' worth of each resource type the hub
    /// must keep in reserve before a print is allowed to touch it. This is
    /// the one knob a later tuning pass may reasonably revisit; every other
    /// constant on this type is a verified game fact, not a guess.
    ///
    /// Chosen as 5: enough that the rail is a real reserve rather than a
    /// rounding error (5 relays' worth of the scarcest type, volatiles, is 50
    /// units — comfortably more than the 10-unit cost of the print it would
    /// be vetoing), while staying far below the live hub's actual holdings
    /// (measured 2026-08-03: carbon 11,368 / conductive 13,434 / rares 5,069
    /// / silicates 13,225 / structural 27,436 / volatiles 4,117), so the rail
    /// protects the floor without becoming a wall the brain trips over during
    /// ordinary operation. A flat 370 was rejected for the reason above; a
    /// per-type multiple of the real bill is the only shape that is coherent
    /// across all six types at once.
    public static let reserveRelays: Double = 5 // CALIBRATE: surfaced in why-view

    /// The reserve floor for one resource type: `K` relays' worth of that
    /// type's real bill. A type absent from `relayBill` (should never happen
    /// against the verified six) floors to zero rather than trapping.
    public static func reserveFloor(for type: String) -> Double {
        (relayBill[type] ?? 0) * reserveRelays
    }

    /// Every type's floor, keyed the same way `printPermitted(hubStock:)`
    /// expects its stock reading.
    public static var reserveFloors: [String: Double] {
        Dictionary(uniqueKeysWithValues: resourceTypes.map { ($0, reserveFloor(for: $0)) })
    }

    /// The sum of every type's floor. The only shape today's `LocationFootprint`
    /// can be checked against — it carries one TOTAL holdings count, not a
    /// per-type breakdown (the per-type stockpile record is a later task,
    /// brain-resource-hub-model ticket 06). `RelayRun` arms its single
    /// `reserveFloor: Int?` with this until that record lands.
    public static let totalReserveFloor: Int = Int(
        resourceTypes.reduce(0) { $0 + (relayBill[$1] ?? 0) } * reserveRelays
    )

    /// Whether printing a relay is permitted given the hub's per-type stock.
    ///
    /// **Fails CLOSED on unreadable stock.** A resource type absent from
    /// `hubStock` — including every type, for a wholly empty or unfetched
    /// reading — is read as zero, which sits below every real floor and
    /// therefore vetoes. This is a deliberate reversal of the general "unknown
    /// is never zero" display convention used elsewhere in this codebase
    /// (salvage percentages, scan completeness): those are UI-legibility
    /// rules about not overstating depletion, not spend-safety rules. Here
    /// the print is a real, irreversible resource commitment, and "we
    /// couldn't read the stock" is not the same claim as "the stock is
    /// fine" — silence must not be read as permission to spend.
    public static func printPermitted(hubStock: [String: Double]) -> Bool {
        resourceTypes.allSatisfy { type in
            hubStock[type, default: 0] >= reserveFloor(for: type)
        }
    }
}
