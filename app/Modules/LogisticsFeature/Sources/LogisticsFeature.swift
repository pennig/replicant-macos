//
//  LogisticsFeature.swift
//  Replicould — Logistics feature
//
//  The haul-yield ledger, and Theatres: what exists, its state, and the
//  operator's half of "brain proposes, operator establishes". One feature,
//  two tabs — they share no query.
//

import ComposableArchitecture
import DirectiveEngine
import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Logistics")

@Reducer
public struct LogisticsFeature {
    public enum Tab: String, CaseIterable, Equatable, Sendable {
        case yields, theatres
        public var title: String {
            switch self {
            case .yields: "Haul Yields"
            case .theatres: "Theatres"
            }
        }
    }

    @ObservableState
    public struct State: Equatable {
        /// The window's figures, folded by SQLite rather than by Swift — see
        /// `HaulYieldDigest`. Seeded with the request for `range`'s default so
        /// the first render is already the window the segmented control claims,
        /// and reloaded by the reducer whenever `range` changes.
        @ObservationStateIgnored
        @Fetch var summary: YieldSummary
        public var range: TimeRange = .defaultRange
        public var tab: Tab = .yields
        /// Recognised theatres, loaded explicitly rather than through
        /// `@FetchAll` — `Theatre` is derived, not a table. See `loadTheatres`.
        public var theatres: [TheatreRowModel] = []
        /// The brain's ranked candidate sites, loaded alongside `theatres`.
        public var candidates: [TheatreSiteRanking.Candidate] = []
        @Presents public var establishTheatre: EstablishTheatreSheet.State?

        public init() {
            @Dependency(\.date.now) var now
            _summary = Fetch(
                wrappedValue: YieldSummary(),
                HaulYieldDigest(range: .defaultRange, now: now)
            )
        }

        /// The digest request for the current selections. The cutoff is pinned
        /// to a `now` taken when the request is built, not when it runs, so the
        /// window is deterministic under a controlled clock — the view's `.task`
        /// rebuilds it on appear so a long-running session's "24 hours" does not
        /// drift into meaning "since whenever this screen first opened".
        var digestRequest: HaulYieldDigest {
            @Dependency(\.date.now) var now
            return HaulYieldDigest(range: range, now: now)
        }
    }

    public enum TimeRange: String, CaseIterable, Equatable, Hashable, Sendable {
        case day, week, month, all

        /// The window `State` opens on — and the one its `@Fetch` seed is cut
        /// for, which a stored-property default cannot be read from in `init`.
        public static let defaultRange = TimeRange.month

        public var title: String {
            switch self {
            case .day: "24 hours"
            case .week: "7 days"
            case .month: "30 days"
            case .all: "All"
            }
        }
        public var days: Int? {
            switch self {
            case .day: 1
            case .week: 7
            case .month: 30
            case .all: nil
            }
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case theatresRefreshTapped
        case theatresLoaded(theatres: [TheatreRowModel], candidates: [TheatreSiteRanking.Candidate])
        case establishTapped(system: String?)
        case establishTheatre(PresentationAction<EstablishTheatreSheet.Action>)
    }

    public init() {}

    private enum CancelID { case loadTheatres }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date

    // Yields load live via `@FetchAll`. Theatres are derived, not a table,
    // so that tab loads on demand: first switch, plus the Refresh action.
    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                // Re-cut the window against the current clock. The `@Fetch` seed
                // was built when `State` was, which for a screen left open is a
                // different day.
                return reloadSummary(state)

            case .binding(\.tab):
                guard state.tab == .theatres else { return .none }
                return loadTheatres()

            case .binding(\.range):
                // `.load` keeps the previous digest on screen until the new one
                // is folded, so the charts change window without flashing empty.
                return reloadSummary(state)

            case .binding:
                return .none

            case .theatresRefreshTapped:
                return loadTheatres()

            case let .theatresLoaded(theatres, candidates):
                state.theatres = theatres
                state.candidates = candidates
                return .none

            case let .establishTapped(system):
                state.establishTheatre = EstablishTheatreSheet.State(suggestedSystem: system)
                return .none

            case .establishTheatre(.presented(.delegate(.established))):
                return loadTheatres()

            case .establishTheatre:
                return .none
            }
        }
        .ifLet(\.$establishTheatre, action: \.establishTheatre) {
            EstablishTheatreSheet()
        }
    }

    /// Reloads the ledger digest for the state's current range and clock.
    private func reloadSummary(_ state: State) -> Effect<Action> {
        .run { [fetch = state.$summary, request = state.digestRequest] _ in
            _ = try? await fetch.load(request)
        }
    }

    /// One `WorldView` read plus the directive table, called only from this
    /// effect — never from a view's `body` or `onChange` — because
    /// `TheatreSiteRanking.rank` walks the whole star catalogue.
    private func loadTheatres() -> Effect<Action> {
        let database = self.database
        let date = self.date
        return .run { send in
            let (view, directives) = try await database.read { db in
                (try WorldView.read(from: db, now: date.now), try Directive.where { $0.deletedAt.is(nil) }.fetchAll(db))
            }
            // Ranking is CPU-bound, not I/O — done here, after the read
            // transaction has closed, so it never holds a DB lock.
            let candidates = TheatreSiteRanking.rank(view: view)
            let theatres = view.theatres.map { TheatreRowModel(theatre: $0, view: view, directives: directives) }
            await send(.theatresLoaded(theatres: theatres, candidates: candidates))
        } catch: { error, _ in
            logger.error("theatre load failed: \(error.localizedDescription, privacy: .public)")
        }
        .cancellable(id: CancelID.loadTheatres, cancelInFlight: true)
    }
}
