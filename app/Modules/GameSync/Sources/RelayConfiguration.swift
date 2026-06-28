//
//  RelayConfiguration.swift
//  Replicould — GameSync
//
//  Connection settings for the account-wide relay (the Rust/Redis SSE service
//  that fans the game's webhooks out to this app). `GameSync` builds its
//  `RelayClient` from these.
//

import Foundation

public struct RelayConfiguration: Sendable {
    /// The relay host. `RelayClient` appends `api/stream` itself, so this is the
    /// scheme + host only (no path).
    public var baseURL: URL
    /// Bearer token presented to the relay; must match its `RELAY_CLIENT_TOKEN`.
    public var clientToken: String

    public init(baseURL: URL, clientToken: String) {
        self.baseURL = baseURL
        self.clientToken = clientToken
    }

    /// The live relay this single-tenant app talks to.
    public static let live = RelayConfiguration(
        baseURL: URL(string: "https://replicant.pennig.name")!,
        clientToken: placeholderClientToken
    )

    /// TECH DEBT (IMPLEMENTATION_PLAN §9): the relay bearer token is a static
    /// secret. This placeholder must be replaced with the real
    /// `RELAY_CLIENT_TOKEN` value before the relay will connect — and moved out
    /// of source (Keychain / remote config) before any distribution, since a
    /// committed token ships in the binary.
    public static let placeholderClientToken = "a3019598bb3ba520dbe752896d189baa0d486a19540adafb4080641a5a6952ee"
}
