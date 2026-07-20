---
name: monospace-system-names
description: Rule — system names are always rendered in a monospaced font token
metadata: 
  node_type: memory
  type: feedback
  originSessionId: bd90fa43-b8d7-44f6-a524-206b3ae0a763
---

Anywhere a system or location name (e.g. SOL, SOL-3, SOL-3-1, etc) is displayed (map labels/dossiers, list rows, detail headers), render it in a **monospaced** font. A system name is a designation code, so it should read like an ID.

**Why:** The user explicitly made this a project rule after liking the mono treatment of the star-map search rows.

**How to apply:** Use a mono token from `DesignSystem.swift` — `.rcMono` / `.rcMonoSmall`, or the prominence-matched `.rcTitleMono` (20 bold), `.rcHeadlineMono` (15 semibold), `.rcBodyEmphMono` (13 semibold) added for this rule. If a needed size/weight is missing, add a new mono token rather than inlining `design: .monospaced`. Codified in `CLAUDE.md` under Rules. Applied across: `NewStarMapFeature` (SystemDossier, orrery SystemHUD star card + body rows), `LocationsFeature` (all list-row kinds + the `LocationDetailView` InspectorScroll/BubbleRow/StructureRow/InventoryHoldingRow name titles), `ReplicantsFeature` detail last-known-location, `LocationEventsFeature` row location label. The `ReplicantsListView` location label was already mono. See [[new-star-map-feature]], [[locations-catalog-feature]].
