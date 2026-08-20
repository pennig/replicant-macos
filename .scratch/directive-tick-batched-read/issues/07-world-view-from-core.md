# 07 — Derive `WorldView` from `WorldCore`

Status: ready-for-agent
Blocked by: 06

The brain's view and the directives' core become the same world, read once.
Built from one transaction they cannot disagree; built from two they routinely
did.

`WorldView`'s own extras are NOT in the core and keep their own fetches inside
the same transaction: the `SiteAssay` salvage filter (`WorldView.swift:177`),
the scoped `stockLocations`/`operationalDepots` reads (`:211`, `:224`) and the
`stockpiles` filter (`:232`). Do not widen `WorldCore` to hold them.

Full steps: `../plan.md` → **Task 7**.

**Done when:** `WorldViewFromCore.matchesTheStandaloneRead` passes on whole-value
equality; `WorldView`'s public shape is unchanged; the DirectiveEngine suite
passes untouched.
