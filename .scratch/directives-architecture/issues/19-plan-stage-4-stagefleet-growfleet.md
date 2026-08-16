# 19 — Write the Stage 4 (StageFleet executor + growFleet, goal B) plan

Type: task
Status: open
Blocked by: 18
Labels: directives-architecture, stage-4, planning

The design is in `spec.md` §Stage 4. This ticket produces the plan and its tickets; no production code. Goal B — replicate vessels into new survey / salvage / relay runs with one or two clicks — is delivered by the build this plan describes. D3 is binding: the engine never dispatches `replicate`.

**Output:** `.scratch/directives-architecture/plan-stage-4.md` + tickets numbered after Stage 3's, `Labels: directives-architecture, stage-4`.

---

- [ ] **Step 1: Pin the facts the plan needs**

Record in `## Comments`: the current replicate UI flow and its entry point (`ReplicantsFeature` / `ReplicationEligibility` in `GameModels`; the source-matrix rule in `replication-source-matrix-feature.md`); `MineRecipe`'s shape and `MineRun`'s `adopting`/`confirmingAdopt` steps as they stand after Stage 2; `RelayRun`'s stow step (`StowOrAttach` after Stage 2); `EventCourierPrint`'s `.awaitingCourierReplication` stall and the stall panel's action surface (`DirectiveStallPanel`); the brain's readiness idle reasons (`SurveyReadiness.idle(...)` etc.) that will become growFleet demand.

- [ ] **Step 2: Invoke `superpowers:writing-plans`** against spec §Stage 4 with these constraints:

- `FleetRecipe` generalises `MineRecipe` (which becomes `FleetRecipe.mine`); recipes `survey`, `salvage`, `relayCarrier`, `mine`; each names `carrierType`, `carried`, `controllerType`, `adopts`, `tag: FleetTag.Goal`, `wantsReplicant: Bool`.
- New `DirectiveKind.stageFleet` + `StageFleetRun` machine composed from Stage 2/3 sub-machines: `PrintJob` per recipe line → `StowOrAttach` carried devices into the carrier → adopt (the `MineRun` shape) → `setDeviceTags` with the theatre-scoped tag → if `wantsReplicant`: `PrintJob(empty_replicant_matrix)`, `PrintJob(matrix_container)`, stow the cradle, stall `.awaitingCourierReplication` → on Retry confirm a replicant is hosted in the cradle → `.done`.
- HITL: `DirectiveStallPanel` gains a per-reason action; for `.awaitingCourierReplication` a **Replicate** button opens the existing replicate flow pre-filled with source = the original matrix's host, target = the cradle in this run's carrier. Two clicks total (button, confirm). D3.
- Brain `growFleet`: per theatre, when a readiness verdict idles for "no tagged vessel/controller" for ≥ N ticks (state N and why), launch one `stageFleet` for that recipe subject to the reserve rail; at most one `stageFleet` in flight per theatre; the staged carrier is then picked up by the existing `ensure*` on the next tick because it wears the scoped tag.
- New theatre: `TheatreSiteRanking` proposes; the operator pins (`EstablishTheatreSheet`); `growFleet` for a pinned-but-not-operational theatre stages a `relayCarrier` recipe at the nearest operational depot and the brain's tendMesh drives it toward the pin. State the gate that stops it launching for a pin the mesh cannot reach.
- Acceptance: from a fleet with one survey vessel, pinning a second theatre and clicking Replicate once results, without further clicks, in a second `auto:survey:<B>` vessel roaming from B within one print cycle + travel time; every intermediate stall reason is one the brain classifies `.retry` or one the panel offers a single action for.

- [ ] **Step 3: Self-review; stop for operator review.**
