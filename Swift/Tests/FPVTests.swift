import XCTest
import simd
import LMEngine
@testable import FPVKit

private func fly(_ drone: inout Drone, _ input: StickInput, _ mode: FlightMode, seconds: Float) {
    let dt: Float = 1.0 / 240.0
    for _ in 0..<Int(seconds / dt) { drone.step(input, mode: mode, dt: dt) }
}

final class FPVTests: XCTestCase {
    func testHoverThrottleHoldsTheDroneStill() {
        var drone = Drone()
        fly(&drone, StickInput(throttle: drone.hoverThrottle), .angle, seconds: 2)
        XCTAssertEqual(drone.position.y, 0, accuracy: 0.01)
        XCTAssertEqual(drone.speed, 0, accuracy: 0.01)
        fly(&drone, StickInput(throttle: 0), .angle, seconds: 1)
        XCTAssertLessThan(drone.velocity.y, -5)                 // motors off: it falls
    }

    func testSticksMoveTheDroneTheWayAPilotExpects() {
        // Stick forward: nose down, flies toward -Z (its nose), then levels when released.
        var drone = Drone()
        fly(&drone, StickInput(throttle: 0.4, pitch: 1), .angle, seconds: 2)
        XCTAssertLessThan(drone.position.z, -10)
        XCTAssertEqual(drone.position.x, 0, accuracy: 0.01)
        XCTAssertLessThan(drone.forward.y, -0.7)
        XCTAssertEqual(degrees(drone.rotation.eulerAngles.x), -55, accuracy: 1)     // the tilt limit of angle mode
        fly(&drone, StickInput(throttle: 0.3), .angle, seconds: 1)
        XCTAssertEqual(drone.up.y, 1, accuracy: 0.01)

        // Roll right: drifts toward +X.
        drone = Drone()
        fly(&drone, StickInput(throttle: 0.3, roll: 1), .angle, seconds: 1)
        XCTAssertGreaterThan(drone.velocity.x, 3)

        // Yaw right: a quarter turn later the nose points toward +X.
        drone = Drone()
        fly(&drone, StickInput(throttle: 0.25, yaw: 1), .angle, seconds: 90 / drone.settings.angleYawRate + 0.05)
        XCTAssertGreaterThan(drone.forward.x, 0.95)
    }

    func testAcroKeepsItsAttitudeAndAngleModeRecoversFromUpsideDown() {
        var drone = Drone()
        fly(&drone, StickInput(throttle: 0.3, roll: 1), .acro, seconds: 0.2)
        let leaned = drone.up
        XCTAssertLessThan(leaned.y, 0.5)
        fly(&drone, StickInput(throttle: 0.3), .acro, seconds: 0.5)        // sticks released: no self-leveling
        XCTAssertEqual(simd_dot(drone.up, leaned), 1, accuracy: 0.05)

        drone = Drone()
        drone.rotation = Quat(angle: radians(170), axis: Vec3(0, 0, 1))
        fly(&drone, StickInput(throttle: 0.3), .angle, seconds: 1.5)
        XCTAssertEqual(drone.up.y, 1, accuracy: 0.01)
    }

    func testRatesCurveIsGentleInTheMiddleAndReachesTheMaximum() {
        XCTAssertEqual(Drone.rate(0, center: 200, maximum: 670), 0, accuracy: 1e-4)
        XCTAssertEqual(Drone.rate(1, center: 200, maximum: 670), 670, accuracy: 1e-3)
        XCTAssertEqual(Drone.rate(-1, center: 200, maximum: 670), -670, accuracy: 1e-3)
        XCTAssertLessThan(Drone.rate(0.5, center: 200, maximum: 670), 335)      // below the straight line
        XCTAssertEqual(Drone.rate(3, center: 200, maximum: 670), 670, accuracy: 1e-3)   // out-of-range sticks are clamped
    }

    func testAGateCountsOnlyWhenFlownThroughTheRightWay() {
        let gate = Gate(center: Vec3(0, 2, -10), yawDegrees: 0, width: 4, height: 3)
        XCTAssertTrue(gate.isPassed(from: Vec3(0, 2, -9), to: Vec3(0, 2, -11)))
        XCTAssertTrue(gate.isPassed(from: Vec3(1.5, 3, -9.9), to: Vec3(1.9, 3.4, -10.1)))
        XCTAssertFalse(gate.isPassed(from: Vec3(0, 2, -11), to: Vec3(0, 2, -9)))        // backwards
        XCTAssertFalse(gate.isPassed(from: Vec3(3, 2, -9), to: Vec3(3, 2, -11)))        // beside it
        XCTAssertFalse(gate.isPassed(from: Vec3(0, 4.5, -9), to: Vec3(0, 4.5, -11)))    // over it
        XCTAssertFalse(gate.isPassed(from: Vec3(0, 2, -8), to: Vec3(0, 2, -9)))         // not there yet

        // A gate that faces +X is flown through toward +X.
        let turned = Gate(center: Vec3(5, 2, 0), yawDegrees: -90)
        XCTAssertEqual(turned.forward.x, 1, accuracy: 1e-5)
        XCTAssertTrue(turned.isPassed(from: Vec3(4, 2, 0.5), to: Vec3(6, 2, 0.5)))
    }

    func testARaceCountsGatesInOrderAndLaps() {
        var race = Race(gateCount: 3, laps: 2)
        XCTAssertFalse(race.pass(gate: 0))                      // still counting down
        race.update(dt: 3.1)
        XCTAssertEqual(race.phase, .running)
        race.update(dt: 1)
        XCTAssertFalse(race.pass(gate: 1))                      // out of order
        XCTAssertTrue(race.pass(gate: 0))
        XCTAssertEqual(race.lastGate, 0)
        XCTAssertTrue(race.pass(gate: 1))
        race.update(dt: 4)
        XCTAssertTrue(race.pass(gate: 2))
        XCTAssertEqual(race.lap, 1)
        XCTAssertEqual(race.nextGate, 0)
        XCTAssertEqual(race.lapTimes[0], 5, accuracy: 1e-4)
        for gate in 0..<3 {
            race.update(dt: 1)
            race.pass(gate: gate)
        }
        XCTAssertEqual(race.phase, .finished)
        XCTAssertEqual(race.time, 8, accuracy: 1e-4)
        XCTAssertEqual(race.lapTimes[1], 3, accuracy: 1e-4)
        race.update(dt: 5)
        XCTAssertEqual(race.time, 8, accuracy: 1e-4)            // the clock has stopped
        XCTAssertEqual(formatTime(83.5), "1:23.50")
    }

    func testTheCourseIsALoopOfGatesThatFaceEachOther() {
        // Flying straight from each gate to the next must cross the next gate the right way.
        for (index, gate) in courseGates.enumerated() {
            let next = courseGates[(index + 1) % courseGates.count]
            let direction = simd_normalize(next.center - gate.center)
            XCTAssertGreaterThan(simd_dot(direction, next.forward), 0.2, "gate \(index + 1) faces away from the gate before it")
            XCTAssertTrue(next.isPassed(from: next.center - direction, to: next.center + direction))
            XCTAssertGreaterThan(next.center.y - next.height * 0.5, 0.2)        // the opening is above the ground
        }
        XCTAssertEqual(distanceToCourse(Vec2(courseGates[0].center.x, courseGates[0].center.z)), 0, accuracy: 1e-4)
    }
}
