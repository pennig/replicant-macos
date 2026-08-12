# `prunableWorld`'s two caller contracts

`prunableWorld` (`DirectiveEngine/Tests/BrainTestSupport.swift`) builds a
`WorldView` for `PrunePredicate` tests. Two of its parameters carry contracts
the signature alone does not show:

**`meshSystems` is DERIVED from `relays` via the real production predicate**
(`SalvageTargetPlanner.meshSystems(in:)`), never hand-set as a plain
`Set<String>` parameter. A fixture that could simply *claim* a system is
meshed, with no relay device actually in it, would let a prune test pass
against a world the production `WorldView.read` path can never produce —
`PrunePredicate` reasons over which relays are load-bearing, and a fixture
that fakes mesh membership defeats the very thing under test.

**`replicants` defaults to `[]`, not `[hub]`.** Earlier designs assumed the
anchor replicant stands co-located with the hub; multi-theatre broke that
assumption (a theatre's depot and the replicant carrying command authority
into it need not be the same location). The empty default exists so a test
must opt in to co-location explicitly rather than inherit it for free, and a
test proving prune behaves correctly WITHOUT co-location has a parameter to
reach for.
