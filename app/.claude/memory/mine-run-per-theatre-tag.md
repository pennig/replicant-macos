The 2026-08-12 final-review fix: `Brain.ensureMine` stamped every `mineRun`
DIRECTIVE with the bare `MineRecipe.fleetTag` ("auto:mine") — Task 9 gave
survey/salvage/haul per-theatre tags but never revisited mine, "the fourth".
Since `reservedDevices` sweeps every device wearing a live directive's
`fleetTag` account-wide, one theatre's live install reserved every OTHER
theatre's `auto:mine`-tagged devices too — including an already-installed,
independent belt's own transport controller, which `Brain.mineFerryController`
then read as unavailable. Fixed by `MineRecipe.fleetTag(forTheatre:)`
(mirrors `SurveyRun.fleetTag(forTheatre:)`) stamped at `Brain.swift:475`.
Safe because `MineRun`'s OWN fleet queries never read `directive.fleetTag` —
they always resolve the bare recipe tag directly, hub-scoped by construction
— so retagging the directive costs nothing there; the fleet actually carried
by a live install stays protected via the transitive stow/attach closure in
`reservedDevices`, independent of the tag-matching clause.
