//
//  Blueprint.swift
//  Replicould — Blueprints feature
//
//  The locally-persisted device blueprint record plus its schema mapping and
//  table migration. Blueprints are fetched from `GET /v1/blueprints` (the
//  account's *unlocked* catalog) and upserted into SQLite so the catalog reads
//  instantly, survives relaunches, and can be searched reactively through a
//  `@FetchAll` query. Mirrors the backend
//  `app_schemas_blueprints_BlueprintSchema` payload.
//
//  The column names track the Swift property names; the snake_case backend keys
//  (`device_type`, `short_description`, `print_time`, …) are mapped at the
//  networking boundary in `BlueprintsClient`.
//

import API
import Foundation
import SQLiteData

/// A single unlocked device blueprint — the recipe (resource cost, print time)
/// and capabilities (features, directives, capacities) for one device type.
@Table
public struct Blueprint: Identifiable, Equatable, Sendable {
    /// The device type this blueprint produces — the natural primary key.
    @Column(primaryKey: true) public var deviceType: String
    public var shortDescription: String
    public var fullDescription: String
    /// Time to print, in seconds.
    public var printTime: Int
    @Column(as: [String].JSONRepresentation.self) public var features: [String]
    @Column(as: [String].JSONRepresentation.self) public var directives: [String]
    /// The build cost, with the six resource kinds coalesced to 0 when the
    /// payload omits them (the wire dict is sparse).
    @Column(as: ResourceCost.JSONRepresentation.self) public var resources: ResourceCost
    public var stowCapacity: Int
    public var cargoCapacity: Int
    public var attachCapacity: Int
    public var queueSize: Int
    public var strength: Double
    /// Present only for `system_hub`; nil otherwise.
    public var currentHubs: Int?

    public var id: String { deviceType }

    public init(
        deviceType: String,
        shortDescription: String,
        fullDescription: String,
        printTime: Int,
        features: [String],
        directives: [String],
        resources: ResourceCost,
        stowCapacity: Int,
        cargoCapacity: Int,
        attachCapacity: Int,
        queueSize: Int,
        strength: Double,
        currentHubs: Int?
    ) {
        self.deviceType = deviceType
        self.shortDescription = shortDescription
        self.fullDescription = fullDescription
        self.printTime = printTime
        self.features = features
        self.directives = directives
        self.resources = resources
        self.stowCapacity = stowCapacity
        self.cargoCapacity = cargoCapacity
        self.attachCapacity = attachCapacity
        self.queueSize = queueSize
        self.strength = strength
        self.currentHubs = currentHubs
    }
}

// MARK: - Resource cost

/// The six-resource build cost of a blueprint. Stored as a JSON blob; every key
/// is coalesced to 0 so the sparse wire dict (e.g. `mining_drone` omits
/// `rares`/`volatiles`) always round-trips to a complete record.
public struct ResourceCost: Codable, Equatable, Sendable {
    public var carbon: Int
    public var silicates: Int
    public var structural: Int
    public var rares: Int
    public var conductive: Int
    public var volatiles: Int

    public init(
        carbon: Int = 0,
        silicates: Int = 0,
        structural: Int = 0,
        rares: Int = 0,
        conductive: Int = 0,
        volatiles: Int = 0
    ) {
        self.carbon = carbon
        self.silicates = silicates
        self.structural = structural
        self.rares = rares
        self.conductive = conductive
        self.volatiles = volatiles
    }

    /// Maps the backend's sparse `{resource: amount}` dict onto the typed cost.
    public init(wire: [String: Int]) {
        self.init(
            carbon: wire["carbon"] ?? 0,
            silicates: wire["silicates"] ?? 0,
            structural: wire["structural"] ?? 0,
            rares: wire["rares"] ?? 0,
            conductive: wire["conductive"] ?? 0,
            volatiles: wire["volatiles"] ?? 0
        )
    }

    /// The non-zero line items in display order, for the inspector's build-cost
    /// breakdown. Empty when the blueprint has no listed cost.
    public var lineItems: [(label: String, amount: Int)] {
        [
            ("Structural", structural),
            ("Conductive", conductive),
            ("Silicates", silicates),
            ("Carbon", carbon),
            ("Rares", rares),
            ("Volatiles", volatiles),
        ].filter { $0.amount > 0 }
    }
}

// MARK: - Mapping

extension Blueprint {
    /// Maps a generated blueprint schema onto the local record, coalescing every
    /// optional. `print_time` arrives as a `Double` on the wire but is whole
    /// seconds; `current_hubs` is preserved as nil unless the payload carries it.
    public init(schema: Components.Schemas.AppSchemasBlueprintsBlueprintSchema) {
        self.init(
            deviceType: schema.deviceType ?? "",
            shortDescription: schema.shortDescription ?? "",
            fullDescription: schema.description ?? "",
            printTime: Int(schema.printTime ?? 0),
            features: schema.features ?? [],
            directives: schema.directives ?? [],
            resources: ResourceCost(wire: schema.resources?.additionalProperties ?? [:]),
            stowCapacity: schema.stowCapacity ?? 0,
            cargoCapacity: schema.cargoCapacity ?? 0,
            attachCapacity: schema.attachCapacity ?? 0,
            queueSize: schema.queueSize ?? 0,
            strength: schema.strength ?? 0,
            currentHubs: schema.currentHubs
        )
    }
}

// MARK: - Schema

extension Blueprint {
    /// Registers the `blueprints` table migration. Kept beside the model so the
    /// schema and the type never drift. Composed into the app's
    /// `bootstrapDatabase` alongside other features' tables.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'blueprints' table") { db in
            try #sql(
                """
                CREATE TABLE "blueprints" (
                  "deviceType" TEXT PRIMARY KEY NOT NULL,
                  "shortDescription" TEXT NOT NULL DEFAULT '',
                  "fullDescription" TEXT NOT NULL DEFAULT '',
                  "printTime" INTEGER NOT NULL DEFAULT 0,
                  "features" TEXT NOT NULL DEFAULT '[]',
                  "directives" TEXT NOT NULL DEFAULT '[]',
                  "resources" TEXT NOT NULL DEFAULT '{}',
                  "stowCapacity" INTEGER NOT NULL DEFAULT 0,
                  "cargoCapacity" INTEGER NOT NULL DEFAULT 0,
                  "attachCapacity" INTEGER NOT NULL DEFAULT 0,
                  "queueSize" INTEGER NOT NULL DEFAULT 0,
                  "strength" REAL NOT NULL DEFAULT 0,
                  "currentHubs" INTEGER
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}

// MARK: - Preview fixtures

extension Blueprint {
    /// Sample catalog used by Xcode previews and the `BlueprintsClient` preview
    /// value. Tests define their own seeds.
    public static let previewCatalog: [Blueprint] = [
        Blueprint(
            deviceType: "ami_mining_controller",
            shortDescription: "An AMI mining controller overseeing a swarm of mining drones.",
            fullDescription: "Life inside an asteroid belt can be chaotic, and this AMI controller has been fabricated to match it. This mining controller issues a constant stream of retargeting instructions to the drones it commands.",
            printTime: 1800,
            features: ["ami", "cruise", "stow"],
            directives: ["gather_resources", "maintain_ratios", "gather_evenly", "deplete_smallest", "gather_salvage"],
            resources: ResourceCost(carbon: 35, silicates: 40, structural: 150, rares: 20, conductive: 80, volatiles: 10),
            stowCapacity: 0,
            cargoCapacity: 0,
            attachCapacity: 0,
            queueSize: 0,
            strength: 0,
            currentHubs: nil
        ),
        Blueprint(
            deviceType: "heaven_vessel",
            shortDescription: "This Von Neumann probe is composed of several segments connected to form a pencil-shaped exploration vessel.",
            fullDescription: "The Heaven Vessel is an elongated probe with a surge engine at the base. At the centre of the ship sits a replicant matrix cradle, holding the uploaded consciousness of its host.",
            printTime: 28800,
            features: ["surge", "cruise", "system_scan", "mine", "cradle", "print", "census"],
            directives: [],
            resources: ResourceCost(carbon: 400, silicates: 500, structural: 2000, rares: 300, conductive: 1000, volatiles: 200),
            stowCapacity: 10,
            cargoCapacity: 0,
            attachCapacity: 0,
            queueSize: 0,
            strength: 0,
            currentHubs: nil
        ),
        Blueprint(
            deviceType: "mining_drone",
            shortDescription: "Extracts resources from asteroid belts and salvage sites.",
            fullDescription: "Six robotic arms extend from a circular frame — each one tipped with a multi-tool cutting head. Raw chunks are pushed into the core, where tiny internal furnaces melt and reform the materials into uniform resource blocks.",
            printTime: 600,
            features: ["cruise", "mine", "stow"],
            directives: [],
            resources: ResourceCost(carbon: 25, silicates: 25, structural: 100, rares: 0, conductive: 50, volatiles: 0),
            stowCapacity: 0,
            cargoCapacity: 0,
            attachCapacity: 0,
            queueSize: 0,
            strength: 0,
            currentHubs: nil
        ),
    ]
}
