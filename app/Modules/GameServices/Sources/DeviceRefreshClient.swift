//
//  DeviceRefreshClient.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The single seam every feature and the sync engine use to request an
//  authoritative device confirm-read. It fronts one process-shared
//  `PollCoordinator`, so all reads — stream-event invalidations, deadline
//  confirmations, and a feature's while-viewing poll — funnel through the same
//  coalescing / TTL / budget logic instead of racing each other with duplicate
//  network reads. Vended as `@Dependency(\.deviceRefresher)`.
//

import Dependencies
import Foundation
import GameModels

public struct DeviceRefreshClient: Sendable {
    /// Refresh a device's authoritative snapshot (read → reconcile), subject to
    /// coalescing, TTL, and read-budget. Returns the device if a read happened
    /// (or joined one in flight), or nil if it was suppressed / deferred / failed.
    public var refresh: @Sendable (_ deviceCode: String, _ priority: RefreshPriority) async -> Device?

    public init(refresh: @escaping @Sendable (_ deviceCode: String, _ priority: RefreshPriority) async -> Device?) {
        self.refresh = refresh
    }
}

extension DeviceRefreshClient: DependencyKey {
    /// Backed by one shared coordinator for the whole process, so the coalescing
    /// map and last-read stamps are consistent across every caller. `Reconciler`
    /// is stateless (all state lives in SQLite), so the coordinator owning its
    /// own instance is equivalent to sharing GameSync's.
    public static let liveValue: DeviceRefreshClient = {
        let coordinator = PollCoordinator(reconciler: Reconciler())
        return DeviceRefreshClient { deviceCode, priority in
            await coordinator.refresh(deviceCode, priority: priority)
        }
    }()

    /// Inert by default: tests opt into a real coordinator (or a stub) explicitly.
    public static let testValue = DeviceRefreshClient { _, _ in nil }
    public static let previewValue = DeviceRefreshClient { _, _ in nil }
}

extension DependencyValues {
    public var deviceRefresher: DeviceRefreshClient {
        get { self[DeviceRefreshClient.self] }
        set { self[DeviceRefreshClient.self] = newValue }
    }
}
