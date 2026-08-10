//
//  LogisticsFeature.swift
//  Replicould — Logistics feature
//
//  The haul-yield ledger: every Haul Run pickup and the charts over it.
//

import ComposableArchitecture
import Foundation
import GameModels
import SQLiteData

@Reducer
public struct LogisticsFeature {
    @ObservableState
    public struct State: Equatable {
        @ObservationStateIgnored
        @FetchAll(HaulYield.order { $0.collectedAt.desc() }) public var yields: [HaulYield]
        public var range: TimeRange = .month
        public init() {}
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
    }

    public init() {}

    // `@FetchAll` loads and stays live on its own, so there is no load action
    // and no `.task` — adding one would be a no-op the view still called.
    public var body: some ReducerOf<Self> {
        BindingReducer()
    }
}
