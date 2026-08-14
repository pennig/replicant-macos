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
import UniverseModels

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
    /// launched nothing, which is when an operator most needs them.
    ///
    /// **Uncapped.** These used to be truncated to five with the remainder
    /// counted, because the whole report was pinned above the Directives list
    /// and a ranked field running to dozens would have become the entire pane.
    /// It now renders in a scrolling detail pane, so there is nothing left to
    /// protect and the operator can read the whole field.
    public var candidates: [BrainWhyRow]
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
    /// What the Survey Run goal is doing — a different fleet and question
    /// from `topGoalGate`'s grow/prune story. Never absent, the same
    /// discipline `limitPressure` follows for the rails.
    public var survey: BrainWhySurvey
    /// The production liveness goals, salvage first. Never absent, for the
    /// same reason `survey` is not.
    public var goals: [BrainWhyGoal]
    /// One line per installed mine, health read fresh off device rows —
    /// distinct from `goals`' single mine-install line. Empty when no mine
    /// stands yet, which is the ordinary pre-first-mine state.
    public var mineHealth: [BrainWhyMineHealth]
    /// Present only when this tick's mine siting ranked belts against demand
    /// priced with an empty blueprint catalog — nil otherwise, distinct from
    /// `mineHealth`, which says nothing about the demand side.
    public var mineDemandNote: [BrainWhySpan]?
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
    /// One section per recognised theatre — see `groups(for:)`.
    public var theatreGroups: [BrainWhyTheatreGroup]
    /// The events waiting on an operator's pick. Empty is the ordinary state
    /// and renders as nothing at all — never as a "nothing pending" line.
    public var eventChoices: [BrainWhyEventChoice]
    /// Distinguishes idle-calm from a stall (robustness bar clause 6): a
    /// brain with nothing to do is surfaced but calm; a stalled one is
    /// surfaced AND escalated. The view must not let these look alike. A
    /// DEFERRAL is not a stall either — it is a tick that chose not to act,
    /// which is normal operation.
    public var isEscalated: Bool

    public init(
        topGoalGate: [BrainWhySpan],
        candidates: [BrainWhyRow],
        pruneNotes: [BrainWhyPruneNote] = [],
        survey: BrainWhySurvey,
        goals: [BrainWhyGoal] = [],
        mineHealth: [BrainWhyMineHealth] = [],
        mineDemandNote: [BrainWhySpan]? = nil,
        limitPressure: [BrainWhyPressure],
        theatreGroups: [BrainWhyTheatreGroup] = [],
        eventChoices: [BrainWhyEventChoice] = [],
        isEscalated: Bool
    ) {
        self.topGoalGate = topGoalGate
        self.candidates = candidates
        self.pruneNotes = pruneNotes
        self.survey = survey
        self.goals = goals
        self.mineHealth = mineHealth
        self.mineDemandNote = mineDemandNote
        self.limitPressure = limitPressure
        self.theatreGroups = theatreGroups
        self.eventChoices = eventChoices
        self.isEscalated = isEscalated
    }

    /// The gate as one plain string — what an operator would read aloud, and
    /// what the card's accessibility label uses.
    public var gateText: String { topGoalGate.text }

    /// Whether the flat Survey/Salvage/Haul/Mine sections should render:
    /// no theatres at all, or every recognised one still `.claimed` and so
    /// carrying no goal line — a live run predating the pin must stay visible.
    public var flatSectionsVisible: Bool {
        !theatreGroups.contains { !$0.goalLines.isEmpty }
    }

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

    /// Projects the brain's tick report into the why-view's shape.
    ///
    /// Exhaustive over `BrainDecision`, no `default:` — a case added later
    /// must force this switch open again, exactly as `.dispatch` once did.
    public static func from(report: BrainReport) -> BrainWhy {
        BrainWhy(
            topGoalGate: .spans(
                in: gate(for: report.decision), designations: knownDesignations(in: report)
            ),
            candidates: candidates(in: report),
            pruneNotes: pruneNotes(in: report),
            survey: surveyLine(status: report.survey, report: report),
            goals: [
                goalLine(.salvage, status: report.salvage, report: report),
                goalLine(.haul, status: report.haul, report: report),
                goalLine(.mine, status: report.mine, report: report),
            ],
            mineHealth: report.mines.map(mineHealthLine),
            mineDemandNote: mineDemandNote(in: report),
            limitPressure: pressure(in: report),
            theatreGroups: groups(for: report),
            eventChoices: report.pendingEventChoices.map(BrainWhyEventChoice.init),
            isEscalated: isEscalated(report.decision)
        )
    }

    // MARK: - Theatre groups

    /// One section per theatre, in `report.theatres`' own order. A
    /// `.claimed` theatre renders its shortfalls in place of goal lines,
    /// since no goal runs there.
    public static func groups(for report: BrainReport) -> [BrainWhyTheatreGroup] {
        report.theatres.map { theatre in
            guard case let .claimed(missing) = theatre.readiness else {
                return BrainWhyTheatreGroup(
                    depot: theatre.depot, goalLines: theatreGoalLines(for: report, theatre: theatre), shortfallLines: []
                )
            }
            return BrainWhyTheatreGroup(
                depot: theatre.depot, goalLines: [],
                shortfallLines: Theatre.Shortfall.allCases.filter(missing.contains).map(shortfallText)
            )
        }
    }

    /// Grow, survey, the three liveness goals and this theatre's own stock,
    /// in that fixed order. Grow and mine stay the report's flat figures;
    /// survey, salvage, haul and stock are each THIS theatre's own.
    private static func theatreGoalLines(for report: BrainReport, theatre: Theatre) -> [BrainWhyTheatreGroup.Line] {
        [
            growLine(report),
            surveyGroupLine(report, theatre: theatre),
            goalGroupLine(goalLine(
                .salvage, status: report.theatreSalvage[theatre.depot] ?? .idle(reason: "not evaluated"), report: report
            )),
            goalGroupLine(goalLine(
                .haul, status: report.theatreHaul[theatre.depot] ?? .idle(reason: "not evaluated"), report: report
            )),
            goalGroupLine(goalLine(
                .mine, status: report.theatreMine[theatre.depot] ?? .idle(reason: "not evaluated"), report: report
            )),
            stockGroupLine(report: report, theatre: theatre),
        ]
    }

    /// The mesh grow/prune gate, restated as a group line in the same voice
    /// `topGoalGate` already speaks.
    private static func growLine(_ report: BrainReport) -> BrainWhyTheatreGroup.Line {
        let kind: BrainWhyGoal.Kind
        if isEscalated(report.decision) {
            kind = .halted
        } else if case .dispatch = report.decision {
            kind = .running
        } else {
            kind = .idle
        }
        let spans = [BrainWhySpan].spans(in: gate(for: report.decision), designations: knownDesignations(in: report))
        return BrainWhyTheatreGroup.Line(id: "grow", label: "Grow", spans: spans, kind: kind)
    }

    private static func surveyGroupLine(_ report: BrainReport, theatre: Theatre) -> BrainWhyTheatreGroup.Line {
        let status = report.theatreSurvey[theatre.depot] ?? .idle(reason: "not evaluated")
        let survey = surveyLine(status: status, report: report)
        return BrainWhyTheatreGroup.Line(
            id: "survey", label: "Survey", spans: survey.spans, kind: surveyKind(survey.kind)
        )
    }

    private static func goalGroupLine(_ goal: BrainWhyGoal) -> BrainWhyTheatreGroup.Line {
        BrainWhyTheatreGroup.Line(id: goal.goal.rawValue, label: goal.goal.title, spans: goal.spans, kind: goal.kind)
    }

    /// This theatre's own hub-stock line — `report.theatreLimits[theatre]`,
    /// never the flat `report.limits` another theatre's card would show too.
    private static func stockGroupLine(report: BrainReport, theatre: Theatre) -> BrainWhyTheatreGroup.Line {
        guard let limits = report.theatreLimits[theatre.depot] else {
            return BrainWhyTheatreGroup.Line(id: "stock", label: "Stock", spans: [.prose("not evaluated")], kind: .idle)
        }
        let kind: BrainWhyGoal.Kind = limits.hubStockStanding(at: report.observedAt) == .clear ? .idle : .halted
        return BrainWhyTheatreGroup.Line(
            id: "stock", label: "Stock", spans: [.prose(stockDetail(limits, at: report.observedAt))], kind: kind
        )
    }

    /// `BrainWhySurvey.Kind` and `BrainWhyGoal.Kind` name the same five
    /// states as two separate types; this is the mechanical bridge.
    private static func surveyKind(_ kind: BrainWhySurvey.Kind) -> BrainWhyGoal.Kind {
        switch kind {
        case .running: .running
        case .halted: .halted
        case .paused: .paused
        case .ready: .ready
        case .idle: .idle
        }
    }

    private static func shortfallText(_ shortfall: Theatre.Shortfall) -> String {
        switch shortfall {
        case .noPrintCapableDevice: "no autofactory here"
        case .noStock: "no stock"
        case .offMesh: "off mesh"
        }
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

    // MARK: - Survey

    /// Survey's own line, in `topGoalGate`'s voice but never merged into it —
    /// a different fleet and a different question. `.idle`'s reason is
    /// carried verbatim, never reworded.
    private static func surveyLine(status: BrainSurveyStatus, report: BrainReport) -> BrainWhySurvey {
        switch status {
        case let .launched(carrier, roamCentre, status):
            return launchedSurveyLine(carrier: carrier, roamCentre: roamCentre, status: status)
        case let .ready(carrier, roamCentre):
            return BrainWhySurvey(
                kind: .ready,
                spans: [.prose("ready to roam from "), .designation(roamCentre), .prose(" — carrier \(carrier)")]
            )
        case let .idle(reason):
            return BrainWhySurvey(kind: .idle, spans: .spans(in: reason, designations: knownDesignations(in: report)))
        }
    }

    /// A halted or paused run with a centre states it as a static place, never
    /// as the present-progressive "roaming" verb — that would claim motion a
    /// stopped run is not making. `.running` keeps the verb; it is true there.
    private static func launchedSurveyLine(
        carrier: String, roamCentre: String?, status: BrainSurveyStatus.LaunchedStatus
    ) -> BrainWhySurvey {
        let tail: [BrainWhySpan] = [.prose(" — carrier \(carrier)")]
        guard let roamCentre else {
            let activity: [BrainWhySpan] = [.prose("surveying a fixed target queue")]
            switch status {
            case .running: return BrainWhySurvey(kind: .running, spans: activity + tail)
            case .needsAttention: return BrainWhySurvey(kind: .halted, spans: [.prose("halted — ")] + activity + tail)
            case .paused: return BrainWhySurvey(kind: .paused, spans: [.prose("paused — ")] + activity + tail)
            }
        }
        switch status {
        case .running:
            return BrainWhySurvey(kind: .running, spans: [.prose("roaming from "), .designation(roamCentre)] + tail)
        case .needsAttention:
            return BrainWhySurvey(
                kind: .halted, spans: [.prose("halted, roam centre "), .designation(roamCentre)] + tail
            )
        case .paused:
            return BrainWhySurvey(
                kind: .paused, spans: [.prose("paused, roam centre "), .designation(roamCentre)] + tail
            )
        }
    }

    // MARK: - Salvage and haul

    /// All three liveness goals render through one builder: they answer the
    /// same question over different fleets. A halted or paused run states its
    /// focus as a static place, never with an active verb.
    static func goalLine(
        _ goal: BrainWhyGoal.Goal, status: BrainGoalStatus, report: BrainReport
    ) -> BrainWhyGoal {
        let verb = activityVerb(for: goal)
        let vesselLabel = vesselLabel(for: goal)
        switch status {
        case let .launched(vessel, focus, launched):
            let tail: [BrainWhySpan] = [.prose(" — \(vesselLabel) \(vessel)")]
            guard let focus else {
                let idleActivity: [BrainWhySpan] = [.prose(noFocusText(for: goal))]
                return BrainWhyGoal(goal: goal, kind: kind(for: launched), spans: prefix(launched) + idleActivity + tail)
            }
            switch launched {
            case .running:
                return BrainWhyGoal(goal: goal, kind: .running, spans: [.prose(verb), .designation(focus)] + tail)
            case .needsAttention:
                return BrainWhyGoal(
                    goal: goal, kind: .halted,
                    spans: [.prose("halted, last "), .designation(focus)] + tail
                )
            case .paused:
                return BrainWhyGoal(
                    goal: goal, kind: .paused,
                    spans: [.prose("paused, last "), .designation(focus)] + tail
                )
            }
        case let .ready(vessel):
            return BrainWhyGoal(
                goal: goal, kind: .ready,
                spans: [.prose("ready to launch — \(vesselLabel) \(vessel)")]
            )
        case let .idle(reason):
            return BrainWhyGoal(
                goal: goal, kind: .idle,
                spans: .spans(in: reason, designations: knownDesignations(in: report))
            )
        }
    }

    private static func activityVerb(for goal: BrainWhyGoal.Goal) -> String {
        switch goal {
        case .salvage: "working "
        case .haul: "delivering to "
        case .mine: "installing at "
        }
    }

    private static func vesselLabel(for goal: BrainWhyGoal.Goal) -> String {
        switch goal {
        case .salvage, .mine: "carrier"
        case .haul: "controller"
        }
    }

    private static func noFocusText(for goal: BrainWhyGoal.Goal) -> String {
        switch goal {
        case .salvage: "no target yet"
        case .haul: "no sink resolved"
        case .mine: "no belt yet"
        }
    }

    private static func kind(for status: BrainGoalStatus.LaunchedStatus) -> BrainWhyGoal.Kind {
        switch status {
        case .running: .running
        case .needsAttention: .halted
        case .paused: .paused
        }
    }

    private static func prefix(_ status: BrainGoalStatus.LaunchedStatus) -> [BrainWhySpan] {
        switch status {
        case .running: []
        case .needsAttention: [.prose("halted — ")]
        case .paused: [.prose("paused — ")]
        }
    }

    // MARK: - Mine health

    /// A mine's per-belt health line: a status and a static fact, never a
    /// status and an active verb. Any false flag renders `.halted`, naming
    /// exactly what lapsed — `kind` alone carries the word "halted".
    static func mineHealthLine(_ health: BrainMineHealth) -> BrainWhyMineHealth {
        guard health.miningActive, health.surveyActive, health.ferryInForce else {
            var issues: [String] = []
            if !health.miningActive { issues.append("mining directive inactive") }
            if !health.surveyActive { issues.append("survey directive inactive") }
            if !health.ferryInForce { issues.append("no ferry in force") }
            return BrainWhyMineHealth(
                belt: health.belt, kind: .halted,
                spans: [.prose("\(issues.joined(separator: ", ")) at ")] + [.designation(health.belt)]
            )
        }
        return BrainWhyMineHealth(
            belt: health.belt, kind: .running,
            spans: [.prose("mining, surveying and ferrying "), .designation(health.belt)]
        )
    }

    private static func mineDemandNote(in report: BrainReport) -> [BrainWhySpan]? {
        guard report.mineDemandIncomplete else { return nil }
        return [.prose("mine siting incomplete — blueprint catalog empty, demand under-counted")]
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
                kind: .commandGovernor,
                detail: """
                    commands — \(count(limits.actionsRemaining)) of \(count(limits.actionsLimit)) \
                    left this minute, pacing ourselves below \(count(limits.actionsFloor))
                    """
            )
        )

        // Its own bucket, and the one a paged walk or a confirm-read spends
        // from — a healthy command budget is no evidence about this one.
        lines.append(
            BrainWhyPressure(
                kind: .readGovernor,
                detail: """
                    reads — \(count(limits.readsRemaining)) of \(count(limits.readsLimit)) \
                    left this minute, pacing ourselves below \(count(limits.readsFloor))
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
        lines.append(
            BrainWhyPressure(kind: .reserveFloor, detail: "hub stock — \(stockDetail(limits, at: report.observedAt))")
        )

        return lines
    }

    /// The reserve-floor line's own sentence for one `BrainLimits` reading —
    /// shared by the flat pressure line above and each theatre's own stock
    /// line, so the two can never quote the rail differently.
    private static func stockDetail(_ limits: BrainLimits, at observedAt: Date) -> String {
        let floor = count(limits.spendFloor)
        switch limits.hubStockStanding(at: observedAt) {
        case .unread:
            return "no census reading — printing vetoed until one lands"
        case let .stale(age):
            // Name the AGE, not the figure's size: an operator told a healthy
            // -looking number is vetoed would go hunting for a shortage that
            // does not exist. Same reasoning as `printStockShortDiagnosis`.
            return """
            \(limits.hubStock.map(count) ?? "?") units, but the census reading is \(aged(age)) \
            — printing vetoed until it refreshes
            """
        case .belowFloor:
            return "\(limits.hubStock.map(count) ?? "?") units, below the \(floor) reserve floor — printing vetoed"
        case .clear:
            return "\(limits.hubStock.map(count) ?? "?") units against a \(floor) reserve floor"
        }
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
        for theatre in report.theatres {
            codes.insert(theatre.depot)
            // The survey roam centre — `Brain.surveyReadiness` derives it the
            // same way, so an idle reason naming it (the census-miss case)
            // still tags mono without a second field to carry it.
            codes.insert(theatre.system)
        }
        return codes
    }
}

/// The brain's status, as one line of window chrome above the Directives list —
/// **a doorway, not a dashboard.**
///
/// This used to be the whole report: the gate, both rails, prune's findings and
/// five ranked candidates, all pinned above the list. That does not scale. Every
/// goal the brain learns adds another block to a header nobody asked to see,
/// and the header is the one place in this window where height is most
/// expensive — it is subtracted from the list on every screen, forever.
///
/// So the header now answers exactly one question — *what is the brain doing
/// right now?* — and everything behind that answer moves to
/// `BrainWhyDetailView`, which scrolls and can afford to grow. Tapping selects
/// the brain in the same `selectedRowID` the rows use.
///
/// The gate stays `lineLimit`ed for a second reason beyond brevity: chrome that
/// wraps without a bound reports its zero-width wrap height as the WINDOW's
/// minimum height (see the chrome-min-height memory note). Two lines here is a
/// ceiling, not a target.
public struct BrainWhyView: View {
    let why: BrainWhy
    let action: () -> Void

    public init(why: BrainWhy, action: @escaping () -> Void) {
        self.why = why
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: why.isEscalated ? "exclamationmark.triangle.fill" : "brain.head.profile")
                    .font(.system(size: IconSize.m))
                    .foregroundStyle(why.isEscalated ? .rcWarning : .rcTextSecondary)
                why.topGoalGate
                    .styled(prose: .rcBodyEmph, designation: .rcBodyEmphMono)
                    .foregroundStyle(.rcTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.xs)
                // The affordance. Without it the strip reads as a status label
                // and nobody discovers there is anything behind it.
                Image(systemName: "chevron.right")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
            .padding(Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(why.isEscalated ? .rcWarning : .rcSeparator, lineWidth: Hairline.thin)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Brain: \(why.gateText)")
        .accessibilityHint("Shows the brain's full report")
    }
}
