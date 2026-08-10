//
//  HaulYield.swift
//  Replicould — GameModels
//
//  One Haul Run pickup: what a transport loaded, where, and when. Delivery
//  columns fill in when that half is observed. Yields are reconstructed from
//  digest deltas, never reported, so `breakdownState` says how much to trust.
//

import Foundation
import SQLiteData

@Table
public struct HaulYield: Identifiable, Equatable, Sendable {
    @Column(primaryKey: true) public var id: UUID
    /// The `haulRun` directive this pickup belongs to; empty when unresolved.
    public var directiveID: String
    public var controllerCode: String
    public var deviceCode: String
    public var sourceDesignation: String
    public var collectedAt: Date
    /// Digest `cargo_carried` delta — the reliable figure.
    public var unitsCollected: Int
    @Column(as: ResourceCost.JSONRepresentation.self) public var perType: ResourceCost
    public var breakdownState: BreakdownState
    public var destinationDesignation: String?
    public var deliveredAt: Date?
    public var unitsDelivered: Int?
    /// The stream was disconnected between this row and the previous one, so
    /// the interval between them is unobserved rather than empty.
    public var followsGap: Bool

    public enum BreakdownState: String, Codable, QueryBindable, Sendable {
        /// Hold was empty beforehand and the per-type sum matches the delta.
        case exact
        /// A multi-stop load, or the sum disagreed with the delta.
        case partial
        /// The device read failed; `unitsCollected` still holds.
        case unavailable
    }

    public var isOpen: Bool { deliveredAt == nil }

    public init(
        id: UUID,
        directiveID: String,
        controllerCode: String,
        deviceCode: String,
        sourceDesignation: String,
        collectedAt: Date,
        unitsCollected: Int,
        perType: ResourceCost,
        breakdownState: BreakdownState,
        destinationDesignation: String? = nil,
        deliveredAt: Date? = nil,
        unitsDelivered: Int? = nil,
        followsGap: Bool = false
    ) {
        self.id = id
        self.directiveID = directiveID
        self.controllerCode = controllerCode
        self.deviceCode = deviceCode
        self.sourceDesignation = sourceDesignation
        self.collectedAt = collectedAt
        self.unitsCollected = unitsCollected
        self.perType = perType
        self.breakdownState = breakdownState
        self.destinationDesignation = destinationDesignation
        self.deliveredAt = deliveredAt
        self.unitsDelivered = unitsDelivered
        self.followsGap = followsGap
    }
}

extension HaulYield {
    public static let createHaulYields = SchemaMigration("Create 'haulYields' table") { db in
        try #sql(
            """
            CREATE TABLE "haulYields" (
              "id" TEXT PRIMARY KEY NOT NULL,
              "directiveID" TEXT NOT NULL DEFAULT '',
              "controllerCode" TEXT NOT NULL DEFAULT '',
              "deviceCode" TEXT NOT NULL DEFAULT '',
              "sourceDesignation" TEXT NOT NULL DEFAULT '',
              "collectedAt" TEXT NOT NULL,
              "unitsCollected" INTEGER NOT NULL DEFAULT 0,
              "perType" TEXT NOT NULL DEFAULT '{}',
              "breakdownState" TEXT NOT NULL DEFAULT 'unavailable',
              "destinationDesignation" TEXT,
              "deliveredAt" TEXT,
              "unitsDelivered" INTEGER,
              "followsGap" INTEGER NOT NULL DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)
    }
}
