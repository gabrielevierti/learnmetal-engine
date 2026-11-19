// The drone game's flight model and race rules. No graphics involved: the model is
// stepped in a loop, exactly as the game steps it, and asked where the drone ended up.

import FPVKit
import LMEngine
import XCTest
import simd

final class FPVTests: XCTestCase {
    private let step: Float = 1.0 / 480.0

    private func fly(_ drone: inout Drone, _ sticks: StickInput, _ mode: FlightMode, seconds: Float) {
        for _ in 0..<Int(seconds / step) { drone.step(sticks, mode: mode, dt: step) }
    }

    /// A drone high in the air, hovering, with its motors already up to speed.
    private func hovering(_ airframe: Airframe) -> (drone: Drone, sticks: StickInput) {
        var drone = Drone(airframe)
        drone.place(at: Vec3(0, 100, 0), heading: 0)
        var sticks = StickInput(throttle: drone.hoverThrottle)
        fly(&drone, sticks, .angle, seconds: 0.5)
        sticks.throttle = drone.hoverThrottle
        return (drone, sticks)
    }

    func testHoverThrottleHoldsTheDroneAndIsFarBelowHalf() {
        for airframe in [Airframe.fiveInch, Airframe.whoop] {
            var (drone, sticks) = hovering(airframe)
            let before = drone.position.y
            fly(&drone, sticks, .angle, seconds: 2)
            XCTAssertLessThan(abs(drone.position.y - before), 1.5)
            XCTAssertLessThan(drone.speed, 1.5)
            XCTAssertEqual(drone.up.y, 1, accuracy: 1e-3)
            sticks.throttle = 0
        }
        // Thrust grows with the square of motor speed: a strong quad hovers on a quarter of its throttle.
        let strong = Drone(.fiveInch)
        XCTAssertTrue(strong.hoverThrottle > 0.15 && strong.hoverThrottle < 0.32)
        let weak = Drone(.whoop)
        XCTAssertTrue(weak.hoverThrottle > 0.35 && weak.hoverThrottle < 0.55)
    }

    func testSticksMoveTheDroneTheWayAPilotExpects() {
        var (forward, sticks) = hovering(.fiveInch)
        sticks.pitch = 0.5
        fly(&forward, sticks, .angle, seconds: 1.5)
        XCTAssertLessThan(forward.position.z, -3)                   // stick forward: toward -Z, where the nose points
        XCTAssertLessThan(abs(forward.position.x), 0.5)

        var (sideways, rollSticks) = hovering(.fiveInch)
        rollSticks.roll = 0.5
        fly(&sideways, rollSticks, .angle, seconds: 1.5)
        XCTAssertGreaterThan(sideways.position.x, 3)                // stick right: toward +X

        var (turning, yawSticks) = hovering(.fiveInch)
        yawSticks.yaw = 0.3
        fly(&turning, yawSticks, .angle, seconds: 0.5)
        XCTAssertGreaterThan(turning.forward.x, 0.2)                // yaw right: the nose swings toward +X
        XCTAssertEqual(turning.up.y, 1, accuracy: 0.01)

        var (climbing, climbSticks) = hovering(.fiveInch)
        climbSticks.throttle = 1
        fly(&climbing, climbSticks, .angle, seconds: 0.5)
        XCTAssertGreaterThan(climbing.velocity.y, 15)               // more than three g: a real 5-inch leaps
    }

    func testAcroKeepsItsAttitudeAndAngleModeRecoversFromUpsideDown() {
        var (acro, sticks) = hovering(.fiveInch)
        sticks.roll = 0.6
        fly(&acro, sticks, .acro, seconds: 0.3)
        sticks.roll = 0
        fly(&acro, sticks, .acro, seconds: 0.2)                     // the roll stops
        let tilt = acro.up.y
        XCTAssertLessThan(tilt, 0.75)
        fly(&acro, sticks, .acro, seconds: 0.5)
        XCTAssertEqual(acro.up.y, tilt, accuracy: 0.03)             // hands off, it stays where it was left

        var (angle, levelSticks) = hovering(.fiveInch)
        angle.rotation = Quat(angle: radians(178), axis: Vec3(0, 0, 1))
        fly(&angle, levelSticks, .angle, seconds: 1.2)
        XCTAssertGreaterThan(angle.up.y, 0.99)
        levelSticks.throttle = 0
    }

    func testRatesFollowBetaflightActualRates() {
        XCTAssertEqual(actualRate(0, center: 70, maximum: 670, expo: 0), 0, accuracy: 1e-4)
        XCTAssertEqual(actualRate(1, center: 70, maximum: 670, expo: 0), 670, accuracy: 1e-3)
        XCTAssertEqual(actualRate(-1, center: 70, maximum: 670, expo: 0.5), -670, accuracy: 1e-3)
        XCTAssertEqual(actualRate(0.001, center: 70, maximum: 670, expo: 0) / 0.001, 70, accuracy: 1)   // the slope in the middle is the center rate
        XCTAssertEqual(actualRate(0.5, center: 70, maximum: 670, expo: 0), 35 + 600 * 0.25, accuracy: 1e-3)
        XCTAssertLessThan(actualRate(0.5, center: 70, maximum: 670, expo: 0.8), actualRate(0.5, center: 70, maximum: 670, expo: 0))
    }

    func testARollReachesItsRateQuicklyWithLittleOvershoot() {
        for airframe in [Airframe.fiveInch, Airframe.whoop] {
            var (drone, sticks) = hovering(airframe)
            sticks.roll = 0.75
            let wanted = actualRate(0.75, center: airframe.centerRate, maximum: airframe.maxRate, expo: airframe.rateExpo)
            var peak: Float = 0, reached: Float = -1
            for i in 0..<480 {
                drone.step(sticks, mode: .acro, dt: step)
                let rate = -degrees(drone.angularVelocity.z)
                peak = max(peak, rate)
                if reached < 0 && rate > 0.63 * wanted { reached = Float(i) * step }
            }
            XCTAssertTrue(reached > 0.015 && reached < 0.08)        // motors need time to change speed; a good tune hides most of it
            XCTAssertLessThan(peak, wanted * 1.2)
            XCTAssertEqual(-degrees(drone.angularVelocity.z), wanted, accuracy: wanted * 0.08)
        }
    }

    func testStaysUnderControlAtEveryThrottle() {
        for airframe in [Airframe.fiveInch, Airframe.whoop] {
            for throttle in stride(from: Float(0), through: 1, by: 0.125) {
                var drone = Drone(airframe)
                drone.place(at: Vec3(0, 2000, 0), heading: 0)
                var random = Random(seed: 5)
                var sticks = StickInput(throttle: throttle)
                for _ in 0..<30 {
                    sticks.roll = random.range(-1, 1)
                    sticks.pitch = random.range(-1, 1)
                    sticks.yaw = random.range(-1, 1)
                    fly(&drone, sticks, .acro, seconds: 0.2)
                    XCTAssertTrue(drone.position.x.isFinite && drone.rotation.vector.w.isFinite)
                    // 0.2 seconds after any change of mind, the drone turns about as fast as asked.
                    let wanted = -radians(actualRate(sticks.roll, center: airframe.centerRate, maximum: airframe.maxRate, expo: airframe.rateExpo))
                    XCTAssertLessThan(abs(drone.angularVelocity.z - wanted), radians(360))
                }
            }
        }
    }

    func testTopSpeedAndBatteryAreThoseOfRealDrones() {
        // Nose far down, full throttle: drag and the propellers running out of bite set the limit.
        var fast = Drone(.fiveInch)
        fast.place(at: Vec3(0, 500, 0), heading: 0)
        fast.rotation = Quat(angle: radians(-72), axis: Vec3(1, 0, 0))
        let full = StickInput(throttle: 1)
        fly(&fast, full, .acro, seconds: 8)
        XCTAssertTrue(fast.speed > 28 && fast.speed < 48)           // 100 to 170 km/h
        XCTAssertTrue(fast.cellVoltage > 3.1 && fast.cellVoltage < 3.7)         // the pack sags under a hundred amperes
        XCTAssertTrue(fast.battery.current > 60 && fast.battery.current < 150)

        var small = Drone(.whoop)
        small.place(at: Vec3(0, 500, 0), heading: 0)
        small.rotation = Quat(angle: radians(-65), axis: Vec3(1, 0, 0))
        fly(&small, full, .acro, seconds: 8)
        XCTAssertTrue(small.speed > 9 && small.speed < 22)          // 30 to 80 km/h

        // Hovering, the packs last what their makers say: minutes, not hours.
        let whoop = hovering(.whoop).drone
        var minutes = whoop.airframe.capacity * 0.8 / whoop.battery.current * 60
        XCTAssertTrue(minutes > 3 && minutes < 7)
        let five = hovering(.fiveInch).drone
        minutes = five.airframe.capacity * 0.8 / five.battery.current * 60
        XCTAssertTrue(minutes > 5 && minutes < 14)

        XCTAssertEqual(restingCellVoltage(charge: 1), 4.2, accuracy: 1e-4)
        XCTAssertTrue(restingCellVoltage(charge: 0.5) > 3.7 && restingCellVoltage(charge: 0.5) < 3.9)
        XCTAssertLessThan(restingCellVoltage(charge: 0.05), 3.5)
        for charge in stride(from: Float(0.05), through: 1, by: 0.05) {
            XCTAssertGreaterThan(restingCellVoltage(charge: charge), restingCellVoltage(charge: charge - 0.05))
        }
    }

    func testTheAirMattersGroundWindAndWake() {
        // Close to the ground the same throttle lifts more.
        XCTAssertGreaterThan(groundEffect(height: 0.05, propRadius: 0.065), 1.1)
        XCTAssertEqual(groundEffect(height: 5, propRadius: 0.065), 1, accuracy: 0.001)
        XCTAssertGreaterThan(groundEffect(height: 0.1, propRadius: 0.065), groundEffect(height: 0.3, propRadius: 0.065))

        // Sinking straight down at about the speed of the downwash is the worst place to be.
        XCTAssertEqual(propwashStrength(sinkSpeed: 0, sideSpeed: 0, inducedSpeed: 7), 0, accuracy: 1e-4)
        XCTAssertGreaterThan(propwashStrength(sinkSpeed: 7, sideSpeed: 0, inducedSpeed: 7), 0.9)
        XCTAssertLessThan(propwashStrength(sinkSpeed: 7, sideSpeed: 12, inducedSpeed: 7), 0.05)     // moving sideways steps out of it
        XCTAssertLessThan(propwashStrength(sinkSpeed: 25, sideSpeed: 0, inducedSpeed: 7), 0.05)     // falling fast leaves it behind

        // A wind from the left carries a hovering drone to the right.
        var (drone, sticks) = hovering(.whoop)
        drone.wind = Vec3(6, 0, 0)
        fly(&drone, sticks, .angle, seconds: 3)
        XCTAssertGreaterThan(drone.position.x, 2)

        // Disarmed, it falls.
        var falling = hovering(.fiveInch).drone
        falling.isArmed = false
        sticks.throttle = 0.3
        fly(&falling, sticks, .angle, seconds: 1)
        XCTAssertLessThan(falling.velocity.y, -7)
        XCTAssertLessThan(falling.motors[0], 0.01)
    }

    // MARK: - The race

    func testAGateCountsOnlyWhenFlownThroughTheRightWay() {
        let gate = Gate(center: Vec3(0, 2, -10), yawDegrees: 0, width: 4, height: 3)
        XCTAssertTrue(gate.isPassed(from: Vec3(0, 2, -9), to: Vec3(0, 2, -11)))
        XCTAssertFalse(gate.isPassed(from: Vec3(0, 2, -11), to: Vec3(0, 2, -9)))        // backwards
        XCTAssertFalse(gate.isPassed(from: Vec3(3, 2, -9), to: Vec3(3, 2, -11)))        // beside it
        XCTAssertFalse(gate.isPassed(from: Vec3(0, 4, -9), to: Vec3(0, 4, -11)))        // over it
        XCTAssertFalse(gate.isPassed(from: Vec3(0, 2, -8), to: Vec3(0, 2, -9)))         // not there yet
        let turned = Gate(center: Vec3(5, 2, 0), yawDegrees: 90, width: 4, height: 3)   // 90 degrees to the left: fly toward -X
        XCTAssertTrue(turned.isPassed(from: Vec3(6, 2, 0.5), to: Vec3(4, 2, 0.5)))
        XCTAssertFalse(turned.isPassed(from: Vec3(4, 2, 0), to: Vec3(6, 2, 0)))
    }

    func testARaceCountsGatesInOrderAndLaps() {
        var race = Race(gateCount: 3, laps: 2)
        XCTAssertFalse(race.pass(gate: 0))                          // not during the countdown
        race.update(dt: 3.1)
        XCTAssertTrue(race.phase == .running)
        race.update(dt: 5)
        XCTAssertFalse(race.pass(gate: 1))                          // out of order
        XCTAssertTrue(race.pass(gate: 0))
        XCTAssertTrue(race.pass(gate: 1))
        XCTAssertEqual(race.lastGate, 1)
        race.update(dt: 5)
        XCTAssertTrue(race.pass(gate: 2))
        XCTAssertTrue(race.lap == 1 && race.nextGate == 0)
        XCTAssertEqual(race.lapTimes[0], 10, accuracy: 1e-4)
        race.update(dt: 8)
        XCTAssertTrue(race.pass(gate: 0))
        XCTAssertTrue(race.pass(gate: 1))
        XCTAssertTrue(race.pass(gate: 2))
        XCTAssertTrue(race.phase == .finished)
        XCTAssertEqual(race.lapTimes[1], 8, accuracy: 1e-4)
        race.update(dt: 5)
        XCTAssertEqual(race.time, 18, accuracy: 1e-4)               // the clock stops at the finish
        XCTAssertEqual(formatTime(83.5), "1:23.50")
        XCTAssertEqual(formatTime(7.04), "0:07.04")
    }

    func testTheCourseIsALoopOfGatesThatFaceEachOther() {
        XCTAssertGreaterThanOrEqual(courseGates.count, 6)
        for (index, gate) in courseGates.enumerated() {
            let next = courseGates[(index + 1) % courseGates.count]
            let toNext = next.center - gate.center
            XCTAssertGreaterThan(simd_dot(simd_normalize(toNext), gate.forward), 0.3)       // the next gate is ahead, not behind
            XCTAssertGreaterThan(simd_dot(simd_normalize(toNext), next.forward), 0.3)       // and is entered from its front
            XCTAssertGreaterThan(simd_length(toNext), 15)
            XCTAssertGreaterThan(gate.center.y - gate.height * 0.5, 0.4)                    // room to pass above the grass
        }
        XCTAssertLessThan(distanceToCourse(Vec2(courseGates[0].center.x, courseGates[0].center.z)), 0.01)
        XCTAssertGreaterThan(distanceToCourse(Vec2(200, 200)), 100)
    }
}
