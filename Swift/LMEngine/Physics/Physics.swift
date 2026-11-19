// Physics.swift
// Arcade rigid-body physics: the kind most games want.
//
// What it does: spheres, oriented boxes and capsules; gravity, bouncing and friction;
// static, kinematic (moved by the game) and dynamic (moved by forces) bodies; triggers,
// collision layers, raycasts and overlap queries; a fixed time step with interpolation.
//
// What it leaves out, on purpose: bodies do not spin from impacts (rotation stays under
// the game's control), there are no joints, and fast objects can pass through thin ones.
// Those are the hard parts of a physics engine; when a game needs them, a dedicated
// library is the right tool.
//
// Entities that take part in physics must not have a parent: their Transform is
// read and written as a world-space position.

import Foundation
import simd

public enum BodyType {
    case `static`       // never moves
    case kinematic      // moves with its velocity, is not pushed by anything: platforms, doors
    case dynamic        // moved by gravity and collisions
}

public struct RigidBody {
    public var type = BodyType.dynamic
    public var mass: Float = 1
    public var restitution: Float = 0.1         // 0 does not bounce, 1 bounces back to the same height
    public var friction: Float = 0.6
    public var linearDamping: Float = 0.05      // air resistance
    public var gravityScale: Float = 1
    public var velocity = Vec3(0, 0, 0)

    // Maintained by Physics. Read them freely; change position only through Physics.teleport.
    public var position = Vec3(0, 0, 0)
    public var previousPosition = Vec3(0, 0, 0)
    public var isGrounded = false               // resting on something walkable this step
    public var groundNormal = Vec3(0, 1, 0)
    public var isInitialized = false

    public init(type: BodyType = .dynamic, mass: Float = 1, restitution: Float = 0.1, friction: Float = 0.6,
                velocity: Vec3 = Vec3(0, 0, 0)) {
        self.type = type
        self.mass = mass
        self.restitution = restitution
        self.friction = friction
        self.velocity = velocity
    }
}

/// A shape for collision detection. Without a RigidBody on the same entity it is a
/// static obstacle. Sizes are in world units and ignore Transform.scale.
public struct Collider {
    public var shape = ColliderShape.box
    public var halfExtents = Vec3(0.5, 0.5, 0.5)
    public var radius: Float = 0.5
    public var halfHeight: Float = 0.5
    public var offset = Vec3(0, 0, 0)           // from the entity's position, in its local space
    public var isTrigger = false                // detects overlaps but does not block
    public var layer: UInt32 = 1                // the group this collider belongs to, as a bit
    public var mask: UInt32 = 0xFFFF_FFFF       // the groups it interacts with

    public init() {}

    public static func sphere(radius: Float) -> Collider {
        var c = Collider()
        c.shape = .sphere
        c.radius = radius
        return c
    }

    public static func box(halfExtents: Vec3) -> Collider {
        var c = Collider()
        c.shape = .box
        c.halfExtents = halfExtents
        return c
    }

    public static func capsule(radius: Float, halfHeight: Float) -> Collider {
        var c = Collider()
        c.shape = .capsule
        c.radius = radius
        c.halfHeight = halfHeight
        return c
    }
}

public struct Contact {
    public var a: Entity
    public var b: Entity
    public var point: Vec3
    public var normal: Vec3                     // from a to b
    public var depth: Float
    public var impactSpeed: Float               // how fast the two were approaching
}

public struct RaycastHit {
    public var entity: Entity
    public var point: Vec3
    public var normal: Vec3
    public var distance: Float
}

public final class Physics {
    public var gravity = Vec3(0, -9.81, 0)
    public var solverIterations = 6

    /// Two solid colliders started touching.
    public var onContactBegin: ((Contact) -> Void)?
    /// Something entered or left a trigger. The trigger is the first argument.
    public var onTriggerEnter: ((Entity, Entity) -> Void)?
    public var onTriggerExit: ((Entity, Entity) -> Void)?

    /// The solid contacts found by the last step.
    public private(set) var contacts: [Contact] = []

    private var touching: [UInt64: (Entity, Entity)] = [:]
    private var triggering: [UInt64: (Entity, Entity)] = [:]

    private let penetrationSlop: Float = 0.005      // overlap we tolerate, to keep resting contacts stable
    private let correctionFraction: Float = 0.8     // how much of the remaining overlap is removed per step
    private let bounceThreshold: Float = 1.0        // approach speeds below this do not bounce
    private let walkableNormalY: Float = 0.65       // surfaces flatter than about 50 degrees count as ground

    private struct Proxy {
        var entity: Entity
        var collider: Collider
        var bodyIndex: Int?
        var shape: ShapeInstance
        var bounds: AABB
        var inverseMass: Float
    }

    public init() {}

    /// Forgets every contact and trigger overlap. Call it after Scene.clear(), so that
    /// no "exit" event is sent for entities that no longer exist.
    public func reset() {
        contacts.removeAll()
        touching.removeAll()
        triggering.removeAll()
    }

    private static func makeShape(_ collider: Collider, position: Vec3, rotation: Quat) -> ShapeInstance {
        var shape = ShapeInstance()
        shape.shape = collider.shape
        shape.center = position + rotation.act(collider.offset)
        shape.rotation = rotation
        shape.halfExtents = collider.halfExtents
        shape.radius = collider.radius
        shape.halfHeight = collider.halfHeight
        return shape
    }

    private static func pairKey(_ a: Entity, _ b: Entity) -> UInt64 {
        (UInt64(max(a.index, b.index)) << 32) | UInt64(min(a.index, b.index))
    }

    /// Advances the simulation by `dt` seconds. Call with a fixed dt.
    public func step(_ scene: Scene, dt: Float) {
        // 1. Integrate: velocity from forces, then position from velocity (semi-implicit Euler).
        let gravity = self.gravity
        scene.each(RigidBody.self, Transform.self) { _, body, transform in
            if !body.isInitialized {
                body.position = transform.position
                body.isInitialized = true
            }
            body.previousPosition = body.position
            body.isGrounded = false
            if body.type == .dynamic {
                body.velocity += gravity * (body.gravityScale * dt)
                body.velocity *= 1 / (1 + body.linearDamping * dt)
            }
            if body.type != .`static` { body.position += body.velocity * dt }
        }

        // 2. Place every collider in the world. Bodies are copied into a local array,
        //    worked on there, and written back to the scene at the end of the step.
        var proxies: [Proxy] = []
        var bodies: [RigidBody] = []
        var bodyEntities: [Entity] = []
        scene.each(Collider.self, Transform.self) { entity, collider, transform in
            var bodyIndex: Int? = nil
            var position = transform.position
            var inverseMass: Float = 0
            if let body = scene[entity, RigidBody.self] {
                bodyIndex = bodies.count
                bodies.append(body)
                bodyEntities.append(entity)
                position = body.position
                if body.type == .dynamic { inverseMass = 1 / max(body.mass, 1e-4) }
            }
            let shape = Physics.makeShape(collider, position: position, rotation: transform.rotation)
            proxies.append(Proxy(entity: entity, collider: collider, bodyIndex: bodyIndex, shape: shape,
                                 bounds: shape.bounds, inverseMass: inverseMass))
        }

        func velocity(of proxy: Proxy) -> Vec3 {
            if let i = proxy.bodyIndex { return bodies[i].velocity }
            return Vec3(0, 0, 0)
        }

        func moves(_ proxy: Proxy) -> Bool {
            if let i = proxy.bodyIndex { return bodies[i].type != .`static` }
            return false
        }

        // 3. Broad phase, "sort and sweep": order the boxes along x, then each box only
        //    needs to be compared with the ones that start before it ends.
        let order = proxies.indices.sorted { proxies[$0].bounds.min.x < proxies[$1].bounds.min.x }

        contacts.removeAll()
        var contactProxies: [(Int, Int)] = []
        var touchingNow: [UInt64: (Entity, Entity)] = [:]
        var triggeringNow: [UInt64: (Entity, Entity)] = [:]

        for i in 0..<order.count {
            let a = proxies[order[i]]
            var j = i + 1
            while j < order.count {
                let b = proxies[order[j]]
                j += 1
                if b.bounds.min.x > a.bounds.max.x { break }                // nothing further along can overlap a
                if !a.bounds.intersects(b.bounds) { continue }
                if (a.collider.layer & b.collider.mask) == 0 || (b.collider.layer & a.collider.mask) == 0 { continue }
                if !moves(a) && !moves(b) { continue }                      // two obstacles never need testing

                // 4. Narrow phase: the exact shapes.
                guard let info = collide(a.shape, b.shape) else { continue }

                if a.collider.isTrigger || b.collider.isTrigger {
                    triggeringNow[Physics.pairKey(a.entity, b.entity)] =
                        a.collider.isTrigger ? (a.entity, b.entity) : (b.entity, a.entity)
                    continue
                }
                if a.inverseMass + b.inverseMass <= 0 { continue }          // kinematic against static: nothing to solve

                let approach = -simd_dot(velocity(of: b) - velocity(of: a), info.normal)
                contacts.append(Contact(a: a.entity, b: b.entity, point: info.point, normal: info.normal,
                                        depth: info.depth, impactSpeed: max(0, approach)))
                contactProxies.append((order[i], order[j - 1]))
                touchingNow[Physics.pairKey(a.entity, b.entity)] = (a.entity, b.entity)
            }
        }

        // 5. Resolve velocities with impulses. Several passes let contacts that share a
        //    body, like a ball in a corner, settle against each other.
        for _ in 0..<solverIterations {
            for c in 0..<contacts.count {
                let contact = contacts[c]
                let a = proxies[contactProxies[c].0], b = proxies[contactProxies[c].1]
                var velocityA = velocity(of: a), velocityB = velocity(of: b)
                var relative = velocityB - velocityA
                let normalSpeed = simd_dot(relative, contact.normal)
                if normalSpeed >= 0 { continue }                            // already separating

                let restitutionA = a.bodyIndex.map { bodies[$0].restitution } ?? 0
                let restitutionB = b.bodyIndex.map { bodies[$0].restitution } ?? 0
                let bounce = -normalSpeed > bounceThreshold ? max(restitutionA, restitutionB) : 0
                let inverseMassSum = a.inverseMass + b.inverseMass
                let normalImpulse = -(1 + bounce) * normalSpeed / inverseMassSum
                let impulse = contact.normal * normalImpulse
                velocityA -= impulse * a.inverseMass
                velocityB += impulse * b.inverseMass

                // Friction acts along the surface, against the sliding direction, and can
                // never be stronger than the friction coefficient times the normal impulse.
                relative = velocityB - velocityA
                var tangent = relative - contact.normal * simd_dot(relative, contact.normal)
                let slideSpeed = simd_length(tangent)
                if slideSpeed > 1e-5 {
                    tangent /= slideSpeed
                    let frictionA = a.bodyIndex.map { bodies[$0].friction } ?? 0.6
                    let frictionB = b.bodyIndex.map { bodies[$0].friction } ?? 0.6
                    let coefficient = (frictionA * frictionB).squareRoot()
                    let frictionImpulse = min(slideSpeed / inverseMassSum, coefficient * normalImpulse)
                    velocityA += tangent * (frictionImpulse * a.inverseMass)
                    velocityB -= tangent * (frictionImpulse * b.inverseMass)
                }
                if a.inverseMass > 0, let i = a.bodyIndex { bodies[i].velocity = velocityA }
                if b.inverseMass > 0, let i = b.bodyIndex { bodies[i].velocity = velocityB }
            }
        }

        // 6. Remove what is left of the overlap by moving the bodies apart, and note who
        //    is standing on what.
        for c in 0..<contacts.count {
            let contact = contacts[c]
            let a = proxies[contactProxies[c].0], b = proxies[contactProxies[c].1]
            let inverseMassSum = a.inverseMass + b.inverseMass
            let amount = max(contact.depth - penetrationSlop, 0) * correctionFraction / inverseMassSum
            if a.inverseMass > 0, let i = a.bodyIndex {
                bodies[i].position -= contact.normal * (amount * a.inverseMass)
                if contact.normal.y < -walkableNormalY {
                    bodies[i].isGrounded = true
                    bodies[i].groundNormal = -contact.normal
                }
            }
            if b.inverseMass > 0, let i = b.bodyIndex {
                bodies[i].position += contact.normal * (amount * b.inverseMass)
                if contact.normal.y > walkableNormalY {
                    bodies[i].isGrounded = true
                    bodies[i].groundNormal = contact.normal
                }
            }
        }

        for (i, entity) in bodyEntities.enumerated() {
            scene[entity, RigidBody.self] = bodies[i]
        }

        // 7. Events. Collected first and sent last, so a callback can change the scene freely.
        let began = contacts.filter { touching[Physics.pairKey($0.a, $0.b)] == nil }
        let entered = triggeringNow.filter { triggering[$0.key] == nil }.map { $0.value }
        let exited = triggering.filter { triggeringNow[$0.key] == nil }.map { $0.value }
        touching = touchingNow
        triggering = triggeringNow

        if let callback = onContactBegin { began.forEach(callback) }
        if let callback = onTriggerEnter { entered.forEach { callback($0.0, $0.1) } }
        if let callback = onTriggerExit { exited.forEach { callback($0.0, $0.1) } }
    }

    /// Writes body positions into Transforms, blended between the last two steps.
    /// `alpha` is Time.alpha.
    public func writeTransforms(_ scene: Scene, alpha: Float) {
        scene.each(RigidBody.self, Transform.self) { _, body, transform in
            if body.isInitialized {
                transform.position = lerp(body.previousPosition, body.position, alpha)
            }
        }
    }

    /// Moves a body instantly, without sweeping through what is in between.
    public func teleport(_ scene: Scene, _ entity: Entity, to position: Vec3) {
        scene[entity, Transform.self]?.position = position
        if var body = scene[entity, RigidBody.self] {
            body.position = position
            body.previousPosition = position                        // no blending across the jump
            body.isInitialized = true
            scene[entity, RigidBody.self] = body
        }
    }

    /// The closest collider hit by the ray. Triggers are ignored.
    public func raycast(_ scene: Scene, _ ray: Ray, maxDistance: Float = 1e9, mask: UInt32 = 0xFFFF_FFFF,
                        ignore: Entity = .invalid) -> RaycastHit? {
        var closest: RaycastHit? = nil
        scene.each(Collider.self, Transform.self) { entity, collider, transform in
            if collider.isTrigger || (collider.layer & mask) == 0 || entity == ignore { return }
            var position = transform.position
            if let body = scene[entity, RigidBody.self], body.isInitialized { position = body.position }
            let shape = Physics.makeShape(collider, position: position, rotation: transform.rotation)
            guard let hit = raycastShape(ray, shape), hit.distance <= maxDistance else { return }
            if closest == nil || hit.distance < closest!.distance {
                closest = RaycastHit(entity: entity, point: ray.at(hit.distance), normal: hit.normal, distance: hit.distance)
            }
        }
        return closest
    }

    /// Every entity with a collider that touches the sphere.
    public func overlapSphere(_ scene: Scene, center: Vec3, radius: Float, mask: UInt32 = 0xFFFF_FFFF) -> [Entity] {
        var found: [Entity] = []
        var probe = ShapeInstance()
        probe.shape = .sphere
        probe.center = center
        probe.radius = radius
        scene.each(Collider.self, Transform.self) { entity, collider, transform in
            if (collider.layer & mask) == 0 { return }
            var position = transform.position
            if let body = scene[entity, RigidBody.self], body.isInitialized { position = body.position }
            if collide(probe, Physics.makeShape(collider, position: position, rotation: transform.rotation)) != nil {
                found.append(entity)
            }
        }
        return found
    }
}
