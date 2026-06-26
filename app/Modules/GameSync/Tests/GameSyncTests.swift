//
//  GameSyncTests.swift
//  Replicould — GameSync
//
//  Routing is the core of the ingestion service, so it's tested directly: a
//  `RelayRouter` with canned routes must dispatch an event only to the route
//  whose `type` matches, and to every matching route. (Pipeline/relay I/O is
//  exercised end-to-end in the app, not here.)
//

import API
import ComposableArchitecture
import Foundation
import Testing
@testable import GameSync

@Suite struct RelayRouterTests {

    /// Build a `UnifiedEvent` of a given top-level type from a relay payload.
    private func event(type: String) throws -> UnifiedEvent {
        let raw = #"{"type":"\#(type)","title":"x","body":"y","timestamp":"2026-06-25T09:42:06-05:00"}"#
        return try UnifiedEvent(relayEvent: RelayEvent(id: "1-0", raw: Data(raw.utf8)))
    }

    @Test func dispatchRunsOnlyTheMatchingRoute() async throws {
        let routes = LockIsolated<[RelayRoute]>([])
        let router = RelayRouter(routes: routes)
        let messageRan = LockIsolated(false)
        let eventRan = LockIsolated(false)

        routes.withValue {
            $0.append(RelayRoute(id: "message", type: "message") { _ in messageRan.setValue(true) })
            $0.append(RelayRoute(id: "event", type: "event") { _ in eventRan.setValue(true) })
        }

        await router.dispatch(try event(type: "message"))

        #expect(messageRan.value == true)
        #expect(eventRan.value == false)
    }

    @Test func dispatchRunsEveryRouteForTheSameType() async throws {
        let routes = LockIsolated<[RelayRoute]>([])
        let router = RelayRouter(routes: routes)
        let count = LockIsolated(0)

        routes.withValue {
            $0.append(RelayRoute(id: "a", type: "message") { _ in count.withValue { $0 += 1 } })
            $0.append(RelayRoute(id: "b", type: "message") { _ in count.withValue { $0 += 1 } })
        }

        await router.dispatch(try event(type: "message"))

        #expect(count.value == 2)
    }
}
