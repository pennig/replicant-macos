# Research: device delivery/hand-off + control-range/tag mechanics

Type: research
Status: resolved
Blocked by:
Labels: wayfinder:ticket

## Question

What are the live mechanics of delivering a device and knowing what the brain can command?

Grounds the `deliver` primitive (05), the ownership/seam ticket (04), and the world model
(01). **GET-only is safe; do NOT mutate the live account.**

Answer, with citations:
- **Delivery / hand-off.** To place a device (relay, drone, service bot) at a target: stow
  → travel → deploy → activate — confirm the real sequence and the events that mark each
  step (see [[device-command-shapes]], [[travel-block-leg-vs-route]]). How does command
  authority transfer/attach on arrival ([[ftl-authority-rule]])?
- **`in_control_range`.** It's in openapi.json and the generated client but read by nothing
  ([[device-tags-and-control-range]]). What does it actually report, and can the brain use
  it as a cheap "can I command this?" signal instead of recomputing the mesh?
- **Tags as addressing.** `GET devices/tags/{tag}` is fleet-wide and sees stowed/travelling
  devices `?location=` cannot. How far can tag-based addressing take a tag-driven,
  non-AMI automation (the deferred thread in [[salvage-run-design]])? What does it cost
  vs an AMI controller (which runs server-side, free of the actions budget)?
- **Delivery targets.** How is a Lagrange point / L4 / event site addressed as a travel
  destination (relay+beacon emplacement thread)?

Write findings to `.scratch/automation-brain/research/09-delivery-control-mechanics.md` and
link here. Use `probe-api` + `/research`; consult https://replicant.space/docs/.

## Answer

Findings: [`research/09-delivery-control-mechanics.md`](../research/09-delivery-control-mechanics.md)
(GET-only live probes 2026-07-31 + docs + openapi + memory; no mutation).

- **Delivery** has two live patterns: the cradle path `stow → travel → deploy → activate` (self-mobile
  cargo, the salvage/relay fleet) and the surge path `attach → travel → detach` (+ compact/unfurl).
  Events: `device.stowed`; per-leg `device_cruise_arrived` then final `device_travel_arrived`
  (single-leg emits cruise only); `device.deployed`; activate is device-quiet. Authority does **not**
  hand off per-device — activating a relay at a system's L4 is what meshes the system.
- **`in_control_range`** is the server's authoritative "can I command this now" bool on both schemas,
  already decoded/read by the app. Live: `false` for a device in transit AND for a stationary device
  in an unmeshed system (SOL-3 beacon); per-device (cargo reads `true` inside a `false` carrier). The
  brain should read it, not recompute the mesh; never gate on the mover's flag; `available_commands`
  is NOT range-filtered.
- **Tags** (`GET devices/tags/{tag}`, account-wide, sees stowed/travelling) supply an AMI controller's
  *addressing* but not its *coordination* — AMI runs server-side free of the actions budget, so
  tag-driven non-AMI automation reliably finds its fleet but pays budget per command.
- **Lagrange/L4** is a first-class travel target (`<STAR>-<n>-L4`, `location_type:"lagrange"`); event
  emplacement = relay at the L4 (meshes the system) + beacon at the site.
