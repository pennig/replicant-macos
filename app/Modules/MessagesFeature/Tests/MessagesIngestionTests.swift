//
//  MessagesIngestionTests.swift
//  Replicould — MessagesFeature
//
//  The inbox's declared event routes: both the live-event path and the tier-2
//  gap repair speak only `invalidate(.inbox)` — nothing slow on the router's
//  dispatch path.
//

import API
import ComposableArchitecture
import Foundation
import GameServices
import Testing
@testable import MessagesFeature

@Suite struct MessagesIngestionTests {

    private func event(_ name: String) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0",
            category: String(name.split(separator: ".").first ?? ""),
            event: name,
            createdAt: "2026-07-21T09:00:00Z"
        )
    }

    /// A spy `DomainFreshnessClient` recording invalidated domains.
    private func spy(into invalidated: LockIsolated<[FreshnessDomain]>) -> DomainFreshnessClient {
        DomainFreshnessClient(
            register: { _, _ in },
            invalidate: { domain in invalidated.withValue { $0.append(domain) } },
            refreshIfStale: { _ in },
            reset: {}
        )
    }

    @Test func messageAndStoryEventsInvalidateTheInbox() async {
        let invalidated = LockIsolated<[FreshnessDomain]>([])
        await withDependencies {
            $0.domainFreshness = spy(into: invalidated)
        } operation: {
            let routes = MessagesIngestion.eventRoutes
            let message = routes.first { $0.id == "message" }
            let story = routes.first { $0.id == "messages.story" }
            await message?.apply(event("message.received"))
            await story?.apply(event("story.published"))
        }
        #expect(invalidated.value == [.inbox, .inbox])
    }

    @Test func gapRepairInvalidatesTheInboxUnconditionally() async {
        let invalidated = LockIsolated<[FreshnessDomain]>([])
        await withDependencies {
            $0.domainFreshness = spy(into: invalidated)
        } operation: {
            await MessagesIngestion.eventRoutes.first { $0.id == "message" }?.gapRepair()
        }
        #expect(invalidated.value == [.inbox])
    }
}
