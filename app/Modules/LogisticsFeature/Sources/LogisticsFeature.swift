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
    /// How many rows the ledger observes at once, newest first — the same
    /// bounded-`@FetchAll` precedent as `EventLogFeature.displayLimit`, guarding
    /// against the same AttributeGraph "exhausted data space" failure mode.
    public static let displayLimit = 1000

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
        @ObservationStateIgnored
        @FetchAll(HaulYield.order { $0.collectedAt.desc() }.limit(LogisticsFeature.displayLimit))
        public var yields: [HaulYield]
        public var range: TimeRange = .month
        public var tab: Tab = .yields
        /// Recognised theatres, loaded explicitly rather than through
        /// `@FetchAll` — `Theatre` is derived, not a table. See `loadTheatres`.
        public var theatres: [TheatreRowModel] = []
        /// The brain's ranked candidate sites, loaded alongside `theatres`.
        public var candidates: [TheatreSiteRanking.Candidate] = []
        @Presents public var establishTheatre: EstablishTheatreSheet.State?
        public init() {}

        // Not `public`: `YieldSummary` is internal, and this is read only by
        // `LogisticsView` in the same module.
        var summary: YieldSummary {
            @Dependency(\.date.now) var now
            return YieldSummary(yields: yields, range: range, now: now)
        }
    }

    public enum TimeRange: String, CaseIterable, Equatable, Hashable, Sendable {
        case week, month, all
        public var title: String {
            switch self {
            case .week: "7 days"
            case .month: "30 days"
            case .all: "All"
            }
        }
        public var days: Int? {
            switch self {
            case .week: 7
            case .month: 30
            case .all: nil
            }
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
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
            case .binding(\.tab):
                guard state.tab == .theatres else { return .none }
                return loadTheatres()

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
