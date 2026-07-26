//
//  Civilisation.swift
//  Replicould — Civilisations feature
//
//  The locally-persisted civilisation (backend "species") record plus its
//  schema mappings and table migration. The full species roster comes from
//  `GET /v1/species` and is upserted into SQLite; the account's standing with
//  each species (`GET /v1/accounts/reputation`, met species only) is merged
//  into the nullable `totalReputation` column, keyed by `species_key`. A nil
//  reputation means the account hasn't encountered that species yet.
//
//  The column names track the Swift property names; the snake_case backend
//  keys (`species_key`, `homeworld_type`, `tech_affinity`, `star_regions`, …)
//  are mapped at the networking boundary in `CivilisationsClient`.
//

import API
import Foundation
import SQLiteData

/// A single civilisation — one intelligent species of the galaxy, blended with
/// the account's reputation standing when the species has been encountered.
@Table
public struct Civilisation: Identifiable, Equatable, Sendable {
    /// The backend's stable species identifier — the natural primary key.
    @Column(primaryKey: true) public var speciesKey: String
    public var name: String
    public var speciesDescription: String
    public var government: String
    /// The species' first-contact communication, shown as flavor text.
    public var greeting: String
    public var homeworldType: String
    public var techAffinity: String
    public var trait: String
    /// The star regions this species is found in. Present on only some species.
    @Column(as: [String].JSONRepresentation.self) public var starRegions: [String]
    /// The account's standing with this species; nil until first contact.
    public var totalReputation: Int?

    public var id: String { speciesKey }

    public init(
        speciesKey: String,
        name: String,
        speciesDescription: String,
        government: String,
        greeting: String,
        homeworldType: String,
        techAffinity: String,
        trait: String,
        starRegions: [String],
        totalReputation: Int?
    ) {
        self.speciesKey = speciesKey
        self.name = name
        self.speciesDescription = speciesDescription
        self.government = government
        self.greeting = greeting
        self.homeworldType = homeworldType
        self.techAffinity = techAffinity
        self.trait = trait
        self.starRegions = starRegions
        self.totalReputation = totalReputation
    }
}

// MARK: - Reputation entry

/// One row of the account's reputation standing — the join-relevant slice of
/// `app_schemas_species_AccountReputationEntrySchema` (the payload's `name`,
/// `trait`, and `description` duplicate the species record and are dropped).
public struct SpeciesReputation: Equatable, Sendable {
    public var speciesKey: String
    public var totalReputation: Int

    public init(speciesKey: String, totalReputation: Int) {
        self.speciesKey = speciesKey
        self.totalReputation = totalReputation
    }
}

// MARK: - Mapping

extension Civilisation {
    /// Maps a generated species schema onto the local record, coalescing every
    /// optional. Reputation never rides the species payload, so it starts nil
    /// and is merged separately from the account reputation endpoint.
    public init(schema: Components.Schemas.AppSchemasSpeciesSpeciesSchema) {
        self.init(
            speciesKey: schema.speciesKey ?? "",
            name: schema.name ?? "",
            speciesDescription: schema.description ?? "",
            government: schema.government ?? "",
            greeting: schema.greeting ?? "",
            homeworldType: schema.homeworldType ?? "",
            techAffinity: schema.techAffinity ?? "",
            trait: schema.trait ?? "",
            starRegions: schema.starRegions ?? [],
            totalReputation: nil
        )
    }
}

extension SpeciesReputation {
    /// Maps a generated reputation entry. `total_reputation` is spec'd as
    /// `number` (so generated as `Double?`) but is whole points on the wire.
    public init(schema: Components.Schemas.AppSchemasSpeciesAccountReputationEntrySchema) {
        self.init(
            speciesKey: schema.speciesKey ?? "",
            totalReputation: Int(schema.totalReputation ?? 0)
        )
    }
}

// MARK: - Schema

extension Civilisation {
    /// Creates the `civilisations` table. Kept beside the model so the schema
    /// and the type never drift.
    public static let createCivilisations = SchemaMigration("Create 'civilisations' table") { db in
        try #sql(
            """
            CREATE TABLE "civilisations" (
              "speciesKey" TEXT PRIMARY KEY NOT NULL,
              "name" TEXT NOT NULL DEFAULT '',
              "speciesDescription" TEXT NOT NULL DEFAULT '',
              "government" TEXT NOT NULL DEFAULT '',
              "greeting" TEXT NOT NULL DEFAULT '',
              "homeworldType" TEXT NOT NULL DEFAULT '',
              "techAffinity" TEXT NOT NULL DEFAULT '',
              "trait" TEXT NOT NULL DEFAULT '',
              "starRegions" TEXT NOT NULL DEFAULT '[]',
              "totalReputation" INTEGER
            ) STRICT
            """
        )
        .execute(db)
    }
}

// MARK: - Preview fixtures

extension Civilisation {
    /// Sample species used by Xcode previews and the `CivilisationsClient`
    /// preview value. Pure species data (reputation nil, as `init(schema:)`
    /// yields); previews wanting a met species set `totalReputation` directly.
    /// Tests define their own seeds.
    public static let previewCatalog: [Civilisation] = [
        Civilisation(
            speciesKey: "humans",
            name: "Humans",
            speciesDescription: "A resourceful and adaptable species from the third planet of the Sol system. Known for their curiosity, social complexity, and a drive to explore beyond their world.",
            government: "Fragmented Democracies",
            greeting: "This is Earth. We come in peace.",
            homeworldType: "terrestrial",
            techAffinity: "engineering",
            trait: "curious",
            starRegions: [],
            totalReputation: nil
        ),
        Civilisation(
            speciesKey: "dzhekari",
            name: "Dzhekari",
            speciesDescription: "Fungal colony organisms spanning subterranean cave networks. Each colony is a single distributed mind. They think slowly but with precision.",
            government: "The Consensus",
            greeting: "Low-frequency vibration. The pattern repeats once. A single acknowledgment.",
            homeworldType: "ice_world",
            techAffinity: "energy",
            trait: "collective",
            starRegions: ["alpha"],
            totalReputation: nil
        ),
        Civilisation(
            speciesKey: "vorchek",
            name: "Vorchek",
            speciesDescription: "Armoured reptilians that nest near geothermal vents. Their metallurgy is exotic, within naturally occurring forges.",
            government: "Merchant Guild Alliance",
            greeting: "Broadband signal on commerce frequency. Itemised trade manifest attached.",
            homeworldType: "volcanic",
            techAffinity: "materials",
            trait: "mercantile",
            starRegions: [],
            totalReputation: nil
        ),
        Civilisation(
            speciesKey: "qivari",
            name: "Qivari",
            speciesDescription: "Endothermic beings that generate intense internal heat to survive on their frozen world. Their technology revolves around thermal engineering, and their cities glow.",
            government: "Hearthbound Federation",
            greeting: "Infrared signal detected. Thermal pattern encodes a welcome sequence.",
            homeworldType: "frozen",
            techAffinity: "energy",
            trait: "diplomatic",
            starRegions: [],
            totalReputation: nil
        ),
    ]

    /// The preview reputation standings, matching `previewCatalog`.
    public static let previewReputations: [SpeciesReputation] = [
        SpeciesReputation(speciesKey: "humans", totalReputation: 10),
        SpeciesReputation(speciesKey: "qivari", totalReputation: 3),
    ]
}
