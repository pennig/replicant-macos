# Typed SSE Event Payloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deepen the SSE event-stream fold from scattered, stringly-typed `payload["x"]` extraction into one uniform, type-safe shape — a `…EventPayload` value per extracting event, decoded through a shared `Utils` reader, with persistence folds consuming the typed value. This makes "what else does this event carry that we're ignoring?" an answerable, reviewable question, and lands one concrete read-elimination on top: **discovery-seeding**.

**Architecture:** Generalize the pattern `SalvageEventPayload`/`BobnetMessage` already prove. Every stream event that extracts named fields gets exactly one standalone `…EventPayload` struct with `parse(from: [String: JSONValue]) -> Self?`, co-located with its ingestion owner; no route pokes `JSONValue` by key directly (all key access goes through a `Utils` reader). The one **behavior change** in the whole effort is `event.discovered`: it carries the full quest shape (title/description/criteria/rewards/tier — the existing route comment claiming otherwise is stale), so the route **seeds a complete quest row** instead of paying a full `accounts/events` walk. Progress can only be deferred, not avoided — it rides the existing `refreshOpenLocationEvents` (post-deposit) / `travel.arrived` triggers — so seeding is safe.

**Tech Stack:** Swift 6 / SwiftUI, SPM package rooted at `app/Modules`, GRDB via SQLiteData (`@Table`), Point-Free `Dependencies` + `swift-composable-architecture` (feature tier only), Swift Testing (`@Test`/`#expect`) with the JSON event stream, `os.Logger`.

## Global Constraints

- **Additive only. No new SPM module.** Each `…EventPayload` value lands beside its ingestion owner in an existing module; the `Utils` reader extends the `Utils` target. No `.xcodeproj`/pbxproj edits.
- **No migration.** `LocationEvent.seeding` writes existing columns + the `detail` blob only. Nothing schema-touching; `SchemaManifestTests`/`GoldenSchemaTests` untouched.
- **Scope edge = the SSE event stream only** (locked). REST-response decoders (`LocationEvent.merging`, `LocationEventDetail`, census/locations/mesh DTOs) are explicitly OUT of scope. The `Utils` reader is available to them but this pass does not touch them.
- **One uniform shape (locked).** Every extracting event → exactly one standalone `…EventPayload` with `parse(from:) -> Self?`. Persistence/model folds consume the typed value, **never** a raw `[String: JSONValue]`. No parse-on-the-model shortcuts (BobnetMessage's inline parse is migrated to this shape).
- **No direct stream-payload poking left in `Sources`.** After the sweep, a grep for `event.payload?[` / `payload["` in stream-ingestion `Sources` returns only the documented opaque blob-store. All key access is via the `Utils` reader.
- **Deliberately-opaque store stays opaque, documented.** `Reconciler.swift:337` stores the whole payload verbatim as `detail.result` — that is not extraction; leave it, and add a one-line comment saying so.
- **Replay-safe folds.** A replayed event (catch-up / gap-repair) must never downgrade live state. `seeding` only ever creates/fills-if-blank and translates `criteria` → a **zero-progress** `progress` block; it never overwrites an existing `progress`.
- **Never silently lose a quest.** `event.discovered` seeds if the payload parses; it falls back to the `accounts/events` invalidate ONLY when the payload is unparseable. `scan.completed` keeps its existing `.locationEvents` nudge (a scan-revealed quest still needs the read).
- **No catalog artifact.** A typed payload existing *is* the "we fold" signal; drift is caught by fixture tests, not a registry.
- **Testing convention.** Pure `parse` tested with fixtures captured verbatim from live payloads (the confirmed `STELLA-3-EVT-002` discovery payload is fixture #1). Folds tested through the model; route behavior tested without the live stream.
- **LSP hygiene (per `app/CLAUDE.md`):** before signing off any task, `cd app/Modules && swift build --build-tests` then `./scripts/link-index-store.sh`, and query Swift-LSP — treating an empty `findReferences` on same-session code as a cold index, not proof of no callers.
- **Run tests via the event stream**, never by scraping console text — use the `swift-test-event-stream` skill.
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category = the module/service name.
- **Commits:** per-family, directly to local `main` (no PRs, no origin).

## The complete site inventory (defines "done")

Stream-payload extraction sites the sweep must convert:

| Family | Site | Keys |
|---|---|---|
| LocationEvents (flagship) | `LocationEventsIngestion.swift:85`, `LocationEvent.completing` (`:173-180`) | designation, location, event_type, tier, rewards, consumed, **+ new** criteria/title/description via discovery |
| Bobnet | `BobnetMessage.swift:60-70` (already typed — migrate to standalone value) | id, time, replicant_name/code, current_star, channel, message |
| Device | `GameSync.swift:333` / `:391` | new_device_code, stowed_in_device_code |
| Experience | `AccountIngestion.swift:78,99` | amount, source |
| Directive | `DirectiveIngestion.swift:51` / `:81` / `:38`; `LocationsIngestion.swift:195` | directive, devices_deployed |
| Locations | `LocationsClient.swift:234` (result) + survey-digest; `LocationEventPolicy.swift:103-120` | result block; location/star |
| Salvage | `SalvageEventPayload.swift` | already conforms — the reference model |

Opaque (leave, document): `Reconciler.swift:337` `detail.result`.

---

## Tasks

### Task 1 — The shared `Utils` reader
- [ ] Add keyed accessors on `[String: JSONValue]` in `Utils` (`Utils/Sources/`), encoding the empty-string→nil trap once: `nonEmptyString(_:)`, `double(_:)`, `int(_:)`, `bool(_:)`, `object(_:)`, `doubleMap(_:)` (a `{k: number}` → `[String: Double]`), `array(_:)`. Signatures returning Optionals; missing/wrong-type → nil.
- [ ] Tests in `Utils/Tests` covering each accessor incl. the empty-string case and wrong-type case.

### Task 2 — Flagship A: the LocationEvents payloads
- [ ] `DiscoveredEventPayload` in `GameModels` (beside `LocationEvent`): designation (required — nil without it), location, locationName?, title, description, eventType, category?, tier, criteria (options → resource/device *required* targets), rewards. Parse via the Task 1 reader.
- [ ] `CompletedEventPayload` in `GameModels`: designation (required), location?, eventType?, tier?, rewards?, consumed?.
- [ ] Fixture tests: `DiscoveredEventPayload` against the captured `STELLA-3-EVT-002` payload; `CompletedEventPayload` against a captured completion payload.

### Task 3 — Flagship B: `LocationEvent.seeding` + route rewire
- [ ] `LocationEvent.seeding(_ p: DiscoveredEventPayload, now:)` — sibling to `merging`/`completing`. Create-or-fill-if-blank the summary columns; translate `criteria` → a zero-progress `progress` block in `detail` (each requirement `current: 0`, `met: false`); preserve `firstSeenAt`; **never** overwrite an existing non-zero `progress`.
- [ ] Rewire `LocationEvent.completing` to take `CompletedEventPayload` (not a raw dict).
- [ ] Rewire `LocationEventsIngestion.eventRoute`: on `event.discovered`, parse → `seeding` (no invalidate); fall back to `invalidate(.locationEvents)` only when parse fails. Keep the `scan.completed` nudge. Rewire `completedRoute` to build `CompletedEventPayload`.
- [ ] Correct the stale comment (`LocationEventsIngestion.swift:63-64`): discovery DOES carry criteria + full shape; what it lacks is live `progress`, deferred to existing triggers.
- [ ] Tests: seed renders a complete row with zero-progress; replayed discovery does not downgrade progress; unparseable discovery falls back to the read; a seeded row satisfies `refreshOpenLocationEvents`' `status == active` gate.

### Task 4 — Sweep: Bobnet
- [ ] `BobnetEventPayload` in `GameModels` (standalone value); `BobnetMessage.init(_ p: BobnetEventPayload)` consumes it. Remove the inline parse from `BobnetMessage`. Reader-based. Tests migrated/added.

### Task 5 — Sweep: Device
- [ ] `PrintCompletedPayload` (new_device_code) and `DeviceStowedPayload` (stowed_in_device_code) in `GameSync/Sources`; rewire `GameSync.deviceRoute` (`:333`) and the stow fold (`:391`). Preserve the `⚠️ device.stowed WITHOUT stowed_in_device_code` notice. Behavior-identical. Tests.

### Task 6 — Sweep: Experience
- [ ] `ExperienceGainedPayload` (amount, source) in `AccountManager/Sources`; rewire `AccountIngestion.swift:78,99`. Behavior-identical (`.stream`-only credit unchanged). Tests.

### Task 7 — Sweep: Directive
- [ ] `DirectiveCompletedPayload` (directive) and `AMILaunchedPayload` (devices_deployed) in `DirectiveEngine/Sources`; rewire `DirectiveIngestion.swift:51,81` and the diagnostic at `:38`. Reuse `DirectiveCompletedPayload` for the `survey_system` cross-check at `LocationsIngestion.swift:195`. Behavior-identical (incl. the "deployed nothing" early-out). Tests.

### Task 8 — Sweep: Locations
- [ ] Normalize the `scan.completed` result extraction (`LocationsClient.swift:234`) and the survey-digest scans path, plus `LocationEventPolicy.swift:103-120` (location/star), to reader-based typed payloads. Behavior-identical. Tests.

### Task 9 — Completeness gate + opaque-store doc
- [ ] Add the one-line "intentionally opaque blob-store" comment at `Reconciler.swift:337`.
- [ ] Prove the migration is complete: grep stream-ingestion `Sources` for `event.payload?[` / direct `payload["`; the only remaining hit is the documented `Reconciler` blob. Fix any stragglers.
- [ ] Full `swift build --build-tests` + full test run green (via the event stream). Update the `event-stream-migration` / `event-log-feature` memory notes if any taxonomy fact shifted.

---

## Sequencing rationale

Task 1 lands the shared vocabulary. Tasks 2–3 land the **flagship** — proving the pattern *and* delivering the discovery read-cut + instant render. Tasks 4–8 apply the identical shape to every remaining family so nothing is left mixed. Task 9 gates completeness. Each task is an independent, behavior-preserving commit except Task 3 (the one intended behavior change).
