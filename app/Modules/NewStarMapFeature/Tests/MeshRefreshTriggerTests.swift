//
//  MeshRefreshTriggerTests.swift
//  Replicould — NewStarMapFeature
//
//  What the Stars view asks of the mesh domain. A roster change names the
//  relays that moved, so the refresh can fold one in rather than reading
//  every relay's network view.
//

import ComposableArchitecture
import GameModels
import GameServices
import Testing
@testable import NewStarMapFeature

@MainActor
@Suite struct MeshRefreshTriggerTests {

    private struct Spy {
        let noted = LockIsolated<[String?]>([])
        let invalidated = LockIsolated<[FreshnessDomain]>([])
        let staleChecks = LockIsolated<[FreshnessDomain]>([])
    }

    private func store(_ spy: Spy) -> TestStoreOf<NewStarMapFeature> {
        TestStore(initialState: NewStarMapFeature.State()) {
            NewStarMapFeature()
        } withDependencies: {
            $0.ftlMeshRefresher = FTLMeshRefresher(
                refresh: {},
                noteRelayChanged: { code in spy.noted.withValue { $0.append(code) } })
            $0.domainFreshness = DomainFreshnessClient(
                register: { _, _ in },
                invalidate: { domain in spy.invalidated.withValue { $0.append(domain) } },
                refreshIfStale: { domain in spy.staleChecks.withValue { $0.append(domain) } },
                reset: {})
        }
    }

    /// The whole point: one relay moved, so the refresh is told WHICH one and
    /// can read that relay alone.
    @Test func aSingleChangedRelayIsNotedByCode() async {
        let spy = Spy()
        let store = store(spy)

        await store.send(.refreshMesh(changedRelays: ["AAA"]))
        await store.finish()

        #expect(spy.noted.value == ["AAA"])
        #expect(spy.invalidated.value == [.ftlMesh])
    }

    /// Never `nil`: an unattributed note forces the full sweep by construction,
    /// which is what having the diff exists to avoid.
    @Test func aChangedRelayIsNeverNotedUnattributed() async {
        let spy = Spy()
        let store = store(spy)

        await store.send(.refreshMesh(changedRelays: ["AAA"]))
        await store.finish()

        #expect(!spy.noted.value.contains(nil))
    }

    @Test func everyChangedRelayIsNoted() async {
        let spy = Spy()
        let store = store(spy)

        await store.send(.refreshMesh(changedRelays: ["AAA", "BBB"]))
        await store.finish()

        #expect(Set(spy.noted.value.compactMap { $0 }) == ["AAA", "BBB"])
    }

    /// A pane appear names no relay, so it takes the freshness-gated path and
    /// notes nothing at all.
    @Test func anAppearWithNoRosterChangeOnlyChecksFreshness() async {
        let spy = Spy()
        let store = store(spy)

        await store.send(.refreshMesh(changedRelays: []))
        await store.finish()

        #expect(spy.noted.value.isEmpty)
        #expect(spy.invalidated.value.isEmpty)
        #expect(spy.staleChecks.value == [.ftlMesh])
    }
}
