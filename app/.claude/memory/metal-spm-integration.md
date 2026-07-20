---
name: metal-spm-integration
description: How to wire raw-Metal (.metal shader + shared C struct header) into an SPM library target in this package
metadata: 
  node_type: memory
  type: reference
  originSessionId: acf63055-6a9a-4ae6-b6f4-c4d5ed6f2b46
---

Getting raw Metal into an SPM library target (done for [[new-star-map-feature]]) needs three non-obvious things — SwiftPM does NOT auto-handle any of them:

1. **The `.metal` must be declared as a processed resource**, else SwiftPM silently ignores it (no metallib, no compile error). In the target: `resources: [.process("Shaders.metal")]`. This compiles it into the target's `default.metallib` AND synthesizes `Bundle.module`.
2. **Load the library via the module bundle:** `try? device.makeDefaultLibrary(bundle: .module)` — NOT the argless `makeDefaultLibrary()` (that reads the main app bundle). Without a synthesized `Bundle.module` (i.e. no resources declared), `.module` resolves to an imported dep's internal `Bundle.module` and errors "inaccessible due to internal protection level".
3. **Shared C struct header (CPU↔GPU) needs its own C target.** SPM library targets can't use an app-style bridging header. Put `ShaderTypes.h` in a C target (`CStarMapShaderTypes`, path `.../CShaderTypes`, header in `include/`, plus a `shim.c` that `#include`s it so the target is buildable). Swift files that use the structs `import CStarMapShaderTypes`. The `.metal` reaches the same header via a **relative include across targets**: `#include "../CShaderTypes/include/ShaderTypes.h"` (the Metal/clang compiler resolves relative to the .metal file's own dir — this works).

**Do NOT add `.defaultIsolation(MainActor.self)` to the target** to mimic the app's `SWIFT_DEFAULT_ACTOR_ISOLATION`: it makes TCA's `@Reducer` macro fail with "circular reference" (TCA 1.26). The ported render code compiles fine nonisolated because the AppKit/MetalKit superclasses (MTKView, etc.) already carry MainActor.
