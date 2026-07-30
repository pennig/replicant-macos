//
//  AccountIngestion.swift
//  Replicould — AccountManager
//
//  The account's event-ingestion policy, declared beside the two things it
//  moves: the `@Shared(.account)` profile (the sidebar footer's XP total) and
//  the `Replicant` roster row (the active-replicant header's XP). The
//  composition root registers these values at launch — the domain registration
//  under `.account`, and the route with `GameSync`.
//

import API
import Dependencies
import Foundation
import GameModels
import GameServices
import OSLog
import Sharing
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "AccountManager")

public enum AccountIngestion {
    /// Defer the reconcile once the reads bucket drops to this many tokens. It
    /// sits above `PollCoordinator`'s floor of 12 deliberately: a device
    /// confirm-read moves the fleet, while this only corrects a number the
    /// optimistic credit has already shown the player.
    static let readsFloor = 20

    /// The `.account` domain's refresh policy: one `GET /accounts/me`, which is
    /// authoritative for both the profile's `experience_points_total` and every
    /// roster row's `experience_points`.
    ///
    /// The debounce is long because XP arrives in clusters — a survey run scans
    /// a dozen bodies and each one pays out — and a single read after the
    /// cluster observes exactly the state a dozen reads would.
    ///
    /// The refresh is droppable: under read-budget pressure it spends nothing
    /// and returns `false`, which leaves the domain marked stale rather than
    /// stamping it fresh. So a starved reconcile is deferred, not lost — the
    /// next nudge (or a `refreshIfStale` caller) tries again.
    public static let domainRegistration = DomainRegistration(
        debounce: .seconds(15),
        ttl: 60,
        refresh: {
            @Dependency(\.gameClient) var gameClient
            @Dependency(\.accountManager) var accountManager

            let budget = await gameClient.budget(.reads)
            guard budget.remaining > readsFloor else {
                logger.notice("account reconcile: deferred (reads budget \(budget.remaining) ≤ floor \(readsFloor))")
                return false
            }
            return await accountManager.refreshAccount()
        }
    )

    /// Experience is awarded for nearly everything — a scan, a print, an
    /// achievement, closing a location event — and until now moved only when
    /// something re-read `accounts/me`, which is to say at launch. So an
    /// all-day session showed a frozen XP total.
    ///
    /// The route credits the amount locally the instant it arrives, so the
    /// footer and the replicant header tick in step with the game, and then
    /// nudges the `.account` domain to reconcile that optimistic arithmetic
    /// against the server.
    ///
    /// **Live stream events only.** Catch-up is history being replayed on
    /// launch, from a window the launch `accounts/me` read has already folded
    /// in — crediting it again would double every gain in the gap. The same
    /// reasoning gates the roster's location writes in `LocationsIngestion`.
    /// This channel needs no `gapRepair` for the same reason: the launch
    /// refresh *is* its catch-up.
    public static let eventRoute: EventRoute =
        EventRoute(id: "account.experience", match: .event("experience.gained")) { event in
            guard event.provenance == .stream else { return }
            guard
                let amount = event.payload?["amount"]?.numberValue.map(Int.init),
                amount != 0
            else { return }

            @Dependency(\.defaultDatabase) var database
            @Dependency(\.domainFreshness) var domainFreshness
            @Shared(.account) var account

            $account.withLock { $0.experiencePointsTotal += amount }

            // The envelope names the replicant that earned it. Some awards
            // (achievements) are account-wide and carry no code — those move the
            // total only, which is what the server does with them too.
            if let code = event.replicantCode {
                try? await database.write { db in
                    try Replicant.where { $0.replicantCode.eq(code) }
                        .update { $0.experiencePoints += amount }
                        .execute(db)
                }
            }

            let source = event.payload?["source"]?.stringValue ?? "-"
            logger.debug("experience +\(amount) [\(source, privacy: .public)] → \(event.replicantCode ?? "account", privacy: .public)")

            domainFreshness.invalidate(.account)
        }
}
