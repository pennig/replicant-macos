//
//  LogisticsView+Previews.swift
//  Replicould — Logistics feature
//
//  Kept apart from the views it exercises (Xcode 26 preview JIT crash).
//

import ComposableArchitecture
import Foundation
import GameModels
import SQLiteData
import SwiftUI

private func seededDatabase(rows: [HaulYield] = HaulYield.previewRows) -> any DatabaseWriter {
    let database = try! SQLiteData.defaultDatabase()
    var migrator = DatabaseMigrator()
    HaulYield.createHaulYields.register(in: &migrator)
    HaulYield.addControllerCodeIndex.register(in: &migrator)
    try! migrator.migrate(database)
    if !rows.isEmpty {
        try! database.write { db in
            try HaulYield.insert { rows }.execute(db)
        }
    }
    return database
}

extension HaulYield {
    fileprivate static let previewRows: [HaulYield] = {
        let day: (Int) -> Date = { Date(timeIntervalSince1970: TimeInterval(20 - $0) * 86_400) }
        return [
            HaulYield(
                id: UUID(), directiveID: "D1", controllerCode: "AMI-01", deviceCode: "VES-7F3A2",
                sourceDesignation: "ACHERNUR-BELT-1", collectedAt: day(5), unitsCollected: 620,
                perType: ResourceCost(carbon: 40, silicates: 180, structural: 400),
                breakdownState: .exact
            ),
            HaulYield(
                id: UUID(), directiveID: "D1", controllerCode: "AMI-01", deviceCode: "VES-7F3A2",
                sourceDesignation: "ACHERNUR-BELT-1", collectedAt: day(4), unitsCollected: 540,
                perType: ResourceCost(silicates: 90, rares: 60, conductive: 390),
                breakdownState: .exact
            ),
            HaulYield(
                id: UUID(), directiveID: "D2", controllerCode: "AMI-01", deviceCode: "VES-7F3A2",
                sourceDesignation: "KRIOS-2-BELT", collectedAt: day(3), unitsCollected: 310,
                perType: ResourceCost(), breakdownState: .unavailable, followsGap: true
            ),
            HaulYield(
                id: UUID(), directiveID: "D2", controllerCode: "AMI-01", deviceCode: "VES-7F3A2",
                sourceDesignation: "KRIOS-2-BELT", collectedAt: day(2), unitsCollected: 275,
                perType: ResourceCost(carbon: 275),
                breakdownState: .exact
            ),
            HaulYield(
                id: UUID(), directiveID: "D3", controllerCode: "AMI-02", deviceCode: "VES-119C0",
                sourceDesignation: "TAU-9-BELT-2", collectedAt: day(1), unitsCollected: 890,
                perType: ResourceCost(structural: 210, rares: 80, conductive: 100, volatiles: 500),
                breakdownState: .partial
            ),
            HaulYield(
                id: UUID(), directiveID: "D3", controllerCode: "AMI-02", deviceCode: "VES-119C0",
                sourceDesignation: "TAU-9-BELT-2", collectedAt: day(0), unitsCollected: 150,
                perType: ResourceCost(volatiles: 150),
                breakdownState: .exact
            ),
        ]
    }()
}

#Preview("Dark") {
    let _ = prepareDependencies { $0.defaultDatabase = seededDatabase() }
    LogisticsView(store: Store(initialState: LogisticsFeature.State()) { LogisticsFeature() })
        .frame(width: 900, height: 900)
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    let _ = prepareDependencies { $0.defaultDatabase = seededDatabase() }
    LogisticsView(store: Store(initialState: LogisticsFeature.State()) { LogisticsFeature() })
        .frame(width: 900, height: 900)
        .preferredColorScheme(.light)
}

#Preview("Narrow") {
    let _ = prepareDependencies { $0.defaultDatabase = seededDatabase() }
    LogisticsView(store: Store(initialState: LogisticsFeature.State()) { LogisticsFeature() })
        .frame(width: 420, height: 900)
        .preferredColorScheme(.dark)
}

#Preview("Empty") {
    let _ = prepareDependencies { $0.defaultDatabase = seededDatabase(rows: []) }
    LogisticsView(store: Store(initialState: LogisticsFeature.State()) { LogisticsFeature() })
        .frame(width: 900, height: 600)
        .preferredColorScheme(.dark)
}
