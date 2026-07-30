//
//  AccountIngestionTests.swift
//  Replicould — AccountManager
//
//  The account's declared ingestion: an `experience.gained` event credits the
//  profile total and the earning replicant's roster row on the spot, but only
//  when it arrives live — a catch-up replay would double a gain the launch
//  `accounts/me` read has already counted. Plus the `.account` domain's
//  budget-aware, droppable reconcile.
//

import API
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import GameSession
import SQLiteData
import Sharing
import Testing
import Utils
@testable import AccountManager

@MainActor
@Suite struct AccountIngestionTests {

    // MARK: Fixtures

    private func experienceEvent(
        amount: Double?,
        replicantCode: String? = "RX-01",
        provenance: GameEventEnvelope.Provenance = .stream
    ) -> GameEventEnvelope {
        var payload: [String: JSONValue] = ["source": .string("scan")]
        if let amount { payload["amount"] = .number(amount) }
        var event = GameEventEnvelope(
            id: "1-0",
            category: "experience",
            event: "experience.gained",
            replicantCode: replicantCode,
            payload: payload,
            createdAt: "2026-07-30T09:00:00Z"
        )
        event.provenance = provenance
        return event
    }

    private func seedRoster(_ database: any DatabaseWriter) async throws {
        try await database.write { db in
            try Replicant.upsert {
                Replicant(
                    replicantCode: "RX-01",
                    name: "Nexus",
                    createdAt: Date(timeIntervalSince1970: 0),
                    experiencePoints: 100
                )
            }
            .execute(db)
            try Replicant.upsert {
                Replicant(
                    replicantCode: "RX-02",
                    name: "Pris",
                    createdAt: Date(timeIntervalSince1970: 0),
                    experiencePoints: 40
                )
            }
            .execute(db)
        }
    }

    private func freshnessSpy(into invalidated: LockIsolated<[FreshnessDomain]>) -> DomainFreshnessClient {
        DomainFreshnessClient(
            register: { _, _ in },
            invalidate: { domain in invalidated.withValue { $0.append(domain) } },
            refreshIfStale: { _ in },
            reset: {}
        )
    }

    private func experience(of code: String, in database: any DatabaseWriter) async throws -> Int? {
        try await database.read { db in
            try Replicant.where { $0.replicantCode.eq(code) }.fetchOne(db)?.experiencePoints
        }
    }

    // MARK: The route

    /// A live award credits the account total AND the replicant that earned it,
    /// leaves every other roster row alone, and nudges the reconcile.
    @Test func liveAwardCreditsAccountAndEarningReplicant() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedRoster(database)
        let invalidated = LockIsolated<[FreshnessDomain]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.defaultFileStorage = .inMemory
            $0.domainFreshness = freshnessSpy(into: invalidated)
        } operation: {
            @Shared(.account) var account
            $account.withLock { $0.experiencePointsTotal = 5_000 }
            await AccountIngestion.eventRoute.apply(experienceEvent(amount: 250))
            #expect(account.experiencePointsTotal == 5_250)
        }

        #expect(try await experience(of: "RX-01", in: database) == 350)
        #expect(try await experience(of: "RX-02", in: database) == 40)
        #expect(invalidated.value == [.account])
    }

    /// Catch-up is history replayed at launch, from a window the launch
    /// `accounts/me` read already covered. Crediting it would double the gain.
    @Test func catchUpReplayCreditsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedRoster(database)
        let invalidated = LockIsolated<[FreshnessDomain]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.defaultFileStorage = .inMemory
            $0.domainFreshness = freshnessSpy(into: invalidated)
        } operation: {
            @Shared(.account) var account
            $account.withLock { $0.experiencePointsTotal = 5_000 }
            await AccountIngestion.eventRoute.apply(
                experienceEvent(amount: 250, provenance: .catchUp)
            )
            #expect(account.experiencePointsTotal == 5_000)
        }

        #expect(try await experience(of: "RX-01", in: database) == 100)
        #expect(invalidated.value.isEmpty)
    }

    /// An account-wide award (an achievement) carries no replicant code. The
    /// total still moves; no roster row is invented or touched.
    @Test func awardWithoutReplicantCodeMovesOnlyTheTotal() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedRoster(database)
        let invalidated = LockIsolated<[FreshnessDomain]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.defaultFileStorage = .inMemory
            $0.domainFreshness = freshnessSpy(into: invalidated)
        } operation: {
            @Shared(.account) var account
            $account.withLock { $0.experiencePointsTotal = 5_000 }
            await AccountIngestion.eventRoute.apply(
                experienceEvent(amount: 1_500, replicantCode: nil)
            )
            #expect(account.experiencePointsTotal == 6_500)
        }

        #expect(try await experience(of: "RX-01", in: database) == 100)
        #expect(invalidated.value == [.account])
    }

    /// A malformed or zero award spends nothing — no write, no reconcile.
    @Test func missingAmountIsIgnored() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedRoster(database)
        let invalidated = LockIsolated<[FreshnessDomain]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.defaultFileStorage = .inMemory
            $0.domainFreshness = freshnessSpy(into: invalidated)
        } operation: {
            @Shared(.account) var account
            $account.withLock { $0.experiencePointsTotal = 5_000 }
            await AccountIngestion.eventRoute.apply(experienceEvent(amount: nil))
            await AccountIngestion.eventRoute.apply(experienceEvent(amount: 0))
            #expect(account.experiencePointsTotal == 5_000)
        }

        #expect(try await experience(of: "RX-01", in: database) == 100)
        #expect(invalidated.value.isEmpty)
    }

    /// The route matches its one event name, so the Event Log counts it handled.
    @Test func routeMatchesOnlyExperienceGained() {
        let match = AccountIngestion.eventRoute.match
        #expect(!match.isCatchAll)
        #expect(match.matches(experienceEvent(amount: 10)))
        #expect(!match.matches(
            GameEventEnvelope(id: "2-0", category: "experience", event: "experience.lost")
        ))
    }

    // MARK: The reconcile

    /// With budget to spare, the reconcile reads and reports what the read did.
    @Test func reconcileReadsWhenBudgetAllows() async {
        for outcome in [true, false] {
            let refreshed = LockIsolated(false)
            let result = await withDependencies {
                $0.gameClient.budget = { _ in .init(limit: 120, remaining: 100, resetAt: nil) }
                $0.accountManager.refreshAccount = {
                    refreshed.setValue(true)
                    return outcome
                }
            } operation: {
                await AccountIngestion.domainRegistration.refresh()
            }
            #expect(refreshed.value)
            #expect(result == outcome)
        }
    }

    /// At the floor it spends nothing and reports failure, which leaves the
    /// domain stale — so the reconcile is deferred to the next nudge, not lost.
    @Test func reconcileDefersUnderBudgetPressure() async {
        let refreshed = LockIsolated(false)
        let result = await withDependencies {
            $0.gameClient.budget = { _ in
                .init(limit: 120, remaining: AccountIngestion.readsFloor, resetAt: nil)
            }
            $0.accountManager.refreshAccount = {
                refreshed.setValue(true)
                return true
            }
        } operation: {
            await AccountIngestion.domainRegistration.refresh()
        }
        #expect(!refreshed.value)
        #expect(result == false)
    }
}
