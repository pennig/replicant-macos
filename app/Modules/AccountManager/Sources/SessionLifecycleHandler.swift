//
//  SessionLifecycleHandler.swift
//  Replicould — AccountManager
//
//  The unit of registration for cross-module session lifecycle work. Any module
//  (or the app composition root) can hand the `AccountManager` a handler so it
//  gets a chance to prepare on login and clean up on logout — e.g. clearing a
//  feature's locally-persisted table when the session ends.
//

import Foundation

/// A login/logout hook registered with the `AccountManager`.
///
/// Handlers are identified by `id` so re-registering (e.g. on relaunch) replaces
/// rather than duplicates. Both callbacks default to no-ops, so a handler can opt
/// into just one side of the lifecycle.
public struct SessionLifecycleHandler: Sendable, Identifiable {
    public let id: String
    /// Run after a successful login, once the account roster/profile is persisted.
    public var onLogin: @Sendable () async -> Void
    /// Run at the start of logout, before the session credentials are cleared.
    public var onLogout: @Sendable () async -> Void

    public init(
        id: String,
        onLogin: @Sendable @escaping () async -> Void = {},
        onLogout: @Sendable @escaping () async -> Void = {}
    ) {
        self.id = id
        self.onLogin = onLogin
        self.onLogout = onLogout
    }
}
