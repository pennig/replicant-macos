---
name: location-events-feature
description: "LocationEventsFeature (Location Events \"quest log\") — module, data source, and the accounts/events endpoint facts."
metadata: 
  node_type: memory
  type: project
  originSessionId: 54ee8278-c941-48d2-9101-7af4f76e0513
---

Location Events = a top-level "Missions" sidebar category (a quest log). Discovered location events are calls-for-help sited at a location with tiered rewards fulfilled by delivering resources/devices.

- **Authoritative source: `GET /v1/accounts/events?status=all`** — returns the whole account's discovered events *with full detail* (criteria, live per-resource/-device progress, rewards) in one paged (`next_cursor`) call. This is the account-wide list, not per-location. `locations/{code}/events` is the per-location variant — and its GET **lacks a `200` in openapi.json** (only 422/default), so it's undecodable via the generated client without a spec patch; accounts/events has a proper 200 so no patch was needed. See [[openapi-spec-drift-leniency]].
- **`LocationEvent` @Table lives in GameModels** (beside [[replicants-feature]]'s KnownReplicant) — so SidebarFeature's badge query needs no new dep. Summary columns + full raw payload in `detail: JSONValue`; `LocationEventDetail(_:)` decodes the quest (progress/rewards) on demand.
- **`LocationEventsClient` (GameServices)**: `refresh()` walks accounts/events and upserts — mirrors `ReplicantsClient.refresh`. Reused by the feature `.task` and by a relay route (`ReplicantApp.registerGameSync`, type "event", triggers on `location_event`/`scan_complete`) as an authoritative re-read + gap-repair, exactly like the Messages inbox.
- **UI**: `LocationEventsFeature` module (reducer + list + full quest-sheet detail). `@FetchAll` list in [[list-feature-query-in-state]] style.
- Same change renamed the old **Event Log → "Operations Log"** and moved it into the Operations group (it reads the Operation table; `SidebarItem.eventLog` → `.operationsLog`).
- **Completion flow (added)**: an event whose objectives are met while still open reads as **Ready** (its own green tone), not Active. Backing = a denormalised `LocationEvent.objectivesMet: Bool` column (2nd migration, ALTER ADD COLUMN), set in `merging` from `detail.progress.met`; computed `isReady = isActive && objectivesMet` and `displayStatus` (`ready` vs raw status). `DeviceStatus.tone(for:)` maps `"ready"` → `.ready`. Row + detail badges use `displayStatus`; list orders ready-first (`status.asc, objectivesMet.desc, tier.desc`).
- **Complete button**: detail pane shows a primary "Complete Event" CTA when `isReady` → `LocationEventsClient.complete(location, designation)` does an **empty POST** `postV1LocationsLocationCodeEventsDesignation` (endpoint docs only a `default` response, so success and error both land in `.default(statusCode,_)` — split on 2xx; error message from the flask ErrorSchema `message`), then re-pulls the list. `LocationEventError` carries the server message to the feature banner.
- **Sidebar badge** = the [[sidebar-feature]] dual-pill (same shape as Messages story/unread): accent pill = ready count (`status=active && objectivesMet`), plain `+N` = remaining active. `SidebarView.accentCount(for:)` generalised the messages-only path.
- **Unload cross-reference**: `CommandClient` immediate-success path, after a `depositResources` (unload) device read, counts open `LocationEvent`s at the device's location and calls `locationEventsClient.refresh()` if any — so a now-ready event surfaces without opening Locations.
