# 03 — Theatre recognition

Type: task
Status: open
Blocked by: 01, 02
Labels: multi-theatre

The three-tier rule from the spec, as one pure function: a pin, else an owned `system_hub`, else today's derivation applied per mesh component.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/TheatreRegistry.swift`
- Modify: `app/Modules/DirectiveEngine/Tests/TheatreRecognitionTests.swift`

**Interfaces:**
- Consumes: `Theatre` (ticket 02), `TheatrePin` (ticket 02), `MeshGraph.components(of:)` (ticket 01), `Device.isPrintHub` (`GameModels/Sources/Device.swift:177`), `SiteAssay.system(of:)`.
- Produces:
  ```swift
  public enum TheatreRegistry {
      public static func recognise(
          devices: [Device],
          pins: [TheatrePin],
          meshSystems: Set<String>,
          components: [String: String],
          stockByLocation: [String: Int]
      ) -> [Theatre]
  }
  ```
  Returns theatres ordered by depot designation, so the result is a total order and two ticks over the same world produce an identical array.

**Rules, in order. First match for a given system wins.**

1. Every pin becomes a theatre with `depot = pin.location`, `origin: .pinned`.
2. Every device of type `system_hub` whose system holds no pin becomes a theatre, `origin: .systemHub(code)`. Its depot is the richest stocked print-capable location **in that system**, falling back to the hub device's own location when there is none — a theatre must always have an identity, and that fallback is what makes it visibly `.claimed` rather than absent.
3. For every mesh component holding no **operational** theatre after 1–2, apply the existing `WorldView.hubLocation` rule within that component and emit `origin: .derived`.

`.operational`, not "any theatre", is load-bearing in rule 3: a pin over an empty system must not suppress derivation of a working depot elsewhere in the same component.

---

- [ ] **Step 1: Write the failing tests**

Append to `app/Modules/DirectiveEngine/Tests/TheatreRecognitionTests.swift`:

```swift
private func printer(_ code: String, at location: String) -> Device {
    Device.fixture(deviceCode: code, deviceType: "autofactory", location: location,
                   availableCommands: ["enqueue_print"])
}

private func systemHub(_ code: String, at location: String) -> Device {
    Device.fixture(deviceCode: code, deviceType: "system_hub", location: location,
                   availableCommands: ["activate"])
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
            meshSystems: ["AINALRAM", "GRAZ", "OMEROPE", "DENEBED"],
            components: homeAndPocket,
            stockByLocation: ["AINALRAM-BELT-1": 40_000, "OMEROPE-BELT-1": 900]
        )

        #expect(theatres.map(\.depot) == ["AINALRAM-BELT-1", "OMEROPE-BELT-1"])
        #expect(theatres.allSatisfy { $0.origin == .derived })
        #expect(theatres.allSatisfy(\.isOperational))
    }

    @Test("A pin beats derivation in the same system")
    func pinBeatsDerivation() {
        let theatres = TheatreRegistry.recognise(
            devices: [printer("AF1", at: "AINALRAM-BELT-1"), printer("AF2", at: "AINALRAM-2-L4")],
            pins: [TheatrePin(location: "AINALRAM-2-L4", createdAt: .distantPast)],
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
            meshSystems: ["AINALRAM", "GRAZ"],
            components: ["AINALRAM": "AINALRAM", "GRAZ": "AINALRAM"],
            stockByLocation: ["AINALRAM-BELT-1": 40_000]
        )

        #expect(theatres.map(\.depot) == ["AINALRAM-BELT-1", "GRAZ-1-L4"])
        #expect(theatres.filter(\.isOperational).map(\.depot) == ["AINALRAM-BELT-1"])
    }

    @Test("An off-mesh depot is claimed, not operational")
    func offMeshIsClaimed() {
        let theatres = TheatreRegistry.recognise(
            devices: [printer("AF1", at: "OMEROPE-BELT-1")],
            pins: [TheatrePin(location: "OMEROPE-BELT-1", createdAt: .distantPast)],
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
            devices: devices, pins: [], meshSystems: ["AINALRAM"],
            components: ["AINALRAM": "AINALRAM"], stockByLocation: stock
        )
        let second = TheatreRegistry.recognise(
            devices: devices.reversed(), pins: [], meshSystems: ["AINALRAM"],
            components: ["AINALRAM": "AINALRAM"], stockByLocation: stock
        )

        #expect(first == second)
        #expect(first.count == 1)
        #expect(first[0].depot == "AINALRAM-BELT-2")
    }
}
```

If `Device.fixture(...)` does not exist with these parameters, reuse whichever device fixture helper `BrainSurveyTests.swift` or `RelayReturnAndRestockTests.swift` already defines rather than inventing a new one — match the existing test idiom.

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
cd app/Modules && swift test --filter TheatreRecognitionTests --event-stream-output-path /tmp/t03.json
```

Expected: compile failure, `cannot find 'TheatreRegistry' in scope`.

- [ ] **Step 3: Implement `TheatreRegistry`**

Create `app/Modules/DirectiveEngine/Sources/TheatreRegistry.swift`:

```swift
//
//  TheatreRegistry.swift
//  Replicould — DirectiveEngine
//
//  Theatre recognition: a pin, else an owned system_hub, else the richest
//  stocked printer in a component that has no operational theatre yet.
//

import Foundation
import GameModels
import UniverseModels

public enum TheatreRegistry {
    /// Every recognised theatre, ordered by depot designation. Ordering and
    /// tie-breaks are total, so two ticks over one world produce one answer.
    public static func recognise(
        devices: [Device],
        pins: [TheatrePin],
        meshSystems: Set<String>,
        components: [String: String],
        stockByLocation: [String: Int]
    ) -> [Theatre] {
        let printLocations = Set(devices.filter(\.isPrintHub).compactMap(\.location))

        func readiness(of depot: String) -> Theatre.Readiness {
            var missing: Set<Theatre.Shortfall> = []
            if !printLocations.contains(depot) { missing.insert(.noPrintCapableDevice) }
            if (stockByLocation[depot] ?? 0) <= 0 { missing.insert(.noStock) }
            if !meshSystems.contains(SiteAssay.system(of: depot)) { missing.insert(.offMesh) }
            return missing.isEmpty ? .operational : .claimed(missing: missing)
        }

        func theatre(depot: String, origin: Theatre.Origin) -> Theatre {
            Theatre(
                depot: depot, system: SiteAssay.system(of: depot), origin: origin,
                readiness: readiness(of: depot), stock: stockByLocation[depot] ?? 0
            )
        }

        /// Richest stocked print location among `candidates`, designation as the
        /// tie-break — the rule `WorldView.hubLocation` has always used.
        func richest(among candidates: Set<String>) -> String? {
            candidates
                .filter { printLocations.contains($0) && (stockByLocation[$0] ?? 0) > 0 }
                .max {
                    let (left, right) = (stockByLocation[$0] ?? 0, stockByLocation[$1] ?? 0)
                    return left == right ? $0 > $1 : left < right
                }
        }

        var claimedSystems: Set<String> = []
        var result: [Theatre] = []

        for pin in pins {
            result.append(theatre(depot: pin.location, origin: .pinned))
            claimedSystems.insert(SiteAssay.system(of: pin.location))
        }

        for hub in devices.filter({ $0.deviceType == "system_hub" }).sorted(by: { $0.deviceCode < $1.deviceCode }) {
            guard let hubLocation = hub.location else { continue }
            let system = SiteAssay.system(of: hubLocation)
            guard !claimedSystems.contains(system) else { continue }
            let inSystem = Set(printLocations.filter { SiteAssay.system(of: $0) == system })
            result.append(
                theatre(depot: richest(among: inSystem) ?? hubLocation, origin: .systemHub(hub.deviceCode))
            )
            claimedSystems.insert(system)
        }

        let servedComponents = Set(
            result.filter(\.isOperational).compactMap { components[$0.system] }
        )
        var byComponent: [String: Set<String>] = [:]
        for location in printLocations {
            guard let component = components[SiteAssay.system(of: location)] else { continue }
            byComponent[component, default: []].insert(location)
        }
        for (component, candidates) in byComponent.sorted(by: { $0.key < $1.key }) {
            guard !servedComponents.contains(component), let depot = richest(among: candidates) else { continue }
            guard !claimedSystems.contains(SiteAssay.system(of: depot)) else { continue }
            result.append(theatre(depot: depot, origin: .derived))
        }

        return result.sorted { $0.depot < $1.depot }
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
cd app/Modules && swift test --filter TheatreRecognitionTests --event-stream-output-path /tmp/t03.json
```

Expected: 8 recognition tests plus the 3 vocabulary tests from ticket 02, all passing.

- [ ] **Step 5: Run the whole suite, then check comments and commit**

```bash
cd app/Modules && swift test --event-stream-output-path /tmp/t03-all.json
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/TheatreRegistry.swift
git add app/Modules/DirectiveEngine
git commit -m "feat(theatre): three-tier theatre recognition"
```
