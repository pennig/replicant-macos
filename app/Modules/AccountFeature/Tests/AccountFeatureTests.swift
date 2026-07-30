//
//  AccountFeatureTests.swift
//  Replicould — Account feature
//
//  The reducer's jobs: on appear, seed the Settings drafts from the shared
//  account and load the merged achievement list; on save, PATCH the edited fields
//  and re-sync the shared profile through `AccountManager`; surface a save error.
//  Plus the domain merge that powers the Achievements tab.
//

import AccountManager
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import Testing

@testable import AccountFeature

@MainActor
@Suite struct AccountFeatureTests {

    private func makeAccount() -> Account {
        Account(
            email: "matt@pennig.name",
            name: "pennig",
            timezone: "America/Chicago",
            bobnetChannels: ["#general", "#trade"],
            replicantCooperation: "individual"
        )
    }

    /// On appear, the Settings drafts seed from the shared account and the merged
    /// achievement list loads.
    @Test func taskSeedsDraftsAndLoadsAchievements() async throws {
        let database = try GameDatabase.bootstrap()
        let sample = [
            Achievement(key: "a", title: "A", summary: "s", category: "travel", xpReward: 100, isEarned: true, achievedAt: .now, playerCount: 3),
        ]
        await withDependencies {
            $0.defaultDatabase = database
            $0.defaultFileStorage = .inMemory
            $0.accountClient.fetchAchievements = { sample }
        } operation: {
            @Shared(.account) var account
            $account.withLock { $0 = makeAccount() }

            let store = TestStore(initialState: AccountFeature.State(apiKey: "k")) { AccountFeature() }

            await store.send(.task) {
                $0.draftName = "pennig"
                $0.draftTimezone = "America/Chicago"
                $0.draftCooperation = "individual"
                $0.draftChannelsText = "#general, #trade"
                $0.isLoadingAchievements = true
            }
            await store.receive(\.achievementsLoaded) {
                $0.isLoadingAchievements = false
                $0.achievements = sample
            }
        }
    }

    /// Saving forwards the edited fields to `accountClient.update` and then re-syncs
    /// the shared profile via `accountManager.refreshAccount`.
    @Test func saveSettingsUpdatesAndRefreshes() async throws {
        let database = try GameDatabase.bootstrap()
        let captured = LockIsolated<AccountUpdate?>(nil)
        let refreshed = LockIsolated(false)
        await withDependencies {
            $0.defaultDatabase = database
            $0.defaultFileStorage = .inMemory
            $0.accountClient.fetchAchievements = { [] }
            $0.accountClient.update = { captured.setValue($0) }
            $0.accountManager.refreshAccount = { refreshed.setValue(true); return true }
        } operation: {
            @Shared(.account) var account
            $account.withLock { $0 = makeAccount() }

            let store = TestStore(initialState: AccountFeature.State(apiKey: "k")) { AccountFeature() }
            store.exhaustivity = .off

            await store.send(.task)
            await store.send(.binding(.set(\.draftName, "pennig-2")))
            await store.send(.saveSettings)
            await store.finish()

            #expect(captured.value?.name == "pennig-2")
            #expect(captured.value?.timezone == "America/Chicago")
            #expect(captured.value?.replicantCooperation == "individual")
            #expect(captured.value?.bobnetChannels == ["#general", "#trade"])
            #expect(refreshed.value == true)
        }
    }

    /// A rejected save surfaces the server message and does not refresh the profile.
    @Test func saveSettingsFailureSurfacesError() async throws {
        let database = try GameDatabase.bootstrap()
        await withDependencies {
            $0.defaultDatabase = database
            $0.defaultFileStorage = .inMemory
            $0.accountClient.fetchAchievements = { [] }
            $0.accountClient.update = { _ in throw AccountClient.UpdateError("Name already taken.") }
        } operation: {
            @Shared(.account) var account
            $account.withLock { $0 = makeAccount() }

            let store = TestStore(initialState: AccountFeature.State(apiKey: "k")) { AccountFeature() }
            store.exhaustivity = .off

            await store.send(.task)
            await store.send(.binding(.set(\.draftName, "taken")))
            await store.send(.saveSettings)
            // Non-exhaustive: skip past `.achievementsLoaded` to the failure.
            await store.receive(\.saveFailed) {
                $0.saveError = "Name already taken."
                $0.isSaving = false
            }
            await store.finish()
        }
    }

    /// Nothing edited → save is a no-op (guarded by `hasUnsavedChanges`), so the
    /// client is never called.
    @Test func saveWithNoChangesIsNoOp() async throws {
        let database = try GameDatabase.bootstrap()
        await withDependencies {
            $0.defaultDatabase = database
            $0.defaultFileStorage = .inMemory
            $0.accountClient.fetchAchievements = { [] }
        } operation: {
            @Shared(.account) var account
            $account.withLock { $0 = makeAccount() }

            let store = TestStore(initialState: AccountFeature.State(apiKey: "k")) { AccountFeature() }
            store.exhaustivity = .off

            await store.send(.task)   // seeds drafts to match the account exactly
            await store.send(.saveSettings)   // hasUnsavedChanges == false → no effect
            await store.finish()
            // No `accountClient.update` stub is provided; reaching it would fail loudly.
        }
    }

    // MARK: - Domain merge

    /// The merge lists every catalog achievement, flips the earned ones (carrying
    /// their date), keeps galaxy-wide counts, and never drops an earned-only entry.
    @Test func mergeAnnotatesCatalogWithEarnedSet() {
        let earned = [
            Achievement(key: "e1", title: "Earned One", summary: "", category: "travel", xpReward: 100, isEarned: true, achievedAt: .distantPast),
            Achievement(key: "orphan", title: "Orphan", summary: "", category: "misc", xpReward: 10, isEarned: true, achievedAt: .distantPast),
        ]
        let catalog = [
            Achievement(key: "e1", title: "Earned One", summary: "", category: "travel", xpReward: 100, isEarned: false, playerCount: 50),
            Achievement(key: "locked", title: "Locked", summary: "", category: "travel", xpReward: 200, isEarned: false, playerCount: 3),
        ]

        let merged = Achievement.merged(earned: earned, catalog: catalog)

        #expect(merged.count == 3)   // e1 + locked + orphan
        let e1 = merged.first { $0.key == "e1" }
        #expect(e1?.isEarned == true)
        #expect(e1?.achievedAt == .distantPast)
        #expect(e1?.playerCount == 50)   // catalog count preserved
        #expect(merged.first { $0.key == "locked" }?.isEarned == false)
        #expect(merged.contains { $0.key == "orphan" })   // earned-only entry kept
    }
}
