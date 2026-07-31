# Research: location-event fulfilment endpoints + choice structure

Type: research
Status: resolved
Blocked by:
Labels: wayfinder:ticket

## Question

How are location events fulfilled on the live API, and how is the "choice of approach" expressed?

Location events are the one HITL seam: the brain surfaces the fulfilment approaches and
their tradeoffs, the operator picks. This research establishes what an event *is* on the
wire and what the fulfilment options structurally look like. **GET-only is safe; do NOT
mutate** — do not attempt to fulfil a real event.

Answer, with citations:
- What does a location event look like (`accounts/events`, `LocationEvent` — see
  [[location-events-feature]])? Which fields describe *requirements* (what it wants) vs
  *rewards*?
- **The choice.** Do events genuinely offer multiple fulfilment approaches, and is that
  structured in the payload or implicit in the game rules? What are the tradeoff axes
  (device types, quantities, delivery vs on-site action, time, cost)?
- What action fulfils an event — deliver a device/cargo, run a command, both? What
  confirms completion (`event.completed`, and note [[experience-and-completion-events]]:
  the completion event is display-only, XP is double-delivered)?
- What's the population like — how many events, how often, what variety? Enough to judge
  whether "few clicks" is a rare interrupt or a constant one.

Write findings to `.scratch/automation-brain/research/08-location-event-fulfilment.md` and
link here. Use `probe-api` + `/research`; consult https://replicant.space/docs/.

## Answer

Findings: [08-location-event-fulfilment.md](../research/08-location-event-fulfilment.md)
(GET-only live probe of `accounts/events`, 16 events; no mutation attempted).

An event's `criteria[]` holds its fulfilment *options* (devices+resources); `rewards` holds
gains; live `progress` (active events) mirrors options with `current`/`required` counters +
`met_option`. **The choice is real but a minority** — 11 of 16 events have a single
prescribed option, only 5 offer alternatives — and it's **structured in the `criteria`
payload, not selected by the fulfilment call**: you stage the devices/resources of one option
on-site and the server records which `met_option` you satisfied. Fulfilment = deliver on-site,
then an **empty POST** `locations/{code}/events/{designation}` (no body; resolver auto-picked
LIFO; needs a replicant present). Completion = `status→completed` + `completed_at`; the
`event.completed` stream event is display-only (XP double-*delivered* via `experience.gained`,
single-*credited*). Population is a rare bursty interrupt (~0.5/day, clustered, tiers 1–3, some
expire), so the HITL seam is occasional, not constant. Drift flagged: `criteria/rewards/progress`
untyped in openapi, `location_name` always null, per-location GET lacks a 200, resolve POST now
declares a 200 (memory notes said default-only).
