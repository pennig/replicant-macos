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
including the list, and it survives stowing — confirmed directly on the live
fleet: vessel `F2908E6E` at AMEDIOHA-3-L4 held controller `B2CBDEC6` plus six
survey drones all stowed, every drone reporting `controller_device_code:
"B2CBDEC6"` while the controller's own row had no `controlled_devices` at all. `SurveyRun.adoptedDrones` now accepts either end of the
link — the drone's column, or the controller's `controlled_devices` when a
detail read happens to have populated it.

`DeviceAdoption` (in `DevicesFeature`) is now the one place the union is taken —
`adopted(by:fleet:)` merges the controller's tail with every fleet row naming it,
`controller(of:fleet:)` reads the drone's column. The inspector's "Adopted
Devices" / "Adopted By" cards and both `CommandAvailability` pickers read it, so
they no longer depend on a detail read having landed. Prefer it over
`Device.controlledDevices` at any new call site.

The inspector's per-device read on selection used to be what made the adopt and
release pickers correct; it is no longer load-bearing for them. Still affected:
`DirectiveRow` (built-in directive rows show a controller's controlled-device
count/list, which under-reports for a list-synced controller) — it reads
`device.controlledDevices` directly and has no fleet in hand. See
[[directives-feature]].
