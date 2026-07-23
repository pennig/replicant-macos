//
//  CommandClient+Lifecycle.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The lifecycle family: the parameter-less commands (`activate`, `deploy`,
//  `recall`, …) plus `stow` and `set_directive`. Also home to the family
//  classification sets the dispatcher consults: which no-param commands are
//  nonetheless deadline-tracked, and which immediate commands terminate a
//  device's running action.
//

import API
import Foundation
import Utils

extension CommandClient {
    private typealias NoParam = Components.Schemas.AppSchemasDeviceCommandsNoParamSchema
    private typealias SetDirectiveSchema = Components.Schemas.AppSchemasDeviceCommandsSetDirectiveSchema

    static func stowBody(_ params: CommandParams) -> Operations.PostV1DevicesDeviceCode.Input.Body {
        .json(.stow(.init(command: "stow", target: params.target)))
    }

    static func setDirectiveBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let directive = params.directive else { throw CommandError.missingParameter("directive") }
        return .json(.setDirective(.init(
            command: "set_directive",
            directive: directive,
            configuration: try configurationPayload(from: params.configuration)
        )))
    }

    /// No-param commands that are nonetheless self-describing with a deadline —
    /// e.g. `recall` cruises the device home to stow on the nearest craft and
    /// returns `arrives_at`, so it's a tracked deadline op like travel (its
    /// tracked-path supersede ends any in-flight mining/travel op). `search` is a
    /// long-running survey scan whose deadline lives in the device's `scan` block
    /// (`eta_seconds`) rather than the dispatch response, so it's tracked here and
    /// its `completesAt` is back-filled from the post-command read. `compact`
    /// packs the device down for transport over a fixed window and returns
    /// `completes_at`, so it's a tracked deadline op too; `unfurl` is its inverse
    /// (expanding a packed device back) and behaves identically. `repair`
    /// (parameterized, but classified here too) works a target back to capacity
    /// over time — its deadline lives in the bot's `repair` block, back-filled
    /// from the post-command read like `search`.
    static let deadlineCommands: Set<String> = ["recall", "search", "compact", "unfurl", "repair"]

    /// Immediate commands that stop a device's running action — closing its open
    /// operation so a lingering mining/travel row doesn't survive the stop.
    /// (`recall` is excluded — it's deadline-tracked and supersedes instead.)
    static let terminatingCommands: Set<String> = ["deactivate", "decommission", "stow"]

    /// The supported parameter-less commands, each routed to its discriminated
    /// `oneOf` case (the body enum is closed, so only vetted verbs dispatch).
    static func simpleBody(for command: String) -> Operations.PostV1DevicesDeviceCode.Input.Body? {
        let schema = NoParam(command: command)
        switch command {
        case "activate":        return .json(.activate(schema))
        case "deactivate":      return .json(.deactivate(schema))
        case "deploy":          return .json(.deploy(schema))
        case "recall":          return .json(.recall(schema))
        case "decommission":    return .json(.decommission(schema))
        case "clear_queue":     return .json(.clearQueue(schema))
        case "clear_directive": return .json(.clearDirective(schema))
        case "assemble":        return .json(.assemble(schema))
        case "compact":         return .json(.compact(schema))
        case "launch":          return .json(.launch(schema))
        case "unfurl":          return .json(.unfurl(schema))
        case "withdraw":        return .json(.withdraw(schema))
        case "search":          return .json(.search(schema))
        case "set_entry_point": return .json(.setEntryPoint(schema))
        default:                return nil
        }
    }

    /// The set of parameter-less lifecycle commands `simpleBody` can dispatch —
    /// the device-side gate for surfacing them as confirm-only grid buttons.
    public static let supportedSimpleCommands: Set<String> = [
        "activate", "deactivate", "deploy", "recall", "decommission",
        "clear_queue", "clear_directive", "assemble", "compact", "launch",
        "unfurl", "withdraw", "search", "set_entry_point",
    ]

    /// Bridge the loosely-typed `set_directive` configuration into the generated
    /// schema's `ConfigurationPayload` (an untyped `additionalProperties` bag) by
    /// round-tripping through JSON — the payload's decoder slurps every key as an
    /// additional property, so arbitrary per-directive shapes pass through intact.
    /// Nil/empty configuration is omitted (the field defaults to null server-side).
    private static func configurationPayload(
        from configuration: [String: JSONValue]?
    ) throws -> SetDirectiveSchema.ConfigurationPayload? {
        guard let configuration, !configuration.isEmpty else { return nil }
        let data = try jsonEncoder.encode(JSONValue.object(configuration))
        return try JSONDecoder().decode(SetDirectiveSchema.ConfigurationPayload.self, from: data)
    }
}
