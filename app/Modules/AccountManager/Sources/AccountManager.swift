//
//  AccountManager.swift
//  Replicould — AccountManager
//
//  Owns all account *session* business logic so the UI layer doesn't have to:
//  validating + signing in a key (which fetches `/accounts/me` and persists the
//  account profile + replicant roster), signing up, restoring a session at
//  launch, and signing out (clearing every trace of the previous user). Features
//  register `SessionLifecycleHandler`s to run their own prep/cleanup alongside.
//
//  Exposed as `@Dependency(\.accountManager)`. `LoginFeature` and the app's root
//  drive it; the session token still lives only in the Keychain (read live by
//  `GameClient`), so it's never threaded through feature state.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import GameServices
import SQLiteData

public struct AccountManager: Sendable {
    /// Validate and sign in an API key: store it, fetch `/accounts/me`, persist
    /// the roster to SQLite + the profile to disk, default the active replicant,
    /// then run every registered `onLogin` handler. Throws `LoginError` on a bad
    /// key or a failed verification (rolling the Keychain write back first).
    public var logIn: @Sendable (_ apiKey: String) async throws -> Void

    /// Sign out: run every registered `onLogout` handler, clear the persisted
    /// account profile, active-replicant selection, and replicant roster, then
    /// delete the session token.
    public var logOut: @Sendable () async -> Void

    /// Create an account. The server replies 201 and emails a verification link;
    /// the API key is revealed on that page. Throws `SignupError` on failure.
    public var signUp: @Sendable (_ name: String, _ email: String, _ timeZone: String) async throws -> Void

    /// Re-fetch `/accounts/me` and re-seed the roster + account profile, without
    /// touching the session token. Called at launch when a session was restored
    /// from the Keychain (login isn't re-run then), so the sidebar roster and the
    /// Replicants directory's "own" set stay fresh across relaunches. Best-effort:
    /// a failed refresh leaves the last-persisted roster in place.
    public var refreshAccount: @Sendable () async -> Void

    /// The stored session token, if any — used to decide the initial app state
    /// synchronously at launch.
    public var restoredAPIKey: @Sendable () -> String?

    /// Register a lifecycle handler. Re-registering the same `id` replaces it.
    public var registerHandler: @Sendable (_ handler: SessionLifecycleHandler) -> Void

    public init(
        logIn: @escaping @Sendable (String) async throws -> Void,
        logOut: @escaping @Sendable () async -> Void,
        signUp: @escaping @Sendable (String, String, String) async throws -> Void,
        refreshAccount: @escaping @Sendable () async -> Void,
        restoredAPIKey: @escaping @Sendable () -> String?,
        registerHandler: @escaping @Sendable (SessionLifecycleHandler) -> Void
    ) {
        self.logIn = logIn
        self.logOut = logOut
        self.signUp = signUp
        self.refreshAccount = refreshAccount
        self.restoredAPIKey = restoredAPIKey
        self.registerHandler = registerHandler
    }

    /// A login failure, distinguishing a rejected key from a verification that
    /// couldn't complete (so the UI can show the right message).
    public enum LoginError: Error, Equatable {
        case rejected
        case verificationFailed
    }

    /// A signup failure carrying a user-facing message.
    public struct SignupError: Error, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }
}

// MARK: - Live implementation

extension AccountManager {
    /// Build a live manager backed by a fresh handler registry. The process
    /// shares one instance via `liveValue` (mirroring how `GameClient` shares a
    /// single `RateLimitGovernor`); tests call this for an isolated instance.
    public static func makeLive() -> AccountManager {
        // One registry per manager: handlers registered at app launch persist for
        // the process lifetime.
        let handlers = LockIsolated<[SessionLifecycleHandler]>([])

        return AccountManager(
            logIn: { apiKey in
                @Dependency(\.keychain) var keychain
                @Dependency(\.gameClient) var gameClient
                @Dependency(\.defaultDatabase) var database
                @Dependency(\.date) var date
                @Shared(.account) var account
                @Shared(.appStorage(Account.activeReplicantCodeKey)) var activeReplicantCode: String?

                // Store first so `gameClient()` authenticates with this key…
                try keychain.save(apiKey, KeychainClient.apiKeyAccount)
                do {
                    let output = try await gameClient().getV1AccountsMe()
                    guard case let .ok(ok) = output else {
                        try? keychain.delete(KeychainClient.apiKeyAccount)   // …roll back a bad key
                        throw LoginError.rejected
                    }
                    // The key is good — consume the profile. Persist the roster to
                    // SQLite (both the sidebar roster and the Replicants directory's
                    // own set) and the account profile to disk.
                    let body = try ok.body.json
                    let replicants = (body.replicants ?? []).map(Replicant.init(schema:))
                    try await database.write { db in
                        for replicant in replicants {
                            try Replicant.upsert { replicant }.execute(db)
                        }
                        try KnownReplicant.upsert(roster: replicants, into: db, now: date.now)
                    }
                    $account.withLock { $0 = Account(schema: body) }
                    // Default the active replicant to the first in the roster if
                    // none is selected, or the current selection is no longer ours.
                    let current = activeReplicantCode
                    if let first = replicants.first,
                       current == nil || !replicants.contains(where: { $0.replicantCode == current }) {
                        $activeReplicantCode.withLock { $0 = first.replicantCode }
                    }
                } catch let error as LoginError {
                    throw error
                } catch {
                    try? keychain.delete(KeychainClient.apiKeyAccount)
                    throw LoginError.verificationFailed
                }
                for handler in handlers.value {
                    await handler.onLogin()
                }
            },
            logOut: {
                @Dependency(\.keychain) var keychain
                @Dependency(\.defaultDatabase) var database
                @Shared(.account) var account
                @Shared(.appStorage(Account.activeReplicantCodeKey)) var activeReplicantCode: String?

                // Give each feature a chance to clean up while still signed in…
                for handler in handlers.value {
                    await handler.onLogout()
                }
                // …then wipe the previous user's persisted footprint.
                try? await database.write { db in
                    try Replicant.delete().execute(db)
                }
                $account.withLock { $0 = Account() }
                $activeReplicantCode.withLock { $0 = nil }
                try? keychain.delete(KeychainClient.apiKeyAccount)
            },
            signUp: { name, email, timeZone in
                @Dependency(\.gameClient) var gameClient
                do {
                    let output = try await gameClient().postV1Accounts(
                        body: .json(.init(email: email, name: name, timezone: timeZone))
                    )
                    switch output {
                    case .created:
                        return
                    case let .conflict(response):
                        throw SignupError((try? response.body.json.error) ?? "An account with that email already exists.")
                    case let .badRequest(response):
                        throw SignupError((try? response.body.json.error) ?? "Please check your details and try again.")
                    default:
                        throw SignupError("Something went wrong creating your account. Please try again.")
                    }
                } catch let error as SignupError {
                    throw error
                } catch {
                    throw SignupError("Something went wrong creating your account. Please try again.")
                }
            },
            refreshAccount: {
                @Dependency(\.gameClient) var gameClient
                @Dependency(\.defaultDatabase) var database
                @Dependency(\.date) var date
                @Shared(.account) var account
                @Shared(.appStorage(Account.activeReplicantCodeKey)) var activeReplicantCode: String?

                // Best-effort: any failure (offline, rate limit, transient) leaves
                // the last-persisted roster untouched.
                guard
                    let output = try? await gameClient().getV1AccountsMe(),
                    case let .ok(ok) = output,
                    let body = try? ok.body.json
                else { return }

                let replicants = (body.replicants ?? []).map(Replicant.init(schema:))
                try? await database.write { db in
                    for replicant in replicants {
                        try Replicant.upsert { replicant }.execute(db)
                    }
                    try KnownReplicant.upsert(roster: replicants, into: db, now: date.now)
                }
                $account.withLock { $0 = Account(schema: body) }
                // Keep the active-replicant selection valid: default to the first
                // when nothing is chosen or the prior choice is no longer ours.
                let current = activeReplicantCode
                if let first = replicants.first,
                   current == nil || !replicants.contains(where: { $0.replicantCode == current }) {
                    $activeReplicantCode.withLock { $0 = first.replicantCode }
                }
            },
            restoredAPIKey: {
                @Dependency(\.keychain) var keychain
                return keychain.load(KeychainClient.apiKeyAccount)
            },
            registerHandler: { handler in
                handlers.withValue { current in
                    current.removeAll { $0.id == handler.id }
                    current.append(handler)
                }
            }
        )
    }
}

extension AccountManager: DependencyKey {
    public static let liveValue = AccountManager.makeLive()
}

extension AccountManager: TestDependencyKey {
    /// Unimplemented by default so a test that reaches the manager without
    /// stubbing the methods it uses fails loudly.
    public static let testValue = AccountManager(
        logIn: unimplemented("AccountManager.logIn"),
        logOut: unimplemented("AccountManager.logOut"),
        signUp: unimplemented("AccountManager.signUp"),
        refreshAccount: unimplemented("AccountManager.refreshAccount"),
        restoredAPIKey: unimplemented("AccountManager.restoredAPIKey", placeholder: nil),
        registerHandler: unimplemented("AccountManager.registerHandler")
    )
}

extension DependencyValues {
    public var accountManager: AccountManager {
        get { self[AccountManager.self] }
        set { self[AccountManager.self] = newValue }
    }
}
