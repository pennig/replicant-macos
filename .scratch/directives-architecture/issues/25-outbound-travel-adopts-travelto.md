# 25 — The nine outbound travel sites adopt `TravelTo`

Type: task
Status: open
Blocked by: 24
Labels: directives-architecture, stage-2

`SalvageRun:350`, `:491`; `SurveyRun:567`; `MineRun:355`; `RelayRun:570`, `:756`, `:808`; `EventRun:497`, `:510`. Each keeps its own arrival destination, pre-guards and stalls; what goes is the identical guard triple and the `.dispatch` literal.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 6 carries the per-site table and the three special cases in full.

**Use the UNOWNED guard** (`ctx.openOperation(for:)`). All 13 sites use it today; switching to owner-scoped would stop a co-tenant's op blocking travel, which is a real behaviour change and is not this ticket. It goes on the punch list in ticket 32.

**Every `.finished` branch takes whatever that site returns today, copied verbatim.** Do not re-derive a destination — read the line and move it.

Three sites are not plain returns: `RelayRun:756` forks on mesh membership after arriving, `RelayRun:808` runs the triple nested inside an `if` and continues past it to a `deploy`, and `EventRun:497` falls through to a second frame for the freighter.

---

- [ ] **Step 1:** Migrate the six plain sites (1, 2, 3, 4, 5, 9).
- [ ] **Step 2:** Migrate `RelayRun:756`, keeping the mesh fork and its `meshRaceLoss` warning.
- [ ] **Step 3:** Migrate `RelayRun:808`, keeping the three stalls above it where they are.
- [ ] **Step 4:** Migrate `EventRun:485-514`, both frames.
- [ ] **Step 5:** `grep` for `travelPositionUnconfirmed|lastTravelCompletion` — expect hits only inside `Steps/TravelTo.swift`, bar the two return-homes ticket 26 takes.
- [ ] **Step 6:** `swift test --filter DirectiveEngineTests` green with **no assertion edited**; `check-comments.sh`; commit.

**Done when:** nine sites carry no guard triple of their own and the whole target is green unedited.
