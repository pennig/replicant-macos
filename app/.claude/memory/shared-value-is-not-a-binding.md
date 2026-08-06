# A `@Shared` value is written through `withLock`, not through `BindingReducer`

Putting a `@Shared` property in `@ObservableState` and driving it from the view
with `BindingReducer()` compiles, and the tests pass — but every write goes
through `Shared`'s **deprecated** setter:

> Setter for 'x' is deprecated: Use '$shared.withLock' to modify a shared value
> with exclusive access; when constructing a SwiftUI binding, use `Binding($shared)`

Deprecation warnings do not fail this package's build, so the only signal is the
warning itself, and `swift test`'s console output buries it. It surfaced on
`DevicesFeature.State.grouping`, whose design doc had specified "driven by the
existing `BindableAction`/`BindingReducer()` — no bespoke actions".

**The shape that works:** give the gesture a real action, write the value inside
it, and hand the view a `Binding` that sends the action.

```swift
case let .groupingSelected(grouping):
    state.$grouping.withLock { $0 = grouping }
    return .none
```

```swift
Binding(get: { store.grouping }, set: { store.send(.groupingSelected($0)) })
```

Point-Free's own answer for a plain (non-TCA) view is `Binding($shared)`, which
writes straight through; inside a reducer-owned feature the action keeps the
reducer the single writer and gives `TestStore` something to assert against.

Two related facts, both from the same build:

- `@ObservationStateIgnored` is required on the property (same as `@FetchAll`
  here) because `@Shared` runs its own observation. SwiftUI still re-renders.
- Tests touching `@Shared` are **automatically insulated** from one another, so
  no per-test `UserDefaults(suiteName:)` is needed. Two stores built inside one
  test share that test's ephemeral storage, which is what makes a
  "choice survives a state round-trip" assertion possible. Only *repeated* or
  *parameterised* tests need the `.dependencies` trait.
