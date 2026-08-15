---
name: directives-body-type-check-budget
description: "DirectivesFeature.body sat one declaration away from the type-checker's time budget — adding ONE public func to GameModels broke the build in a file that change never touched. Split into body + core 2026-08-15."
metadata:
  type: project
---

`DirectivesFeature.body` was `BindingReducer()` + a ~250-line `Reduce { switch … }` with six
`.ifLet`s chained onto it — **one expression**. It compiled, with no margin.

Adding `RelayNode.changed(from:to:)` to `GameModels` — a single public static func, in a file
`DirectivesFeature` does not import a symbol from — pushed it over:

    DirectivesFeature.swift:507:53: error: the compiler is unable to type-check this
    expression in reasonable time; try breaking up the expression into distinct sub-expressions

## Recognising it

The error names a file and line that have **nothing to do with your change**, and it is
reproducible rather than flaky. Do not go looking for a mistake in the named file. Bisect by
reverting your own edits one module at a time and building just that target
(`swift build --target DirectivesFeature`, ~20s) — that is what identifies the perturbation as
the trigger and the expression as the cause.

## The fix

Hoist the switch into `private var core: some ReducerOf<Self>` and leave the `.ifLet` chain in
`body` applied to `core`. The opaque return type gives the switch its own constraint system, so
the two are solved separately. Pure code motion — no behaviour change, all 255
`DirectivesFeatureTests` still pass.

## Why it matters beyond that one build

Any expression sitting this close to the budget is a **latent break on an unrelated commit**.
The cost is paid by whoever next adds a declaration to a widely-imported module (`GameModels`
grows constantly), and the error will point at a file they never opened. When you see this
error, split the expression rather than reverting the innocent change that exposed it.

See [[ftl-mesh-incremental-fold]] for the change that exposed this one.
