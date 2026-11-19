import XCTest
import simd
@testable import LMEngine

final class MathTests: XCTestCase {
    func testPerspectiveMapsNearTo0AndFarTo1() {
        let p = Mat4.perspective(fovY: radians(60), aspect: 1.5, near: 0.1, far: 100)
        let nearPoint = p * Vec4(0, 0, -0.1, 1), farPoint = p * Vec4(0, 0, -100, 1)
        XCTAssertEqual(nearPoint.z / nearPoint.w, 0, accuracy: 1e-5)
        XCTAssertEqual(farPoint.z / farPoint.w, 1, accuracy: 1e-4)
        // A point on the top edge of the view lands on y = 1.
        let top = p * Vec4(0, tan(radians(30)) * 10, -10, 1)
        XCTAssertEqual(top.y / top.w, 1, accuracy: 1e-4)
    }

    func testOrthographicMapsBoxToClipSpace() {
        let o = Mat4.orthographic(left: -2, right: 2, bottom: -1, top: 1, near: 1, far: 11)
        let a = o * Vec4(2, 1, -1, 1), b = o * Vec4(-2, -1, -11, 1)
        XCTAssertEqual(a.x, 1, accuracy: 1e-6); XCTAssertEqual(a.y, 1, accuracy: 1e-6); XCTAssertEqual(a.z, 0, accuracy: 1e-6)
        XCTAssertEqual(b.x, -1, accuracy: 1e-6); XCTAssertEqual(b.y, -1, accuracy: 1e-6); XCTAssertEqual(b.z, 1, accuracy: 1e-6)
    }

    func testLookAtPutsTargetOnNegativeZ() {
        let view = Mat4.lookAt(eye: Vec3(3, 4, 5), target: Vec3(0, 1, 0))
        let target = view.transformPoint(Vec3(0, 1, 0))
        XCTAssertEqual(target.x, 0, accuracy: 1e-5)
        XCTAssertEqual(target.y, 0, accuracy: 1e-5)
        XCTAssertLessThan(target.z, 0)
        XCTAssertEqual(-target.z, simd_distance(Vec3(3, 4, 5), Vec3(0, 1, 0)), accuracy: 1e-4)
    }

    func testLookRotationTurnsMinusZToForward() {
        for forward in [Vec3(1, 0, 0), Vec3(0, 0, 1), Vec3(1, 1, 1), Vec3(0, 1, 0), Vec3(0, -1, 0)] {
            let result = Quat.lookRotation(forward: forward).act(Vec3(0, 0, -1))
            XCTAssertEqual(simd_distance(result, simd_normalize(forward)), 0, accuracy: 1e-4)
        }
        let up = Quat.lookRotation(forward: Vec3(1, 0, 0)).act(Vec3(0, 1, 0))
        XCTAssertEqual(up.y, 1, accuracy: 1e-5)
    }

    func testComposeEqualsTranslateRotateScale() {
        let t = Vec3(1, 2, 3), s = Vec3(2, 3, 4)
        let r = Quat(pitch: 0.3, yaw: 1.1, roll: -0.4)
        let expected = Mat4.translation(t) * Mat4.rotation(r) * Mat4.scaling(s)
        XCTAssertTrue(simd_almost_equal_elements(Mat4.compose(position: t, rotation: r, scale: s), expected, 1e-5))
    }

    func testNormalMatrixKeepsNormalsPerpendicular() {
        let model = Mat4.compose(position: Vec3(0, 0, 0), rotation: Quat(pitch: 0.5, yaw: 0.2), scale: Vec3(1, 4, 0.5))
        let tangent = model.transformDirection(Vec3(1, 0, 0))
        let normal = model.normalMatrix.transformDirection(Vec3(0, 1, 0))
        XCTAssertEqual(simd_dot(tangent, normal), 0, accuracy: 1e-5)
    }

    func testFrustumCullsBoxesOutsideTheView() {
        let projection = Mat4.perspective(fovY: radians(60), aspect: 1, near: 0.1, far: 100)
        let viewProjection = projection * Mat4.lookAt(eye: Vec3(0, 0, 0), target: Vec3(0, 0, -1))
        let frustum = Frustum(viewProjection: viewProjection)
        let half = Vec3(0.5, 0.5, 0.5)
        XCTAssertTrue(frustum.intersects(AABB(center: Vec3(0, 0, -10), halfExtents: half)))
        XCTAssertFalse(frustum.intersects(AABB(center: Vec3(0, 0, 10), halfExtents: half)))       // behind the camera
        XCTAssertFalse(frustum.intersects(AABB(center: Vec3(0, 0, -200), halfExtents: half)))     // beyond the far plane
        XCTAssertFalse(frustum.intersects(AABB(center: Vec3(-30, 0, -10), halfExtents: half)))    // far to the left
        XCTAssertTrue(frustum.intersects(AABB(center: Vec3(-5.9, 0, -10), halfExtents: half)))    // straddles the left plane
        XCTAssertFalse(frustum.intersects(AABB(center: Vec3(0, 0, -0.05), halfExtents: Vec3(0.02, 0.02, 0.02))))
    }

    func testFrustumCanIgnoreItsNearPlane() {
        // A shadow map's box: whatever stands between the light and the box must still count.
        let projection = Mat4.orthographic(left: -5, right: 5, bottom: -5, top: 5, near: 0, far: 20)
        let frustum = Frustum(viewProjection: projection * Mat4.lookAt(eye: Vec3(0, 0, 0), target: Vec3(0, 0, -1)))
        let half = Vec3(0.5, 0.5, 0.5)
        let inFront = AABB(center: Vec3(0, 0, 30), halfExtents: half)                  // on the light's side of the near plane
        XCTAssertFalse(frustum.intersects(inFront))
        XCTAssertTrue(frustum.intersects(inFront, testNearPlane: false))
        XCTAssertFalse(frustum.intersects(AABB(center: Vec3(0, 0, -30), halfExtents: half), testNearPlane: false))  // beyond the far plane: still out
        XCTAssertFalse(frustum.intersects(AABB(center: Vec3(9, 0, 30), halfExtents: half), testNearPlane: false))   // off to the side: still out
    }

    func testAABBTransformedEnclosesRotatedBox() {
        let box = AABB(min: Vec3(-1, -1, -1), max: Vec3(1, 1, 1))
        let turned = box.transformed(Mat4.rotation(Quat(angle: radians(45), axis: Vec3(0, 1, 0))))
        XCTAssertEqual(turned.max.x, Float(2).squareRoot(), accuracy: 1e-5)
        XCTAssertEqual(turned.max.y, 1, accuracy: 1e-5)
        XCTAssertEqual(box.transformed(Mat4.translation(Vec3(5, 0, 0))).min.x, 4, accuracy: 1e-5)
    }

    func testRayIntersections() {
        let ray = Ray(origin: Vec3(0, 0, 5), direction: Vec3(0, 0, -1))
        XCTAssertEqual(intersectSphere(ray, center: Vec3(0, 0, 0), radius: 1) ?? -1, 4, accuracy: 1e-5)
        XCTAssertNil(intersectSphere(ray, center: Vec3(3, 0, 0), radius: 1))
        XCTAssertEqual(intersectAABB(ray, AABB(min: Vec3(-1, -1, -1), max: Vec3(1, 1, 2))) ?? -1, 3, accuracy: 1e-5)
        XCTAssertNil(intersectAABB(Ray(origin: Vec3(0, 5, 5), direction: Vec3(0, 0, -1)), AABB(min: Vec3(-1, -1, -1), max: Vec3(1, 1, 1))))
        let down = Ray(origin: Vec3(0, 3, 0), direction: Vec3(0, -1, 0))
        XCTAssertEqual(intersectPlane(down, Plane(normal: Vec3(0, 1, 0), d: 0)) ?? -1, 3, accuracy: 1e-5)
    }

    func testRandomIsDeterministicAndInRange() {
        // The same values the C++ engine's tests check: both implementations must
        // produce the same sequence.
        var rng = Random(seed: 42)
        XCTAssertEqual(rng.nextUInt(), 3270867926)
        XCTAssertEqual(rng.nextUInt(), 1795671209)
        XCTAssertEqual(rng.nextUInt(), 1924641435)
        XCTAssertEqual(rng.next(), 0.266133, accuracy: 1e-5)

        var other = Random(seed: 7)
        for _ in 0..<1000 {
            let value = other.range(2, 3)
            XCTAssertTrue(value >= 2 && value < 3)
            XCTAssertEqual(simd_length(other.onUnitSphere()), 1, accuracy: 1e-4)
            XCTAssertGreaterThanOrEqual(other.inCone(Vec3(0, 1, 0), halfAngle: radians(20)).y, cos(radians(20)) - 1e-4)
        }
    }

    func testDampIsFrameRateIndependent() {
        var a: Float = 0, b: Float = 0
        for _ in 0..<60 { a = damp(a, 10, sharpness: 5, dt: 1.0 / 60.0) }
        for _ in 0..<240 { b = damp(b, 10, sharpness: 5, dt: 1.0 / 240.0) }
        XCTAssertEqual(a, b, accuracy: 1e-3)
        XCTAssertGreaterThan(a, 9.9)
    }
}

extension MathTests {
    func testEulerAnglesComeBackOutOfARotation() {
        for angles in [Vec3(0.3, -1.2, 0.5), Vec3(-1.0, 2.5, -0.7), Vec3(0, 0, 0), Vec3(1.2, 0.1, 3.0), Vec3(0, -3.0, 0)] {
            let back = Quat(pitch: angles.x, yaw: angles.y, roll: angles.z).eulerAngles
            XCTAssertEqual(back.x, angles.x, accuracy: 1e-4)
            XCTAssertEqual(back.y, angles.y, accuracy: 1e-4)
            XCTAssertEqual(back.z, angles.z, accuracy: 1e-4)
        }
        // Straight up: only the rotation as a whole can be recovered, not the split between yaw and roll.
        let up = Quat(pitch: Float.pi / 2, yaw: 0.4, roll: 0.3)
        let angles = up.eulerAngles
        let again = Quat(pitch: angles.x, yaw: angles.y, roll: angles.z)
        XCTAssertEqual(abs(simd_dot(up.vector, again.vector)), 1, accuracy: 1e-4)
    }
}
