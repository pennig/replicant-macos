import simd

// Right-handed view/projection math with Metal's z ∈ [0, 1] clip space.
// Kept tiny and explicit so the camera code below reads unambiguously.

extension simd_float4x4 {

    /// Right-handed perspective with Metal NDC (z ∈ [0,1], camera looks down -Z).
    static func perspective(fovyRadians fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovy * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0,  0,        0),
            SIMD4<Float>(0,  ys, 0,        0),
            SIMD4<Float>(0,  0,  zs,      -1),
            SIMD4<Float>(0,  0,  zs * near, 0)
        ))
    }

    /// Right-handed look-at.
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye - center)          // forward is +Z toward the eye (RH → camera looks down -Z)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return simd_float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        ))
    }
}

extension SIMD4 {
    /// The first three lanes as a SIMD3 — Swift's simd lacks the `.xyz` swizzle
    /// that Metal Shading Language provides.
    var xyz: SIMD3<Scalar> { SIMD3(x, y, z) }
}
