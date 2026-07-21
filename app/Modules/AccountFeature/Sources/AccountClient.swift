//
//  AccountClient.swift
//  Replicould — Account feature
//
//  The dependency that talks to the account endpoints the Account screen needs
//  beyond the shared `@Shared(.account)` profile: the achievements pair and the
//  account-update PATCH. Like the other feature clients it resolves the shared
//  generated `gameClient()` (bearer auth + rate limiting + logging from its
//  middleware stack) and maps generated payloads to value types. Exposed via
//  `@Dependency(\.accountClient)`.
//
//  Refreshing the persisted `@Shared(.account)` after a successful update is NOT
//  done here — that stays the sole responsibility of `AccountManager`
//  (`refreshAccount()`), so the account profile keeps a single writer.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import GameSession

public struct AccountClient: Sendable {
    /// Fetch every achievement (the global catalog) annotated with the signed-in
    /// account's earned set — one merged, locked-or-earned list for the tab.
    public var fetchAchievements: @Sendable () async throws -> [Achievement]
    /// Apply an account update (`PATCH /v1/accounts/me`). Fields left nil are
    /// unchanged server-side. Throws `UpdateError` when the server rejects it.
    public var update: @Sendable (_ update: AccountUpdate) async throws -> Void

    /// A failed account update, carrying a user-facing message.
    public struct UpdateError: Error, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }
}

/// The editable subset of the account this pass supports. A nil field is omitted
/// from the PATCH, so the server leaves it unchanged. (Email and the notification
/// matrix are intentionally excluded — see the feature plan.)
public struct AccountUpdate: Equatable, Sendable {
    public var name: String?
    public var timezone: String?
    public var replicantCooperation: String?
    public var bobnetChannels: [String]?
    /// Event-stream preferences (AMI digest interval + mute patterns). When set,
    /// the mutes take effect server-side on the event stream.
    public var events: Account.EventSettings?
    /// Message-delivery preferences (email opt-in + subscribed categories).
    public var messages: Account.MessageSettings?

    public init(
        name: String? = nil,
        timezone: String? = nil,
        replicantCooperation: String? = nil,
        bobnetChannels: [String]? = nil,
        events: Account.EventSettings? = nil,
        messages: Account.MessageSettings? = nil
    ) {
        self.name = name
        self.timezone = timezone
        self.replicantCooperation = replicantCooperation
        self.bobnetChannels = bobnetChannels
        self.events = events
        self.messages = messages
    }
}

// MARK: - Live implementation

extension AccountClient: DependencyKey {
    public static let liveValue = AccountClient(
        fetchAchievements: {
            @Dependency(\.gameClient) var gameClient
            // Resolve the client once and fire both reads concurrently — they're
            // independent, and merging needs both.
            let client = gameClient()
            async let earnedJSON = client.getV1AccountsAchievements().ok.body.json
            async let catalogJSON = client.getV1Achievements().ok.body.json
            let earned = try await (earnedJSON.achievements ?? []).map(Achievement.init(earned:))
            let catalog = try await (catalogJSON.achievements ?? []).map(Achievement.init(catalog:))
            return Achievement.merged(earned: earned, catalog: catalog)
        },
        update: { update in
            @Dependency(\.gameClient) var gameClient
            let output = try await gameClient().patchV1AccountsMe(
                body: .json(.init(
                    name: update.name,
                    timezone: update.timezone,
                    bobnetChannels: update.bobnetChannels,
                    replicantCooperation: update.replicantCooperation,
                    events: update.events.map { .init(value1: .init(
                        amiDigestInterval: $0.amiDigestInterval,
                        muted: $0.muted
                    )) },
                    messages: update.messages.map { .init(value1: .init(
                        email: $0.email,
                        subscribed: $0.subscribed.compactMap {
                            Components.Schemas.AppSchemasAccountsMessageSettingsSchema.SubscribedPayloadPayload(rawValue: $0)
                        }
                    )) }
                ))
            )
            switch output {
            case .ok:
                break
            case let .badRequest(response):
                throw UpdateError((try? response.body.json.error) ?? "Couldn't update your account.")
            case let .unprocessableContent(response):
                throw UpdateError((try? response.body.json.message) ?? "Some of those values weren't accepted.")
            case .default:
                throw UpdateError("Couldn't update your account.")
            }
        }
    )
}

// MARK: - Test / preview implementation

extension AccountClient: TestDependencyKey {
    /// Unimplemented by default so a test that reaches the network without
    /// stubbing it fails loudly.
    public static let testValue = AccountClient(
        fetchAchievements: unimplemented("AccountClient.fetchAchievements", placeholder: []),
        update: unimplemented("AccountClient.update")
    )

    /// Previews get the sample list + a no-op update so the UI renders.
    public static let previewValue = AccountClient(
        fetchAchievements: { Achievement.previewCatalog },
        update: { _ in }
    )
}

extension DependencyValues {
    public var accountClient: AccountClient {
        get { self[AccountClient.self] }
        set { self[AccountClient.self] = newValue }
    }
}
