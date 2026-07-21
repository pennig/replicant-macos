//
//  AccountFeature.swift
//  Replicould — Account feature
//
//  The signed-in account screen, presented as a sheet from the sidebar footer.
//  Promoted out of `SidebarFeature` (where it was a plain `AccountView` over the
//  sidebar's own state) into its own feature so it can carry real behaviour: a
//  three-tab layout — Profile (read-only identity + API key + logout), Settings
//  (editable name/timezone/cooperation/channels via `PATCH /v1/accounts/me`), and
//  Achievements (earned + locked, merged from the player + global endpoints).
//
//  The account profile itself stays the shared `@Shared(.account)` value; a
//  successful settings save re-syncs it through `AccountManager.refreshAccount()`
//  so the profile keeps a single writer. Logout bubbles to the app root via the
//  delegate, exactly as the old sidebar path did.
//

import AccountManager
import ComposableArchitecture
import Foundation
import GameModels
import SQLiteData

@Reducer
public struct AccountFeature {
    /// The screen's three tabs.
    public enum Tab: String, CaseIterable, Equatable, Sendable {
        case profile, settings, achievements
    }

    @ObservableState
    public struct State: Equatable {
        /// The signed-in account profile (identity + editable prefs live here).
        @Shared(.account) public var account: Account
        /// The account's replicant roster, for the Profile tab's count.
        @ObservationStateIgnored
        @FetchAll public var replicants: [Replicant]
        /// The session API key, shown read-only on the Profile tab.
        public var apiKey: String
        public var selectedTab: Tab

        // Achievements tab
        public var achievements: [Achievement]
        public var isLoadingAchievements: Bool
        public var achievementsError: String?

        // Settings tab — editable drafts, seeded from `account` on appear.
        public var draftName: String
        public var draftTimezone: String
        public var draftCooperation: String
        /// Bobnet channels edited as a comma-separated field (parsed on save).
        public var draftChannelsText: String
        public var isSaving: Bool
        public var saveError: String?

        public init(apiKey: String, selectedTab: Tab = .profile) {
            self.apiKey = apiKey
            self.selectedTab = selectedTab
            self.achievements = []
            self.isLoadingAchievements = false
            self.achievementsError = nil
            self.draftName = ""
            self.draftTimezone = ""
            self.draftCooperation = ""
            self.draftChannelsText = ""
            self.isSaving = false
            self.saveError = nil
        }

        /// Whether the Settings drafts differ from the current account — drives the
        /// Save button's enabled state.
        public var hasUnsavedChanges: Bool {
            draftName != account.name
                || draftTimezone != account.timezone
                || draftCooperation != account.replicantCooperation
                || Self.parseChannels(draftChannelsText) != account.bobnetChannels
        }

        /// Seed the editable drafts from the current account profile.
        mutating func seedDrafts() {
            draftName = account.name
            draftTimezone = account.timezone
            draftCooperation = account.replicantCooperation
            draftChannelsText = account.bobnetChannels.joined(separator: ", ")
        }

        /// Split the comma-separated channels field into a trimmed, non-empty list.
        static func parseChannels(_ text: String) -> [String] {
            text
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// The sheet appeared — seed the Settings drafts and load achievements.
        case task
        case achievementsLoaded([Achievement])
        case achievementsFailed(String)
        /// Save the edited settings via PATCH, then re-sync the shared profile.
        case saveSettings
        case saveSucceeded
        case saveFailed(String)
        case logoutButtonTapped
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            /// Log Out was tapped — the app root tears the session down.
            case loggedOut
        }
    }

    @Dependency(\.accountClient) var accountClient
    @Dependency(\.accountManager) var accountManager

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                state.seedDrafts()
                state.isLoadingAchievements = true
                state.achievementsError = nil
                let accountClient = self.accountClient
                return .run { send in
                    do {
                        let list = try await accountClient.fetchAchievements()
                        await send(.achievementsLoaded(list))
                    } catch {
                        await send(.achievementsFailed("Couldn't load achievements."))
                    }
                }

            case let .achievementsLoaded(list):
                state.isLoadingAchievements = false
                state.achievements = list
                return .none

            case let .achievementsFailed(message):
                state.isLoadingAchievements = false
                state.achievementsError = message
                return .none

            case .saveSettings:
                guard !state.isSaving, state.hasUnsavedChanges else { return .none }
                state.isSaving = true
                state.saveError = nil
                let update = AccountUpdate(
                    name: state.draftName,
                    timezone: state.draftTimezone,
                    replicantCooperation: state.draftCooperation,
                    bobnetChannels: State.parseChannels(state.draftChannelsText)
                )
                let accountClient = self.accountClient
                let accountManager = self.accountManager
                return .run { send in
                    do {
                        try await accountClient.update(update)
                        // Single writer for the shared profile stays AccountManager.
                        await accountManager.refreshAccount()
                        await send(.saveSucceeded)
                    } catch {
                        await send(.saveFailed((error as? AccountClient.UpdateError)?.message ?? "Couldn't save your changes."))
                    }
                }

            case .saveSucceeded:
                state.isSaving = false
                // The shared account has been re-synced; reseed drafts to the
                // canonical (possibly server-normalised) values.
                state.seedDrafts()
                return .none

            case let .saveFailed(message):
                state.isSaving = false
                state.saveError = message
                return .none

            case .logoutButtonTapped:
                return .send(.delegate(.loggedOut))

            case .delegate:
                return .none
            }
        }
    }
}
