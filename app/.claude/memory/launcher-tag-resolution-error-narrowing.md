The 2026-08-12 final-review fix, in `NewDirectiveFeature`/`NewHaulRunFeature`/
`NewSalvageRunFeature`'s `launchTapped`: all three wrapped their theatre-tag
resolution in `try?`, so a genuine `database.read`/`WorldView.read` FAILURE
and the ordinary "this vessel resolves no theatre" case (a stowed or
in-transit vessel — ordinary, not an error) both silently produced the same
bare-tag fallback with no way to tell which happened from the log. Fixed by
replacing `try?` with `do`/`catch`: the legitimate no-theatre guard still logs
`.notice` and falls back to the bare tag from INSIDE the read closure; a
genuine throw is now caught separately and logged `.error` before falling
back to the same tag value. The stamped tag is unchanged either way (it must
never be nil — see `reservedDevices`' tag sweep) — this is a diagnostics-only
fix with no new assertable behavior in the persisted directive, so it carries
no new automated test beyond the pre-existing tag-value coverage.
