//
//  GameClient.swift
//  Replicant
//
//  A shared dependency that vends the generated Replicant Space API client,
//  already authenticated with the stored session token. Domain clients
//  (`MessagesClient`, `StarsClient`, …) resolve `@Dependency(\.gameClient)` and
//  call generated operations on the returned `Client` — so the session token is
//  sourced in exactly one place (the Keychain) instead of being threaded through
//  feature state and every call site.
//

import API
import ComposableArchitecture
import Foundation

public struct GameClient: Sendable {
    /// Build a fully-wired generated client: bearer auth from the current
    /// session token, plus the shared rate-limit governor and request logging.
    /// The token is read fresh each call, so the client tracks login/logout
    /// without any reconfiguration.
    public var make: @Sendable () -> Client

    public init(make: @escaping @Sendable () -> Client) {
        self.make = make
    }

    /// Convenience: build a client now.
    public func callAsFunction() -> Client { make() }
}

extension GameClient: DependencyKey {
    public static let liveValue: GameClient = {
        // One governor per process: rate limits are token-scoped, so every
        // client built here shares the same throttle budget.
        let governor = RateLimitGovernor()
        return GameClient(make: {
            @Dependency(\.keychain) var keychain
            let token = keychain.load(KeychainClient.apiKeyAccount) ?? ""
            return ReplicantSpace.client(apiKey: token, governor: governor)
        })
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
