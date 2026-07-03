//
//  MessagesFeatureTests.swift
//  Replicould — Messages feature
//

import ComposableArchitecture
import Foundation
import SQLiteData
import Testing
@testable import MessagesFeature

/// A stand-in error whose `localizedDescription` is a known string, for
/// asserting surfaced error messages.
private struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Suite struct MessagesFeatureTests {
    /// Refreshing fetches a page and upserts it into the local store.
    @Test func refreshPersistsFetchedMessages() async throws {
        let database = try makeDatabase()
        let inbox = [
            Message(id: 1, messageType: "system", title: "Welcome", body: "Hi", isRead: false,
                    createdAt: Date(timeIntervalSince1970: 100)),
            Message(id: 2, messageType: "combat", title: "Skirmish", body: "Boom", isRead: true,
                    createdAt: Date(timeIntervalSince1970: 200)),
        ]

        let store = TestStore(initialState: MessagesFeature.State()) {
            MessagesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.messagesClient.fetch = { _, _, _ in
                MessagePage(messages: inbox, nextCursor: nil, unreadCount: 1)
            }
        }

        await store.send(.task) { $0.isLoading = true }
        await store.receive(\.refreshSucceeded) { $0.isLoading = false }

        let stored = try await database.read { db in
            try Message.order { $0.id }.fetchAll(db)
        }
        #expect(stored.map(\.id) == [1, 2])
        #expect(stored.map(\.title) == ["Welcome", "Skirmish"])
        #expect(stored.map(\.isRead) == [false, true])
    }

    /// A failed fetch surfaces an error and clears the loading flag.
    @Test func refreshFailureSurfacesError() async throws {
        let database = try makeDatabase()
        let store = TestStore(initialState: MessagesFeature.State()) {
            MessagesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.messagesClient.fetch = { _, _, _ in
                throw StubError(message: "boom")
            }
        }

        await store.send(.task) { $0.isLoading = true }
        await store.receive(\.refreshFailed) {
            $0.isLoading = false
            $0.errorMessage = "boom"
        }
    }

    /// Selecting an unread message marks it read locally and tells the server.
    @Test func selectingUnreadMarksReadLocallyAndOnServer() async throws {
        let database = try makeDatabase()
        try await seed(database, [
            Message(id: 1, messageType: "system", title: "A", body: "", isRead: false,
                    createdAt: Date(timeIntervalSince1970: 1)),
        ])

        let markReadCalls = LockIsolated<[MarkRead]>([])
        let store = TestStore(initialState: MessagesFeature.State()) {
            MessagesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.messagesClient.markRead = { ids, markAll in
                markReadCalls.withValue { $0.append(MarkRead(ids: ids, markAll: markAll)) }
            }
        }

        await store.send(.binding(.set(\.selectedMessageID, 1))) {
            $0.selectedMessageID = 1
        }
        await store.finish()

        #expect(markReadCalls.value == [MarkRead(ids: [1], markAll: false)])
        let isRead = try await database.read { db in
            try Message.where { $0.id.eq(1) }.fetchOne(db)?.isRead
        }
        #expect(isRead == true)
    }

    /// Re-selecting an already-read message touches neither the store nor the
    /// server — the guard that keeps arrow-key scrolling from tripping the API
    /// rate limiter.
    @Test func selectingAlreadyReadMessageDoesNotHitServer() async throws {
        let database = try makeDatabase()
        try await seed(database, [
            Message(id: 1, messageType: "system", title: "A", body: "", isRead: true,
                    createdAt: Date(timeIntervalSince1970: 1)),
        ])

        let markReadCalls = LockIsolated<[MarkRead]>([])
        let store = TestStore(initialState: MessagesFeature.State()) {
            MessagesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.messagesClient.markRead = { ids, markAll in
                markReadCalls.withValue { $0.append(MarkRead(ids: ids, markAll: markAll)) }
            }
        }

        await store.send(.binding(.set(\.selectedMessageID, 1))) {
            $0.selectedMessageID = 1
        }
        await store.finish()

        #expect(markReadCalls.value.isEmpty)
    }

    /// A failed server mark-read surfaces an error. The local row stays read —
    /// the optimistic write isn't rolled back.
    @Test func selectingUnreadSurfacesServerError() async throws {
        let database = try makeDatabase()
        try await seed(database, [
            Message(id: 1, messageType: "system", title: "A", body: "", isRead: false,
                    createdAt: Date(timeIntervalSince1970: 1)),
        ])

        let store = TestStore(initialState: MessagesFeature.State()) {
            MessagesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.messagesClient.markRead = { _, _ in
                throw StubError(message: "rate limited")
            }
        }

        await store.send(.binding(.set(\.selectedMessageID, 1))) {
            $0.selectedMessageID = 1
        }
        await store.receive(\.markReadFailed) {
            $0.errorMessage = "rate limited"
        }
    }

    /// A second `.task`/refresh while one is in flight is ignored.
    @Test func refreshIsIgnoredWhileLoading() async throws {
        let database = try makeDatabase()
        let store = TestStore(initialState: MessagesFeature.State(isLoading: true)) {
            MessagesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }

        // No state change and no effect: the in-flight guard short-circuits.
        await store.send(.task)
        await store.send(.refreshButtonTapped)
    }

    /// A failed mark-all surfaces an error.
    @Test func markAllReadFailureSurfacesError() async throws {
        let database = try makeDatabase()
        let store = TestStore(initialState: MessagesFeature.State()) {
            MessagesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.messagesClient.markRead = { _, _ in
                throw StubError(message: "boom")
            }
        }

        await store.send(.markAllReadButtonTapped)
        await store.receive(\.markReadFailed) {
            $0.errorMessage = "boom"
        }
    }

    /// Dismissing an error clears it.
    @Test func dismissErrorClearsMessage() async throws {
        let database = try makeDatabase()
        let store = TestStore(
            initialState: MessagesFeature.State(errorMessage: "boom")
        ) {
            MessagesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }

        await store.send(.dismissError) {
            $0.errorMessage = nil
        }
    }

    /// Marking all read clears every unread flag in the store.
    @Test func markAllReadClearsUnread() async throws {
        let database = try makeDatabase()
        try await database.write { db in
            try Message.upsert {
                Message(id: 1, messageType: "system", title: "A", body: "", isRead: false,
                        createdAt: Date(timeIntervalSince1970: 1))
            }
            .execute(db)
            try Message.upsert {
                Message(id: 2, messageType: "trade", title: "B", body: "", isRead: false,
                        createdAt: Date(timeIntervalSince1970: 2))
            }
            .execute(db)
        }

        let store = TestStore(initialState: MessagesFeature.State()) {
            MessagesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.messagesClient.markRead = { _, _ in }
        }

        await store.send(.markAllReadButtonTapped)
        await store.finish()

        let unread = try await database.read { db in
            try Message.where { !$0.isRead }.fetchCount(db)
        }
        #expect(unread == 0)
    }

    /// Builds a fresh, migrated database. SQLiteData vends an in-memory store in
    /// the test context.
    private func makeDatabase() throws -> any DatabaseWriter {
        let database = try SQLiteData.defaultDatabase()
        var migrator = DatabaseMigrator()
        Message.registerMigrations(&migrator)
        try migrator.migrate(database)
        return database
    }

    /// Inserts the given messages into the store.
    private func seed(_ database: any DatabaseWriter, _ messages: [Message]) async throws {
        try await database.write { db in
            for message in messages {
                try Message.upsert { message }.execute(db)
            }
        }
    }
}

/// Records a single `markRead` invocation so tests can assert on what the
/// feature sent to the server.
private struct MarkRead: Equatable {
    var ids: [Int]?
    var markAll: Bool
}
