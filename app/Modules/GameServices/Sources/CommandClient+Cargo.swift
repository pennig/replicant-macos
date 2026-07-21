//
//  CommandClient+Cargo.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The cargo family: `collect_resources` (load a transport's hold from the
//  local stockpile) and `deposit_resources` (unload at the current location).
//  A successful unload can satisfy a location event sited at the drop-off, so
//  the family also owns the post-deposit quest cross-reference.
//

import API
import Dependencies
import Foundation
import GameModels
import OSLog
import SQLiteData
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Command")

extension CommandClient {
    private typealias CollectResourcesSchema = Components.Schemas.AppSchemasDeviceCommandsCollectResourcesSchema
    private typealias DepositResourcesSchema = Components.Schemas.AppSchemasDeviceCommandsDepositResourcesSchema

    static func collectResourcesBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        // Load the hold from the local stockpile — the server needs at least
        // one resource/amount to move, so an empty map fails fast.
        guard let resources = params.resources, !resources.isEmpty else {
            throw CommandError.missingParameter("resources")
        }
        return .json(.collectResources(try resourcesSchema(
            CollectResourcesSchema.self, command: "collect_resources", resources: resources
        )))
    }

    static func depositResourcesBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        // Unload the hold at the current location. `resources` is optional here:
        // omitting it empties the entire hold (what the inspector's Unload does).
        return .json(.depositResources(try resourcesSchema(
            DepositResourcesSchema.self, command: "deposit_resources", resources: params.resources
        )))
    }

    /// A successful unload can satisfy a location event sited where the cargo
    /// was dropped. Cross-reference the drop-off location against known events
    /// and re-pull the quest list if any are open there, so a now-ready event
    /// surfaces (sidebar badge + Ready status) without the user opening the
    /// Locations screen.
    static func refreshOpenLocationEvents(at location: String) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.locationEventsClient) var locationEventsClient
        let openThere = (try? await database.read { db in
            try LocationEvent
                .where { $0.location.eq(location) && $0.status.eq("active") }
                .fetchCount(db)
        }) ?? 0
        if openThere > 0 {
            _ = try? await locationEventsClient.refresh()
            logger.info("unload at \(location, privacy: .public): refreshed \(openThere, privacy: .public) open location event(s)")
        }
    }

    /// Build a `collect_resources`/`deposit_resources` body carrying a per-type
    /// `resources` map. Those generated schemas type `resources` as an
    /// `additionalProperties` bag (schemaless keys → numbers), so — as with
    /// `set_directive`'s configuration — round-trip a `{command, resources}` object
    /// through JSON and let the schema's decoder slurp the per-resource amounts.
    /// A nil/empty map omits `resources` entirely (a deposit then empties the hold).
    private static func resourcesSchema<Schema: Decodable>(
        _ type: Schema.Type, command: String, resources: [String: Int]?
    ) throws -> Schema {
        var object: [String: JSONValue] = ["command": .string(command)]
        if let resources, !resources.isEmpty {
            object["resources"] = .object(resources.mapValues { .number(Double($0)) })
        }
        let data = try jsonEncoder.encode(JSONValue.object(object))
        return try JSONDecoder().decode(Schema.self, from: data)
    }
}
