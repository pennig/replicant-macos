---
name: preview-rewriter-self-init
description: A
metadata: 
  node_type: memory
  type: project
  originSessionId: 6b482f6f-d795-4ac8-a32a-f3285b339db4
---

Adding a `#Preview` to a file makes Xcode's preview **design-time rewriter** instrument that whole file (wrapping expressions in `__designTimeSelection(...)`). It chokes on `convenience`/delegating initializers that call `self.init(...)`, failing the preview thunk build with `initializer delegation ('self.init') cannot be nested in another expression` (plus spurious `cannot convert return expression ... to some View`). The file compiles fine normally and the app is unaffected — only the preview JIT path breaks.

Hit on `Modules/UI/Sources/SelectableList.swift`, whose convenience inits (flat + sectioned) all delegate via `self.init`. Fix: previews moved to `Modules/UI/Sources/SelectableListPreviews.swift`; the rewriter then only touches the preview file, leaving the delegating inits compiled normally. Both `#Preview`s render clean after the split.

**Why:** the rewriter can't express `self.init` delegation inside its instrumentation wrapper.
**How to apply:** any type with delegating convenience initializers (esp. generic builders returning `some View`) — put its `#Preview`s in a separate file from the start. Generalizes the List-row rule in [[list-row-preview-crash]]: preview-only code belongs in its own file whenever the host file has code the rewriter can't safely instrument.
