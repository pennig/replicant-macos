# Survey Run fleet tag — the silent no-repair regression (FIXED 2026-08-09)

The exact incident [[salvage-fleet-repair-build]]'s residual predicted. `abd5f88`
(2026-08-07 00:09) made `RepairFleet.answers` refuse a tagged bot to a nil owner
and threaded the owner through `SalvageRun` only; the survey bots were then
tagged `auto:survey`, and from **2026-08-07 05:14** every `SurveyRun` repair
phase saw an empty fleet and fell through in ~5 s per target — bots never
deployed, drones ran unrepaired for two days, and nothing stalled because quiet
degradation on a botless vessel is the designed path. The directive log is the
diagnostic shape to remember: `deployingBots`/`repairing`/`stowingBots` each
kept logging `stepStarted` every target (83+) while `commandDispatched` on the
confirm pairs froze at the tag moment.

**Not a brain regression**, though it read like one: the brain takeover
(`1d8a0aa`, same day) touched no repair code, and the brain-launched run entered
every repair step faithfully. The tell-apart: a missing *step* is a machine
regression; a step that enters and instantly advances is an empty *query*.

Fix (this branch): `SurveyRun.defaultFleetTag = "auto:survey"` +
`fleetTag(_:)` falling back to it (so the live nil-`fleetTag` row heals on
Retry with no row surgery), `owner:` threaded through all 15 fleet-scoped
`RepairFleet` call sites, `Brain.ensureSurvey` stamps the tag on launch and
`Brain.surveyCarrierTag` now aliases the constant, and `answers` compares both
sides through `Device.normalizedTag` (a case-drifted tag previously escaped the
`auto:` prefix filter and read as *untagged*, answering everyone — the worse
direction of the same bug).

Residual: any future mission that carries bots must pass an owner from day one —
`answers`'s nil-owner = refuse-tagged contract makes an owner-less caller wrong
the moment its bots are tagged, and quiet repair-phase degradation means the
failure will again be silent.

Amended 2026-08-17: `RepairFleet.answers` is no longer root-tolerant upward — a bot wearing a scoped tag answers that theatre alone, never a bare-tagged owner — see `.scratch/directives-architecture/issues/12-scoped-tag-outranks-location.md`.
