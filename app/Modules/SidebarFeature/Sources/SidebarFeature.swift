//
//  SidebarFeature.swift
//  Replicould — Sidebar feature
//
//  The signed-in window's left column: the active-replicant header (switcher +
//  live progress + editable plan), the grouped category list, and the account
//  footer. Extracted from `MainFeature` so the app root stays a thin container
//  that only scopes child state. The category selection lives here and is read
//  back by `MainView` to drive its content/detail panes.
//

import ComposableArchitecture
import DependencyClients
import Foundation
import MessagesFeature
import ReplicantsFeature
import SQLiteData

@Reducer
public struct SidebarFeature {
    @ObservableState
    public struct State: Equatable {
        /// The signed-in account profile (footer + Account sheet).
        @Shared(.account) public var account: Account
        /// The account's replicant roster, observed from SQLite (switcher + footer).
        @ObservationStateIgnored
        @FetchAll public var replicants: [Replicant]
        /// The session API key, shown (read-only) in the Account sheet.
        public var apiKey: String
        /// The selected category — the split view's navigation spine. `MainView`
        /// reads this to choose the content/detail panes.
        public var category: SidebarItem?
        /// Whether the Account sheet is presented (opened from the footer).
        public var isShowingAccount: Bool

        public init(apiKey: String, category: SidebarItem? = .devices) {
            self.apiKey = apiKey
            self.category = category
            self.isShowingAccount = false
        }
    }

    @Dependency(\.replicantsClient) var replicantsClient

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// Hydrate the active replicant's public details (its `plan`) so the header
        /// can show and edit it.
        case loadActivePlan(String)
        /// Persist an edited plan for the given replicant via PATCH.
        case savePlan(code: String, plan: String)
        case logoutButtonTapped
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            /// The Account sheet's Log Out was tapped — the app root tears down.
            case loggedOut
            /// The category selection changed — the container resets its detail
            /// selection. (The category itself lives here; only the reset bridges.)
            case categoryChanged
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.category):
                return .send(.delegate(.categoryChanged))

            case .binding:
                return .none

            case let .loadActivePlan(code):
                // Best-effort: the header reads the plan straight from SQLite, so
                // a failed load just leaves the last-known value in place.
                let replicantsClient = self.replicantsClient
                return .run { _ in try? await replicantsClient.loadDetails(code) }

            case let .savePlan(code, plan):
                let replicantsClient = self.replicantsClient
                return .run { _ in
                    _ = await withErrorReporting {
                        try await replicantsClient.updatePlan(code, plan)
                    }
                }

            case .logoutButtonTapped:
                return .send(.delegate(.loggedOut))

            case .delegate:
                return .none
            }
        }
    }
}
