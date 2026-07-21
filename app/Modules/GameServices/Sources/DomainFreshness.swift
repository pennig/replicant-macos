//
//  DomainFreshness.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Per-domain freshness for the non-device tables the event stream keeps warm
//  (ARCHITECTURE_REVIEW V3.5). An event route never runs a domain refresh on the
//  router's critical path — a slow inbox read or an O(relays) mesh rebuild would
//  head-of-line-block all event ingestion behind it (V3.4-B2/B3). Instead a
//  route calls `invalidate(domain)`, which returns immediately: it marks the
//  domain stale and (re)arms a trailing debounce, so a burst of qualifying
//  events — a catch-up replay, several messages landing together — costs one
//  refresh after the burst quiets instead of one per event.
//
//  The same bookkeeping gives on-demand semantics: `refreshIfStale(domain)` is
//  for appear-paths that today refetch unconditionally (V3.4-B6) — it runs the
//  refresh only when the domain is marked stale or its last refresh is older
//  than the registered TTL, so an SSE-kept-warm table costs nothing to revisit.
//
//  The composition root registers each domain's refresh closure once at launch
//  (it owns that wiring, like `EventRoute` registration); routes and features
//  then speak only in domain names. Exposed via `@Dependency(\.domainFreshness)`
//  over one process-shared instance.
//

import Dependencies
import Foundation
import OSLog

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DomainFreshness")

/// The refreshable non-device domains. A new SSE-warmed table is a new case
/// here plus one `register` call in the composition root.
public enum FreshnessDomain: String, CaseIterable, Sendable {
    case inbox            // Message table — head-page authoritative re-read
    case locationEvents   // LocationEvent table — full accounts/events walk
    case ftlMesh          // FTLLinkRecord table — O(relays) network reads
}

/// How a registered domain refreshes: the debounce window an `invalidate`
/// burst collapses into, the TTL an on-demand `refreshIfStale` honors, and the
/// authoritative refresh itself.
public struct DomainRegistration: Sendable {
    public var debounce: Duration
    public var ttl: TimeInterval
    /// The authoritative re-read. Returns whether it actually refreshed —
    /// a failed read (offline, auth teardown) must return `false` so the
    /// domain keeps reading as stale instead of being stamped fresh for a
    /// full TTL on the strength of a swallowed error.
    public var refresh: @Sendable () async -> Bool

    public init(
        debounce: Duration = .seconds(2),
        ttl: TimeInterval = 30,
        refresh: @escaping @Sendable () async -> Bool
    ) {
        self.debounce = debounce
        self.ttl = ttl
        self.refresh = refresh
    }
}

public struct DomainFreshnessClient: Sendable {
    /// Register (or replace) a domain's refresh policy. Synchronous, so
    /// registrations made at app launch are in place before any event arrives.
    public var register: @Sendable (FreshnessDomain, DomainRegistration) -> Void

    /// Mark a domain stale and (re)arm its trailing debounce. Returns
    /// immediately — never runs the refresh inline — so it's safe on the event
    /// router's dispatch path.
    public var invalidate: @Sendable (FreshnessDomain) -> Void

    /// Refresh now iff the domain is marked stale, has never refreshed, or its
    /// last refresh is older than the registered TTL; otherwise a no-op. Joins
    /// a refresh already running rather than doubling it.
    public var refreshIfStale: @Sendable (FreshnessDomain) async -> Void

    /// Cancel every pending debounce and running refresh and clear all stamps
    /// (logout teardown — a refresh armed just before logout must not fire
    /// into freshly-wiped tables, and a stale `lastRefreshedAt` must not let
    /// the next session skip its first re-read).
    public var reset: @Sendable () -> Void

    public init(
        register: @escaping @Sendable (FreshnessDomain, DomainRegistration) -> Void,
        invalidate: @escaping @Sendable (FreshnessDomain) -> Void,
        refreshIfStale: @escaping @Sendable (FreshnessDomain) async -> Void,
        reset: @escaping @Sendable () -> Void
    ) {
        self.register = register
        self.invalidate = invalidate
        self.refreshIfStale = refreshIfStale
        self.reset = reset
    }
}

// MARK: - Live implementation

/// The engine behind the client. `LockIsolated` state + synchronous arming
/// (mirroring the route-debounce pattern it replaces) rather than an actor, so
/// `register`/`invalidate` need no suspension and registration order is
/// deterministic at launch.
final class DomainFreshnessEngine: Sendable {
    private struct DomainState {
        var registration: DomainRegistration
        /// The armed trailing-debounce task, if any.
        var pending: Task<Void, Never>?
        /// A refresh actually executing, joinable by `refreshIfStale` and a
        /// concurrently-due debounce.
        var running: Task<Void, Never>?
        /// Set by `invalidate`, cleared when a refresh *starts* (so an
        /// invalidate arriving mid-refresh marks the domain stale again and
        /// earns its own follow-up pass).
        var staleSince: Date?
        var lastRefreshedAt: Date?
    }

    private struct EngineState {
        /// Bumped by `reset()`; a refresh finishing after a reset compares its
        /// entry generation and skips the completion stamps, so a torn-down
        /// session can't leave a fresh-looking `lastRefreshedAt` behind.
        var generation = 0
        var domains: [FreshnessDomain: DomainState] = [:]
    }

    private let state = LockIsolated(EngineState())

    func register(_ domain: FreshnessDomain, _ registration: DomainRegistration) {
        state.withValue { current in
            current.domains[domain, default: DomainState(registration: registration)]
                .registration = registration
        }
    }

    func invalidate(_ domain: FreshnessDomain) {
        @Dependency(\.date) var date
        state.withValue { current in
            guard var domainState = current.domains[domain] else {
                logger.error("invalidate \(domain.rawValue, privacy: .public): no registration — dropped")
                return
            }
            if domainState.staleSince == nil {
                domainState.staleSince = date.now
            }
            domainState.pending?.cancel()
            let debounce = domainState.registration.debounce
            // Capture the generation at arm time: a debounce that survives into
            // the next session (its cancellation raced `reset()`) must not run
            // a refresh — or leave stamps — on the new session's behalf.
            let generation = current.generation
            domainState.pending = Task { [weak self] in
                @Dependency(\.continuousClock) var clock
                try? await clock.sleep(for: debounce)
                guard !Task.isCancelled else { return }
                await self?.runRefresh(domain, ifGeneration: generation)
            }
            current.domains[domain] = domainState
            logger.debug("invalidate \(domain.rawValue, privacy: .public): debounce (re)armed")
        }
    }

    func refreshIfStale(_ domain: FreshnessDomain) async {
        @Dependency(\.date) var date
        let now = date.now
        enum Verdict { case unregistered, fresh, stale }
        let verdict = state.withValue { current -> Verdict in
            guard let domainState = current.domains[domain] else { return .unregistered }
            if domainState.running != nil { return .stale }   // join it in runRefresh
            if domainState.staleSince != nil { return .stale }
            guard let last = domainState.lastRefreshedAt else { return .stale }
            return now.timeIntervalSince(last) >= domainState.registration.ttl ? .stale : .fresh
        }
        switch verdict {
        case .unregistered:
            logger.error("refreshIfStale \(domain.rawValue, privacy: .public): no registration — dropped")
        case .fresh:
            logger.debug("refreshIfStale \(domain.rawValue, privacy: .public): fresh — skipped")
        case .stale:
            await runRefresh(domain)
        }
    }

    func reset() {
        state.withValue { current in
            current.generation += 1
            for domain in current.domains.keys {
                current.domains[domain]?.pending?.cancel()
                current.domains[domain]?.pending = nil
                current.domains[domain]?.running?.cancel()
                current.domains[domain]?.running = nil
                current.domains[domain]?.staleSince = nil
                current.domains[domain]?.lastRefreshedAt = nil
            }
        }
    }

    /// Run a domain's refresh exactly once for all the callers that raced into
    /// it: the first installs the `running` task; everyone (including a due
    /// debounce firing mid-refresh) awaits the same task.
    ///
    /// - Parameter generation: when set (the debounce path), the refresh is
    ///   skipped unless the engine is still in that generation — a debounce
    ///   whose cancellation raced a `reset()` must not fire into the next
    ///   session.
    private func runRefresh(_ domain: FreshnessDomain, ifGeneration generation: Int? = nil) async {
        let running: Task<Void, Never>? = state.withValue { current in
            if let generation, generation != current.generation { return nil }
            guard var domainState = current.domains[domain] else { return nil }
            if let running = domainState.running { return running }
            // This refresh reads the same live state a pending debounced pass
            // would — cancel it rather than paying twice. (When the debounce
            // task itself lands here, cancelling it is a harmless self-cancel:
            // it does nothing after this call.)
            domainState.pending?.cancel()
            domainState.pending = nil
            let taskGeneration = current.generation
            let registration = domainState.registration
            let task = Task { [weak self] in
                logger.info("refreshing \(domain.rawValue, privacy: .public)")
                let succeeded = await registration.refresh()
                @Dependency(\.date) var date
                let followUp: Bool = self?.state.withValue { current in
                    guard current.generation == taskGeneration else { return false }
                    current.domains[domain]?.running = nil
                    if succeeded {
                        current.domains[domain]?.lastRefreshedAt = date.now
                    } else if current.domains[domain]?.staleSince == nil {
                        // A failed read leaves the domain stale, so the next
                        // `refreshIfStale` re-reads instead of trusting a TTL
                        // stamped by a swallowed error. No auto-retry here —
                        // a failing endpoint shouldn't be hammered on a loop;
                        // the next event or appear-path recovers it.
                        current.domains[domain]?.staleSince = date.now
                    }
                    // An invalidate that landed *while this refresh ran* saw
                    // `running != nil` and its debounced pass joined us — its
                    // events are NOT reflected in what we just read. Re-arm a
                    // trailing pass so the tail of a long burst is never
                    // silently dropped (only on success: a failure already
                    // left the stale mark, and retrying it on a loop is worse).
                    return succeeded && current.domains[domain]?.staleSince != nil
                } ?? false
                if followUp { self?.invalidate(domain) }
            }
            domainState.running = task
            domainState.staleSince = nil
            current.domains[domain] = domainState
            return task
        }
        if let running { await running.value }
    }
}

extension DomainFreshnessClient: DependencyKey {
    /// One process-shared engine, mirroring `GameClient`'s single governor and
    /// `DeviceRefreshClient`'s single coordinator.
    public static let liveValue: DomainFreshnessClient = {
        let engine = DomainFreshnessEngine()
        return DomainFreshnessClient(
            register: { engine.register($0, $1) },
            invalidate: { engine.invalidate($0) },
            refreshIfStale: { await engine.refreshIfStale($0) },
            reset: { engine.reset() }
        )
    }()
}

extension DomainFreshnessClient: TestDependencyKey {
    /// Inert by default: features that consume freshness override it; routing
    /// tests build an engine (or a spy) explicitly.
    public static let testValue = DomainFreshnessClient(
        register: { _, _ in },
        invalidate: { _ in },
        refreshIfStale: { _ in },
        reset: {}
    )
}

extension DependencyValues {
    public var domainFreshness: DomainFreshnessClient {
        get { self[DomainFreshnessClient.self] }
        set { self[DomainFreshnessClient.self] = newValue }
    }
}
