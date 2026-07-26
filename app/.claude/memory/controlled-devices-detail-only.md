---
name: controlled-devices-detail-only
description: "controlled_devices ships only in GET devices/{code}, never in the fleet-wide GET devices — read adoption from the drone's controller_device_code column instead"
metadata:
  node_type: memory
  type: reference
---

`controlled_devices` — an AMI controller's list of adopted devices — is returned
**only by the single-device endpoint** `GET devices/{code}`. The fleet-wide
`GET devices` omits the key entirely. Verified against the live API 2026-07-26:
the list payload for `E45C43AB` (ami_survey_controller) carries
`available_directives` but has no `controlled_devices`; the detail payload for
the same device carries both.

Consequence, and it bit us: `Device.controlledDevices` / `controlledDeviceCodes`
read that key out of the `detail` blob, so they are **empty for any controller
synced from the list** — which is the normal state. Worse, it is not sticky:
`DevicesClient.fetchAll` builds a whole `Device` per row and the upsert replaces
`detail` wholesale, so a routine fleet sync *erases* the adoption list a previous
inspector read had stored.

**Read adoption from the drone's end instead.** `controller_device_code` is a
promoted typed column (`Device.controllerDeviceCode`), present in every payload
including the list, and it survives stowing (the docs confirm you can "adopt,
release and set directives while your devices are stowed in your vessel, then
launch the controller"). `SurveyRun.adoptedDrones` now accepts either end of the
link — the drone's column, or the controller's `controlled_devices` when a
detail read happens to have populated it.

Safe consumers are the ones reached from the **device inspector**, which does a
per-device read on selection: the adopt/release pickers in
`DevicesFeature/CommandGrid.swift` and the location fallback in
`DirectiveComposer`. Still affected: `DirectiveRow` (built-in directive rows show
a controller's controlled-device count/list, which under-reports for a
list-synced controller). See [[directives-feature]].
