// Collision.swift
// Shape-against-shape tests. Pure geometry: no entities, no velocities.

import Foundation
import simd

public enum ColliderShape {
    case sphere, box, capsule
}

/// A collider placed in the world.
public struct ShapeInstance {
    public var shape = ColliderShape.sphere
    public var center = Vec3(0, 0, 0)
    public var rotation = Quat.identity
    public var halfExtents = Vec3(0.5, 0.5, 0.5)    // box
    public var radius: Float = 0.5                  // sphere and capsule
    public var halfHeight: Float = 0.5              // capsule: half the distance between the centers of its two caps

    public init() {}

    /// The ends of a capsule's inner segment.
    public var capsuleA: Vec3 { center - rotation.act(Vec3(0, halfHeight, 0)) }
    public var capsuleB: Vec3 { center + rotation.act(Vec3(0, halfHeight, 0)) }

    func axis(_ i: Int) -> Vec3 {
        var unit = Vec3(0, 0, 0)
        unit[i] = 1
        return rotation.act(unit)
    }

    public var bounds: AABB {
        switch shape {
        case .sphere:
            return AABB(center: center, halfExtents: Vec3(repeating: radius))
        case .capsule:
            var box = AABB()
            box.expand(capsuleA)
            box.expand(capsuleB)
            box.min -= Vec3(repeating: radius)
            box.max += Vec3(repeating: radius)
            return box
        case .box:
            var extent = Vec3(0, 0, 0)
            for i in 0..<3 { extent += simd_abs(axis(i)) * halfExtents[i] }
            return AABB(center: center, halfExtents: extent)
        }
    }
}

public struct ContactInfo {
    public var normal = Vec3(0, 1, 0)       // unit vector pointing from the first shape to the second
    public var depth: Float = 0             // how far the shapes overlap along the normal
    public var point = Vec3(0, 0, 0)        // a representative point of contact
}

public struct ShapeRayHit {
    public var distance: Float
    public var normal: Vec3
}

public func closestPointOnSegment(_ a: Vec3, _ b: Vec3, _ point: Vec3) -> Vec3 {
    let ab = b - a
    let lengthSquared = simd_length_squared(ab)
    if lengthSquared < 1e-12 { return a }
    return a + ab * saturate(simd_dot(point - a, ab) / lengthSquared)
}

/// The closest pair of points between segment p1-q1 and segment p2-q2.
/// From "Real-Time Collision Detection" by Christer Ericson, section 5.1.9.
public func closestPointsBetweenSegments(_ p1: Vec3, _ q1: Vec3, _ p2: Vec3, _ q2: Vec3) -> (Vec3, Vec3) {
    let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
    let a = simd_dot(d1, d1), e = simd_dot(d2, d2), f = simd_dot(d2, r)
    var s: Float = 0, t: Float = 0
    let epsilon: Float = 1e-10
    if a <= epsilon && e <= epsilon { return (p1, p2) }
    if a <= epsilon {
        t = saturate(f / e)
    } else {
        let c = simd_dot(d1, r)
        if e <= epsilon {
            s = saturate(-c / a)
        } else {
            let b = simd_dot(d1, d2)
            let denominator = a * e - b * b
            s = denominator > epsilon ? saturate((b * f - c * e) / denominator) : 0
            t = (b * s + f) / e
            if t < 0 {
                t = 0
                s = saturate(-c / a)
            } else if t > 1 {
                t = 1
                s = saturate((b - c) / a)
            }
        }
    }
    return (p1 + d1 * s, p2 + d2 * t)
}

private func sphereSphere(_ ca: Vec3, _ ra: Float, _ cb: Vec3, _ rb: Float) -> ContactInfo? {
    let d = cb - ca
    let distanceSquared = simd_length_squared(d), reach = ra + rb
    if distanceSquared >= reach * reach { return nil }
    let distance = distanceSquared.squareRoot()
    var out = ContactInfo()
    out.normal = distance > 1e-6 ? d / distance : Vec3(0, 1, 0)
    out.depth = reach - distance
    out.point = ca + out.normal * ra
    return out
}

/// Normal points from the sphere to the box.
private func sphereBox(_ center: Vec3, _ radius: Float, _ box: ShapeInstance) -> ContactInfo? {
    // Work in the box's own space, where it is axis-aligned and centered on the origin.
    let local = box.rotation.conjugate.act(center - box.center)
    var closest = simd_clamp(local, -box.halfExtents, box.halfExtents)
    let difference = local - closest
    let distanceSquared = simd_length_squared(difference)
    if distanceSquared > radius * radius { return nil }

    var out = ContactInfo()
    var outward = Vec3(0, 0, 0)             // from the box toward the sphere, in box space
    if distanceSquared > 1e-10 {
        let distance = distanceSquared.squareRoot()
        outward = difference / distance
        out.depth = radius - distance
    } else {
        // The center is inside the box: leave through the nearest face.
        var axis = 0
        var nearest = Float.greatestFiniteMagnitude
        for i in 0..<3 {
            let toFace = box.halfExtents[i] - abs(local[i])
            if toFace < nearest {
                nearest = toFace
                axis = i
            }
        }
        outward[axis] = local[axis] < 0 ? -1 : 1
        closest[axis] = outward[axis] * box.halfExtents[axis]
        out.depth = radius + nearest
    }
    out.normal = -box.rotation.act(outward)
    out.point = box.center + box.rotation.act(closest)
    return out
}

/// Separating axis test for two oriented boxes.
private func boxBox(_ a: ShapeInstance, _ b: ShapeInstance) -> ContactInfo? {
    let axesA = [a.axis(0), a.axis(1), a.axis(2)]
    let axesB = [b.axis(0), b.axis(1), b.axis(2)]
    let offset = b.center - a.center
    var best = Float.greatestFiniteMagnitude
    var bestAxis = Vec3(0, 1, 0)

    // Returns false as soon as an axis separates the boxes. `preference` makes an edge
    // axis win only when it is clearly better than a face axis, which avoids jitter.
    func test(_ candidate: Vec3, _ preference: Float) -> Bool {
        let lengthSquared = simd_length_squared(candidate)
        if lengthSquared < 1e-8 { return true }             // parallel edges: no new information
        let axis = candidate / lengthSquared.squareRoot()
        var reachA: Float = 0, reachB: Float = 0
        for i in 0..<3 {
            reachA += a.halfExtents[i] * abs(simd_dot(axesA[i], axis))
            reachB += b.halfExtents[i] * abs(simd_dot(axesB[i], axis))
        }
        let distance = simd_dot(offset, axis)
        let overlap = reachA + reachB - abs(distance)
        if overlap < 0 { return false }
        if overlap + preference < best {
            best = overlap
            bestAxis = distance < 0 ? -axis : axis
        }
        return true
    }

    for i in 0..<3 where !test(axesA[i], 0) { return nil }
    for i in 0..<3 where !test(axesB[i], 0) { return nil }
    for i in 0..<3 {
        for j in 0..<3 where !test(simd_cross(axesA[i], axesB[j]), 0.01) { return nil }
    }

    var out = ContactInfo()
    out.normal = bestAxis
    out.depth = best
    // The corner of b that reaches farthest into a.
    var corner = b.center
    for i in 0..<3 {
        corner += axesB[i] * (simd_dot(axesB[i], bestAxis) > 0 ? -b.halfExtents[i] : b.halfExtents[i])
    }
    out.point = corner
    return out
}

/// Normal points from the capsule to the box.
private func capsuleBox(_ capsule: ShapeInstance, _ box: ShapeInstance) -> ContactInfo? {
    let a = capsule.capsuleA, b = capsule.capsuleB

    // Find the point of the capsule's inner segment that is closest to the box.
    // In the box's own space the squared distance from a point to the box is the sum,
    // over the three axes, of how far the point sticks out of that axis' slab, squared.
    // Along the segment this is a chain of parabolas that changes shape only where the
    // segment crosses a slab boundary, so we cut the segment at those crossings and
    // minimize each piece exactly.
    let toLocal = box.rotation.conjugate
    let origin = toLocal.act(a - box.center), direction = toLocal.act(b - a)
    let h = box.halfExtents
    var cuts: [Float] = [0, 1]
    for axis in 0..<3 where abs(direction[axis]) >= 1e-9 {
        for side in [Float(-1), Float(1)] {
            let t = (side * h[axis] - origin[axis]) / direction[axis]
            if t > 0 && t < 1 { cuts.append(t) }
        }
    }
    cuts.sort()

    var bestT: Float = 0, bestDistanceSquared = Float.greatestFiniteMagnitude
    for i in 0..<(cuts.count - 1) {
        let t0 = cuts[i], t1 = cuts[i + 1]
        let middle = origin + direction * ((t0 + t1) * 0.5)
        var numerator: Float = 0, denominator: Float = 0
        for axis in 0..<3 where abs(middle[axis]) > h[axis] {      // skip the slabs this piece is inside of
            let face = middle[axis] > 0 ? h[axis] : -h[axis]
            numerator += (origin[axis] - face) * direction[axis]
            denominator += direction[axis] * direction[axis]
        }
        let t = denominator > 1e-12 ? min(max(-numerator / denominator, t0), t1) : t0
        let point = origin + direction * t
        let outside = simd_max(simd_abs(point) - h, Vec3(0, 0, 0))
        let distanceSquared = simd_length_squared(outside)
        if distanceSquared < bestDistanceSquared {
            bestDistanceSquared = distanceSquared
            bestT = t
        }
    }
    let localOnSegment = origin + direction * bestT
    let localOnBox = simd_clamp(localOnSegment, -h, h)
    let onBox = box.center + box.rotation.act(localOnBox)

    var out = ContactInfo()
    if bestDistanceSquared > 1e-10 {
        // The segment is outside the box: this is a sphere around its closest point against the box.
        let distance = bestDistanceSquared.squareRoot()
        if distance >= capsule.radius { return nil }
        out.normal = box.rotation.act((localOnBox - localOnSegment) / distance)
        out.depth = capsule.radius - distance
        out.point = onBox
        return out
    }

    // The segment itself passes through the box. Find the shortest way out with the
    // separating axis test (the segment is a box with no thickness), then add the radius.
    let segmentDirection = safeNormalize(b - a)
    let boxAxes = [box.axis(0), box.axis(1), box.axis(2)]
    let candidates = boxAxes + boxAxes.map { simd_cross(segmentDirection, $0) }
    let offset = box.center - capsule.center
    var best = Float.greatestFiniteMagnitude
    var bestAxis = Vec3(0, 1, 0)
    for candidate in candidates {
        let lengthSquared = simd_length_squared(candidate)
        if lengthSquared < 1e-8 { continue }
        let axis = candidate / lengthSquared.squareRoot()
        let reachSegment = capsule.halfHeight * abs(simd_dot(segmentDirection, axis))
        var reachBox: Float = 0
        for i in 0..<3 { reachBox += box.halfExtents[i] * abs(simd_dot(boxAxes[i], axis)) }
        let distance = simd_dot(offset, axis)
        let overlap = reachSegment + reachBox - abs(distance)
        if overlap < best {
            best = overlap
            bestAxis = distance < 0 ? -axis : axis
        }
    }
    out.normal = bestAxis
    out.depth = max(best, 0) + capsule.radius
    out.point = onBox
    return out
}

/// If the shapes overlap, how to push them apart; otherwise nil.
public func collide(_ a: ShapeInstance, _ b: ShapeInstance) -> ContactInfo? {
    switch (a.shape, b.shape) {
    case (.sphere, .sphere):
        return sphereSphere(a.center, a.radius, b.center, b.radius)
    case (.sphere, .box):
        return sphereBox(a.center, a.radius, b)
    case (.box, .box):
        return boxBox(a, b)
    case (.capsule, .sphere):
        let onSegment = closestPointOnSegment(a.capsuleA, a.capsuleB, b.center)
        return sphereSphere(onSegment, a.radius, b.center, b.radius)
    case (.capsule, .capsule):
        let (onA, onB) = closestPointsBetweenSegments(a.capsuleA, a.capsuleB, b.capsuleA, b.capsuleB)
        return sphereSphere(onA, a.radius, onB, b.radius)
    case (.capsule, .box):
        return capsuleBox(a, b)
    default:
        // The remaining pairs are the ones above with the arguments swapped.
        guard var swapped = collide(b, a) else { return nil }
        swapped.normal = -swapped.normal
        return swapped
    }
}

public func raycastShape(_ ray: Ray, _ shape: ShapeInstance) -> ShapeRayHit? {
    switch shape.shape {
    case .sphere:
        guard let t = intersectSphere(ray, center: shape.center, radius: shape.radius) else { return nil }
        return ShapeRayHit(distance: t, normal: safeNormalize(ray.at(t) - shape.center))

    case .box:
        // Move the ray into the box's space and run the slab test, remembering which face was entered.
        let inverse = shape.rotation.conjugate
        let origin = inverse.act(ray.origin - shape.center), direction = inverse.act(ray.direction)
        var tMin: Float = 0, tMax = Float.greatestFiniteMagnitude
        var normal = -direction                             // used when the ray starts inside
        for axis in 0..<3 {
            let h = shape.halfExtents[axis]
            if abs(direction[axis]) < 1e-8 {
                if abs(origin[axis]) > h { return nil }
                continue
            }
            var t1 = (-h - origin[axis]) / direction[axis]
            var t2 = (h - origin[axis]) / direction[axis]
            var sign: Float = -1
            if t1 > t2 {
                swap(&t1, &t2)
                sign = 1
            }
            if t1 > tMin {
                tMin = t1
                normal = Vec3(0, 0, 0)
                normal[axis] = sign
            }
            tMax = min(tMax, t2)
            if tMin > tMax { return nil }
        }
        return ShapeRayHit(distance: tMin, normal: shape.rotation.act(normal))

    case .capsule:
        // Inigo Quilez's capsule intersection.
        let pa = shape.capsuleA, pb = shape.capsuleB
        let ba = pb - pa, oa = ray.origin - pa
        let baba = simd_dot(ba, ba), bard = simd_dot(ba, ray.direction), baoa = simd_dot(ba, oa)
        let rdoa = simd_dot(ray.direction, oa), oaoa = simd_dot(oa, oa)
        let a = baba - bard * bard
        let b = baba * rdoa - baoa * bard
        let c = baba * oaoa - baoa * baoa - shape.radius * shape.radius * baba
        let h = b * b - a * c
        var t: Float = -1
        if h >= 0 && abs(a) > 1e-10 {
            let candidate = (-b - h.squareRoot()) / a
            let y = baoa + candidate * bard
            if y > 0 && y < baba {
                t = candidate                               // hit the cylindrical part
            } else {
                let oc = y <= 0 ? oa : ray.origin - pb      // otherwise test the nearer cap
                let capB = simd_dot(ray.direction, oc)
                let capC = simd_dot(oc, oc) - shape.radius * shape.radius
                let capH = capB * capB - capC
                if capH > 0 { t = -capB - capH.squareRoot() }
            }
        } else if abs(a) <= 1e-10 {
            // The ray runs along the capsule's axis: only the caps can be hit.
            for capCenter in [pa, pb] {
                if let capHit = intersectSphere(ray, center: capCenter, radius: shape.radius), t < 0 || capHit < t {
                    t = capHit
                }
            }
        }
        if t < 0 { return nil }
        let hitPoint = ray.at(t)
        return ShapeRayHit(distance: t, normal: safeNormalize(hitPoint - closestPointOnSegment(pa, pb, hitPoint)))
    }
}
