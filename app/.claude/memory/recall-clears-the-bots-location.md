---
name: recall-clears-the-bots-location
description: "A recalled service bot carries `location: nil` for its whole cruise home, so `RepairFleet.bots(deployedNear:)` — which requires a non-nil location in the vessel's system — cannot see the one bot a recall is waiting on. Both recall steps in both bot-carrying engines read that as an empty system and returned `.advanceTarget`, departing over the bot. Fixed by `botsOut`/`anyBotOut`, which add in-transit bots (stowed == nil AND location == nil AND an open op)."
metadata:
  type: reference
---

Fired live 2026-08-07: a Salvage Run left service bot `AD36227C` at `ALPAHARD-7-11`
in `recall_waiting` and surged to `STARIBOR`, 108 seconds before the bot was due to
land. The run did not stall — it advanced its target index and kept working, so
nothing surfaced. The stranded bot is unrecoverable by the run: the recall it is
waiting on can only stow it into a carrier that has left the system.

## The mechanism

Three separately-correct facts compose into the loss:

1. **A recall is a cruise, not an instant stow.** The op carried
   `origin ALPAHARD-8-9 → destination ALPAHARD-7-11`, 5.063 AU, 128.7 s. The
   sibling bot's recall that same minute was 13.3 s over 0 AU and completed before
   the next tick — which is why only one of two bots was lost, and why the bug is
   distance-dependent and therefore intermittent.
2. **A device in transit reports `location: null`.** Already recorded twice in this
   codebase — `GameSync`'s payload-complete field application ("the arrival's
   destination, null while in transit or stowed") and `DevicesClient.fetchAtLocation`
   ("a travelling device reports `location: null` yet is still matched by the
   filter … which is what makes this usable for watching a recall").
3. **`RepairFleet.bots(deployedNear:)` requires a non-nil location.** Its
   `deployed` filter is `bot.location.map(SiteAssay.system(of:)) == system`, and
   `nil == "ALPAHARD"` is false.

So the query used to decide "is anyone still out?" drops precisely the device the
question is about. `SalvageRun.confirmBotStow` read `out.isEmpty` and returned
`.advanceTarget`.

**The guard written for this case could never fire.** `confirmBotStow`'s next line
is `if let arrival = Self.recallArrival(out), arrival > world.now { return .wait }`,
whose comment says "a recall cruises the bot home, so wait out its own arrival
time" — but `recallArrival` is computed from `out`, and a bot still cruising is
exactly what `out` cannot contain. Guard and selector contradicted each other.

## The shape that was already right

`awaitCompletion`'s drone-recovery path in the same file selects by **stow**, not
location — `drones.filter { $0.stowedInDeviceCode != vessel.deviceCode }` — then
checks `activityDeadline != nil` and waits out `recallArrival`. That path handles a
nil-location traveller correctly and is the reference the bot path now matches.

## The fix

`RepairFleet.botsOut(near:in:owner:)` = `bots(deployedNear:)` plus bots that are
**not stowed, carry no location, and have an open operation**. The open-op
requirement is what keeps it from sweeping in an unrelated bot; the not-stowed
requirement is what keeps it from counting a bot aboard the vessel, which also
carries no location. `anyBotOut` is the same widening of `anyBotDeployed`.

Four sites take it per engine — `stowBots` and `confirmBotStow`, each on both the
vessel-has-a-location path and the nil-location path whose `else` is
`.advanceTarget`. `awaitRepair`'s `anyBotDeployed` guard is deliberately left alone:
its `else` hands to `stowingBots` rather than departing.

`deployBots`/`armingBots`/`awaitRepair` keep the location-scoped query — a bot in
flight is not ready to be deployed or armed, and only a departure decision needs
the wider set.

## Rules

- A query that decides **whether the run may leave** must select by stow state, not
  by location. Location is nil for both halves of "in transit" and "aboard", and
  only one of those is safe to depart over.
- Fixture the nil. Every recall test in both suites gave the bot a location —
  `bot()` defaults to `"TOSLIT-3"`, and `aRecallStillCruisingIsWaitedOutOnItsOwnArrivalTime`
  modelled a cruising bot as `location: "TAU-9"`, a state the server does not
  produce during flight. Six tests now pin the nil-location case; four of them fail
  against the old code.
- A guard whose input comes from a filter that excludes its own subject is dead
  code that reads as protection. Check that the set a wait-condition reads can
  actually contain the thing it waits for.

See [[confirm-steps-need-fresh-evidence]] for the sibling class (a step believing a
row that cannot answer the question), [[location-scope-cannot-see-stowed]] for the
read-side half of the same nil-location fact, and
[[salvage-fleet-repair-build]] / [[survey-fleet-repair-build]] for the two engines.
