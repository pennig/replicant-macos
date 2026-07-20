//
//  ReplicantEditFeature.swift
//  Replicould — Replicants feature
//
//  The editor for one of the account's own replicants, presented as a sheet from
//  the inspector. Seeds draft fields from the selected `KnownReplicant`, gates
//  Save on an actual change, and persists via `ReplicantsClient.updateProfile`
//  (`PATCH /v1/replicants/{code}`) — which re-fetches the canonical record on
//  success so the inspector reflects server-normalized values. Mirrors the
//  AccountFeature Settings draft/save pattern.
//

import ComposableArchitecture
import Foundation
import GameModels
import GameServices

@Reducer
public struct ReplicantEditFeature {
    @ObservableState
    public struct State: Equatable {
        public let replicantCode: String
        public var name: String
        public var isNPC: Bool
        public var pronouns: String
        public var descriptionText: String
        public var plan: String
        public var project: String
        public var cohortPermission: String

        /// The values as loaded, so Save can be gated on a real change.
        var seed: Snapshot
        public var isSaving: Bool = false
        public var saveError: String?

        struct Snapshot: Equatable {
            var name: String
            var isNPC: Bool
            var pronouns: String
            var descriptionText: String
            var plan: String
            var project: String
            var cohortPermission: String
        }

        public init(replicant: KnownReplicant) {
            replicantCode = replicant.replicantCode
            name = replicant.name
            isNPC = replicant.isNPC
            pronouns = replicant.pronouns ?? ""
            descriptionText = replicant.descriptionText ?? ""
            plan = replicant.plan ?? ""
            project = replicant.project ?? ""
            cohortPermission = replicant.cohortPermission ?? "private"
            seed = Snapshot(
                name: replicant.name,
                isNPC: replicant.isNPC,
                pronouns: replicant.pronouns ?? "",
                descriptionText: replicant.descriptionText ?? "",
                plan: replicant.plan ?? "",
                project: replicant.project ?? "",
                cohortPermission: replicant.cohortPermission ?? "private"
            )
        }

        var current: Snapshot {
            Snapshot(
                name: name, isNPC: isNPC, pronouns: pronouns, descriptionText: descriptionText,
                plan: plan, project: project, cohortPermission: cohortPermission
            )
        }

        /// Whether any field differs from what was loaded.
        public var hasUnsavedChanges: Bool { current != seed }

        /// Save is offered only when something changed, we're not mid-save, and the
        /// name isn't blank (the one field the server requires be present).
        public var canSave: Bool {
            hasUnsavedChanges && !isSaving && !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case saveTapped
        case saveSucceeded
        case saveFailed(String)
        case cancelTapped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case saved
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

            case .saveTapped:
                guard state.canSave else { return .none }
                state.isSaving = true
                state.saveError = nil
                let code = state.replicantCode
                let update = ReplicantProfileUpdate(
                    name: state.name.trimmingCharacters(in: .whitespaces),
                    isNPC: state.isNPC,
                    pronouns: state.pronouns,
                    description: state.descriptionText,
                    plan: state.plan,
                    project: state.project,
                    cohortPermission: state.cohortPermission
                )
                let replicantsClient = self.replicantsClient
                return .run { send in
                    try await replicantsClient.updateProfile(code, update)
                    await send(.saveSucceeded)
                } catch: { error, send in
                    await send(.saveFailed((error as? ReplicantsClient.UpdateError)?.message ?? "Couldn’t save your changes."))
                }

            case .saveSucceeded:
                state.isSaving = false
                let dismiss = self.dismiss
                return .run { send in
                    await send(.delegate(.saved))
                    await dismiss()
                }

            case let .saveFailed(message):
                state.isSaving = false
                state.saveError = message
                return .none

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
