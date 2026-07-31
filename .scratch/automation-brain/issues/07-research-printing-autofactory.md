# Research: printing & autofactory mechanics + material costs

Type: research
Status: resolved
Blocked by:
Labels: wayfinder:ticket

## Question

How does printing actually work on the live API — inputs, costs, gating, and outputs?

Establish the ground facts the print/deliver/hub tickets (05, 06) and the auto-print build
depend on. **GET-only against the live API is safe; do NOT issue POST/PATCH/DELETE** — they
mutate the one live account. Prefer the docs site + openapi.json + read-only probes.

Answer, with citations:
- What device/feature gates `print`? What does a print request take (device type, quantity,
  location), and what does it return (enqueued op shape — see [[device-command-shapes]])?
- **Material cost.** What resources does printing a given device consume, and in what
  amounts? Where must the material be (location-bound)? What's the six-type relay bill
  referenced in [[salvage-run-design]]?
- **Autofactory.** What is an autofactory in this game, how is it supplied, and how does it
  differ from a plain `print`? What endpoints expose its state/queue?
- Print lifecycle: enqueue → complete events, and where the printed device appears
  (stockpile? stowed? at the printer's location?).

Write findings to `.scratch/automation-brain/research/07-printing-autofactory.md` and link
here. Use the `probe-api` and `/research` skills; consult https://replicant.space/docs/.

## Answer

Findings: [`research/07-printing-autofactory.md`](../research/07-printing-autofactory.md).

- **Gate:** the **`print` device feature**. Two surfaces — device command
  `POST devices/{code}` `enqueue_print` (autofactory + print vessels), and the replicant
  "internal printer" `POST replicants/{code}/print`. Only 4 types carry `print`: `autofactory`
  (`queue_size:10`, real queue) + `heaven_/racing_/cargo_vessel` (`queue_size:0`, single-job).
- **Material:** the blueprint `resources` map over the six types
  (carbon/silicates/structural/rares/conductive/volatiles), drawn from the printer's **location
  stockpile** (not cargo); short stock → `waiting_for {res:{need,have}}`. The six-type relay bill
  = `ftl_relay` = 370 units total.
- **Autofactory** = a `print`+`modular` device with a 10-slot managed queue, plus scrapping
  (~60% refund), blueprint discovery, and `oncomplete`/`controller`/`tags` auto-deploy; state
  lives entirely on `GET devices/{code}` (`queue_size`/`print_queue`/`printing`/`waiting_for`).
- **Lifecycle:** enqueue → `printing`/`print_queue` → `print_complete` event (carries
  `new_device_code`) → device **auto-deployed at the printer's location** (optionally adopted to a
  controller / running an `oncomplete` verb).
- **Drift:** `autofactory` never appears in openapi (blueprint value only); replicant-print's
  202/`enqueued` + `clear_queue`/`cancel` command responses are docs-only, unverifiable without a
  mutation. GET-only; no live mutations issued.
