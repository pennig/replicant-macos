//
//  ReplicantReplicateFeature.swift
//  Replicould — Replicants feature
//
//  The "Replicate" confirmation for one of the account's own replicants,
//  presented as a sheet from the inspector. Carries a resolved
//  `ReplicationEligibility` snapshot (the requirement checklist + valid targets),
//  lets the user pick a target and name the offspring, and dispatches the
//  `replicate` device command via `ReplicantsClient.replicate`. The action is
//  gated on `eligibility.canReplicate`, so the button only fires when every
//  requirement is met. On success it hands the new replicant's code back to the
//  parent (which refreshes the roster/fleet and reveals it).
//

import ComposableArchitecture
import Foundation
import GameModels
import GameServices

@Reducer
public struct ReplicantReplicateFeature {
    @ObservableState
    public struct State: Equatable {
        public let replicantCode: String
        public let replicantName: String
        public var eligibility: ReplicationEligibility
        public var selectedTargetCode: String?
        public var newName: String = ""
        public var isReplicating: Bool = false
        public var error: String?

        public init(replicantCode: String, replicantName: String, eligibility: ReplicationEligibility) {
            self.replicantCode = replicantCode
            self.replicantName = replicantName
            self.eligibility = eligibility
            self.selectedTargetCode = eligibility.targets.first?.deviceCode
        }

        /// Whether the command can be dispatched: all requirements met, a target
        /// chosen, and not already in flight.
        public var canReplicate: Bool {
            eligibility.canReplicate && selectedTargetCode != nil && !isReplicating
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case confirmTapped
        case replicated(ReplicateOutcome)
        case cancelTapped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case replicated(newCode: String?)
            case cancelled
        }
    }

    @Dependency(\.replicantsClient) var replicantsClient
    @Dependency(\.dismiss) var dismiss

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .confirmTapped:
                guard
                    state.canReplicate,
                    let source = state.eligibility.sourceMatrixCode,
                    let target = state.selectedTargetCode
                else { return .none }
                state.isReplicating = true
                state.error = nil
                let name = state.newName.trimmingCharacters(in: .whitespaces)
                let replicantsClient = self.replicantsClient
                return .run { send in
                    let outcome = await replicantsClient.replicate(source, target, name.isEmpty ? nil : name)
                    await send(.replicated(outcome))
                }

            case let .replicated(outcome):
                state.isReplicating = false
                switch outcome {
                case let .success(newCode, _):
                    let dismiss = self.dismiss
                    return .run { send in
                        await send(.delegate(.replicated(newCode: newCode)))
                        await dismiss()
                    }
                case let .rejected(message), let .failed(message):
                    state.error = message
                    return .none
                }

            case .cancelTapped:
                let dismiss = self.dismiss
                return .run { send in
                    await send(.delegate(.cancelled))
                    await dismiss()
                }

            case .delegate:
                return .none
            }
        }
    }
}
