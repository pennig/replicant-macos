//
//  Account.swift
//  Replicould — shared dependency clients
//
//  The signed-in account profile, mirroring the scalar fields of
//  `GET /v1/accounts/me` (`app_schemas_accounts_AccountMeResponseSchema`). It is
//  persisted to disk as a `@Shared(.account)` value so a returning user — whose
//  session is restored synchronously from the Keychain without re-fetching — sees
//  real account data on the very first frame.
//
//  The account's replicants are *not* stored here; they live in their own SQLite
//  table (`Replicant`). The "active replicant" selection is likewise kept out of
//  this endpoint-mirroring object — it's a local-only choice persisted under
//  `@Shared(.appStorage(Account.activeReplicantCodeKey))`.
//

import API
import ComposableArchitecture
import Foundation

/// The account profile surfaced in the sidebar header/footer and Account sheet.
public struct Account: Codable, Equatable, Sendable {
    public var email: String
    public var name: String
    public var timezone: String
    public var emailVerified: Bool
    public var status: String
    public var createdAt: String
    public var unreadMessageCount: Int
    public var bobnetChannels: [String]
    public var replicantCooperation: String
    public var experiencePointsTotal: Int

    public init(
        email: String = "",
        name: String = "",
        timezone: String = "",
        emailVerified: Bool = false,
        status: String = "",
        createdAt: String = "",
        unreadMessageCount: Int = 0,
        bobnetChannels: [String] = [],
        replicantCooperation: String = "",
        experiencePointsTotal: Int = 0
    ) {
        self.email = email
        self.name = name
        self.timezone = timezone
        self.emailVerified = emailVerified
        self.status = status
        self.createdAt = createdAt
        self.unreadMessageCount = unreadMessageCount
        self.bobnetChannels = bobnetChannels
        self.replicantCooperation = replicantCooperation
        self.experiencePointsTotal = experiencePointsTotal
    }

    /// The `@Shared(.appStorage)` key under which the active replicant's code is
    /// stored. Kept here so the single source of truth for the key string lives
    /// alongside the account it relates to, even though the value itself is a
    /// separate local-only selection rather than part of this object.
    public static let activeReplicantCodeKey = "activeReplicantCode"
}

// MARK: - Mapping

extension Account {
    /// Map the generated `/accounts/me` response onto the local profile,
    /// coalescing the optional generated fields. The `replicants` array is
    /// intentionally ignored here — it is persisted into the `Replicant` table.
    public init(schema: Components.Schemas.AppSchemasAccountsAccountMeResponseSchema) {
        self.init(
            email: schema.email ?? "",
            name: schema.name ?? "",
            timezone: schema.timezone ?? "",
            emailVerified: schema.emailVerified ?? false,
            status: schema.status ?? "",
            createdAt: schema.createdAt ?? "",
            unreadMessageCount: schema.unreadMessageCount ?? 0,
            bobnetChannels: schema.bobnetChannels ?? [],
            replicantCooperation: schema.replicantCooperation ?? "",
            experiencePointsTotal: schema.experiencePointsTotal ?? 0
        )
    }
}

// MARK: - Shared persistence

extension SharedKey where Self == FileStorageKey<Account>.Default {
    /// The signed-in account profile, persisted to Application Support so it is
    /// available immediately on relaunch.
    public static var account: Self {
        Self[
            .fileStorage(.applicationSupportDirectory.appending(component: "account.json")),
            default: Account()
        ]
    }
}
