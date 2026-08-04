//
//  BrainWhyView.swift
//  Replicould — Directives feature
//
//  The brain's legibility surface (`brain-robustness-bar` clause 8): a derived
//  view model projecting the `BrainReport` the engine publishes every tick into
//  graph facts an operator can verify against the map, plus a read-only SwiftUI
//  card rendering it. No table backs this — like `WorldView`, it is recomputed
//  from what the engine already knew, never written itself.
//
//  Wired in Task 19: `DirectiveEngineCore.tickBrain()` publishes a
//  `BrainReport` to `@Shared(.brainReport)`, `DirectivesFeature.State` reads
//  it, and `DirectivesListView` renders this card above the Directives list.
//  Before that the type had no production caller at all — see `BrainReport`'s
//  own header for why the feed is shaped the way it is.
//
//  `BrainWhy` is deliberately top-level here rather than nested in
//  `BrainWhyView` — logic nested on a SwiftUI `View` traps `swift test`
//  (realizing the View's runtime metadata outside a GUI context), so the
//  test file exercises this type directly with no SwiftUI in the loop.
//

import DirectiveEngine
import Foundation
import SwiftUI
import UI

/// A `BrainReport`, projected into what an operator needs to read at a
/// glance: the current goal gate, the candidates under consideration, and
/// what is constraining spend — all as text, never a number to interpret.
public struct BrainWhy: Equatable, Sendable {
    /// The decision's headline, split into prose and designation runs so the
    /// view can honour the monospace rule for codes embedded mid-sentence
    /// (see `BrainWhySpan`). E.g. "idle — no grow or prune work", "launched —
    /// meshing VEGA — 3,200 units, 1 hop", "stalled — Relay didn't come up".
    public var topGoalGate: [BrainWhySpan]
    /// The candidates the tick ranked, best first — including on a tick that
    /// launched nothing, which is when an operator most needs them. Capped at
    /// `maxCandidates`; see `hiddenCandidates`.
    public var candidates: [BrainWhyRow]
    /// How many further candidates the tick ranked but this card does not
    /// show. Reported rather than silently dropped: the ranked field is one
    /// entry per reachable first hop and can run to dozens, which would turn
    /// a card that sits ABOVE the Directives list into the whole pane. An
    /// operator needs to know the tail exists; they do not need to read it.
    public var hiddenCandidates: Int
    /// What prune made of the mesh this tick: a reclaim taken, spare relays
    /// left standing, nothing spare at all, or a refusal to judge.
    ///
    /// **Empty only when prune did not run** (no mesh yet, or a world read that
    /// failed) — not when the mesh is healthy. A surface that spoke up only
    /// when something was spare would leave an operator unable to tell a tidy
    /// mesh from a prune that stopped reporting, which is the same argument
    /// `limitPressure` makes about a healthy rail.
    ///
    /// **Never escalates.** See `BrainWhyPruneNote`'s header: growth can halt
    /// and need an operator, prune cannot.
    public var pruneNotes: [BrainWhyPruneNote]
    /// Where the brain's two standing rails stand right now, plus a recent
    /// 429 when there is one.
    ///
    /// **Never empty**: the governor and the reserve floor are reported on
    /// every tick, healthy or not. That is deliberate — "54 of 60 left" is
    /// headroom rather than pressure, and an operator who only ever sees these
    /// lines when something is wrong cannot tell a healthy rail from a rail
    /// that stopped being reported. `.rateLimited` is the only conditional
    /// entry.
    public var limitPressure: [BrainWhyPressure]
    /// Distinguishes idle-calm from a stall (robustness bar clause 6): a
    /// brain with nothing to do is surfaced but calm; a stalled one is
    /// surfaced AND escalated. The view must not let these look alike. A
    /// DEFERRAL is not a stall either — it is a tick that chose not to act,
    /// which is normal operation.
    public var isEscalated: Bool

    public init(
        topGoalGate: [BrainWhySpan],
        candidates: [BrainWhyRow],
        hiddenCandidates: Int = 0,
        pruneNotes: [BrainWhyPruneNote] = [],
        limitPressure: [BrainWhyPressure],
        isEscalated: Bool
    ) {
        self.topGoalGate = topGoalGate
        self.candidates = candidates
        self.hiddenCandidates = hiddenCandidates
        self.pruneNotes = pruneNotes
        self.limitPressure = limitPressure
        self.isEscalated = isEscalated
    }

    /// The gate as one plain string — what an operator would read aloud, and
    /// what the card's accessibility label uses.
    public var gateText: String { topGoalGate.text }

    /// How recently the server must have answered 429 for it to count as
    /// current pressure rather than history.
    ///
    /// Five minutes: long enough that a 429 is still on screen when the
    /// operator looks up from whatever prompted them to look, short enough
    /// that the line stops meaning "right now" before it stops being shown.
    /// A permanent line would decay into furniture within one session — the
    /// governor's own penalty window is seconds, so anything older than this
    /// has already been recovered from.
    public static let rateLimitWindow: TimeInterval = 300

    /// How many ranked candidates the card lists before it stops.
    ///
    /// Five: enough to see the shape of the decision (the winner and the
    /// field it beat), few enough that the card stays a header rather than
    /// becoming the pane. Beyond about the fifth, rank order has already made
    /// the point and the rest is a list nobody reads — the same judgement
    /// `Brain.list` makes when it names two served systems and counts the
    /// rest.
    public static let maxCandidates = 5

    /// Projects the brain's tick report into the why-view's shape.
    ///
    /// Exhaustive over `BrainDecision`, no `default:` — a case added later
    /// must force this switch open again, exactly as `.dispatch` once did.
    public static func from(report: BrainReport) -> BrainWhy {
        let designations = knownDesignations(in: report)
        let rows = candidates(in: report)
        let visible = visibleCandidates(rows)
        return BrainWhy(
            topGoalGate: .spans(in: gate(for: report.decision), designations: designations),
            candidates: visible,
            hiddenCandidates: max(0, rows.count - visible.count),
            pruneNotes: pruneNotes(in: report),
            limitPressure: pressure(in: report),
            isEscalated: isEscalated(report.decision)
        )
    }

    /// The first `maxCandidates` rows — except that the LAUNCHED row is never
    /// cut.
    ///
    /// `Brain.plan` picks the best candidate NOT already in flight, which is
    /// not necessarily rank 1. With five or more grows already flying, a plain
    /// prefix would show five rows the tick REJECTED under a gate reading
    /// "launched — meshing X" and never list X at all — the card would be
    /// contradicting its own headline. The chosen row displaces the last
    /// visible one instead.
    ///
    /// Its true rank travels with it, so the gap in the numbering (1, 2, 3, 4,
    /// 9) is itself the signal that the field was truncated between them.
    private static func visibleCandidates(_ rows: [BrainWhyRow]) -> [BrainWhyRow] {
        let head = Array(rows.prefix(maxCandidates))
        guard let chosen = rows.first(where: \.isChosen), !head.contains(where: \.isChosen) else {
            return head
        }
        return Array(head.prefix(maxCandidates - 1)) + [chosen]
    }

    // MARK: - The gate

    private static func gate(for decision: BrainDecision) -> String {
        switch decision {
        case let .idle(reason):
            // A deferral already names itself (`BrainDecision.deferralPrefix`)
            // and is its own state, so prefixing it with "idle — " would both
            // read as a stutter and claim there was nothing to do, when in
            // fact there was and the brain declined it.
            decision.isDeferral ? reason : "idle — \(reason)"
        case let .dispatch(goal, _):
            // The goal's own rationale IS the gate: it is already the graph
            // fact for the top candidate ("meshing VEGA — 3,200 units, 1
            // hop"), produced by the same `GrowCandidate` vocabulary the rows
            // below use, so the headline and its row can never disagree.
            "launched — \(goal.rationale)"
        case let .stall(reason):
            "stalled — \(reason.displayName)"
        }
    }

    /// Reads the DECISION and nothing else — in particular, nothing prune
    /// found can reach it. That is the whole of "prune never escalates": a
    /// useless relay left in place is surfaced by `pruneNotes` and cannot
    /// change the card's temperature, because there is no prune stall path to
    /// escalate to.
    private static func isEscalated(_ decision: BrainDecision) -> Bool {
        switch decision {
        case .idle, .dispatch: false
        case .stall: true
        }
    }

    // MARK: - Candidates

    private static func candidates(in report: BrainReport) -> [BrainWhyRow] {
        let chosen: String? = if case let .dispatch(goal, _) = report.decision { goal.target } else { nil }
        return report.ranked.enumerated().map { index, candidate in
            BrainWhyRow(
                rank: index + 1,
                target: candidate.firstHop,
                servedTargets: candidate.targetsBeyondFirstHop,
                // The winning tier's own units plus the chain length — the
                // graph fact, composed from `GrowCandidate`'s vocabulary
                // rather than restated here.
                fact: "\(candidate.magnitudeSummary) · \(candidate.hopSummary)",
                isChosen: candidate.firstHop == chosen
            )
        }
    }

    // MARK: - Prune

    /// How many designations a prune note names before it starts counting the
    /// rest.
    ///
    /// **Three, and the cap is not cosmetic.**
    /// `PruneDeclineReason.censusIncomplete(systems:)` is UNBOUNDED — it names
    /// every system the judgement depended on that the census could not place,
    /// which after a database reset is every mesh system AND every target
    /// system at once. Rendered whole it would push a one-line observation past
    /// the Directives list this card sits above. The spare list has the same
    /// shape and gets the same treatment.
    ///
    /// Three rather than one because a single name reads as THE problem when it
    /// is one of many, and rather than five because past about three the
    /// operator has already learned the only thing this line can teach them —
    /// which neighbourhood to go and look at. The remainder is counted, never
    /// silently dropped, the same judgement `hiddenCandidates` makes.
    public static let maxNamedSystems = 3

    /// What prune had to say, in narrative order: what this tick did, what is
    /// already under way, and what is left over.
    ///
    /// A refusal to judge is the WHOLE answer when it happens: a declined
    /// analysis pins everything as a consequence of the refusal, so pairing it
    /// with "nothing spare" would report a finding the predicate never made.
    ///
    /// **"Nothing spare" is a fallback, not a branch**, and that is what keeps
    /// it honest. It is emitted only when there was nothing else to say at all —
    /// so a mesh whose only loose relay is already being collected reports the
    /// collection rather than claiming the mesh is tight, and a mesh with no
    /// relays deployed reports nothing rather than congratulating itself.
    private static func pruneNotes(in report: BrainReport) -> [BrainWhyPruneNote] {
        guard let prune = report.prune else { return [] }
        if let declined = prune.declined { return [declinedNote(declined)] }

        var notes: [BrainWhyPruneNote] = []
        if let reclaimed = prune.reclaimed { notes.append(reclaimedNote(reclaimed)) }
        if !prune.claimed.isEmpty { notes.append(claimedNote(prune.claimed)) }
        if !prune.spare.isEmpty { notes.append(spareNote(prune.spare)) }
        if notes.isEmpty, prune.pinnedCount > 0 { notes.append(pinnedNote(prune.pinnedCount)) }
        return notes
    }

    /// The reclaim, as a graph fact in the surface's established voice — the
    /// same shape `Goal.rationale` gives a grow ("meshing VEGA — 3,200 units,
    /// 1 hop"): what is happening, an em-dash, and the facts that make it
    /// checkable against the map.
    ///
    /// The device code stays PROSE. The house monospace rule governs system and
    /// location designations; a device code is neither (`BrainWhySpan`'s
    /// header), and monospacing it here would teach the operator that the two
    /// kinds of code are the same kind of thing.
    private static func reclaimedNote(_ reclaim: BrainReclaim) -> BrainWhyPruneNote {
        BrainWhyPruneNote(
            kind: .reclaimed,
            spans: [
                .prose("reclaiming \(reclaim.deviceCode) from "),
                .designation(reclaim.fromSystem),
                // One decimal, matching `Brain.sourcing`'s own formatting of
                // the same number, so the card and the launch log line cannot
                // quote different distances for one flight.
                .prose(" — \(String(format: "%.1f", reclaim.distanceLY)) ly to "),
                .designation(reclaim.toSystem),
                .prose(", no resources spent"),
            ]
        )
    }

    /// Spare relays an in-force run is already flying to collect.
    ///
    /// **The line that keeps a reclaim described for its whole lifetime**, not
    /// just for the tick that launched it. A source relay stays deployed and
    /// `relaying` through the entire travel/deactivate/stow sequence — hundreds
    /// of 5-second ticks — and prune keeps calling it reclaimable the whole
    /// time. Without this the card would say "kept for the next grow" about a
    /// relay a carrier is already on its way to fetch, which is the one thing
    /// this surface exists to stop it saying.
    ///
    /// The wording is invariant in the count on purpose: "collection already
    /// under way" is true of one relay and of five, so there is no pluralised
    /// second clause to keep in step with the first.
    private static func claimedNote(_ claimed: [ReclaimableRelay]) -> BrainWhyPruneNote {
        BrainWhyPruneNote(
            kind: .claimed,
            spans: [.prose("\(relays(claimed.count)) already claimed at ")]
                + named(uniqueSystems(of: claimed))
                + [.prose(" — collection already under way")]
        )
    }

    /// Spare relays left standing — an OBSERVATION, deliberately. The sentence
    /// says what the relays are not doing and what they are being kept for; it
    /// does not ask for anything, because there is nothing for an operator to
    /// do about a relay the next grow will pick up for free.
    ///
    /// Counts RELAYS and names PLACES: two spares in one system name it once,
    /// since a repeated designation reads as a mistake.
    ///
    /// "The next grow" is only true because `BrainPrune.spare` has already had
    /// the claimed relays taken out of it — see `claimedNote`.
    private static func spareNote(_ spare: [ReclaimableRelay]) -> BrainWhyPruneNote {
        BrainWhyPruneNote(
            kind: .spare,
            spans: [.prose("\(relays(spare.count)) spare at ")]
                + named(uniqueSystems(of: spare))
                + [.prose(" — on no road the mesh needs, kept for the next grow")]
        )
    }

    /// Prune judged and found nothing spare. Reported rather than left silent
    /// for the reason `limitPressure` reports a healthy rail: an operator who
    /// only ever sees prune when something is loose cannot tell a tidy mesh
    /// from a prune that stopped answering.
    private static func pinnedNote(_ pinned: Int) -> BrainWhyPruneNote {
        BrainWhyPruneNote(
            kind: .pinned,
            spans: [.prose("nothing spare — \(relays(pinned)) pinned on the roads the mesh needs")]
        )
    }

    /// Prune declined to judge. Leads with "stood down" so it can never be read
    /// as a finding — the sentence's whole job is to say that the all-pinned
    /// answer below it was not earned.
    private static func declinedNote(_ reason: PruneDeclineReason) -> BrainWhyPruneNote {
        let cause: [BrainWhySpan] = switch reason {
        case .noAnchor:
            [.prose("no print hub on the mesh to judge from")]
        case let .censusIncomplete(systems):
            [.prose("the census cannot place ")] + named(systems)
        }
        return BrainWhyPruneNote(
            kind: .declined,
            spans: [.prose("prune stood down — ")] + cause + [.prose(", so every relay stays pinned")]
        )
    }

    /// The systems a set of relays stands in, deduplicated but keeping the
    /// list's own (device-code) order, so the line is stable tick to tick.
    private static func uniqueSystems(of relays: [ReclaimableRelay]) -> [String] {
        var seen: Set<String> = []
        return relays.map(\.system).filter { seen.insert($0).inserted }
    }

    /// The first `maxNamedSystems` designations, tagged for mono, with the
    /// remainder counted.
    private static func named(_ systems: [String]) -> [BrainWhySpan] {
        var spans: [BrainWhySpan] = []
        for (offset, system) in systems.prefix(maxNamedSystems).enumerated() {
            if offset > 0 { spans.append(.prose(", ")) }
            spans.append(.designation(system))
        }
        if systems.count > maxNamedSystems {
            spans.append(.prose(" +\(systems.count - maxNamedSystems) more"))
        }
        return spans
    }

    /// "1 relay" / "14 relays" — the one place this surface pluralises, so the
    /// prune lines read as sentences at either end.
    private static func relays(_ count: Int) -> String {
        "\(self.count(count)) relay\(count == 1 ? "" : "s")"
    }

    // MARK: - Limit pressure

    private static func pressure(in report: BrainReport) -> [BrainWhyPressure] {
        let limits = report.limits
        var lines: [BrainWhyPressure] = []

        // First, because it is the only one of the three that was done TO us.
        if let at = limits.rateLimitedAt {
            let age = report.observedAt.timeIntervalSince(at)
            if age >= 0, age <= rateLimitWindow {
                lines.append(
                    BrainWhyPressure(
                        kind: .rateLimited,
                        detail: "rate limited — the server returned 429 \(elapsed(age)), not self-pacing"
                    )
                )
            }
        }

        // Both halves of the fact: what is left, and where we stop ourselves.
        // "4 left" alone is a number without a scale.
        lines.append(
            BrainWhyPressure(
                kind: .governor,
                detail: """
                    commands — \(count(limits.actionsRemaining)) of \(count(limits.actionsLimit)) \
                    left this minute, pacing ourselves below \(count(limits.actionsFloor))
                    """
            )
        )

        // ALL THREE of the rail's veto conditions, in its own branch order —
        // `BrainLimits.hubStockStanding` mirrors `RelayRun.printStockIsShort`
        // and is test-pinned against it. Rendering only two of them was a real
        // defect: a fresh-looking figure on an hour-old census row would have
        // read as headroom by contrast, while the rail refused every print.
        // The general rule this surface follows is that silence must never
        // read as permission to spend — which has to apply to ALL the ways
        // the reading can be untrustworthy, not just the absent one.
        let floor = count(limits.spendFloor)
        let stock: String = switch limits.hubStockStanding(at: report.observedAt) {
        case .unread:
            "no census reading — printing vetoed until one lands"
        case let .stale(age):
            // Name the AGE, not the figure's size: an operator told a healthy
            // -looking number is vetoed would go hunting for a shortage that
            // does not exist. Same reasoning as `printStockShortDiagnosis`.
            """
            \(limits.hubStock.map(count) ?? "?") units, but the census reading is \(aged(age)) \
            — printing vetoed until it refreshes
            """
        case .belowFloor:
            "\(limits.hubStock.map(count) ?? "?") units, below the \(floor) reserve floor — printing vetoed"
        case .clear:
            "\(limits.hubStock.map(count) ?? "?") units against a \(floor) reserve floor"
        }
        lines.append(BrainWhyPressure(kind: .reserveFloor, detail: "hub stock — \(stock)"))

        return lines
    }

    /// Coarse, because the precision is not the point: an operator needs to
    /// know whether a 429 is still relevant, not to the second when it landed.
    /// Bounded by `rateLimitWindow`, so only "just now" and single-digit
    /// minutes can ever be produced.
    private static func elapsed(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "just now" : "\(Int(seconds / 60))m ago"
    }

    /// How old a census reading is. Only ever called past
    /// `RelayRun.hubFreshness` (5 minutes), so the sub-minute case cannot
    /// arise; hours are spelled out because the whole point of the line is
    /// that an operator notices the reading is ancient.
    private static func aged(_ seconds: TimeInterval) -> String {
        seconds >= 3600 ? "\(Int(seconds / 3600))h old" : "\(Int(seconds / 60))m old"
    }

    /// Grouping pinned to `en_US`, matching `GrowCandidate`'s own counting —
    /// the surrounding sentences are hard-coded English, and a locale-
    /// dependent separator would make these lines (and their tests) read
    /// differently on different machines for no gain.
    private static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    // MARK: - Designations

    /// Every system/location designation this report is known to contain.
    ///
    /// Gathered from the report rather than inferred from the text's shape —
    /// see `BrainWhySpan`'s header for the "Out of FTL relays" case that
    /// rules a shape heuristic out. A carrier device code inside a deferral
    /// reason is deliberately absent: it is not a system or location name,
    /// which is what the monospace rule governs.
    private static func knownDesignations(in report: BrainReport) -> Set<String> {
        var codes = Set(report.ranked.flatMap { [$0.firstHop] + $0.servedTargets })
        if case let .dispatch(goal, _) = report.decision { codes.insert(goal.target) }
        if let hub = report.hubLocation { codes.insert(hub) }
        return codes
    }
}

extension [BrainWhySpan] {
    /// The line as one `Text`, with designations in the prominence-matched
    /// mono token.
    ///
    /// Built as a single `AttributedString` with a per-run `font` attribute
    /// rather than by concatenating `Text` values (`Text + Text` is
    /// deprecated on macOS 26). One `Text` also means the line wraps as one
    /// paragraph, which is what makes the monospace rule satisfiable for a
    /// designation embedded mid-sentence at all.
    func styled(prose: Font, designation: Font) -> Text {
        var line = AttributedString()
        for span in self {
            var run = AttributedString(span.text)
            run.font = span.isDesignation ? designation : prose
            line += run
        }
        return Text(line)
    }
}

/// A read-only card rendering a `BrainWhy`. Actions (launch/retire) already
/// ride the `DirectiveLogEntry` timeline elsewhere in this feature, so this
/// surface never dispatches anything — it only explains.
///
/// Every `fixedSize` line here is `lineLimit`ed, and that is load-bearing: the
/// card renders in a `safeAreaInset`, where an unbounded one reports its
/// zero-width wrap height as the WINDOW's minimum height (4,014pt, unresizable
/// — see the chrome-min-height memory note).
public struct BrainWhyView: View {
    let why: BrainWhy

    public init(why: BrainWhy) {
        self.why = why
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: why.isEscalated ? "exclamationmark.triangle.fill" : "brain.head.profile")
                    .font(.system(size: IconSize.m))
                    .foregroundStyle(why.isEscalated ? .rcWarning : .rcTextSecondary)
                why.topGoalGate
                    .styled(prose: .rcBodyEmph, designation: .rcBodyEmphMono)
                    .foregroundStyle(.rcTextPrimary)
                    // Two lines at the column's narrowest, so three is headroom.
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(why.gateText)

            // Unconditional: `limitPressure` is never empty (see its doc — the
            // two standing rails always report, healthy or not), so a guard
            // here would be dead code.
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(why.limitPressure) { pressure in
                    Text(pressure.detail)
                        .font(.rcCaption)
                        // A 429 was done TO us; the other two are choices we
                        // made. They must not read alike.
                        .foregroundStyle(pressure.isImposed ? .rcWarning : .rcTextSecondary)
                }
            }

            // Prune sits beside the rails rather than among the candidates: the
            // candidate rows are the grow field this tick ranked, and the mesh's
            // standing shape is not one of them. Empty only when prune did not
            // run at all.
            if !why.pruneNotes.isEmpty {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(why.pruneNotes) { note in
                        note.spans
                            .styled(prose: .rcCaption, designation: .rcMonoSmall)
                            // A step back for the states that merely describe a
                            // mesh at rest. Never `.rcWarning`: that is this
                            // card's escalation colour, and prune has nothing to
                            // escalate.
                            .foregroundStyle(note.isObservation ? .rcTextTertiary : .rcTextSecondary)
                            // The longest note (declined) is already bounded in
                            // content by `maxNamedSystems`; three lines fits it.
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !why.candidates.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(why.candidates) { candidate in
                        BrainWhyRowView(row: candidate)
                    }
                    if why.hiddenCandidates > 0 {
                        Text("+\(why.hiddenCandidates) more ranked below these")
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextTertiary)
                    }
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(why.isEscalated ? .rcWarning : .rcSeparator, lineWidth: Hairline.thin)
        )
    }
}
