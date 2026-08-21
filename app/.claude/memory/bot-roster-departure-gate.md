---
name: bot-roster-departure-gate
description: "`Directive.botCodes` is the run's service-bot recovery obligation — enrolled at first deploy, never auto-removed, and the ONLY stow-independent record of who left the hull. Every location-scoped bot query goes blind for the length of an autonomous hop, which is how AD36227C was left at AMIRAM-1-7 for three days. The roster is a UNION with the old location query, never a replacement, and `RepairFleet.inTransit` was deliberately NOT loosened."
metadata:
  type: reference
---

# A departure gate needs a roster, not a location

The second strand of the same bot in ten days, and the second fix.
[[recall-clears-the-bots-location]] is the first; this supersedes its conclusion
that widening the in-transit query is enough.

## The fourteen-second window

Live 2026-08-17, salvage run `760A30F8`, bot `AD36227C`. Reconstructed from
`directiveLogEntries` and `eventLogs`:

    17:35:31  stowingBots dispatches recall to the SIBLING bot only
              (`botsOut` sorts by device code; AD36227C was next round)
    17:35:41  confirmRecall waits 57s for the sibling's cruise home — correct
    17:36:21  sibling stows, leaves the set
    17:36:22  AD36227C departs AMIRAM-1-3 on its OWN service hop, location → nil
    17:36:28  the tick lands. `out` is empty. `.finished` → `.advanceTarget`
    17:36:36  AD36227C lands at AMIRAM-1-7, still deployed
    17:36:46  the vessel departs for GUMALA

Found 55 target systems later, still at `AMIRAM-1-7`, three days on. The run
never surfaced anything — it was in `needsAttention` for an unrelated
`dronesNotRecovered`.

## Why the 2026-08-07 fix could not catch it

`RepairFleet.botsOut` = deployed-in-this-system ∪ in-transit. Both terms miss a
bot mid-hop:

- `deployed(in:system:)` needs a non-nil `location`, and a bot in flight has none.
- `inTransit` needs `world.openOperation(for:) != nil`.

**An autonomous service hop opens no operation row.** Verified on the live
database: `AD36227C` has 267 operations, newest at `17:06:22` — none for any of
its four later hops. The sibling bot did the same thing on 2026-08-20 (`DUBUHE-7-L4
→ DUBUHE-7-28`) and likewise produced only the run-dispatched `deploy`/`activate`
ops. The open-op requirement was written for a RECALL cruise, which the run
itself dispatches and therefore tracks. It cannot see a bot moving on its own
`service` directive — which is every armed bot doing its job.

## Why `inTransit` was NOT simply loosened

Dropping the open-op requirement was the obvious fix and is wrong.
`RepairFleet.answers` returns `true` for a bot wearing NO fleet tag, and
`inTransit` carries no system scope — so an untagged service bot anywhere in the
galaxy, in flight, would block every run's departure indefinitely. The op gate is
the only thing bounding that blast radius. Leave it.

## The roster

`Directive.botCodes`, JSON array column, mirroring `freighterCodes` — but it is
**not a lease**. It reserves nothing and gates nobody's access; it records who the
run owes a ride home.

Three rules, each of which a plausible-looking change would break:

- **Enrol before the first deploy, in `BotPhase.deploy`** — not on confirm. A
  deploy that half-lands still put the bot outside the hull.
- **Enrolment ADDS, never re-derives.** Recomputing the roster from "whatever is
  aboard now" drops precisely the bot that failed to come home. That is the loss.
- **It is a UNION with `botsOut`, never a replacement.** The roster reaches bots
  no location scope can see; the location query reaches bots nobody enrolled, such
  as one an operator deployed by hand.

`owed(vessel:)` selects on stow state alone — `stowedInDeviceCode != vessel` —
with no location term at all. That is the whole point: both states this exists to
catch report a location no in-system query matches. A bot mid-hop has none; a bot
left behind has one in a system the run has quit.

`stranded(owed:vessel:)` stalls when an owed bot's location resolves to a
DIFFERENT system. A nil location is a bot in flight, never a strand — reading it
as one would stall every ordinary hop.

**Its own reason, `serviceBotStranded`, not `serviceBotNotRecovered`.** The
latter's guidance offers Skip, and `skipTarget` bypasses `stowingBots` — the
documented way bots get abandoned ([[salvage-fleet-repair-build]]). The new
reason's guidance says fly the bot back and retry, and never skip. `.escalate`,
because the brain drives only retry/cancel and a retry cannot reach it.

Both bot-carrying engines get this at once: `BotPhase` is one copy serving
`SalvageRun` and `SurveyRun`.

**`botCodes` must stay named in `DirectiveExecutor.commit`'s column list**
([[directive-commit-column-ownership]]). That list is explicit, and a column the
executor assigns but does not name is dropped in silence — the roster reads empty
for ever and the gate is inert with every unit test still green, because the
engine tests build their own `Directive` values and never touch the write path.
`EnrolledRosterPersistence` is the one test that would catch it.

## What this does not cover

- **No backfill.** A directive already running has no record of which bots it put
  out, and deriving one from today's stow state would enrol the bots that came
  home and miss the one that did not. Existing runs start `[]` and enrol on their
  next deploy — so the run that stranded `AD36227C` will not retroactively notice.
- **No way to clear a roster entry but the database.** A bot permanently removed
  from the fleet stalls the run every departure. Deliberate: the alternative was
  dropping a bot whose fleet tag stops matching, and a silent auto-drop is the
  exact class of bug this note exists about. A device row that disappears
  entirely does fall out, via `compactMap`.

See [[recall-clears-the-bots-location]] for the first fix and the nil-location
fact it rests on, [[salvage-controller-recall-race]] for why a command landing on
a device in transit is its own incident (which is why the gate waits a hop out
rather than recalling into it), and [[salvage-fleet-repair-build]] /
[[survey-fleet-repair-build]] for the two engines.
