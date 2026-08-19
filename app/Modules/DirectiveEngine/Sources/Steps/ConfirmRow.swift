//
//  ConfirmRow.swift
//  Replicould — DirectiveEngine
//
//  The order a confirming step asks its questions in. Not what counts as
//  success — the mission owns that — only when it may be asked at all.
//

import Foundation
import GameModels

/// Whether the mission may judge its rows yet.
enum ConfirmVerdict: Equatable, Sendable {
    /// Fresh enough — apply the mission's own success test.
    case judge
    /// Take this instead.
    case act(MissionAction)
}

/// The confirm ladder, as a pure value.
struct ConfirmRow: Equatable, Sendable {
    /// What the deadline means when it passes.
    enum Expiry: Equatable, Sendable {
        /// Buy one last read carrying the stall; the engine collapses an
        /// unresolved re-ask onto it. No `detail:` — `MissionAction`'s refresh
        /// cases have no slot for one.
        case readThenStall(DirectiveAttentionReason)
        /// Stall outright, buying no read.
        case stallNow(DirectiveAttentionReason, detail: String? = nil)
        /// Hand back to the mission to judge whatever it holds — the
        /// degrade-rather-than-halt exit.
        case judge
    }

    /// What "read since this mattered" means.
    enum Watermark: Equatable, Sendable {
        case stepStart
        /// `stepStartedAt` less a tolerance, for a server clock seconds behind.
        case skewed(TimeInterval)
        /// Pure age, with no relation to the step — for a row named before the
        /// step existed.
        case age(TimeInterval)
    }

    /// Which read buys the evidence.
    enum Refresh: Equatable, Sendable {
        case devices
        case fleet(FleetTag)
    }

    let deadline: TimeInterval
    let onExpiry: Expiry
    var watermark: Watermark = .stepStart
    var refresh: Refresh = .devices
    /// Grace before the first read of a just-ordered command.
    var probeDelay: TimeInterval = 0
    /// Floor between reads of one row.
    var readInterval: TimeInterval = 30
    /// Wait out a device's own cruise home before reading it.
    var waitsOutArrival: Bool = false

    init(deadline: TimeInterval, onExpiry: Expiry) {
        self.deadline = deadline
        self.onExpiry = onExpiry
    }

    func verdict(_ rows: [Device], _ ctx: StepContext) -> ConfirmVerdict {
        if ctx.elapsed < probeDelay { return .act(.wait) }
        if ctx.elapsed > deadline { return expired(rows) }
        if waitsOutArrival, let arrival = rows.compactMap(\.activityDeadline).max(),
           arrival > ctx.now {
            return .act(.wait)
        }
        guard rows.contains(where: { !isFresh($0, ctx) }) else { return .judge }
        let lastLook = rows.map(\.updatedAt).min() ?? .distantPast
        if ctx.now.timeIntervalSince(lastLook) > readInterval {
            return .act(read(rows, thenStall: nil))
        }
        return .act(.wait)
    }

    private func expired(_ rows: [Device]) -> ConfirmVerdict {
        switch onExpiry {
        case let .readThenStall(reason): .act(read(rows, thenStall: reason))
        case let .stallNow(reason, detail): .act(.stall(reason, detail: detail))
        case .judge: .judge
        }
    }

    private func read(_ rows: [Device], thenStall: DirectiveAttentionReason?) -> MissionAction {
        switch refresh {
        case .devices: .refreshDevices(deviceCodes: rows.map(\.deviceCode), thenStall: thenStall)
        case let .fleet(tag): .refreshFleet(tag: tag, thenStall: thenStall)
        }
    }

    private func isFresh(_ device: Device, _ ctx: StepContext) -> Bool {
        switch watermark {
        case .stepStart:
            ctx.isFresh(device)
        case let .skewed(tolerance):
            device.updatedAt >= ctx.directive.stepStartedAt.addingTimeInterval(-tolerance)
        case let .age(maximum):
            ctx.now.timeIntervalSince(device.updatedAt) <= maximum
        }
    }
}
