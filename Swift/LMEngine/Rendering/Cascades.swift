// Cascades.swift
// Cascaded shadow maps: the math that fits several shadow maps to the camera's view.
//
// One shadow map stretched over everything the camera sees would be far too coarse up
// close. So the view distance is cut into slices, the "cascades", and each slice gets a
// shadow map of its own: small and sharp near the camera, large and soft far away.

import Foundation
import simd

public let maxCascades = 4

public struct Cascades {
    public var count = 0
    public var viewProjection = [Mat4](repeating: matrix_identity_float4x4, count: maxCascades)  // world space to each cascade's shadow map
    public var splitFar = [Float](repeating: 0, count: maxCascades)     // view-space distance at which each cascade ends
    public var radius = [Float](repeating: 0, count: maxCascades)       // world-space radius each cascade covers
}

public struct CascadeSettings {
    public var count = 4
    public var shadowDistance: Float = 60       // no sun shadows beyond this distance from the camera
    public var splitLambda: Float = 0.75        // 0 spaces the slices evenly, 1 logarithmically
    public var resolution = 2048                // shadow map edge, in texels
    public var casterDistance: Float = 80       // how far behind a cascade an object can be and still cast into it

    public init() {}
}

/// `cameraWorld` is the camera's world matrix (the inverse of its view matrix) and
/// `lightDirection` the direction the sunlight travels.
public func computeCascades(cameraWorld: Mat4, fovY: Float, aspect: Float, nearPlane: Float,
                            lightDirection: Vec3, settings: CascadeSettings) -> Cascades {
    var cascades = Cascades()
    cascades.count = min(max(settings.count, 1), maxCascades)
    let farPlane = max(settings.shadowDistance, nearPlane + 0.1)

    // The light's orientation is the same for every cascade: a view looking along the light.
    let direction = safeNormalize(lightDirection, fallback: Vec3(0, -1, 0))
    let up = abs(direction.y) > 0.99 ? Vec3(0, 0, 1) : Vec3(0, 1, 0)
    let lightRotation = Mat4.lookAt(eye: Vec3(0, 0, 0), target: direction, up: up)
    let lightRotationInverse = lightRotation.transpose                 // a pure rotation: inverse = transpose

    let tanHalfY = tan(fovY * 0.5), tanHalfX = tanHalfY * aspect
    var sliceNear = nearPlane

    for i in 0..<cascades.count {
        // Where this slice ends: a blend of even spacing and logarithmic spacing.
        let p = Float(i + 1) / Float(cascades.count)
        let uniformSplit = nearPlane + (farPlane - nearPlane) * p
        let logSplit = nearPlane * pow(farPlane / nearPlane, p)
        let sliceFar = lerp(uniformSplit, logSplit, settings.splitLambda)

        // The eight corners of the slice of the view frustum, in world space.
        var corners: [Vec3] = []
        for distance in [sliceNear, sliceFar] {
            for sy in [Float(-1), Float(1)] {
                for sx in [Float(-1), Float(1)] {
                    corners.append(cameraWorld.transformPoint(Vec3(sx * tanHalfX * distance, sy * tanHalfY * distance, -distance)))
                }
            }
        }

        // Enclose the slice in a sphere. A sphere looks the same from every direction,
        // so the area the cascade covers does not change when the camera turns.
        var center = Vec3(0, 0, 0)
        for corner in corners { center += corner }
        center /= 8
        var radius: Float = 0
        for corner in corners { radius = max(radius, simd_distance(center, corner)) }
        radius = ceil(radius * 16) / 16

        // Snap the center to whole shadow-map texels, measured in the light's space.
        // Without this, shadow edges shimmer as the camera moves.
        let texel = 2 * radius / Float(settings.resolution)
        var lightSpaceCenter = lightRotation.transformPoint(center)
        lightSpaceCenter.x = floor(lightSpaceCenter.x / texel) * texel
        lightSpaceCenter.y = floor(lightSpaceCenter.y / texel) * texel
        let snappedCenter = lightRotationInverse.transformPoint(lightSpaceCenter)

        // An orthographic box around the sphere, pulled back toward the light so that
        // objects outside the view can still cast shadows into it.
        let eye = snappedCenter - direction * (radius + settings.casterDistance)
        let view = Mat4.lookAt(eye: eye, target: snappedCenter, up: up)
        let projection = Mat4.orthographic(left: -radius, right: radius, bottom: -radius, top: radius,
                                           near: 0, far: 2 * radius + settings.casterDistance)

        cascades.viewProjection[i] = projection * view
        cascades.splitFar[i] = sliceFar
        cascades.radius[i] = radius
        sliceNear = sliceFar
    }
    return cascades
}
