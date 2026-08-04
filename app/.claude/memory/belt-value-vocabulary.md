# Belt value vocabulary (density/richness) + the locked `BeltClass` mapping

Confirmed live 2026-08-03 (automation-brain Task 9, `BeltClass`): probed the
live API (`replicant raw GET locations/SOL`) plus aggregated the local synced
database (`~/Library/Containers/name.pennig.replicould/Data/Library/Application
Support/SQLiteData.db`, table `systemDetails`) across **141 scanned systems
containing 56 belts**.

## `Belt.density` — exactly three live values, no more

`sparse` (11 belts), `moderate` (24), `dense` (21). There is **no** `rich`,
`abundant`, `medium`, or `thin` value in the whole live dataset — any code
branching on those strings is dead.

## `Belt.richness` (wire name `resources`) — five qualifiers, no `abundant`

`scarce`, `low`, `moderate`, `high`, `rich`. There is **no `abundant`**.

## Real resource-type keys (the `richness` map's keys)

`carbon`, `conductive`, `rares`, `silicates`, `structural`, `volatiles`. Not
`"metal"` / `"silicon"` — those never appear.

## The locked `BeltClass` mapping (`DirectiveEngine/Sources/MeshValue.swift`)

Density (primary):

| `density` | `BeltClass` |
|---|---|
| `dense` | `.rich` |
| `moderate` | `.moderate` |
| `sparse` | `.sparse` |
| anything else / nil | fall back to `richness` |

Richness (fallback, richest-per-resource wins when several are present):

| `richness` qualifier | `BeltClass` |
|---|---|
| `rich`, `high` | `.rich` |
| `moderate` | `.moderate` |
| `low`, `scarce` | `.sparse` |
| anything else | ignored |

If neither `density` nor any `richness` entry resolves, `classify` returns
`nil` — "unknown" stays unknown rather than defaulting to `.sparse`; a belt
with no legible value data yields no target.

## Decoded belt model keys

`designation`, `density`, `richness`, `innerRadiusAu`, `outerRadiusAu`,
`sites`, `inventory`, `devices` (`Belt`, `UniverseModels/Sources/
LocationModels.swift:518`). Both `density: String?` and `richness: [String:
String]` are already optional/keyed exactly as above; `richness` has no
default population guarantee (can be empty).
