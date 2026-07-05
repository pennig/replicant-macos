//
//  AccountManagerTests.swift
//  Replicould — AccountManager
//
//  Exercises the session business logic end-to-end against a canned API
//  transport, an in-memory SQLite store, and in-memory shared storage: signing in
//  persists the roster + profile and defaults the active replicant, a bad key is
//  rejected and rolled back, signing out clears every trace (and runs registered
//  handlers), and signup maps server responses to outcomes.
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameServices
import HTTPTypes
import OpenAPIRuntime
import SQLiteData
import Testing
@testable import AccountManager

@MainActor
@Suite struct AccountManagerTests {

    // MARK: Login

    /// A valid key is stored, the roster is persisted, and the active replicant
    /// defaults to the first in the list.
    @Test func validKeyPersistsRosterAndDefaultsActive() async throws {
        let database = try GameDatabase.bootstrap()
        let appStorage = UserDefaults.inMemory
        let saves = LockIsolated<[String]>([])
        let manager = AccountManager.makeLive()
        let body = """
            {
              "email": "roy@tyrell.example",
              "name": "Roy",
              "replicants": [
                {"replicant_code": "RX-01", "name": "Nexus", "created_at": "2026-06-01T00:00:00Z", "experience_points": 10, "device_count": 2},
                {"replicant_code": "RX-02", "name": "Pris", "created_at": "2026-06-02T00:00:00Z", "experience_points": 5, "device_count": 1}
              ]
            }
            """

        try await withDependencies {
            $0.gameClient = stubGameClient { _ in jsonResponse(200, body) }
            $0.keychain.save = { value, _ in saves.withValue { $0.append(value) } }
            $0.defaultDatabase = database
            $0.defaultAppStorage = appStorage
            $0.defaultFileStorage = .inMemory
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            try await manager.logIn("rk_live_abc")
        }

        #expect(saves.value == ["rk_live_abc"])
        let stored = try await database.read { db in try Replicant.fetchAll(db) }
        #expect(Set(stored.map(\.replicantCode)) == ["RX-01", "RX-02"])
        #expect(appStorage.string(forKey: Account.activeReplicantCodeKey) == "RX-01")
    }

    /// A non-200 from /me throws `.rejected` and rolls the Keychain write back.
    @Test func rejectedKeyThrowsAndRollsBack() async throws {
        let database = try GameDatabase.bootstrap()
        let deletes = LockIsolated<[String]>([])
        let manager = AccountManager.makeLive()

        await withDependencies {
            $0.gameClient = stubGameClient { _ in jsonResponse(401) }
            $0.keychain.delete = { account in deletes.withValue { $0.append(account) } }
            $0.defaultDatabase = database
            $0.defaultAppStorage = .inMemory
            $0.defaultFileStorage = .inMemory
        } operation: {
            await #expect(throws: AccountManager.LoginError.rejected) {
                try await manager.logIn("bad")
            }
        }

        #expect(deletes.value == [KeychainClient.apiKeyAccount])
    }

    // MARK: Logout

    /// Logout runs registered handlers, clears the roster + shared values, and
    /// deletes the session token.
    @Test func logOutClearsEverythingAndRunsHandlers() async throws {
        let database = try GameDatabase.bootstrap()
        let appStorage = UserDefaults.inMemory
        let deletes = LockIsolated<[String]>([])
        let handlerRan = LockIsolated(false)
        let manager = AccountManager.makeLive()
        manager.registerHandler(
            SessionLifecycleHandler(id: "spy", onLogout: { handlerRan.setValue(true) })
        )

        try await withDependencies {
            $0.keychain.delete = { account in deletes.withValue { $0.append(account) } }
            $0.defaultDatabase = database
            $0.defaultAppStorage = appStorage
            $0.defaultFileStorage = .inMemory
        } operation: {
            // Seed a signed-in footprint.
            try await database.write { db in
                try Replicant.upsert {
                    Replicant(replicantCode: "RX-01", name: "Nexus", createdAt: Date(timeIntervalSince1970: 0))
                }
                .execute(db)
            }
            @Shared(.account) var account
            @Shared(.appStorage(Account.activeReplicantCodeKey)) var activeReplicantCode: String?
            $account.withLock { $0 = Account(name: "Roy") }
            $activeReplicantCode.withLock { $0 = "RX-01" }

            await manager.logOut()

            #expect(account == Account())
            #expect(activeReplicantCode == nil)
        }

        #expect(handlerRan.value)
        #expect(deletes.value == [KeychainClient.apiKeyAccount])
        let count = try await database.read { db in try Replicant.fetchCount(db) }
        #expect(count == 0)
    }

    // MARK: Signup

    /// A 201 resolves without throwing.
    @Test func signUpSuccess() async throws {
        let manager = AccountManager.makeLive()
        try await withDependencies {
            $0.gameClient = stubGameClient { _ in jsonResponse(201) }
        } operation: {
            try await manager.signUp("Roy", "roy@tyrell.example", "UTC")
        }
    }

    /// A 409 throws a `SignupError` carrying the server's message.
    @Test func signUpConflictThrows() async throws {
        let manager = AccountManager.makeLive()
        await withDependencies {
            $0.gameClient = stubGameClient { _ in jsonResponse(409, #"{"error":"Email taken"}"#) }
        } operation: {
            await #expect(throws: AccountManager.SignupError("Email taken")) {
                try await manager.signUp("Roy", "taken@tyrell.example", "UTC")
            }
        }
    }
}

// MARK: - Stubbed game client

/// Vends a `GameClient` whose generated `Client` is backed by a canned transport.
private func stubGameClient(
    _ respond: @escaping @Sendable (HTTPRequest) -> (HTTPResponse, HTTPBody?)
) -> GameClient {
    GameClient(make: {
        Client(serverURL: URL(string: "https://stub.invalid")!, transport: StubTransport(respond: respond))
    })
}

/// A `ClientTransport` that returns a fixed response, ignoring the request.
private struct StubTransport: ClientTransport {
    let respond: @Sendable (HTTPRequest) -> (HTTPResponse, HTTPBody?)
    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        respond(request)
    }
}

/// A JSON response with the given status code and body.
private func jsonResponse(_ status: Int, _ body: String = "{}") -> (HTTPResponse, HTTPBody?) {
    (
        HTTPResponse(status: .init(code: status), headerFields: [.contentType: "application/json"]),
        HTTPBody(Array(body.utf8))
    )
}
