# 13 — Logistics Theatres screen

Type: task
Status: open
Blocked by: 04, 12
Labels: multi-theatre

`LogisticsFeature` is today only the haul-yield ledger. Give it a Theatres tab: what exists, what state each is in, and the operator's half of "brain proposes, operator establishes".

**Files:**
- Create: `app/Modules/LogisticsFeature/Sources/TheatresTab.swift`
- Create: `app/Modules/LogisticsFeature/Sources/TheatreRow.swift`
- Create: `app/Modules/LogisticsFeature/Sources/EstablishTheatreSheet.swift`
- Modify: `app/Modules/LogisticsFeature/Sources/LogisticsFeature.swift`
- Modify: `app/Modules/LogisticsFeature/Sources/LogisticsView.swift`
- Test: `app/Modules/LogisticsFeature/Tests/TheatresTabTests.swift` (create)

**Interfaces:**
- Consumes: `Theatre` (02), `TheatrePin` (02), `TheatreSiteRanking.Candidate` (12).
- Produces: `LogisticsFeature.State.tab: Tab` (`.yields` / `.theatres`), and a `TheatrePin` write on establish.

**Per row:** depot in a monospace token, origin badge (Pinned / Hub-claimed / Derived), readiness, and for a `.claimed` theatre the shortfalls spelled out — "no autofactory here", "no stock", "off mesh" — because that list is the operator's to-do list for standing it up. Then component size, stock, and the directives the theatre owns.

**Establish sheet:** pick a location, write the pin, and offer to queue the `system_hub` print. Establishing writes a pin and nothing else; recognition does the rest on the next tick. The sheet must say that a `system_hub` costs 6,800 units and ~16 h and that its cost rises with the number of hubs owned, because that is the largest single spend in the game and the operator is authorising it here.

**House rules that bite in this ticket:**
- `TheatreRow` lives in its own file with no `#Preview` beside it — the Xcode 26 preview JIT crashes otherwise.
- The sheet presents a *feature* (its own reducer), so it uses `@Presents` / enum destinations, not a presentation optional. Dismissal cancels its in-flight effects.
- Every designation renders monospace (`.rcMono`, `.rcBodyEmphMono`, or a prominence-matched token). Add a token to `DesignSystem.swift` rather than inlining `design: .monospaced`.
- No hard-coded colours, spacing or font sizes. Status colour comes through `DeviceStatus.tone(for:)` where it applies.

---

- [ ] **Step 1: Write the failing test**

Create `app/Modules/LogisticsFeature/Tests/TheatresTabTests.swift` using the TCA `TestStore` idiom already used elsewhere in the module:

```swift
@Test("Establishing writes a pin and nothing else")
func establishWritesPin() async throws {
    let store = TestStore(initialState: LogisticsFeature.State()) {
        LogisticsFeature()
    } withDependencies: {
        $0.date.now = Date(timeIntervalSince1970: 5_000)
    }

    await store.send(.establishTapped("OMEROPE-BELT-1"))
    await store.receive(.pinWritten("OMEROPE-BELT-1"))

    let pins = try await store.dependencies.defaultDatabase.read {
        try TheatrePin.all.fetchAll($0)
    }
    #expect(pins.map(\.location) == ["OMEROPE-BELT-1"])
}

@Test("A claimed theatre lists every shortfall it has")
func claimedListsShortfalls() {
    let row = TheatreRow.Model(theatre: Theatre(
        depot: "OMEROPE-BELT-1", system: "OMEROPE", origin: .pinned,
        readiness: .claimed(missing: [.noPrintCapableDevice, .noStock]), stock: 0
    ))

    #expect(row.shortfallLines.count == 2)
}
```

- [ ] **Step 2: Run and confirm it fails**

```bash
cd app/Modules && swift test --filter TheatresTabTests --event-stream-output-path /tmp/t13.json
```

- [ ] **Step 3: Add the tab to the feature**

Give `LogisticsFeature.State` a `tab` and observe theatres. The existing `@FetchAll` yields observation stays exactly as it is — the two tabs share a feature, not a query.

- [ ] **Step 4: Build the row and the tab**

`TheatreRow` first, in its own file. Then `TheatresTab` as the list plus the ranked-candidate section fed by `TheatreSiteRanking.rank(view:)`, each candidate rendering its `reasons` verbatim.

- [ ] **Step 5: Build the establish sheet**

`@Presents` destination on `LogisticsFeature`, its own reducer, writing a `TheatrePin` on confirm.

- [ ] **Step 6: Verify both colour schemes and the design rules**

Check the screen with `.preferredColorScheme(.light)` and `.dark`. Confirm by reading the diff that no hex, no numeric spacing and no numeric font size was inlined, and that every designation uses a mono token.

- [ ] **Step 7: Run the tests, check comments, commit**

```bash
cd app/Modules && swift test --event-stream-output-path /tmp/t13-all.json
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/LogisticsFeature/Sources
git add app/Modules/LogisticsFeature
git commit -m "feat(theatre): Logistics Theatres tab with establish flow"
```
