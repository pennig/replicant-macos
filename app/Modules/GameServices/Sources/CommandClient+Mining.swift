//
//  CommandClient+Mining.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The mining family: `start_mining` (continuous — runs until stopped) and
//  `retarget` (switch an active miner to another belt resource).
//

import API
import Foundation

extension CommandClient {
    private typealias MiningSchema = Components.Schemas.AppSchemasDeviceCommandsStartMiningSchema
    private typealias RetargetSchema = Components.Schemas.AppSchemasDeviceCommandsRetargetSchema

    static func mineBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let resource = params.resourceType else { throw CommandError.missingParameter("resource_type") }
        guard let payload = MiningSchema.ResourceTypePayload(rawValue: resource) else {
            throw CommandError.invalidParameter("resource_type", resource)
        }
        return .json(.startMining(.init(command: "start_mining", resourceType: payload, target: params.target)))
    }

    static func retargetBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let resource = params.resourceType else { throw CommandError.missingParameter("resource_type") }
        guard let payload = RetargetSchema.ResourceTypePayload(rawValue: resource) else {
            throw CommandError.invalidParameter("resource_type", resource)
        }
        return .json(.retarget(.init(command: "retarget", resourceType: payload)))
    }
}
