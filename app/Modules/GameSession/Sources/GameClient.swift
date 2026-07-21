//
//  GameClient.swift
//  Replicould — GameSession (session, auth + authenticated transport)
//
//  A shared dependency that vends the generated Replicant Space API client,
//  already authenticated with the stored session token. Domain clients
//  (`MessagesClient`, `StarsClient`, …) resolve `@Dependency(\.gameClient)` and
//  call generated operations on the returned `Client` — so the session token is
//  sourced in exactly one place (the Keychain) instead of being threaded through
//  feature state and every call site.
//
//  Lives in `GameSession` (not `GameServices`) so read-only features that need
//  nothing but an authenticated client don't ride every sync-engine rebuild.
//

import API
import Dependencies
import Foundation

public struct GameClient: Sendable {
    /// Build a fully-wired generated client: bearer auth from the current
    /// session token, plus the shared rate-limit governor, request logging, and
    /// decode-error diagnostics. The token is read fresh each call, so the client
    /// tracks login/logout without any reconfiguration. Vends `any APIProtocol`
    /// (a `DiagnosticAPIClient` wrapping the generated `Client`) — call sites use
    /// operations exactly as before.
    public var make: @Sendable () -> any APIProtocol

    /// A read-only view of the process-shared rate-limit budget for a bucket,
    /// for surfacing remaining reads/actions in the UI (e.g. a debug HUD). The
    /// budget tracks the same governor every `make()`-built client throttles on.
    public var budget: @Sendable (RateLimitGovernor.Bucket) async -> RateLimitGovernor.Snapshot

    public init(
        make: @escaping @Sendable () -> any APIProtocol,
        budget: @escaping @Sendable (RateLimitGovernor.Bucket) async -> RateLimitGovernor.Snapshot = { _ in
            RateLimitGovernor.Snapshot(limit: 0, remaining: 0, resetAt: nil)
        }
    ) {
        self.make = make
        self.budget = budget
    }

    /// Convenience: build a client now.
    public func callAsFunction() -> any APIProtocol { make() }
}

extension GameClient: DependencyKey {
    public static let liveValue: GameClient = {
        // One governor per process: rate limits are token-scoped, so every
        // client built here shares the same throttle budget.
        let governor = RateLimitGovernor()
        return GameClient(
            make: {
                @Dependency(\.keychain) var keychain
                let token = keychain.load(KeychainClient.apiKeyAccount) ?? ""
                return ReplicantSpace.client(apiKey: token, governor: governor)
            },
            budget: { bucket in await governor.snapshot(bucket) }
        )
    }()
}

extension GameClient: TestDependencyKey {
    /// Tests and previews exercise domain clients through their own stubbed
    /// `liveValue`/`testValue`s, so this is only a placeholder client that is
    /// never expected to perform a request.
    public static let testValue = GameClient(make: {
        ReplicantSpace.client(apiKey: "")
    })
}

extension DependencyValues {
    public var gameClient: GameClient {
        get { self[GameClient.self] }
        set { self[GameClient.self] = newValue }
    }
}
