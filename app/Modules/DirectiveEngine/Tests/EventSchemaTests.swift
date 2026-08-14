import Foundation
import GameModels
import SQLiteData
import Testing
@testable import GameDatabase

@Suite("Event fulfilment schema")
struct EventSchemaTests {
    @Test("the two new columns exist and round-trip")
    func columnsRoundTrip() async throws {
        let database = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 0)
        try await database.write { db in
            try Directive.insert {
                Directive(
                    id: "d1", kind: .eventRun, status: .running, deviceCode: "CARRIER",
                    controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
                    targets: ["X-1-EVT-001"], targetIndex: 0, step: "preflight",
                    stepStartedAt: now, returnToOrigin: true, originDesignation: "HUB",
                    attentionReason: nil, createdAt: now, updatedAt: now,
                    theatreDepot: "HUB-1", freighterCode: "FREIGHT"
                )
            }.execute(db)
            try LocationEvent.insert {
                LocationEvent(
                    designation: "X-1-EVT-001", location: "X-1", status: "active",
                    firstSeenAt: now, updatedAt: now, chosenOption: "booster"
                )
            }.execute(db)
        }
        let (directive, event) = try await database.read { db in
            (try Directive.all.fetchOne(db), try LocationEvent.all.fetchOne(db))
        }
        #expect(directive?.freighterCode == "FREIGHT")
        #expect(event?.chosenOption == "booster")
    }
}
