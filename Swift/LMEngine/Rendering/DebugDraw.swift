// DebugDraw.swift
// Lines in 3D that last for one frame: bounding boxes, rays, axes, collider outlines.
// Call these from anywhere during a frame; the renderer draws them after the scene.

import Foundation
import ShaderTypes
import simd

public final class DebugDraw {
    public private(set) var vertices: [LineVertex] = []

    public init() {}

    public func line(_ from: Vec3, _ to: Vec3, _ color: Vec4) {
        vertices.append(LineVertex(position: from, color: color))
        vertices.append(LineVertex(position: to, color: color))
    }

    /// A box with any orientation, as its twelve edges.
    public func box(center: Vec3, halfExtents: Vec3, rotation: Quat = .identity, _ color: Vec4) {
        var corners: [Vec3] = []
        for i in 0..<8 {
            let sign = Vec3((i & 1) != 0 ? 1 : -1, (i & 2) != 0 ? 1 : -1, (i & 4) != 0 ? 1 : -1)
            corners.append(center + rotation.act(sign * halfExtents))
        }
        // Two corners share an edge when their indices differ in exactly one bit.
        for i in 0..<8 {
            for bit in [1, 2, 4] where (i & bit) == 0 {
                line(corners[i], corners[i | bit], color)
            }
        }
    }

    public func box(_ bounds: AABB, _ color: Vec4) {
        box(center: bounds.center, halfExtents: bounds.halfExtents, color)
    }

    /// Three circles, one around each axis.
    public func sphere(center: Vec3, radius: Float, _ color: Vec4, segments: Int = 24) {
        for axis in 0..<3 {
            var previous = Vec3(0, 0, 0)
            for i in 0...segments {
                let angle = Float(i) / Float(segments) * 2 * Float.pi
                let c = cos(angle) * radius, s = sin(angle) * radius
                let point = center + (axis == 0 ? Vec3(0, c, s) : (axis == 1 ? Vec3(c, 0, s) : Vec3(c, s, 0)))
                if i > 0 { line(previous, point, color) }
                previous = point
            }
        }
    }

    /// The X (red), Y (green) and Z (blue) axes of a transform.
    public func axes(_ transform: Mat4, size: Float = 1) {
        let origin = xyz(transform.columns.3)
        line(origin, origin + safeNormalize(xyz(transform.columns.0)) * size, Vec4(1, 0.2, 0.2, 1))
        line(origin, origin + safeNormalize(xyz(transform.columns.1)) * size, Vec4(0.2, 1, 0.2, 1))
        line(origin, origin + safeNormalize(xyz(transform.columns.2)) * size, Vec4(0.3, 0.5, 1, 1))
    }

    public func clear() { vertices.removeAll(keepingCapacity: true) }
}
