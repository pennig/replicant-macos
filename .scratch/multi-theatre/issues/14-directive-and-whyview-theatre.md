# 14 — Theatre on directive rows and the why-view

Type: task
Status: open
Blocked by: 05, 10
Labels: multi-theatre

With several theatres running, a Directives list that does not say which theatre a row serves is unreadable. The brain's why-view has the same problem one level up: it prints one hub line and five goal lines, and there are now five goal lines *per theatre*.

**Files:**
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveRow.swift`
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveTargetsSection.swift` (`:83`, `:102`)
- Modify: `app/Modules/DirectivesFeature/Sources/BrainWhyView.swift` (`:610`, and the goal-line builders around `:367-399`)
- Modify: `app/Modules/DirectivesFeature/Sources/DirectivesFeature.swift` (filter state)
- Test: `app/Modules/DirectivesFeature/Tests/WhyViewTheatreTests.swift` (create)

**Interfaces:**
- Consumes: `Directive.theatreDepot` (05), `BrainReport.theatres` (10).
- Produces: `DirectivesFeature.State.theatreFilter: String?` — nil shows every theatre.

**What each surface shows:**
- **Directive row** — the theatre's depot, monospace, subordinate to the row's existing identity. A row with no `theatreDepot` reads "unassigned" rather than being hidden; that state is real after a migration and the operator needs to see it.
- **Targets section** — the coverage line at `:83` and the centre at `:102` stay as they are; `anchorsOnCentre(directive.kind)` already decides which kinds show a centre, and a theatre is a different axis from a roam centre. Do not merge them.
- **Why-view** — one group per theatre, each carrying that theatre's goal lines, and a group for the ranked candidates from ticket 12. A theatre in `.claimed` renders its shortfalls instead of goal lines, since no goal will run there.

---

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectivesFeature/Tests/WhyViewTheatreTests.swift`:

```swift
@Test("The why-view renders one group per theatre")
func oneGroupPerTheatre() {
    let report = brainReportFixture(theatres: [
        Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                readiness: .operational, stock: 40_000),
        Theatre(depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
                readiness: .operational, stock: 900),
    ])

    let groups = BrainWhyView.groups(for: report)

    #expect(groups.map(\.depot) == ["AINALRAM-BELT-1", "DENEBED-BELT-1"])
    #expect(groups.allSatisfy { $0.goalLines.count == 5 })
}

@Test("A claimed theatre renders its shortfalls in place of goal lines")
func claimedRendersShortfalls() {
    let report = brainReportFixture(theatres: [
        Theatre(depot: "OMEROPE-BELT-1", system: "OMEROPE", origin: .pinned,
                readiness: .claimed(missing: [.noPrintCapableDevice]), stock: 0),
    ])

    let groups = BrainWhyView.groups(for: report)

    #expect(groups[0].goalLines.isEmpty)
    #expect(groups[0].shortfallLines.count == 1)
}

@Test("A directive with no theatre reads as unassigned rather than disappearing")
func unassignedRowVisible() {
    let model = DirectiveRow.Model(directive: directiveFixture(theatreDepot: nil))
    #expect(model.theatreLabel == "unassigned")
}

@Test("The theatre filter narrows the list without hiding unassigned rows")
func filterKeepsUnassignedVisible() {
    var state = DirectivesFeature.State()
    state.theatreFilter = "AINALRAM-BELT-1"
    let shown = state.visibleDirectives([
        directiveFixture(id: "A", theatreDepot: "AINALRAM-BELT-1"),
        directiveFixture(id: "B", theatreDepot: "DENEBED-BELT-1"),
        directiveFixture(id: "C", theatreDepot: nil),
    ])

    #expect(shown.map(\.id) == ["A", "C"])
}
```

The last expectation is a deliberate product decision: an unassigned row is visible under every filter, because a row nobody owns is exactly the one that must not be filtered out of sight.

- [ ] **Step 2: Run and confirm it fails**

```bash
cd app/Modules && swift test --filter WhyViewTheatreTests --event-stream-output-path /tmp/t14.json
```

- [ ] **Step 3: Group the why-view**

Replace the single hub line at `BrainWhyView.swift:610` with a group per theatre. The existing goal-line builders (`launchedSurveyLine` and its siblings around `:367-399`) already take their focus as a parameter — pass the theatre's depot rather than the world's hub, and the line text needs no change.

- [ ] **Step 4: Add the theatre to the directive row and the filter**

Monospace token for the depot. The filter is a picker over the recognised theatres plus "All".

- [ ] **Step 5: Check both colour schemes, run the suite, commit**

```bash
cd app/Modules && swift test --event-stream-output-path /tmp/t14-all.json
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/DirectivesFeature/Sources
git add app/Modules/DirectivesFeature
git commit -m "feat(theatre): directives and the why-view are grouped by theatre"
```

- [ ] **Step 6: Write the memory note**

This is the last ticket, so record what the effort learned in `app/.claude/memory/` as one fact per file with a matching `MEMORY.md` index line. At minimum:

- **`theatre-recognition-model`** — theatres are recognised, never placed; the three tiers and why `.operational` gates rule 3; identity is the depot location.
- **`theatre-component-vs-distance`** — inward filters by component, outward ranks by distance; the live mesh is a single component, so the filter guards only genuinely unreachable pockets.
- **`haul-round-trip-ranking`** — the ranking change, `secondsPerLy` still uncalibrated, and that the raw-units order is its fallback.

Delete the corresponding claims from `brain-resource-hub-model`'s "single hub this effort" line, or amend it to point here — leaving it unamended makes the next reader believe multi-hub is still deferred.
