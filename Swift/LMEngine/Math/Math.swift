// Math.swift
// Vector, matrix and quaternion helpers on top of Apple's simd library, plus the
// small geometric types the engine needs: boxes, rays, planes, frustums, random numbers.
//
// Conventions, the same as on the LearnMetal site:
//   - right-handed world, +Y up, a camera looks down its own -Z axis
//   - matrices are column-major and multiply column vectors: world = model * local
//   - clip-space depth runs from 0 (near) to 1 (far), as Metal expects

import Foundation
import simd

public typealias Vec2 = SIMD2<Float>
public typealias Vec3 = SIMD3<Float>
public typealias Vec4 = SIMD4<Float>
public typealias Mat3 = simd_float3x3
public typealias Mat4 = simd_float4x4
public typealias Quat = simd_quatf

// MARK: - Scalars

public func radians(_ degrees: Float) -> Float { degrees * (Float.pi / 180) }
public func degrees(_ radians: Float) -> Float { radians * (180 / Float.pi) }
public func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
public func saturate(_ x: Float) -> Float { min(max(x, 0), 1) }

public func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = saturate((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
}

/// Moves `current` toward `target` at a rate that does not depend on the frame rate.
/// `sharpness` is roughly "how many times per second the gap shrinks by a factor of e".
public func damp(_ current: Float, _ target: Float, sharpness: Float, dt: Float) -> Float {
    lerp(current, target, 1 - exp(-sharpness * dt))
}

public func easeOutCubic(_ t: Float) -> Float {
    let u = 1 - saturate(t)
    return 1 - u * u * u
}

public func easeInOutCubic(_ t: Float) -> Float {
    let x = saturate(t)
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}

public func easeOutBack(_ t: Float) -> Float {
    let c1: Float = 1.70158, c3: Float = 1.70158 + 1
    let u = saturate(t) - 1
    return 1 + c3 * u * u * u + c1 * u * u
}

// MARK: - Vectors

public func xyz(_ v: Vec4) -> Vec3 { Vec3(v.x, v.y, v.z) }
public func lerp(_ a: Vec3, _ b: Vec3, _ t: Float) -> Vec3 { a + (b - a) * t }
public func lerp(_ a: Vec4, _ b: Vec4, _ t: Float) -> Vec4 { a + (b - a) * t }
public func damp(_ current: Vec3, _ target: Vec3, sharpness: Float, dt: Float) -> Vec3 {
    lerp(current, target, 1 - exp(-sharpness * dt))
}

/// normalize() that returns `fallback` instead of NaN for a zero-length vector.
public func safeNormalize(_ v: Vec3, fallback: Vec3 = Vec3(0, 1, 0)) -> Vec3 {
    let lengthSquared = simd_length_squared(v)
    return lengthSquared > 1e-12 ? v / lengthSquared.squareRoot() : fallback
}

// MARK: - Quaternions

public extension simd_quatf {
    /// No rotation. (Note that `simd_quatf()` is all zeros, which is not a rotation at all.)
    static let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    /// Yaw around Y, then pitch around X, then roll around Z: the order a first-person camera wants.
    init(pitch: Float, yaw: Float, roll: Float = 0) {
        let yawRotation = simd_quatf(angle: yaw, axis: Vec3(0, 1, 0))
        let pitchRotation = simd_quatf(angle: pitch, axis: Vec3(1, 0, 0))
        let rollRotation = simd_quatf(angle: roll, axis: Vec3(0, 0, 1))
        self = yawRotation * pitchRotation * rollRotation
    }

    /// The reverse of init(pitch:yaw:roll:): pitch, yaw and roll (as x, y, z) of this rotation.
    /// What an editor shows, because three angles are easier to read than a quaternion.
    var eulerAngles: Vec3 {
        let m = simd_float3x3(self)
        // With R = yaw * pitch * roll, the third column is (sin y cos p, -sin p, cos y cos p)
        // and the second row starts with (cos p sin r, cos p cos r).
        let sinPitch = Swift.min(Swift.max(-m.columns.2.y, -1), 1)
        let pitch = asin(sinPitch)
        if abs(sinPitch) > 0.9999 {
            // Looking straight up or down: yaw and roll turn around the same axis. Call it all yaw.
            return Vec3(pitch, atan2(-m.columns.0.z, m.columns.0.x), 0)
        }
        return Vec3(pitch, atan2(m.columns.2.x, m.columns.2.z), atan2(m.columns.0.y, m.columns.1.y))
    }

    /// The rotation that turns -Z into `forward` while keeping +Y as close to `up` as possible.
    static func lookRotation(forward: Vec3, up: Vec3 = Vec3(0, 1, 0)) -> simd_quatf {
        let f = safeNormalize(forward, fallback: Vec3(0, 0, -1))
        var right = simd_cross(f, up)
        if simd_length_squared(right) < 1e-8 {              // forward is parallel to up
            right = simd_cross(f, Vec3(1, 0, 0))
        }
        right = simd_normalize(right)
        let realUp = simd_cross(right, f)
        return simd_quatf(simd_float3x3(columns: (right, realUp, -f)))
    }
}

// MARK: - Matrices

public extension simd_float4x4 {
    static func translation(_ t: Vec3) -> simd_float4x4 {
        simd_float4x4(columns: (Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(t.x, t.y, t.z, 1)))
    }

    static func scaling(_ s: Vec3) -> simd_float4x4 {
        simd_float4x4(diagonal: Vec4(s.x, s.y, s.z, 1))
    }

    static func rotation(_ q: simd_quatf) -> simd_float4x4 { simd_float4x4(q) }

    /// translation * rotation * scale, written out so that no matrix product is needed.
    static func compose(position: Vec3, rotation: simd_quatf, scale: Vec3) -> simd_float4x4 {
        let r = simd_float3x3(rotation)
        return simd_float4x4(columns: (Vec4(r.columns.0 * scale.x, 0), Vec4(r.columns.1 * scale.y, 0),
                                       Vec4(r.columns.2 * scale.z, 0), Vec4(position, 1)))
    }

    /// Right-handed perspective projection with depth from 0 to 1. `fovY` is in radians.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (Vec4(x, 0, 0, 0), Vec4(0, y, 0, 0), Vec4(0, 0, z, -1), Vec4(0, 0, z * near, 0)))
    }

    /// Right-handed orthographic projection with depth from 0 to 1.
    static func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
        simd_float4x4(columns: (Vec4(2 / (right - left), 0, 0, 0),
                                Vec4(0, 2 / (top - bottom), 0, 0),
                                Vec4(0, 0, 1 / (near - far), 0),
                                Vec4((left + right) / (left - right), (top + bottom) / (bottom - top), near / (near - far), 1)))
    }

    /// View matrix for a camera at `eye` looking at `target`.
    static func lookAt(eye: Vec3, target: Vec3, up: Vec3 = Vec3(0, 1, 0)) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (Vec4(s.x, u.x, -f.x, 0), Vec4(s.y, u.y, -f.y, 0), Vec4(s.z, u.z, -f.z, 0),
                                       Vec4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    func transformPoint(_ p: Vec3) -> Vec3 {
        let r = self * Vec4(p, 1)
        return xyz(r) / r.w
    }

    func transformDirection(_ d: Vec3) -> Vec3 { xyz(self * Vec4(d, 0)) }

    /// The matrix that transforms normals correctly even under non-uniform scale.
    var normalMatrix: simd_float4x4 { inverse.transpose }
}

// MARK: - Shapes

public struct AABB {
    public var min = Vec3(repeating: Float.greatestFiniteMagnitude)
    public var max = Vec3(repeating: -Float.greatestFiniteMagnitude)

    public init() {}
    public init(min: Vec3, max: Vec3) {
        self.min = min
        self.max = max
    }
    public init(center: Vec3, halfExtents: Vec3) {
        self.init(min: center - halfExtents, max: center + halfExtents)
    }

    public var isEmpty: Bool { min.x > max.x }
    public var center: Vec3 { (min + max) * 0.5 }
    public var halfExtents: Vec3 { (max - min) * 0.5 }

    public mutating func expand(_ p: Vec3) {
        min = simd_min(min, p)
        max = simd_max(max, p)
    }

    public mutating func expand(_ other: AABB) {
        min = simd_min(min, other.min)
        max = simd_max(max, other.max)
    }

    public func contains(_ p: Vec3) -> Bool { all(p .>= min) && all(p .<= max) }
    public func intersects(_ other: AABB) -> Bool { all(min .<= other.max) && all(max .>= other.min) }

    /// The box that encloses this one after `m` is applied (Arvo's method: no corner loop needed).
    public func transformed(_ m: Mat4) -> AABB {
        let c = m.transformPoint(center)
        let h = halfExtents
        let e = simd_abs(xyz(m.columns.0)) * h.x + simd_abs(xyz(m.columns.1)) * h.y + simd_abs(xyz(m.columns.2)) * h.z
        return AABB(min: c - e, max: c + e)
    }
}

public struct Ray {
    public var origin: Vec3
    public var direction: Vec3          // must be normalized

    public init(origin: Vec3, direction: Vec3) {
        self.origin = origin
        self.direction = direction
    }

    public func at(_ t: Float) -> Vec3 { origin + direction * t }
}

/// All points p with dot(normal, p) + d = 0. The normal points to the "inside" half-space.
public struct Plane {
    public var normal: Vec3
    public var d: Float

    public init(normal: Vec3 = Vec3(0, 1, 0), d: Float = 0) {
        self.normal = normal
        self.d = d
    }

    public func signedDistance(_ p: Vec3) -> Float { simd_dot(normal, p) + d }
}

/// The six planes of a view volume, extracted from a view-projection matrix.
public struct Frustum {
    public var planes: [Plane] = []     // left, right, bottom, top, near, far

    public init(viewProjection m: Mat4) {
        func row(_ i: Int) -> Vec4 { Vec4(m[0, i], m[1, i], m[2, i], m[3, i]) }
        let r0 = row(0), r1 = row(1), r2 = row(2), r3 = row(3)
        let raw = [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2]     // depth 0..1: the near plane is row 2 alone
        planes = raw.map { plane in
            let length = simd_length(xyz(plane))
            return Plane(normal: xyz(plane) / length, d: plane.w / length)
        }
    }

    /// False only when the box is certainly outside. A box near a corner may pass even
    /// though it is outside, which costs a draw call but never drops a visible object.
    /// With `testNearPlane` false, whatever is in front of the near plane counts as inside:
    /// shadow maps want that, because anything between the light and the view casts a shadow.
    public func intersects(_ box: AABB, testNearPlane: Bool = true) -> Bool {
        for i in 0..<6 {
            if i == 4 && !testNearPlane { continue }
            let plane = planes[i]
            let farthest = Vec3(plane.normal.x >= 0 ? box.max.x : box.min.x,
                                plane.normal.y >= 0 ? box.max.y : box.min.y,
                                plane.normal.z >= 0 ? box.max.z : box.min.z)
            if plane.signedDistance(farthest) < 0 { return false }
        }
        return true
    }
}

/// Distance along the ray to a sphere, or nil.
public func intersectSphere(_ ray: Ray, center: Vec3, radius: Float) -> Float? {
    let oc = ray.origin - center
    let b = simd_dot(oc, ray.direction)
    let c = simd_dot(oc, oc) - radius * radius
    var h = b * b - c
    if h < 0 { return nil }
    h = h.squareRoot()
    var t = -b - h
    if t < 0 { t = -b + h }                                 // the origin is inside the sphere
    return t < 0 ? nil : t
}

/// Distance along the ray to an axis-aligned box (slab method), or nil.
public func intersectAABB(_ ray: Ray, _ box: AABB) -> Float? {
    var tMin: Float = 0, tMax = Float.greatestFiniteMagnitude
    for axis in 0..<3 {
        let origin = ray.origin[axis], direction = ray.direction[axis]
        if abs(direction) < 1e-8 {
            if origin < box.min[axis] || origin > box.max[axis] { return nil }
            continue
        }
        var t1 = (box.min[axis] - origin) / direction
        var t2 = (box.max[axis] - origin) / direction
        if t1 > t2 { swap(&t1, &t2) }
        tMin = max(tMin, t1)
        tMax = min(tMax, t2)
        if tMin > tMax { return nil }
    }
    return tMin
}

/// Distance along the ray to a plane, or nil if the ray is parallel or points away.
public func intersectPlane(_ ray: Ray, _ plane: Plane) -> Float? {
    let denominator = simd_dot(plane.normal, ray.direction)
    if abs(denominator) < 1e-8 { return nil }
    let t = -plane.signedDistance(ray.origin) / denominator
    return t < 0 ? nil : t
}

// MARK: - Random numbers

/// A small, fast, seedable generator (PCG32). The same seed gives the same sequence on
/// every machine and in both the C++ and the Swift engine, which keeps gameplay and
/// tests reproducible.
public struct Random {
    public var state: UInt64 = 0
    public var increment: UInt64 = 1442695040888963407

    public init(seed: UInt64 = 0x853c49e6748fea9b) {
        _ = nextUInt()
        state &+= seed
        _ = nextUInt()
    }

    public mutating func nextUInt() -> UInt32 {
        let old = state
        state = old &* 6364136223846793005 &+ increment
        let xorshifted = UInt32(truncatingIfNeeded: ((old >> 18) ^ old) >> 27)
        let rot = UInt32(truncatingIfNeeded: old >> 59)
        return (xorshifted >> rot) | (xorshifted << ((32 &- rot) & 31))
    }

    /// Uniform in [0, 1).
    public mutating func next() -> Float { Float(nextUInt() >> 8) * (1.0 / 16777216.0) }

    public mutating func range(_ low: Float, _ high: Float) -> Float { low + (high - low) * next() }

    /// Uniform integer in [low, high).
    public mutating func rangeInt(_ low: Int, _ high: Int) -> Int {
        low + Int(nextUInt() % UInt32(Swift.max(high - low, 1)))
    }

    public mutating func onUnitSphere() -> Vec3 {
        let z = range(-1, 1)
        let angle = range(0, 2 * Float.pi)
        let r = Swift.max(0, 1 - z * z).squareRoot()
        return Vec3(r * cos(angle), r * sin(angle), z)
    }

    public mutating func insideUnitSphere() -> Vec3 {
        let direction = onUnitSphere()
        return direction * cbrt(next())
    }

    /// A unit vector within `halfAngle` radians of `direction`.
    public mutating func inCone(_ direction: Vec3, halfAngle: Float) -> Vec3 {
        let cosTheta = range(cos(halfAngle), 1)
        let sinTheta = Swift.max(0, 1 - cosTheta * cosTheta).squareRoot()
        let phi = range(0, 2 * Float.pi)
        let w = safeNormalize(direction)
        let helper = abs(w.y) < 0.99 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
        let u = simd_normalize(simd_cross(helper, w))
        let v = simd_cross(w, u)
        return u * (sinTheta * cos(phi)) + v * (sinTheta * sin(phi)) + w * cosTheta
    }
}
