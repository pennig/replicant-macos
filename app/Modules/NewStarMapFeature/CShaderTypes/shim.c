// This translation unit exists only so SwiftPM treats CStarMapShaderTypes as a
// buildable C target. All the content lives in include/ShaderTypes.h, which is
// the single source of truth for the CPU<->GPU struct layout — imported into
// Swift as the `CStarMapShaderTypes` module and #included by Shaders.metal.
#include "ShaderTypes.h"
