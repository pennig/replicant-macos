//
//  CommandGovernorClient.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The seam every engine dispatch goes through, fronting one process-shared
//  `CommandGovernor` so the per-device in-flight claim is global rather than
//  per-executor. Vended as `@Dependency(\.commandGovernor)`, mirroring
//  `DeviceRefreshClient` over `PollCoordinator`.
//

import Dependencies
import Foundation
import GameModels

public struct CommandGovernorClient: Sendable {
    /// Dispatch a command subject to the actions budget and the per-device
    /// in-flight guard. Never throws; a refusal comes back as `.deferred`.
    public var dispatch: @Sendable (
        _ kind: OperationKind,
        _ deviceCode: String,
        _ params: CommandParams
    ) async -> CommandDispatchResult

    /// Same as `dispatch`, but attributes the resulting `Operation` row to the
    /// dispatching directive step. `dispatch` calls this with `owner: nil`.
    public var dispatchOwned: @Sendable (
        _ kind: OperationKind,
        _ deviceCode: String,
        _ params: CommandParams,
        _ owner: CommandOwner?
    ) async -> CommandDispatchResult

    /// The actions-budget floor the shared governor defers at — the number
    /// behind "we are pacing ourselves", surfaced so the brain's why-view can
    /// state it rather than restate a literal that could drift from the one
    /// `CommandGovernor` enforces.
    public static let actionFloor = CommandGovernor.defaultActionFloor

    public init(
        dispatch: @escaping @Sendable (OperationKind, String, CommandParams) async -> CommandDispatchResult,
        dispatchOwned: @escaping @Sendable (OperationKind, String, CommandParams, CommandOwner?) async -> CommandDispatchResult
    ) {
        self.dispatch = dispatch
        self.dispatchOwned = dispatchOwned
    }
}

extension CommandGovernorClient: DependencyKey {
    /// One governor for the whole process — the in-flight claim only means
    /// anything if every caller shares it.
    public static let liveValue: CommandGovernorClient = {
        let governor = CommandGovernor()
        return CommandGovernorClient(
            dispatch: { kind, deviceCode, params in
                await governor.dispatch(kind, on: deviceCode, params: params, owner: nil)
            },
            dispatchOwned: { kind, deviceCode, params, owner in
                await governor.dispatch(kind, on: deviceCode, params: params, owner: owner)
            }
        )
    }()

    /// Loud by default: a test that dispatches without stubbing this must fail.
    public static let testValue = CommandGovernorClient(
        dispatch: unimplemented(
            "CommandGovernorClient.dispatch",
            placeholder: .deferred(.budgetExhausted)
        ),
        dispatchOwned: unimplemented(
            "CommandGovernorClient.dispatchOwned",
            placeholder: .deferred(.budgetExhausted)
        )
    )

    public static let previewValue = CommandGovernorClient(
        dispatch: { _, _, _ in .dispatched(.accepted(operationID: nil)) },
        dispatchOwned: { _, _, _, _ in .dispatched(.accepted(operationID: nil)) }
    )
}

extension DependencyValues {
    public var commandGovernor: CommandGovernorClient {
        get { self[CommandGovernorClient.self] }
        set { self[CommandGovernorClient.self] = newValue }
    }
}
