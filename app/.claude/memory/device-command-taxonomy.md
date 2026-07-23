---
name: device-command-taxonomy
description: "Full device-command inventory (feature gates), live-roster coverage, Stage 4 folded all verbs in (detonate dropped), and the approved command-grouping + presentation plan for the DeviceDetailView command revamp."
metadata:
  node_type: memory
  type: reference
---

Probed the live account's full device roster (2026-07-22) to ground the DeviceDetailView command revamp. Roster: **32 devices, 14 types**. Complements [[device-command-shapes]] (response classes) and [[preview-sheet-item-not-ispresented]] (sheet dialect).

## Command inventory (string → feature gate → what it does)

Commands are surfaced per device by the backend's `available_commands`; each is gated by a device **feature** (or `device_type` for the hub). Groups render only when non-empty, so feature-gating falls out for free — no client-side feature checks needed.

- `travel` (cruise/surge), `recall` (cruise, "return + stow itself")
- `deploy` + `stow` (both `stow` feature — always appear/disappear together; grouped in Movement)
- `start_mining`, `retarget` (`mine`)
- `scan`, `search` (`survey`), `system_scan` (`system_scan`), `stellar_census` (`census`)
- `enqueue_print`, `dequeue_print`, `clear_queue` (`print`) — the three print-queue ops
- `set_directive`, `clear_directive`, `adopt`, `release`, `launch`, `withdraw`, `assemble` (`ami`)
- `attach`, `detach`, `configure` (`attach`/surge_plate; `configure` sets `taxi_mode`)
- `collect_resources`, `deposit_resources` (`transport`)
- `compact`, `unfurl` (`modular`)
- `activate` (`relay` + propulsors), `deactivate` (universal), `message` (`relay`, takes a message body)
- `replicate` (`cradle`/replicant_matrix)
- `repair` (`repair`/service_bot, takes a target device)
- `decommission` (`cruise` — **special**: only works in-system with an autofactory, which destroys the device and learns its blueprint)
- `set_entry_point`, `rename` (`system_hub` **only**)
- `change_owner` (universal admin — reassign device between replicants)

**`assemble`** (documentation found 2026-07-22) — brings all of a controller's adopted devices to the controller's own location. Present on all three AMI controllers *and* the service_bot (every `ami` device). Grouped under Control; confirm-only (no params).

## Coverage findings

The roster exercises nearly the whole surface. **Uncovered** (no owned device offers them): `set_entry_point`, `rename`, `prospect` (own no system_hub / prospector) and **`detonate`** (zero devices — a phantom; being dropped from `supportedSimpleCommands`).

**Live commands the old grid silently omitted** (in `available_commands` but never mapped by `DeviceCommand.init`/`supportedSimpleCommands`): `configure`, `message`, `replicate`, `repair`, `change_owner`, `dequeue_print`. Decision: **fold in `configure` / `message` / `replicate` / `repair`** during the revamp (their param shapes still need probing at impl time); `dequeue_print` belongs to print-queue management; `change_owner` → Special, gated on account having >1 replicant.

## Approved grouping (revamp)

Stable order; only non-empty groups render:

1. **Movement** — Travel, Recall, Deploy, Stow
2. **Tasks** — Mine, Retarget, Scan, Search, System Scan, Census, Repair
3. **Production** — Print, Dequeue, Clear Queue
4. **Control** (AMI) — Directive, Clear Directive, Adopt, Release, Launch, Withdraw, Assemble
5. **Carrier & Cargo** — Attach, Detach, Configure, Load, Unload
6. **Modular** — Compact, Unfurl
7. **Power** — Activate, Deactivate, Message
8. **Special** — Decommission, Replicate, Set Entry Point, Rename, Change Owner

**Change Owner** is gated on the account having **>1 replicant** (no other replicant → no transfer target → hide it, same candidate-gating pattern as adopt/release). Its param is a picker over the account's *other* replicants.

## Presentation rule (kills the sheet/inline mishmash)

**needs live server data / rich preview / heavy form → sheet · light local params → inline · no params → confirm.** This moves **Directive → sheet** (all three controller types), joining Travel/Print/Load. The ~500-line directive editor extracts into its own sheet-presented `DirectiveComposer` feature (`@Presents`; dismissal cancels `salvageSitesRequested`). Directive naming clash to resolve: AMI-controller "directive" vs the planned automation feature [[directives-feature]] — keep them lexically distinct.

## Stage 4 status (2026-07-23)

Folded in: `configure` (Carrier & Cargo, mode picker seeded from `taxi_mode`), `message` (Power, BobNet channel picker + body), `repair` (Tasks, under-capacity fleet picker, deadline-tracked), `replicate` (Special, via ReplicantsClient — never CommandClient), `change_owner` (Special, other-own-replicants picker). `detonate` dropped everywhere. Derived-universe test pins taxonomy == 34 dispatchable verbs.

**Re-check when these paths go live** (dormant on this account today): (1) repair — no service_bot owned; when one appears, sanity-check `repairCandidates`' `operationalCapacity < 100` filter against devices whose payload omits `operational_capacity` (defaulted to 0 → spurious "0%" rows); (2) change_owner — 1 replicant; verify the picker on a 2-replicant account. Known UX gap, deliberate: `message` hides until BobNet has synced channels (a `.notice` fallback was suggested in final review, deferred).
