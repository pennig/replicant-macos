# The Survey Run buys its own system scan, and the error schema that hid why

The 2026-08-10 LAONROCK stall. The drones surveyed all 5 planets and 7 moons,
`directive.completed` arrived, and `confirming` stalled `surveyIncomplete` —
correctly, on its own terms: `GET locations/LAONROCK` came back in the SMALL
unscanned shape, which carries **no `planets_scanned` / `planets_total` at all**
(`planets: []`, `system_scanned: false`, plus `explored` / `estimated_planets` /
`has_hub` inside `star`). `StarSystem.isFullyScanned` reads nil counts as not
scanned, so the run had nothing to confirm against.

Those counts appear only once `POST /v1/replicants/{code}/scan` has run, and the
survey drones scan BODIES, never the system. Nothing in `SurveyRun` called it.
The only automatic caller in the app was — and for the passive path still is —
`LocationsIngestion`'s `locations.scan` route: a 2-second-debounced
fire-and-forget behind `try?`, armed by a `travel.arrived` whose `deviceCode`
equals the replicant's `hostedDeviceCode`. One dropped call and the target is
permanently unconfirmable. **ULESATH 37 minutes earlier survived only because
its passive scan happened to succeed** — the run had no claim on it either way.

Two things made it unrecoverable rather than merely slow:

- **Retry was a structural no-op.** `confirm` judges `world.system(target)` — the
  cached blob — and issues no read; the only `.refreshSystem` sits in
  `awaitCompletion`, which a retry re-entering at `confirming` never reaches.
  Eight retries each re-stalled within five seconds.
- **The scan's failure was invisible.** `try?` at the ingestion site swallows it
  with no log, so the one call that mattered left no trace anywhere.

## The error schema that hid the trigger

Three `post/v1/devices/{device_code}` calls failed in the same 23 seconds
(22:06:25 / :32 / :48, two different directives), all reading
`DecodingError.dataCorrupted … Path: error … Additional properties are disabled,
but found 1 unknown keys`. **`Path:` names the REJECTED KEY, not a nesting
path** — swift-openapi-runtime builds it with `dataCorruptedError(forKey:in:)`
(`CodableExtensions.swift:28`), so the unknown key is literally `error`.

The culprit is `flask_smorest_error_handler_ErrorSchema`, the body behind
`components/responses/DEFAULT_ERROR` — i.e. the `default` catch-all carried by
**89 operations**, including both the device POST and the replicant scan. It
declares `{code, status, message, errors}` with `additionalProperties: false`
and no `error`, while the API really sends `{"error": "…"}` (which
`app_schemas_common_ErrorSchema`, used for the DECLARED 4xx, documents). So any
UNDECLARED status — 429, 500, 503 — throws a decode error instead of surfacing
the status, on every one of those operations.

**Not a v2.5.0 regression.** That schema is byte-identical in
`openapi-2.3.3-edits.json` and `openapi-2.5.0-edits.json`, as are
`LocationResponseSchema` and `SystemScanResponseSchema`; the whole device-POST
diff across the upgrade is a `triangulate` case added to the request-body
`oneOf`. Patched per [openapi-spec-drift-leniency](openapi-spec-drift-leniency.md)
with one targeted nullable `error: string`, not by relaxing strictness.

## The fix

`SurveyRun` gained a `scanning` step and `MissionAction.scanSystem(designation:
nextStep:)`. When `confirming` sees a claimed completion whose target has
`planetsTotal == nil`, it routes to `scanning` rather than stalling; the
executor resolves a `Replicant` whose `currentStar` equals the designation and
calls `LocationsClient.scanAndPersist`, best-effort like `.refreshSystem`.

Three things worth keeping:

- **The discriminator is `planetsTotal == nil`, never `systemScanned == false`.**
  `StarSystem.systemScanned` defaults to `false`, so gating on it would reroute
  every existing half-surveyed fixture. Absent counts and short counts are
  different facts: short counts are a real contradiction no re-scan changes, and
  they must still stall.
- **The loop bound comes off the log, not `stepStartedAt`.** A self-targeting
  refresh is the `RelayRun.acquire` trap — `DirectiveExecutor.move` re-stamps on
  every hop, so a freshness gate keyed on it hammers the API forever.
  `MissionLogBudget.dispatchRounds(dispatch: scanning, confirm: confirming)`
  bounds it at `scanRounds = 3`.
- **A retry now buys something.** `dispatchRounds` stops its walk on `.resolved`,
  so the Retry the operator presses re-arms the whole scan budget instead of
  re-judging the same cached blob.

The executor gates on a replicant standing IN the target system because the
endpoint scans the replicant's own system — calling it from elsewhere would
persist a different system and leave the target exactly as unconfirmable. A
survey vessel that hosts no replicant therefore still cannot self-heal; it logs
and stalls. Closing that needs a survey-fleet change, not an engine one.

Still open: the passive path's `try?` at `LocationsIngestion.swift:143` remains
silent. It has `DecodingDiagnostics` available and uses none of it.
