import XCTest
import simd
@testable import LMEngine

private func sphereAt(_ center: Vec3, _ radius: Float) -> ShapeInstance {
    var s = ShapeInstance()
    s.shape = .sphere
    s.center = center
    s.radius = radius
    return s
}

private func boxAt(_ center: Vec3, _ halfExtents: Vec3, _ rotation: Quat = .identity) -> ShapeInstance {
    var s = ShapeInstance()
    s.shape = .box
    s.center = center
    s.halfExtents = halfExtents
    s.rotation = rotation
    return s
}

private func capsuleAt(_ center: Vec3, _ radius: Float, _ halfHeight: Float) -> ShapeInstance {
    var s = ShapeInstance()
    s.shape = .capsule
    s.center = center
    s.radius = radius
    s.halfHeight = halfHeight
    return s
}

@discardableResult
private func addStaticBox(_ scene: Scene, _ center: Vec3, _ halfExtents: Vec3, _ rotation: Quat = .identity) -> Entity {
    let e = scene.create()
    scene.add(e, Transform(position: center, rotation: rotation))
    scene.add(e, Collider.box(halfExtents: halfExtents))
    return e
}

private func addBall(_ scene: Scene, _ center: Vec3, radius: Float = 0.5) -> Entity {
    let e = scene.create()
    scene.add(e, Transform(position: center))
    scene.add(e, Collider.sphere(radius: radius))
    scene.add(e, RigidBody())
    return e
}

private func run(_ physics: Physics, _ scene: Scene, seconds: Float) {
    let dt: Float = 1.0 / 120.0
    for _ in 0..<Int(seconds / dt) { physics.step(scene, dt: dt) }
}

private func turn(_ axis: Vec3, _ degrees: Float) -> Quat { Quat(angle: radians(degrees), axis: axis) }

final class PhysicsTests: XCTestCase {
    func testABallNeverBouncesHigherThanItStarted() {
        let scene = Scene()
        let physics = Physics()
        addStaticBox(scene, Vec3(0, -0.5, 0), Vec3(10, 0.5, 10))
        let ball = addBall(scene, Vec3(0, 4, 0))
        scene[ball, RigidBody.self]?.restitution = 0.9
        var highestAfterBounce: Float = 0
        var bounced = false
        for _ in 0..<(120 * 5) {
            physics.step(scene, dt: 1.0 / 120.0)
            guard let body = scene[ball, RigidBody.self] else { continue }
            if body.position.y < 0.6 { bounced = true }
            if bounced { highestAfterBounce = max(highestAfterBounce, body.position.y) }
        }
        XCTAssertTrue(bounced)
        XCTAssertGreaterThan(highestAfterBounce, 2)         // it does bounce
        XCTAssertLessThan(highestAfterBounce, 4)            // but loses energy
    }

    func testClosestPointsBetweenSegments() {
        var (a, b) = closestPointsBetweenSegments(Vec3(-1, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, -1), Vec3(0, 1, 1))
        XCTAssertEqual(simd_distance(a, Vec3(0, 0, 0)), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(b, Vec3(0, 1, 0)), 0, accuracy: 1e-5)
        (a, b) = closestPointsBetweenSegments(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(3, 1, 0), Vec3(5, 1, 0))
        XCTAssertEqual(a.x, 1, accuracy: 1e-5)
        XCTAssertEqual(b.x, 3, accuracy: 1e-5)
    }

    func testSphereSphereContact() {
        let info = collide(sphereAt(Vec3(0, 0, 0), 1), sphereAt(Vec3(1.5, 0, 0), 1))
        XCTAssertEqual(info?.normal.x ?? 0, 1, accuracy: 1e-5)
        XCTAssertEqual(info?.depth ?? 0, 0.5, accuracy: 1e-5)
        XCTAssertNil(collide(sphereAt(Vec3(0, 0, 0), 1), sphereAt(Vec3(2.5, 0, 0), 1)))
    }

    func testSphereBoxContactOutsideInsideAndRotated() {
        let unitBox = boxAt(Vec3(0, 0, 0), Vec3(1, 1, 1))
        // Resting on top of a box: the normal points from the sphere down to the box.
        var info = collide(sphereAt(Vec3(0, 1.4, 0), 0.5), unitBox)
        XCTAssertEqual(info?.normal.y ?? 0, -1, accuracy: 1e-5)
        XCTAssertEqual(info?.depth ?? 0, 0.1, accuracy: 1e-5)
        // The reversed order gives the reversed normal.
        info = collide(unitBox, sphereAt(Vec3(0, 1.4, 0), 0.5))
        XCTAssertEqual(info?.normal.y ?? 0, 1, accuracy: 1e-5)
        // Center inside the box: pushed out through the nearest face (+x here).
        info = collide(sphereAt(Vec3(0.9, 0, 0), 0.5), unitBox)
        XCTAssertEqual(info?.normal.x ?? 0, -1, accuracy: 1e-5)
        XCTAssertEqual(info?.depth ?? 0, 0.6, accuracy: 1e-5)
        // A box turned 45 degrees around Z has a corner at height sqrt(2).
        let turned = boxAt(Vec3(0, 0, 0), Vec3(1, 1, 1), turn(Vec3(0, 0, 1), 45))
        XCTAssertNotNil(collide(sphereAt(Vec3(0, 1.7, 0), 0.5), turned))
        XCTAssertNil(collide(sphereAt(Vec3(1.4, 1.4, 0), 0.5), turned))
    }

    func testBoxBoxSeparatingAxes() {
        let unitBox = boxAt(Vec3(0, 0, 0), Vec3(1, 1, 1))
        let info = collide(unitBox, boxAt(Vec3(1.5, 0, 0), Vec3(1, 1, 1)))
        XCTAssertEqual(info?.normal.x ?? 0, 1, accuracy: 1e-5)
        XCTAssertEqual(info?.depth ?? 0, 0.5, accuracy: 1e-5)
        XCTAssertNil(collide(unitBox, boxAt(Vec3(2.1, 0, 0), Vec3(1, 1, 1))))
        // Turned 45 degrees, the second box reaches sqrt(2) along x, so it touches at 2.3 but not at 2.5.
        XCTAssertNotNil(collide(unitBox, boxAt(Vec3(2.3, 0, 0), Vec3(1, 1, 1), turn(Vec3(0, 1, 0), 45))))
        XCTAssertNil(collide(unitBox, boxAt(Vec3(2.5, 0, 0), Vec3(1, 1, 1), turn(Vec3(0, 1, 0), 45))))
    }

    func testContactNormalAndDepthSeparateTheShapes() {
        // For any pair that overlaps, moving the second shape along the contact normal by
        // the contact depth must be exactly enough to separate the two. This checks the
        // direction and the size of every shape-pair test at once.
        var random = Random(seed: 2024)
        let kinds: [ColliderShape] = [.sphere, .box, .capsule]
        var overlapping = 0
        for _ in 0..<4000 {
            var shapes = [ShapeInstance(), ShapeInstance()]
            for k in 0..<2 {
                shapes[k].shape = kinds[random.rangeInt(0, 3)]
                shapes[k].center = random.insideUnitSphere() * 1.2
                let angle = random.range(0, 2 * Float.pi)
                shapes[k].rotation = Quat(angle: angle, axis: random.onUnitSphere())
                let hx = random.range(0.2, 1), hy = random.range(0.2, 1), hz = random.range(0.2, 1)
                shapes[k].halfExtents = Vec3(hx, hy, hz)
                shapes[k].radius = random.range(0.2, 0.8)
                shapes[k].halfHeight = random.range(0.1, 0.8)
            }
            guard let info = collide(shapes[0], shapes[1]) else { continue }
            overlapping += 1
            XCTAssertEqual(simd_length(info.normal), 1, accuracy: 1e-3)
            XCTAssertGreaterThanOrEqual(info.depth, 0)

            let margin: Float = 0.002
            var moved = shapes[1]
            moved.center += info.normal * (info.depth + margin)
            if let after = collide(shapes[0], moved) { XCTAssertLessThan(after.depth, margin * 2) }

            moved = shapes[1]
            moved.center += info.normal * (info.depth * 0.5)
            if info.depth > 0.02 { XCTAssertNotNil(collide(shapes[0], moved)) }
        }
        XCTAssertGreaterThan(overlapping, 500)
    }

    func testCapsuleContacts() {
        let capsule = capsuleAt(Vec3(0, 1, 0), 0.5, 0.5)         // spans y = 0 .. 2
        var info = collide(capsule, sphereAt(Vec3(0.8, 1.2, 0), 0.5))
        XCTAssertEqual(info?.normal.x ?? 0, 1, accuracy: 1e-5)
        XCTAssertEqual(info?.depth ?? 0, 0.2, accuracy: 1e-5)
        info = collide(capsule, boxAt(Vec3(0, -0.4, 0), Vec3(5, 0.5, 5)))      // standing on a floor
        XCTAssertEqual(info?.normal.y ?? 0, -1, accuracy: 1e-4)
        XCTAssertEqual(info?.depth ?? 0, 0.1, accuracy: 1e-4)
        info = collide(capsule, capsuleAt(Vec3(0.9, 1, 0), 0.5, 0.5))
        XCTAssertEqual(info?.depth ?? 0, 0.1, accuracy: 1e-4)
        XCTAssertNil(collide(capsule, capsuleAt(Vec3(1.1, 1, 0), 0.5, 0.5)))
    }

    func testShapeRaycasts() {
        let down = Ray(origin: Vec3(0, 10, 0), direction: Vec3(0, -1, 0))
        var hit = raycastShape(down, sphereAt(Vec3(0, 0, 0), 1))
        XCTAssertEqual(hit?.distance ?? 0, 9, accuracy: 1e-5)
        XCTAssertEqual(hit?.normal.y ?? 0, 1, accuracy: 1e-5)

        hit = raycastShape(Ray(origin: Vec3(-10, 0.2, 0.3), direction: Vec3(1, 0, 0)), boxAt(Vec3(0, 0, 0), Vec3(1, 2, 3)))
        XCTAssertEqual(hit?.distance ?? 0, 9, accuracy: 1e-5)
        XCTAssertEqual(hit?.normal.x ?? 0, -1, accuracy: 1e-5)

        // A box turned 45 degrees around Y shows an edge to a ray coming along x.
        hit = raycastShape(Ray(origin: Vec3(-10, 0, 0.5), direction: Vec3(1, 0, 0)),
                           boxAt(Vec3(0, 0, 0), Vec3(1, 1, 1), turn(Vec3(0, 1, 0), 45)))
        XCTAssertEqual(hit?.distance ?? 0, 10 - (Float(2).squareRoot() - 0.5), accuracy: 1e-4)
        XCTAssertTrue((hit?.normal.x ?? 0) < -0.7 && (hit?.normal.z ?? 0) > 0.7)

        let capsule = capsuleAt(Vec3(0, 1, 0), 0.5, 0.5)
        hit = raycastShape(Ray(origin: Vec3(-10, 1, 0), direction: Vec3(1, 0, 0)), capsule)
        XCTAssertEqual(hit?.distance ?? 0, 9.5, accuracy: 1e-4)
        hit = raycastShape(down, capsule)                         // along the axis: hits the top cap
        XCTAssertEqual(hit?.distance ?? 0, 8, accuracy: 1e-4)
        XCTAssertNil(raycastShape(Ray(origin: Vec3(-10, 5, 0), direction: Vec3(1, 0, 0)), capsule))
    }

    func testABallFallsBouncesAndComesToRestOnTheFloor() {
        let scene = Scene(), physics = Physics()
        addStaticBox(scene, Vec3(0, -0.5, 0), Vec3(10, 0.5, 10))
        let ball = addBall(scene, Vec3(0, 3, 0))
        scene[ball, RigidBody.self]?.restitution = 0.5

        run(physics, scene, seconds: 0.5)
        XCTAssertLessThan(scene[ball, RigidBody.self]!.position.y, 3)        // it fell
        run(physics, scene, seconds: 6)
        let body = scene[ball, RigidBody.self]!
        XCTAssertEqual(body.position.y, 0.5, accuracy: 0.02)                 // resting on the floor, not sinking into it
        XCTAssertLessThan(simd_length(body.velocity), 0.2)
        XCTAssertTrue(body.isGrounded)
        XCTAssertEqual(body.groundNormal.y, 1, accuracy: 1e-3)
    }

    func testABallRollsDownARampAndFrictionStopsABox() {
        let scene = Scene(), physics = Physics()
        // A ramp tilted 20 degrees around Z: it goes down toward +x.
        addStaticBox(scene, Vec3(0, 0, 0), Vec3(10, 0.5, 10), turn(Vec3(0, 0, 1), -20))
        let ball = addBall(scene, Vec3(0, 1.2, 0))
        scene[ball, RigidBody.self]?.friction = 0
        run(physics, scene, seconds: 1)
        XCTAssertGreaterThan(scene[ball, RigidBody.self]!.position.x, 0.5)
        XCTAssertGreaterThan(scene[ball, RigidBody.self]!.velocity.x, 0.5)

        // A sliding box on a flat floor is stopped by friction.
        let flat = Scene(), flatPhysics = Physics()
        addStaticBox(flat, Vec3(0, -0.5, 0), Vec3(50, 0.5, 50))
        let crate = flat.create()
        flat.add(crate, Transform(position: Vec3(0, 0.5, 0)))
        flat.add(crate, Collider.box(halfExtents: Vec3(0.5, 0.5, 0.5)))
        flat.add(crate, RigidBody(friction: 0.8, velocity: Vec3(5, 0, 0)))
        run(flatPhysics, flat, seconds: 3)
        let crateBody = flat[crate, RigidBody.self]!
        XCTAssertLessThan(abs(crateBody.velocity.x), 0.05)
        XCTAssertTrue(crateBody.position.x > 0.5 && crateBody.position.x < 5)
    }

    func testBoxesStackAndAKinematicPlatformCarriesABall() {
        let scene = Scene(), physics = Physics()
        addStaticBox(scene, Vec3(0, -0.5, 0), Vec3(10, 0.5, 10))
        let lower = scene.create(), upper = scene.create()
        for (entity, position) in [(lower, Vec3(0, 0.5, 0)), (upper, Vec3(0.1, 1.6, 0))] {
            scene.add(entity, Transform(position: position))
            scene.add(entity, Collider.box(halfExtents: Vec3(0.5, 0.5, 0.5)))
            scene.add(entity, RigidBody())
        }
        run(physics, scene, seconds: 3)
        XCTAssertEqual(scene[lower, RigidBody.self]!.position.y, 0.5, accuracy: 0.03)
        XCTAssertEqual(scene[upper, RigidBody.self]!.position.y, 1.5, accuracy: 0.05)
        XCTAssertTrue(scene[upper, RigidBody.self]!.isGrounded)

        let moving = Scene(), movingPhysics = Physics()
        let platform = moving.create()
        moving.add(platform, Transform())
        moving.add(platform, Collider.box(halfExtents: Vec3(2, 0.25, 2)))
        moving.add(platform, RigidBody(type: .kinematic, velocity: Vec3(1, 1, 0)))
        let ball = addBall(moving, Vec3(0, 0.75, 0))
        run(movingPhysics, moving, seconds: 2)
        XCTAssertEqual(moving[platform, RigidBody.self]!.position.y, 2, accuracy: 0.02)   // the platform ignores the ball's weight
        XCTAssertEqual(moving[ball, RigidBody.self]!.position.y, 2.75, accuracy: 0.05)    // the ball rides on top
        XCTAssertGreaterThan(moving[ball, RigidBody.self]!.position.x, 1)                 // and friction drags it along
    }

    func testTriggersAndContactEventsFireOnce() {
        let scene = Scene(), physics = Physics()
        physics.gravity = Vec3(0, 0, 0)
        let zone = scene.create()
        scene.add(zone, Transform(position: Vec3(5, 0, 0)))
        var zoneCollider = Collider.box(halfExtents: Vec3(1, 1, 1))
        zoneCollider.isTrigger = true
        scene.add(zone, zoneCollider)
        let ball = addBall(scene, Vec3(0, 0, 0))
        scene[ball, RigidBody.self]?.velocity = Vec3(4, 0, 0)
        scene[ball, RigidBody.self]?.linearDamping = 0

        var entered = 0, exited = 0
        physics.onTriggerEnter = { trigger, other in
            entered += 1
            XCTAssertTrue(trigger == zone && other == ball)
        }
        physics.onTriggerExit = { _, _ in exited += 1 }
        run(physics, scene, seconds: 3)
        XCTAssertTrue(entered == 1 && exited == 1)
        XCTAssertEqual(scene[ball, RigidBody.self]!.velocity.x, 4, accuracy: 1e-3)        // a trigger does not block

        let falling = Scene(), fallingPhysics = Physics()
        addStaticBox(falling, Vec3(0, -0.5, 0), Vec3(10, 0.5, 10))
        let dropped = addBall(falling, Vec3(0, 2, 0))
        falling[dropped, RigidBody.self]?.restitution = 0
        var begins = 0
        var impact: Float = 0
        fallingPhysics.onContactBegin = { contact in
            begins += 1
            impact = contact.impactSpeed
        }
        run(fallingPhysics, falling, seconds: 3)
        XCTAssertEqual(begins, 1)
        XCTAssertTrue(impact > 4 && impact < 6.5)        // sqrt(2 g h) with h = 1.5 is about 5.4
    }

    func testRaycastLayersOverlapTeleportAndInterpolation() {
        let scene = Scene(), physics = Physics()
        let nearBox = addStaticBox(scene, Vec3(0, 0, -5), Vec3(1, 1, 1))
        let farBox = addStaticBox(scene, Vec3(0, 0, -10), Vec3(1, 1, 1))
        scene[nearBox, Collider.self]?.layer = 2
        let ray = Ray(origin: Vec3(0, 0, 0), direction: Vec3(0, 0, -1))

        var hit = physics.raycast(scene, ray)
        XCTAssertEqual(hit?.entity, nearBox)
        XCTAssertEqual(hit?.distance ?? 0, 4, accuracy: 1e-5)
        XCTAssertEqual(hit?.normal.z ?? 0, 1, accuracy: 1e-5)
        hit = physics.raycast(scene, ray, mask: 1)                               // only layer 1: skips the near box
        XCTAssertEqual(hit?.entity, farBox)
        XCTAssertNil(physics.raycast(scene, ray, maxDistance: 3))                // too short
        XCTAssertEqual(physics.raycast(scene, ray, ignore: nearBox)?.entity, farBox)
        XCTAssertEqual(physics.overlapSphere(scene, center: Vec3(0, 0, -7.5), radius: 2).count, 2)
        XCTAssertEqual(physics.overlapSphere(scene, center: Vec3(0, 0, -5), radius: 0.5).count, 1)

        let moving = Scene(), movingPhysics = Physics()
        movingPhysics.gravity = Vec3(0, 0, 0)
        let ball = addBall(moving, Vec3(0, 0, 0))
        moving[ball, RigidBody.self]?.velocity = Vec3(1.2, 0, 0)
        moving[ball, RigidBody.self]?.linearDamping = 0
        movingPhysics.step(moving, dt: 0.1)
        movingPhysics.step(moving, dt: 0.1)
        movingPhysics.writeTransforms(moving, alpha: 0.5)
        XCTAssertEqual(moving[ball, Transform.self]!.position.x, 0.18, accuracy: 1e-5)     // halfway between 0.12 and 0.24
        movingPhysics.teleport(moving, ball, to: Vec3(50, 0, 0))
        movingPhysics.writeTransforms(moving, alpha: 0.5)
        XCTAssertEqual(moving[ball, Transform.self]!.position.x, 50, accuracy: 1e-5)       // no smear across the jump
    }

    func testTheSimulationIsDeterministic() {
        var results: [Vec3] = []
        for _ in 0..<2 {
            let scene = Scene(), physics = Physics()
            addStaticBox(scene, Vec3(0, -0.5, 0), Vec3(10, 0.5, 10), turn(Vec3(1, 0, 0), 5))
            let a = addBall(scene, Vec3(0, 2, 0)), b = addBall(scene, Vec3(0.3, 3.5, 0.1))
            scene[b, RigidBody.self]?.restitution = 0.6
            run(physics, scene, seconds: 4)
            results.append(scene[a, RigidBody.self]!.position + scene[b, RigidBody.self]!.position)
        }
        XCTAssertEqual(results[0], results[1])
    }
}
