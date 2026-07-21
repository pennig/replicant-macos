//
//  LocationEventsIngestionTests.swift
//  Replicould — LocationEventsFeature
//
//  The quest log's declared event route: the `event.*` family and a completed
//  scan nudge one debounced authoritative re-read; unrelated events don't.
//

import API
import ComposableArchitecture
import Foundation
import GameServices
import Testing
@testable import LocationEventsFeature

@Suite struct LocationEventsIngestionTests {

    private func event(_ name: String) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0",
            category: String(name.split(separator: ".").first ?? ""),
            event: name,
            createdAt: "2026-07-21T09:00:00Z"
        )
    }

    private func spy(into invalidated: LockIsolated<[FreshnessDomain]>) -> DomainFreshnessClient {
        DomainFreshnessClient(
            register: { _, _ in },
            invalidate: { domain in invalidated.withValue { $0.append(domain) } },
            refreshIfStale: { _ in },
            reset: {}
        )
    }

    @Test func questFamilyAndScanCompletionInvalidate() async {
        let invalidated = LockIsolated<[FreshnessDomain]>([])
        await withDependencies {
            $0.domainFreshness = spy(into: invalidated)
        } operation: {
            let route = LocationEventsIngestion.eventRoute
            await route.apply(event("event.discovered"))
            await route.apply(event("scan.completed"))
            await route.apply(event("mining.started"))   // unrelated — no nudge
        }
        #expect(invalidated.value == [.locationEvents, .locationEvents])
    }

    @Test func gapRepairInvalidatesUnconditionally() async {
        let invalidated = LockIsolated<[FreshnessDomain]>([])
        await withDependencies {
            $0.domainFreshness = spy(into: invalidated)
        } operation: {
            await LocationEventsIngestion.eventRoute.gapRepair()
        }
        #expect(invalidated.value == [.locationEvents])
    }
}
