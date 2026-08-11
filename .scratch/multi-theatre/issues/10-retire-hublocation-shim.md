# 10 — Retire the hubLocation shim

Type: task
Status: open
Blocked by: 06, 07, 08, 09
Labels: multi-theatre

Delete `WorldView.hubLocation`. This ticket is the proof that nothing depends on a single global hub any more, and it must not be folded into an earlier one — the shim is what let tickets 04–09 land without touching ~335 tests, and only removing it shows whether they actually did the work.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/WorldView.swift` (remove the property and the synthesising initialiser branch)
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift` (`:86`, `:99`, `:132`, `:358`, `:387`, `:399`, `:430`, `:442`, `:632-634`, `:1109-1111`, `:1167`, `:1207`, `:1229`, `:1289`, `:1333`, `:1367`)
- Modify: `app/Modules/DirectiveEngine/Sources/BrainReport.swift` (`:286`, `:315`, `:327`)
- Modify: every test fixture passing `hubLocation:`
- Test: the existing suite is the test

**Interfaces:**
- Removes: `WorldView.hubLocation`, `WorldView.hubLocation(in:meshSystems:stockByLocation:)` (`:275`), `BrainReport.hubLocation`.
- Produces: `BrainReport.theatres: [Theatre]` in place of the single `hubLocation`, so the why-view can group.

---

- [ ] **Step 1: Enumerate the call sites with a warm index**

```bash
cd app/Modules && swift build --build-tests && ./scripts/link-index-store.sh
```

Then use Swift-LSP `findReferences` on `hubLocation`. An empty result here would be a cold index, not an absence — the build above is what makes the answer trustworthy. Cross-check the count against the sites listed in the spec's call-site table.

- [ ] **Step 2: Delete the property and watch the compiler enumerate the work**

Remove `hubLocation` from `WorldView`'s stored properties, its initialiser, and the synthesising branch added in ticket 04. Remove the static `hubLocation(in:meshSystems:stockByLocation:)` — `TheatreRegistry` now owns that rule.

```bash
cd app/Modules && swift build --build-tests 2>&1 | tee /tmp/t10-errors.txt
```

Every error is one site to migrate. This list is the task.

- [ ] **Step 3: Migrate each Brain site**

Each falls into one of three shapes:

- **Reads the hub to launch a goal** (`:358`, `:387`, `:430`, `:442`, `:1229`, `:1289`) — already inside a per-theatre loop after ticket 06. Use the loop's theatre.
- **Reads the hub to report** (`:132`, `:1333`, and `BrainReport`) — carry `view.theatres` and let the why-view group (ticket 14).
- **Guards on the hub existing** (`:632-634`, `:1109-1111`, `:1167`, `:1207`) — becomes "this theatre is operational", which the loop has already established. Delete the guard rather than rewriting it, and check what its `else` branch reported: an idle reason like `"no recognised hub"` becomes `"no operational theatre"`.

`MineRecipe.installedBelts(in:hub:)` (`:399`, `:1367`) takes a hub location; give it the theatre's depot from the enclosing loop.

- [ ] **Step 4: Migrate the test fixtures**

Fixtures passing `hubLocation: "AINALRAM-BELT-1"` become `theatres: [Theatre(depot: "AINALRAM-BELT-1", …, readiness: .operational, …)]` plus a `components:` entry for that system. Consider a single test helper — `singleTheatreView(depot:)` — rather than editing each fixture by hand, and put it somewhere every test target can reach.

A fixture passing `hubLocation: nil` becomes `theatres: []`.

- [ ] **Step 5: Run the whole suite**

```bash
cd app/Modules && swift test --event-stream-output-path /tmp/t10-all.json
```

Expected: the same passing count as before ticket 01, plus every test added by tickets 01–09. **A test whose expectation had to change to make it pass is a finding, not a chore** — write it down and raise it before editing, because it means one of the earlier tickets changed behaviour it was not supposed to.

- [ ] **Step 6: Confirm nothing survives**

```bash
cd app/Modules && grep -rn "hubLocation" Sources Tests || echo "clean"
```

Expected: `clean`. This grep is a completeness check on a symbol that should no longer exist, which is the one job grep is better at than the index.

- [ ] **Step 7: Commit**

```bash
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources
git add app/Modules/DirectiveEngine
git commit -m "refactor(theatre): retire hubLocation; theatres are the only rule"
```
