//
//  CommandClient+Utility.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The utility family: the parameterized odds-and-ends the Stage 4 revamp
//  surfaced — `configure` (surge-plate carry mode), `message` (BobNet post
//  from an FTL relay), `repair` (service-bot repair of a damaged device), and
//  `change_owner` (reassign a device between the account's replicants). Each
//  is a typed body builder that validates its required parameter and fails
//  fast, per the dispatch template. `replicate` is deliberately NOT here — it
//  answers 201 with a new replicant and dispatches through
//  `ReplicantsClient.replicate` instead.
//

import API
import Foundation

extension CommandClient {
    private typealias ConfigureSchema = Components.Schemas.AppSchemasDeviceCommandsConfigureSchema
    private typealias MessageSchema = Components.Schemas.AppSchemasDeviceCommandsMessageSchema
    private typealias RepairSchema = Components.Schemas.AppSchemasDeviceCommandsRepairSchema
    private typealias ChangeOwnerSchema = Components.Schemas.AppSchemasDeviceCommandsChangeOwnerSchema

    static func configureBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let mode = params.mode, !mode.isEmpty else { throw CommandError.missingParameter("mode") }
        guard mode == "taxi" || mode == "manual" else { throw CommandError.invalidParameter("mode", mode) }
        return .json(.configure(.init(command: "configure", mode: mode)))
    }

    static func messageBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let channel = params.channel, !channel.isEmpty else { throw CommandError.missingParameter("channel") }
        guard let text = params.text, !text.isEmpty else { throw CommandError.missingParameter("text") }
        return .json(.message(.init(command: "message", channel: channel, text: text)))
    }

    static func repairBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        // The schema also declares a nullable `device` field, but the docs and
        // server take the device code under `target` — send only that.
        guard let target = params.target, !target.isEmpty else { throw CommandError.missingParameter("target") }
        return .json(.repair(.init(command: "repair", target: target, device: nil)))
    }

    static func changeOwnerBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let target = params.target, !target.isEmpty else { throw CommandError.missingParameter("target") }
        return .json(.changeOwner(.init(command: "change_owner", target: target)))
    }
}
