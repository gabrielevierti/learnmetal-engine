// Components.swift
// The components the engine itself understands. Rendering, physics and particle
// components live next to the systems that use them.

import Foundation
import simd

/// A camera looks down the -Z axis of its entity's Transform. The first active
/// camera found in the scene is the one the renderer uses.
public struct Camera {
    public var fovY: Float = radians(60)            // vertical field of view, in radians
    public var nearPlane: Float = 0.1
    public var farPlane: Float = 500
    public var isOrthographic = false
    public var orthographicHeight: Float = 10       // world units visible from bottom to top
    public var isActive = true

    public init(fovY: Float = radians(60), nearPlane: Float = 0.1, farPlane: Float = 500) {
        self.fovY = fovY
        self.nearPlane = nearPlane
        self.farPlane = farPlane
    }

    public func projection(aspect: Float) -> Mat4 {
        if isOrthographic {
            let h = orthographicHeight * 0.5, w = h * aspect
            return Mat4.orthographic(left: -w, right: w, bottom: -h, top: h, near: nearPlane, far: farPlane)
        }
        return Mat4.perspective(fovY: fovY, aspect: aspect, near: nearPlane, far: farPlane)
    }
}

public enum LightType: UInt32 {
    case directional = 0, point = 1, spot = 2
}

/// A light shines along the -Z axis of its entity's Transform (directional and spot),
/// or in every direction from its position (point).
public struct Light {
    public var type = LightType.point
    public var color = Vec3(1, 1, 1)                // linear RGB
    public var intensity: Float = 1
    public var range: Float = 10                    // point and spot: no light beyond this distance
    public var innerConeAngle: Float = radians(20)  // spot: full brightness inside this half-angle
    public var outerConeAngle: Float = radians(30)  // spot: darkness outside this half-angle
    public var castsShadows = false                 // honored for the first directional light (the sun)

    public init(type: LightType = .point, color: Vec3 = Vec3(1, 1, 1), intensity: Float = 1, range: Float = 10,
                castsShadows: Bool = false) {
        self.type = type
        self.color = color
        self.intensity = intensity
        self.range = range
        self.castsShadows = castsShadows
    }
}

/// Game logic attached to one entity. `update` runs once per frame, `fixedUpdate` once
/// per physics step. Either may be nil.
public struct Behavior {
    public var update: ((Engine, Entity, Float) -> Void)?
    public var fixedUpdate: ((Engine, Entity, Float) -> Void)?

    public init(update: ((Engine, Entity, Float) -> Void)? = nil, fixedUpdate: ((Engine, Entity, Float) -> Void)? = nil) {
        self.update = update
        self.fixedUpdate = fixedUpdate
    }
}
