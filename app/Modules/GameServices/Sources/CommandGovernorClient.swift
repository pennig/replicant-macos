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

    public init(
        dispatch: @escaping @Sendable (OperationKind, String, CommandParams) async -> CommandDispatchResult
    ) {
        self.dispatch = dispatch
    }
}

extension CommandGovernorClient: DependencyKey {
    /// One governor for the whole process — the in-flight claim only means
    /// anything if every caller shares it.
    public static let liveValue: CommandGovernorClient = {
        let governor = CommandGovernor()
        return CommandGovernorClient { kind, deviceCode, params in
            await governor.dispatch(kind, on: deviceCode, params: params)
        }
    }()

    /// Loud by default: a test that dispatches without stubbing this must fail.
    public static let testValue = CommandGovernorClient(
        dispatch: unimplemented(
            "CommandGovernorClient.dispatch",
            placeholder: .deferred(.budgetExhausted)
        )
    )

    public static let previewValue = CommandGovernorClient { _, _, _ in
        .dispatched(.accepted(operationID: nil))
    }
}

extension DependencyValues {
    public var commandGovernor: CommandGovernorClient {
        get { self[CommandGovernorClient.self] }
        set { self[CommandGovernorClient.self] = newValue }
    }
}
