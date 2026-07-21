//
//  MessagesIngestion.swift
//  Replicould — MessagesFeature
//
//  The inbox's event-ingestion policy, declared beside the table and client it
//  drives. The composition root registers these values at launch (it owns the
//  wiring, not the policy): the domain registration under `.inbox`, and the
//  routes with `GameSync`.
//

import ComposableArchitecture
import Foundation
import GameModels
import GameServices
import SQLiteData

public enum MessagesIngestion {
    /// The `.inbox` domain's refresh policy. A message/story event is a thin
    /// notification (no id or read-state — its content lives at the envelope's
    /// top level), so the refresh is one authoritative head-page inbox read.
    /// The rows land in the same `Message` table the Messages feature observes
    /// via @FetchAll, making the inbox live with no change to that feature.
    public static let domainRegistration = DomainRegistration(refresh: {
        @Dependency(\.messagesClient) var messagesClient
        @Dependency(\.defaultDatabase) var database
        guard let page = try? await messagesClient.fetch(nil, 50, false) else { return false }
        let wrote = try? await database.write { db in
            for message in page.messages {
                try Message.upsert { message }.execute(db)
            }
        }
        return wrote != nil
    })

    /// The inbox's event routes. Both are invalidate-only — nothing slow runs
    /// on the event router's dispatch path; the domain's trailing debounce
    /// collapses a burst (an overnight catch-up can replay a dozen message
    /// events) into one head-page read after it quiets.
    ///
    /// `message`: the inbox's own family. The same authoritative inbox read is
    /// this channel's **tier-2 gap repair** (§4.5): on a cold start or a
    /// reconnect beyond the stream's cursor retention, `gapRepair` recovers
    /// messages that arrived while disconnected — the REST inbox is
    /// authoritative, so a head-page re-read is the catch-up. It invalidates
    /// rather than reading directly: `invalidate` always arms (so the repair
    /// runs even when no message event replays), the debounce absorbs any
    /// replayed message events into the same single read, and the engine's
    /// freshness stamp then lets the inbox pane's appear-path skip its own
    /// re-read.
    ///
    /// `messages.story`: narrative beats (Bill/Riker updates, first-contact
    /// reports) are pushed over the stream for immediacy, but the backend also
    /// persists them to the inbox as ordinary messages (`message_type:
    /// "story"`). The stream copy carries no id/read-state, so — exactly like
    /// the `message` route — a story event nudges the same debounced inbox
    /// re-read. No `gapRepair` needed: the `message` route's head-page re-read
    /// already recovers stories missed while disconnected.
    public static let eventRoutes: [EventRoute] =
        [
            EventRoute(
                id: "message",
                match: .category("message"),
                apply: { _ in
                    @Dependency(\.domainFreshness) var domainFreshness
                    domainFreshness.invalidate(.inbox)
                },
                gapRepair: {
                    @Dependency(\.domainFreshness) var domainFreshness
                    domainFreshness.invalidate(.inbox)
                }
            ),
            EventRoute(id: "messages.story", match: .category("story")) { _ in
                @Dependency(\.domainFreshness) var domainFreshness
                domainFreshness.invalidate(.inbox)
            },
        ]
}
