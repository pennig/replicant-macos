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

/// The reserve-floor rail. `printPermitted(hubStock:)` is the true, per-type
/// `R` check: vetoes a print whenever ANY resource type at the hub would drop
/// below `K` relays' worth of that type's real blueprint bill. `RelayRun`
/// cannot feed it real per-type data yet (see `aggregateSpendFloor`'s doc), so
/// today it is armed with a conservative TOTAL-only proxy instead — a
/// distinction this type's naming and docs are deliberately explicit about.
public enum BrainCeiling {
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

    /// The six resource types the game actually speaks in, verified live
    /// 2026-08-03 three separate ways (a fresh `GET blueprints` bill, a fresh
    /// `GET locations/<hub>` inventory read, and `belt-value-vocabulary`'s
    /// independent 141-system aggregate). **Not** `metal`/`silicon` — those
    /// never appeared in any live response and must not be encoded anywhere
    /// near this rail.
    ///
    /// Derived from `relayBill`'s own keys (sorted for a stable order) rather
    /// than restated as a second, parallel literal: a seventh type added to
    /// the bill without a matching entry here would otherwise floor to zero
    /// in `reserveFloor(for:)`, and `printPermitted` would then silently
    /// PERMIT that type at any stock level — a fail-open hole inside a
    /// fail-closed predicate. Deriving both from one source closes that hole
    /// by construction instead of relying on the two lists staying in sync.
    public static let resourceTypes: [String] = relayBill.keys.sorted()

    /// **CALIBRATE.** How many relays' worth of each resource type the hub
    /// must keep in reserve before a print is allowed to touch it. This is
    /// the one knob a later tuning pass may reasonably revisit; every other
    /// constant on this type is a verified game fact, not a guess.
    ///
    /// Chosen as 5, anchored on conductive — the type that actually binds
    /// first under the live mix (see `relaysUntilBindingTypeFloors`'s doc;
    /// volatiles, despite being both the cheapest line in the bill and the
    /// scarcest live stock, is in fact the LAST type to bind, because bind
    /// order depends on stock relative to consumption, not on either alone).
    /// 5 relays' worth of conductive is 600 units against a measured stock of
    /// 13,434 (≈4.5%) — a real reserve, not a rounding error, while staying
    /// far below the live hub's actual holdings across every type (measured
    /// 2026-08-03: carbon 11,368 / conductive 13,434 / rares 5,069 /
    /// silicates 13,225 / structural 27,436 / volatiles 4,117), so the rail
    /// protects the floor without becoming a wall the brain trips over during
    /// ordinary operation. A flat 370 was rejected for the reason above; a
    /// per-type multiple of the real bill is the only shape that is coherent
    /// across all six types at once.
    public static let reserveRelays: Double = 5 // CALIBRATE: surfaced in why-view

    /// The reserve floor for one resource type: `K` relays' worth of that
    /// type's real bill. A type absent from `relayBill` cannot occur —
    /// `resourceTypes` is derived from `relayBill`'s own keys — but floors to
    /// zero rather than trapping if it somehow did.
    public static func reserveFloor(for type: String) -> Double {
        (relayBill[type] ?? 0) * reserveRelays
    }

    /// Every type's floor, keyed the same way `printPermitted(hubStock:)`
    /// expects its stock reading. `printPermitted` is built directly on this
    /// rather than recomputing per type, so the two can never disagree.
    public static var reserveFloors: [String: Double] {
        Dictionary(uniqueKeysWithValues: resourceTypes.map { ($0, reserveFloor(for: $0)) })
    }

    // MARK: - The aggregate proxy `RelayRun` actually arms

    /// The hub stock as measured live 2026-08-03
    /// (`app/.claude/memory/brain-relay-reserve-floor.md`). Used ONLY to
    /// calibrate `aggregateSpendFloor` below — never read at check time,
    /// since `RelayRun`'s only live signal is a single TOTAL count with no
    /// per-type breakdown to recover a live mix from. A future recalibration
    /// pass may refresh this snapshot; `aggregateSpendFloor` recomputes from
    /// whatever is here.
    static let referenceHubStock: [String: Double] = [
        "carbon": 11368, "conductive": 13434, "rares": 5069,
        "silicates": 13225, "structural": 27436, "volatiles": 4117,
    ]

    /// How many relays, printed at the fixed `relayBill` cost against
    /// `referenceHubStock`, before the FIRST type to constrain `K` (by real
    /// per-type floor) would hit its own floor — the reference mix's
    /// "binding type" headroom. Computed, not hand-picked, so recalibrating
    /// `reserveRelays` or refreshing `referenceHubStock` updates it too.
    ///
    /// Under today's constants this is **conductive**, at ≈107 relays — NOT
    /// volatiles. Volatiles is both the cheapest line in the bill (10) and
    /// the scarcest live stock (4,117), which reads as "obviously bites
    /// first," but that conflates absolute scarcity with scarcity RELATIVE
    /// TO CONSUMPTION: volatiles actually survives ≈407 relays, the LAST
    /// type to bind (full ordering: conductive ≈107, rares ≈122, silicates
    /// ≈127, structural ≈338, volatiles ≈407, carbon ≈563).
    static var relaysUntilBindingTypeFloors: Double {
        resourceTypes.compactMap { type -> Double? in
            guard let bill = relayBill[type], bill > 0 else { return nil }
            let stock = referenceHubStock[type] ?? 0
            return (stock - reserveFloor(for: type)) / bill
        }.min() ?? 0
    }

    /// The single number `RelayRun` actually arms `reserveFloor: Int?` with —
    /// the only shape today's `LocationFootprint` can be checked against,
    /// since it carries one TOTAL holdings count and no per-type breakdown
    /// (the per-type stockpile record is a later task, brain-resource-hub-model
    /// ticket 06; when it lands, `RelayRun.printStockIsShort` switches to
    /// calling `printPermitted(hubStock:)` directly and this proxy retires).
    ///
    /// **Deliberately NOT `reserveFloors.values.reduce(0, +)`** (the naive
    /// sum of the six per-type floors, ≈1,850). That undershoots by more
    /// than an order of magnitude: the bill spends in fixed, skewed
    /// proportions (conductive 120 vs. volatiles 10) while live STOCK is
    /// skewed the OTHER way (structural's stock ALONE, 27,436, is ≈15× the
    /// naive sum), so a flat-sum floor cannot fire before the binding type
    /// (conductive) is already exhausted under any realistic mix — checked
    /// against the live account: conductive hits its own floor at relay
    /// ≈107, at which point TOTAL stock is still ≈35,000, roughly 18× the
    /// naive sum.
    ///
    /// Instead: the TOTAL stock at the moment `referenceHubStock`'s binding
    /// type would hit ITS OWN floor — `totalReferenceStock −
    /// relaysUntilBindingTypeFloors × totalBill`, rounded UP (the
    /// conservative direction: a higher floor vetoes SOONER, at more stock
    /// remaining). Total stock drains by exactly `totalBill` per print
    /// regardless of mix, so this is the total reading at which the binding
    /// type is provably AT its own floor under the reference snapshot — the
    /// coarse rail fires no LATER than the true per-type rail would, which is
    /// the safe direction for a proxy to be wrong in.
    ///
    /// Still only a proxy — if the live mix drifts far from the reference
    /// snapshot (other consumers spending disproportionately on one type),
    /// the "no later than true" guarantee weakens — which is exactly why
    /// this is named for what it is rather than claiming to be `R` itself.
    /// The real per-type `R` is `printPermitted(hubStock:)` below.
    public static var aggregateSpendFloor: Int {
        let totalReferenceStock = referenceHubStock.values.reduce(0, +)
        let totalBill = relayBill.values.reduce(0, +)
        let floor = totalReferenceStock - relaysUntilBindingTypeFloors * totalBill
        return Int(floor.rounded(.up))
    }

    // MARK: - The true per-type check

    /// Whether printing a relay is permitted given the hub's per-type stock.
    /// This is `R` as specified (brain-resource-hub-model, ticket 06) — the
    /// per-type check `aggregateSpendFloor` above exists only because
    /// `RelayRun` cannot feed this function real per-type data yet.
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
        reserveFloors.allSatisfy { type, floor in hubStock[type, default: 0] >= floor }
    }
}
