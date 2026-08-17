# 24 — `TravelTo`: the travel frame and the arrival watermark

Type: task
Status: open
Blocked by: 20
Labels: directives-architecture, stage-2

Moves `lastTravelCompletion` and `travelPositionUnconfirmed` off `SalvageRun` — **the single most-borrowed member in the engine**, 4 caller files and 11 sites — and wraps the frame around them.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 5.

The measured shape contradicts the spec's assumption: **11 of the 13 travel sites dispatch into their own step**, with no confirming step and no flight deadline. Only `MineRun.swift:355` and `EventRun.swift:510` have the dispatch/confirm pair. So `confirmStep` is `String?` and nil — the same-step loop — is the default case, not the exception.

`SalvageRun.arrivalConfirmDeadline` (`:76`) and `arrivalReadInterval` (`:80`) move to `TravelTo`. `MineRun.swift:50` aliases the first and `SalvageRun.swift:956` reads the second — repoint both.

---

- [ ] **Step 1:** Write `Tests/Steps/TravelToTests.swift`: both arrival tests (a location is a SITE — `SOL-3` is in `SOL`), the same-step loop, the named confirm step, the open-op wait, the row-predating-its-arrival read, **deadline before read**, and that only a `.completed` travel is a watermark (`.superseded` also stamps `lastConfirmedAt` on travels that never arrived).
- [ ] **Step 2:** Confirm the build fails.
- [ ] **Step 3:** Write `Sources/Steps/TravelTo.swift`.
- [ ] **Step 4:** Delete `SalvageRun.swift:292-334` and the two constants; repoint the two aliases. The 13 call sites break — land this with ticket 25 in one green commit, or fix them there. **The branch must not be left red.**
- [ ] **Step 5:** `swift test --filter TravelToTests`; `check-comments.sh`; commit.

**Done when:** nine tests green and `travelPositionUnconfirmed` exists in exactly one file.
