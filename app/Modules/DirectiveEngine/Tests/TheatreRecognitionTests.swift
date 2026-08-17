//
//  TheatreRecognitionTests.swift
//  Replicould — DirectiveEngine
//
//  The `Theatre` vocabulary; the recognition rule that produces it lands later.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("Theatre vocabulary")
struct TheatreVocabularyTests {
    @Test("Identity is the depot location")
    func identityIsDepot() {
        let theatre = Theatre(
            depot: "AINALRAM-BELT-1", system: "AINALRAM",
            origin: .derived, readiness: .operational, stock: 12_000
        )
        #expect(theatre.id == "AINALRAM-BELT-1")
        #expect(theatre.system == "AINALRAM")
        #expect(theatre.isOperational)
    }

    @Test("A claimed theatre names every clause it fails, and is not operational")
    func claimedNamesShortfalls() {
        let theatre = Theatre(
            depot: "OMEROPE-BELT-1", system: "OMEROPE", origin: .pinned,
            readiness: .claimed(missing: [.noPrintCapableDevice, .noStock]),
            stock: 0
        )
        #expect(!theatre.isOperational)
        #expect(theatre.readiness == .claimed(missing: [.noPrintCapableDevice, .noStock]))
    }

    @Test("A hub-claimed theatre carries the claiming device code")
    func hubOriginCarriesCode() {
        let theatre = Theatre(
            depot: "DENEBED-BELT-1", system: "DENEBED",
            origin: .systemHub("SH8C2A1F"), readiness: .operational, stock: 500
        )
        #expect(theatre.origin == .systemHub("SH8C2A1F"))
    }
}

private func printer(_ code: String, at location: String) -> Device {
    deviceFixture(code: code, type: "autofactory", location: location, availableCommands: ["enqueue_print"])
}

private func systemHub(_ code: String, at location: String) -> Device {
    deviceFixture(code: code, type: "system_hub", location: location, availableCommands: ["activate"])
}

/// Home and pocket are separate components; both hold a stocked printer.
private let homeAndPocket: [String: String] = [
    "AINALRAM": "AINALRAM", "GRAZ": "AINALRAM",
    "OMEROPE": "DENEBED", "DENEBED": "DENEBED",
]

@Suite("Theatre recognition")
struct TheatreRecognitionTests {
    @Test("Each component with a stocked printer derives its own theatre")
    func derivesOnePerComponent() {
        let theatres = TheatreRegistry.recognise(
            devices: [printer("AF1", at: "AINALRAM-BELT-1"), printer("AF2", at: "OMEROPE-BELT-1")],
            pins: [],
            records: [],
            meshSystems: ["AINALRAM", "GRAZ", "OMEROPE", "DENEBED"],
            components: homeAndPocket,
            stockByLocation: ["AINALRAM-BELT-1": 40_000, "OMEROPE-BELT-1": 900]
        )

        #expect(theatres.map(\.depot) == ["AINALRAM-BELT-1", "OMEROPE-BELT-1"])
        #expect(theatres.allSatisfy { $0.origin == .derived })
        #expect(theatres.allSatisfy { $0.isOperational })
    }

    @Test("A pin beats derivation in the same system")
    func pinBeatsDerivation() {
        let theatres = TheatreRegistry.recognise(
            devices: [printer("AF1", at: "AINALRAM-BELT-1"), printer("AF2", at: "AINALRAM-2-L4")],
            pins: [TheatrePin(location: "AINALRAM-2-L4", createdAt: .distantPast)],
            records: [],
            meshSystems: ["AINALRAM"],
            components: ["AINALRAM": "AINALRAM"],
            stockByLocation: ["AINALRAM-BELT-1": 40_000, "AINALRAM-2-L4": 10]
        )

        #expect(theatres.count == 1)
        #expect(theatres[0].depot == "AINALRAM-2-L4")
        #expect(theatres[0].origin == .pinned)
    }

    @Test("A pin beats a system_hub claim in the same system")
    func pinBeatsHub() {
        let theatres = TheatreRegistry.recognise(
            devices: [systemHub("SH1", at: "DENEBED-3-L4"), printer("AF2", at: "DENEBED-BELT-1")],
            pins: [TheatrePin(location: "DENEBED-BELT-1", createdAt: .distantPast)],
            records: [],
            meshSystems: ["DENEBED"],
            components: ["DENEBED": "DENEBED"],
            stockByLocation: ["DENEBED-BELT-1": 700]
        )

        #expect(theatres.count == 1)
        #expect(theatres[0].origin == .pinned)
    }

    @Test("A system_hub claims its system, depot resolving to the stocked printer")
    func hubClaimsWithDepot() {
        let theatres = TheatreRegistry.recognise(
            devices: [systemHub("SH1", at: "DENEBED-3-L4"), printer("AF2", at: "DENEBED-BELT-1")],
            pins: [],
            records: [],
            meshSystems: ["DENEBED"],
            components: ["DENEBED": "DENEBED"],
            stockByLocation: ["DENEBED-BELT-1": 700]
        )

        #expect(theatres.count == 1)
        #expect(theatres[0].depot == "DENEBED-BELT-1")
        #expect(theatres[0].origin == .systemHub("SH1"))
        #expect(theatres[0].isOperational)
    }

    @Test("A claim with no printer is claimed, names its shortfalls, and keeps the hub as its identity")
    func hubClaimWithoutDepot() {
        let theatres = TheatreRegistry.recognise(
            devices: [systemHub("SH1", at: "OMEROPE-6-L4")],
            pins: [],
            records: [],
            meshSystems: ["OMEROPE"],
            components: ["OMEROPE": "OMEROPE"],
            stockByLocation: [:]
        )

        #expect(theatres.count == 1)
        #expect(theatres[0].depot == "OMEROPE-6-L4")
        #expect(!theatres[0].isOperational)
        #expect(theatres[0].readiness == .claimed(missing: [.noPrintCapableDevice, .noStock]))
    }

    @Test("A claimed pin does not suppress derivation in its own component")
    func claimedPinDoesNotSuppress() {
        let theatres = TheatreRegistry.recognise(
            devices: [printer("AF1", at: "AINALRAM-BELT-1")],
            pins: [TheatrePin(location: "GRAZ-1-L4", createdAt: .distantPast)],
            records: [],
            meshSystems: ["AINALRAM", "GRAZ"],
            components: ["AINALRAM": "AINALRAM", "GRAZ": "AINALRAM"],
            stockByLocation: ["AINALRAM-BELT-1": 40_000]
        )

        #expect(theatres.map(\.depot) == ["AINALRAM-BELT-1", "GRAZ-1-L4"])
        #expect(theatres.filter { $0.isOperational }.map(\.depot) == ["AINALRAM-BELT-1"])
    }

    @Test("An off-mesh depot is claimed, not operational")
    func offMeshIsClaimed() {
        let theatres = TheatreRegistry.recognise(
            devices: [printer("AF1", at: "OMEROPE-BELT-1")],
            pins: [TheatrePin(location: "OMEROPE-BELT-1", createdAt: .distantPast)],
            records: [],
            meshSystems: [],
            components: ["OMEROPE": "OMEROPE"],
            stockByLocation: ["OMEROPE-BELT-1": 900]
        )

        #expect(theatres[0].readiness == .claimed(missing: [.offMesh]))
    }

    @Test("Derivation picks the richest, with designation as the tie-break, identically every call")
    func derivationIsATotalOrder() {
        let devices = [printer("AF1", at: "AINALRAM-BELT-1"), printer("AF2", at: "AINALRAM-BELT-2")]
        let stock = ["AINALRAM-BELT-1": 500, "AINALRAM-BELT-2": 500]
        let first = TheatreRegistry.recognise(
            devices: devices, pins: [], records: [], meshSystems: ["AINALRAM"],
            components: ["AINALRAM": "AINALRAM"], stockByLocation: stock
        )
        let second = TheatreRegistry.recognise(
            devices: devices.reversed(), pins: [], records: [], meshSystems: ["AINALRAM"],
            components: ["AINALRAM": "AINALRAM"], stockByLocation: stock
        )

        #expect(first == second)
        #expect(first.count == 1)
        #expect(first[0].depot == "AINALRAM-BELT-1")
    }

    @Test("A claimed system's stock does not block a poorer sibling in the same component from deriving")
    func claimedRichSystemDoesNotBlockSiblingDerivation() {
        let theatres = TheatreRegistry.recognise(
            devices: [printer("AF1", at: "AINALRAM-BELT-1"), printer("AF2", at: "GRAZ-BELT-1")],
            pins: [TheatrePin(location: "AINALRAM-2-L4", createdAt: .distantPast)],
            records: [],
            meshSystems: ["AINALRAM", "GRAZ"],
            components: ["AINALRAM": "AINALRAM", "GRAZ": "AINALRAM"],
            stockByLocation: ["AINALRAM-BELT-1": 40_000, "GRAZ-BELT-1": 900]
        )

        let graz = theatres.first { $0.depot == "GRAZ-BELT-1" }
        #expect(graz?.origin == .derived)
        #expect(graz?.isOperational == true)

        let pin = theatres.first { $0.depot == "AINALRAM-2-L4" }
        #expect(pin?.origin == .pinned)
        #expect(pin?.isOperational == false)
    }
}

private func record(_ depot: String, in system: String, origin: String = "derived") -> TheatreRecord {
    TheatreRecord(depot: depot, system: system, origin: origin, establishedAt: .distantPast)
}

/// `BELT-1` is the richer print location throughout, so every case whose
/// record names `BELT-2` fails unless the persisted depot actually decides.
private let twoPrinters = [printer("AF1", at: "AINALRAM-BELT-1"), printer("AF2", at: "AINALRAM-BELT-2")]
private let lopsidedStock = ["AINALRAM-BELT-1": 40_000, "AINALRAM-BELT-2": 900]

@Suite("Theatre recognition — persisted identity")
struct StickyTheatreRecognitionTests {
    @Test("A derived theatre keeps its persisted depot over a richer sibling")
    func derivedKeepsPersistedDepot() {
        let theatres = TheatreRegistry.recognise(
            devices: twoPrinters,
            pins: [],
            records: [record("AINALRAM-BELT-2", in: "AINALRAM")],
            meshSystems: ["AINALRAM"],
            components: ["AINALRAM": "AINALRAM"],
            stockByLocation: lopsidedStock
        )

        #expect(theatres.count == 1)
        #expect(theatres[0].depot == "AINALRAM-BELT-2")
        #expect(theatres[0].origin == .derived)
    }

    @Test("A persisted depot that lost its printer falls through to derivation")
    func derivedFallsThroughWithoutAPrinter() {
        let theatres = TheatreRegistry.recognise(
            devices: [printer("AF1", at: "AINALRAM-BELT-1")],
            pins: [],
            records: [record("AINALRAM-BELT-2", in: "AINALRAM")],
            meshSystems: ["AINALRAM"],
            components: ["AINALRAM": "AINALRAM"],
            stockByLocation: lopsidedStock
        )

        #expect(theatres.count == 1)
        #expect(theatres[0].depot == "AINALRAM-BELT-1")
    }

    @Test("A system_hub claim keeps its persisted depot over a richer sibling")
    func hubKeepsPersistedDepot() {
        let theatres = TheatreRegistry.recognise(
            devices: twoPrinters + [systemHub("SH1", at: "AINALRAM-3-L4")],
            pins: [],
            records: [record("AINALRAM-BELT-2", in: "AINALRAM", origin: "systemHub")],
            meshSystems: ["AINALRAM"],
            components: ["AINALRAM": "AINALRAM"],
            stockByLocation: lopsidedStock
        )

        #expect(theatres.count == 1)
        #expect(theatres[0].depot == "AINALRAM-BELT-2")
        #expect(theatres[0].origin == .systemHub("SH1"))
    }

    @Test("A hub's persisted depot that lost its printer falls through to derivation")
    func hubFallsThroughWithoutAPrinter() {
        let theatres = TheatreRegistry.recognise(
            devices: [printer("AF1", at: "AINALRAM-BELT-1"), systemHub("SH1", at: "AINALRAM-3-L4")],
            pins: [],
            records: [record("AINALRAM-BELT-2", in: "AINALRAM", origin: "systemHub")],
            meshSystems: ["AINALRAM"],
            components: ["AINALRAM": "AINALRAM"],
            stockByLocation: lopsidedStock
        )

        #expect(theatres.count == 1)
        #expect(theatres[0].depot == "AINALRAM-BELT-1")
    }

    @Test("A pin outranks the persisted depot")
    func pinOutranksTheRecord() {
        let theatres = TheatreRegistry.recognise(
            devices: twoPrinters,
            pins: [TheatrePin(location: "AINALRAM-BELT-1", createdAt: .distantPast)],
            records: [record("AINALRAM-BELT-2", in: "AINALRAM")],
            meshSystems: ["AINALRAM"],
            components: ["AINALRAM": "AINALRAM"],
            stockByLocation: lopsidedStock
        )

        #expect(theatres.count == 1)
        #expect(theatres[0].depot == "AINALRAM-BELT-1")
        #expect(theatres[0].origin == .pinned)
    }

    /// Print-capability is the WHOLE proviso: a persisted depot that has run dry
    /// keeps the identity and reports `.noStock`, rather than hopping to the
    /// stocked sibling. See `app/.claude/memory/theatre-recognition-model.md`.
    @Test("A persisted depot with no stock left still keeps the identity")
    func aDryPersistedDepotKeepsTheIdentity() {
        let theatres = TheatreRegistry.recognise(
            devices: twoPrinters,
            pins: [],
            records: [record("AINALRAM-BELT-2", in: "AINALRAM")],
            meshSystems: ["AINALRAM"],
            components: ["AINALRAM": "AINALRAM"],
            stockByLocation: ["AINALRAM-BELT-1": 40_000, "AINALRAM-BELT-2": 0]
        )

        #expect(theatres.count == 1)
        #expect(theatres[0].depot == "AINALRAM-BELT-2")
        #expect(theatres[0].readiness == .claimed(missing: [.noStock]))
    }

    /// The record names a print-capable depot, so only the SYSTEM key can
    /// reject it — a lookup blind to the system would hand `AINALRAM` the
    /// depot `GRAZ` persisted.
    @Test("A record for another system decides nothing here")
    func aForeignRecordIsIgnored() {
        let theatres = TheatreRegistry.recognise(
            devices: twoPrinters,
            pins: [],
            records: [record("AINALRAM-BELT-2", in: "GRAZ")],
            meshSystems: ["AINALRAM"],
            components: ["AINALRAM": "AINALRAM"],
            stockByLocation: lopsidedStock
        )

        #expect(theatres.count == 1)
        #expect(theatres[0].depot == "AINALRAM-BELT-1")
    }
}

private let ainalram = Position(x: -11.25, y: -37.09, z: -7.68)
private let graz = Position(x: -14.0, y: -30.0, z: -5.0)
private let omerope = Position(x: -291.87, y: -125.98, z: 106.32)
private let denebed = Position(x: -292.55, y: -125.42, z: 113.41)

func twoTheatreView() -> WorldView {
    WorldView(
        devices: [:],
        starPositions: ["AINALRAM": ainalram, "GRAZ": graz, "OMEROPE": omerope, "DENEBED": denebed],
        meshSystems: ["AINALRAM", "GRAZ", "OMEROPE", "DENEBED"],
        salvageUnits: [:],
        eventSystems: [],
        theatres: [
            Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                    readiness: .operational, stock: 40_000),
            Theatre(depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
                    readiness: .operational, stock: 900),
        ],
        components: ["AINALRAM": "AINALRAM", "GRAZ": "AINALRAM",
                     "OMEROPE": "DENEBED", "DENEBED": "DENEBED"],
        now: Date(timeIntervalSince1970: 5_000)
    )
}

@Suite("Theatre resolvers")
struct TheatreResolverTests {
    @Test("Inward resolution refuses a theatre in another component")
    func inwardRespectsComponent() {
        let view = twoTheatreView()
        #expect(view.theatre(servicing: "GRAZ")?.depot == "AINALRAM-BELT-1")
        #expect(view.theatre(servicing: "OMEROPE")?.depot == "DENEBED-BELT-1")
    }

    @Test("Inward resolution returns nil for a system in no serviced component")
    func inwardNilOffComponent() {
        let view = twoTheatreView()
        #expect(view.theatre(servicing: "NOWHERE") == nil)
    }

    @Test("Outward resolution ignores components and takes the nearest")
    func outwardIgnoresComponents() {
        let view = twoTheatreView()
        #expect(view.theatre(nearest: "OMEROPE")?.depot == "DENEBED-BELT-1")
        #expect(view.theatre(nearest: "GRAZ")?.depot == "AINALRAM-BELT-1")
    }

    @Test("Two theatres in ONE component both pass the filter; distance decides")
    func sharedComponentResolvesByDistance() {
        let view = WorldView(
            devices: [:],
            starPositions: ["AINALRAM": ainalram, "GRAZ": graz],
            meshSystems: ["AINALRAM", "GRAZ"],
            salvageUnits: [:], eventSystems: [],
            theatres: [
                Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                        readiness: .operational, stock: 40_000),
                Theatre(depot: "GRAZ-1-L4", system: "GRAZ", origin: .pinned,
                        readiness: .operational, stock: 100),
            ],
            components: ["AINALRAM": "AINALRAM", "GRAZ": "AINALRAM"],
            now: Date(timeIntervalSince1970: 5_000)
        )

        #expect(view.theatre(servicing: "GRAZ")?.depot == "GRAZ-1-L4")
        #expect(view.theatre(servicing: "AINALRAM")?.depot == "AINALRAM-BELT-1")
    }

    @Test("A claimed theatre is never returned by either resolver")
    func claimedIsInvisible() {
        let view = WorldView(
            devices: [:], starPositions: ["OMEROPE": omerope],
            meshSystems: [], salvageUnits: [:], eventSystems: [],
            theatres: [
                Theatre(depot: "OMEROPE-BELT-1", system: "OMEROPE", origin: .pinned,
                        readiness: .claimed(missing: [.offMesh]), stock: 900),
            ],
            components: ["OMEROPE": "OMEROPE"],
            now: Date(timeIntervalSince1970: 5_000)
        )

        #expect(view.theatre(servicing: "OMEROPE") == nil)
        #expect(view.theatre(nearest: "OMEROPE") == nil)
    }
}
