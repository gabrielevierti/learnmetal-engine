// FlightModel.swift
// How the drone flies. Pure math: no graphics, no input devices, so it can be tested
// by calling step() in a loop.
//
// Nothing here is scripted. The model is a rigid body with four motors, and what a
// pilot feels comes out of the physics:
//
//   sticks -> rates wanted       the "Actual" rates curve of Betaflight, or self-leveling
//          -> flight controller  a PID loop per axis compares them with the gyro
//          -> mixer              turns "more roll, less yaw" into four motor commands
//          -> motors             that take time to change speed, and sag with the battery
//          -> propellers         thrust grows with the square of their speed and fades
//                                as the air already moves through them
//          -> the body           thrust, torque, drag, gravity, wind
//
// From this come the things FPV pilots know: a throttle that is anything but linear,
// the small overshoot at the end of a roll, the wobble when dropping through your own
// propwash, yaw that is weaker than roll, a pack that pulls hard for a minute and then
// less and less, the cushion of air just above the ground.
//
// Axes, as everywhere in the engine: +X is the drone's right, +Y its up, -Z its nose.
// Units are SI: meters, seconds, kilograms, newtons, radians, volts, amperes.

import Foundation
import LMEngine
import simd

/// What the pilot asks for. Mode 2, like most radios: the left stick is throttle and yaw,
/// the right stick is pitch and roll.
public struct StickInput {
    public var throttle: Float = 0          // 0 closed, 1 wide open
    public var yaw: Float = 0               // -1 turn left, 1 turn right
    public var pitch: Float = 0             // 1 nose down (stick pushed forward), -1 nose up
    public var roll: Float = 0              // -1 lean left, 1 lean right

    public init(throttle: Float = 0, yaw: Float = 0, pitch: Float = 0, roll: Float = 0) {
        self.throttle = throttle
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }
}

public enum FlightMode {
    /// The sticks set an angle and the drone levels itself when they are released.
    case angle
    /// The sticks set a rate of rotation and the drone keeps whatever attitude it has.
    case acro
}

/// Everything that makes one drone different from another. The numbers are the kind
/// found on a product page or measured on a thrust stand.
public struct Airframe {
    public var name = "5-inch, 6S"

    // The body.
    public var mass: Float = 0.65                       // with its battery
    public var inertia = Vec3(0.003, 0.0052, 0.0024)    // resistance to turning about x (pitch), y (yaw), z (roll)
    public var armX: Float = 0.0795                     // the motors are at (+-armX, 0, +-armZ) from the center
    public var armZ: Float = 0.0795
    public var radius: Float = 0.17                     // of the sphere used for collisions

    // Motors and propellers.
    public var maxThrust: Float = 17                    // of one motor, standing still, at the pack's nominal voltage
    public var idle: Float = 0.055                      // armed motors never stop: their speed at zero throttle
    public var motorTimeUp: Float = 0.032               // seconds to cover most of a change of speed, speeding up
    public var motorTimeDown: Float = 0.045             // and slowing down
    public var maxRevs: Float = 520                     // turns per second at full speed
    public var propRadius: Float = 0.0647
    public var pitchSpeed: Float = 56                   // how fast a propeller at full speed moves the air: thrust fades toward it
    public var torqueRatio: Float = 0.0125              // newton-meters of twist on the body per newton of thrust
    public var rotorInertia: Float = 4.5e-6             // of one propeller and motor bell

    // Air.
    public var dragArea = Vec3(0.012, 0.018, 0.009)     // drag coefficient times area, seen from the side, from above, from the front
    public var rotorDrag: Float = 0.28                  // newtons per meter per second of sideways motion, in a hover

    // Battery.
    public var cells = 6
    public var capacity: Float = 1.3                    // amp-hours
    public var resistance: Float = 0.040                // of the whole pack and its wiring, in ohms
    public var maxCurrent: Float = 35                   // of one motor at full speed
    public var idleCurrent: Float = 0.9                 // flight controller, receiver, video transmitter

    // Rates, as entered in Betaflight ("Actual" rates), in degrees per second.
    public var centerRate: Float = 70                   // per unit of stick, around the center
    public var maxRate: Float = 670                     // at full stick
    public var rateExpo: Float = 0
    public var maxTilt: Float = 55                      // angle mode: degrees at full stick

    public var cameraTilt: Float = 30                   // degrees the camera looks up
    public var range: Float = 320                       // meters at which the radio link is lost
    public var crashSpeed: Float = 3.5                  // meters per second: hitting something faster than this ends the flight

    public init() {}

    /// A 5-inch freestyle quad on six cells: about 650 grams and 5.5 kilograms of thrust.
    public static var fiveInch: Airframe { Airframe() }     // the defaults are this drone

    /// A ducted 2-inch "whoop" on two cells, 95 mm across: the size of the BETAFPV Cetus X.
    public static var whoop: Airframe {
        var a = Airframe()
        a.name = "Whoop 95 mm, 2S"
        a.mass = 0.082
        a.inertia = Vec3(6.4e-5, 1.18e-4, 6.4e-5)
        a.armX = 0.0336
        a.armZ = 0.0336
        a.radius = 0.075
        a.maxThrust = 0.72
        a.idle = 0.06
        a.motorTimeUp = 0.020
        a.motorTimeDown = 0.028
        a.maxRevs = 950
        a.propRadius = 0.0255
        a.pitchSpeed = 38
        a.torqueRatio = 0.006
        a.rotorInertia = 1.0e-7
        a.dragArea = Vec3(0.009, 0.011, 0.008)
        a.rotorDrag = 0.06
        a.cells = 2
        a.capacity = 0.45
        a.resistance = 0.075
        a.maxCurrent = 5.5
        a.idleCurrent = 0.55
        a.cameraTilt = 25
        a.range = 180
        a.crashSpeed = 5.5                              // light, and its propellers are guarded
        return a
    }
}

public struct Battery {
    public var used: Float = 0                          // amp-hours taken out since it was charged
    public var voltage: Float = 0                       // of the pack, under the present load
    public var current: Float = 0                       // amperes being drawn
}

private let gravity: Float = 9.81
private let airDensity: Float = 1.225
private let nominalCell: Float = 3.85                   // the voltage at which a motor reaches "full speed"

// Where each motor is and what it does. Order: front right, front left, rear right, rear left.
private let sideX: [Float] = [1, -1, 1, -1]
private let sideZ: [Float] = [-1, -1, 1, 1]
// Thrust in front lifts the nose (a turn about +X); thrust on the right lifts the right
// side (a turn about +Z). Propellers turn in alternate directions, and each twists the
// body the opposite way: speeding up front-left and rear-right turns the drone about +Y.
private let mixPitch: [Float] = [1, 1, -1, -1]
private let mixRoll: [Float] = [1, -1, 1, -1]
private let mixYaw: [Float] = [-1, 1, 1, -1]

/// How much of the way a filter with this time constant goes in one step.
private func blend(_ dt: Float, _ timeConstant: Float) -> Float {
    1 - exp(-dt / max(timeConstant, 1e-5))
}

private func clampEach(_ v: Vec3, _ limit: Float) -> Vec3 {
    simd_clamp(v, Vec3(repeating: -limit), Vec3(repeating: limit))
}

/// Betaflight's "Actual" rates: degrees per second for a stick position from -1 to 1.
/// `center` is the slope around the middle, `maximum` the rate at full stick; `expo`
/// (0 to 1) flattens the middle further without lowering the maximum.
public func actualRate(_ stickPosition: Float, center: Float, maximum: Float, expo: Float) -> Float {
    let stick = min(max(stickPosition, -1), 1)
    let curve = abs(stick) * (pow(stick, 5) * expo + stick * (1 - expo))
    return stick * center + max(0, maximum - center) * curve
}

/// The voltage of one lithium-polymer cell at rest: 4.2 full, about 3.8 at half, falling away below 3.5.
public func restingCellVoltage(charge: Float) -> Float {
    // Measured curves all look like this: a quick drop from 4.2, a long shallow slope,
    // and a cliff at the end. Straight lines between a few points are close enough.
    let points: [(Float, Float)] = [(0, 3.20), (0.07, 3.52), (0.15, 3.66), (0.3, 3.74), (0.5, 3.82), (0.7, 3.92), (0.9, 4.06), (1, 4.20)]
    let level = saturate(charge)
    for i in 1..<points.count where level <= points[i].0 {
        let t = (level - points[i - 1].0) / (points[i].0 - points[i - 1].0)
        return lerp(points[i - 1].1, points[i].1, t)
    }
    return 4.2
}

/// How much more thrust a propeller makes this close to the ground: 1 far away, more near it.
public func groundEffect(height: Float, propRadius: Float) -> Float {
    // Cheeseman and Bennett's formula for a rotor near the ground. Four rotors side by
    // side trap more air than one, so the effect reaches about twice as high.
    let reach = propRadius * 2
    let ratio = reach / (4 * max(height, reach * 0.3))
    return min(1 / (1 - ratio * ratio), 1.5)
}

/// How badly a drone that sinks at `sinkSpeed` and moves sideways at `sideSpeed` is caught
/// in the air its own propellers pushed down, from 0 to 1. `inducedSpeed` is how fast
/// that air moves in a hover.
public func propwashStrength(sinkSpeed: Float, sideSpeed: Float, inducedSpeed: Float) -> Float {
    // Worst when sinking at about the speed of the downwash, so that the drone stays
    // inside it. Sinking much faster leaves it behind; moving sideways steps out of it.
    let ratio = sinkSpeed / max(inducedSpeed, 0.1)
    let sinking = smoothstep(0.25, 0.7, ratio) * (1 - smoothstep(1.6, 2.4, ratio))
    let clear = saturate(sideSpeed / (1.5 * max(inducedSpeed, 0.1)))
    return sinking * (1 - clear)
}

public struct Drone {
    public var airframe: Airframe
    public var position = Vec3(0, 0, 0)
    public var velocity = Vec3(0, 0, 0)
    public var rotation = Quat.identity
    public var angularVelocity = Vec3(0, 0, 0)          // radians per second about the drone's own axes
    /// The speed of each motor, 0 to about 1: front right, front left, rear right, rear left.
    public var motors: [Float] = [0, 0, 0, 0]
    public var battery = Battery()
    /// Disarmed, the motors stop and the drone is a falling object.
    public var isArmed = true

    // The world around it, set by the game before each step.
    public var wind = Vec3(0, 0, 0)
    public var heightAboveGround: Float = 100

    // What the last step did, for instruments and tests.
    public private(set) var propwash: Float = 0         // 0 clean air ... 1 sinking straight into its own wake
    public private(set) var thrust: Float = 0           // newtons, all four motors

    // Flight controller.
    private var kp = Vec3(0, 0, 0)
    private var ki = Vec3(0, 0, 0)
    private var kd = Vec3(0, 0, 0)
    private var gyro = Vec3(0, 0, 0)                    // the filtered reading
    private var integral = Vec3(0, 0, 0)
    private var derivative = Vec3(0, 0, 0)
    private var heading: Float = 0                      // remembered while the nose points straight up or down
    private var hoverSpeed: Float = 0.3                 // motor speed that carries the weight at nominal voltage
    private var inducedSpeed: Float = 7                 // how fast the air leaves the propellers in a hover
    private var random = Random(seed: 2024)
    private var gust: [Float] = [0, 0, 0, 0]            // the turbulence each propeller is in

    public init(_ airframe: Airframe = .fiveInch) {
        self.airframe = airframe
        tune()
        chargeBattery()
    }

    public var forward: Vec3 { rotation.act(Vec3(0, 0, -1)) }
    public var up: Vec3 { rotation.act(Vec3(0, 1, 0)) }
    public var right: Vec3 { rotation.act(Vec3(1, 0, 0)) }
    public var speed: Float { simd_length(velocity) }
    /// The part of the battery that is left, 1 full to 0 empty.
    public var charge: Float { saturate(1 - battery.used / airframe.capacity) }
    public var cellVoltage: Float { battery.voltage / Float(airframe.cells) }
    /// The throttle that holds the drone in the air right now, with this battery.
    public var hoverThrottle: Float {
        let scale = max(battery.voltage / (nominalCell * Float(airframe.cells)), 0.1)
        return saturate((hoverSpeed / scale - airframe.idle) / (1 - airframe.idle))
    }

    /// Level, still, motors stopped, facing `heading` (radians, 0 toward -Z, positive to the left).
    public mutating func place(at where: Vec3, heading newHeading: Float) {
        position = where
        velocity = Vec3(0, 0, 0)
        rotation = Quat(angle: newHeading, axis: Vec3(0, 1, 0))
        angularVelocity = Vec3(0, 0, 0)
        motors = [0, 0, 0, 0]
        gust = [0, 0, 0, 0]
        gyro = Vec3(0, 0, 0)
        integral = Vec3(0, 0, 0)
        derivative = Vec3(0, 0, 0)
        heading = newHeading
        propwash = 0
        thrust = 0
    }

    public mutating func chargeBattery() {
        battery.used = 0
        battery.current = 0
        battery.voltage = restingCellVoltage(charge: 1) * Float(airframe.cells)
    }

    /// Chooses the gains of the flight controller. A pilot does this by flying, listening
    /// and changing numbers; here they are worked out from the airframe, so that a heavy
    /// 5-inch and a tiny whoop both answer the sticks crisply.
    ///
    /// Around a hover, one unit of "more roll" from the controller changes each motor's
    /// thrust by a known amount, which gives a known angular acceleration: call it K. With
    /// motors that take a time T to respond, the loop behaves like a mass on a spring:
    ///   stiffness K * kp / T,  damping (1 + K * kd) / T.
    /// Asking for a natural frequency and a damping ratio gives kp and kd.
    private mutating func tune() {
        let a = airframe
        hoverSpeed = (a.mass * gravity / (4 * a.maxThrust)).squareRoot()
        let hoverThrust = a.mass * gravity / 4
        inducedSpeed = (hoverThrust / (2 * airDensity * Float.pi * a.propRadius * a.propRadius)).squareRoot()

        let thrustPerUnit = 2 * a.maxThrust * hoverSpeed * (1 - a.idle)        // of one motor, per unit of command
        let lever = Vec3(a.armZ, a.torqueRatio, a.armX)                         // pitch, yaw, roll
        let frequency = Vec3(42, 22, 42)                                        // radians per second
        let damping = Vec3(0.75, 0.9, 0.75)
        for axis in 0..<3 {
            let gain = 4 * thrustPerUnit * lever[axis] / a.inertia[axis]
            kp[axis] = frequency[axis] * frequency[axis] * a.motorTimeUp / gain
            kd[axis] = max(0, 2 * damping[axis] * frequency[axis] * a.motorTimeUp - 1) / gain
            ki[axis] = kp[axis] * frequency[axis] * 0.25
        }
    }

    /// The rates of rotation the pilot is asking for, about the drone's own axes.
    private mutating func wantedRates(_ sticks: StickInput, _ mode: FlightMode) -> Vec3 {
        let a = airframe
        let yawRate = radians(actualRate(sticks.yaw, center: a.centerRate, maximum: a.maxRate, expo: a.rateExpo))
        if mode == .acro {
            // Nose down is a turn about -X, a turn to the right about -Y, a roll to the right about -Z.
            return Vec3(-radians(actualRate(sticks.pitch, center: a.centerRate, maximum: a.maxRate, expo: a.rateExpo)), -yawRate,
                        -radians(actualRate(sticks.roll, center: a.centerRate, maximum: a.maxRate, expo: a.rateExpo)))
        }

        // Angle mode. Where is the nose pointing, seen from above? Straight up or down there
        // is no answer, so the last one is kept.
        let nose = forward
        if nose.x * nose.x + nose.z * nose.z > 0.09 { heading = atan2(-nose.x, -nose.z) }
        let ahead = Vec3(-sin(heading), 0, -cos(heading))
        let side = Vec3(cos(heading), 0, -sin(heading))

        // The sticks say how far "up" should lean forward and to the right.
        let limit = radians(a.maxTilt)
        let wantedUp = simd_normalize(Vec3(0, 1, 0) + ahead * tan(sticks.pitch * limit) + side * tan(sticks.roll * limit))
        // The turn that brings the present "up" onto the wanted one, by the shortest way.
        let currentUp = up
        var axis = simd_cross(currentUp, wantedUp)
        let sine = simd_length(axis)
        let angle = atan2(sine, simd_dot(currentUp, wantedUp))
        axis = sine > 1e-4 ? axis / sine : nose                 // upside down exactly: roll over
        let error = rotation.inverse.act(axis * angle)          // in the drone's own axes

        let levelStrength: Float = 7                            // radians per second of correction per radian of error
        let fastest = radians(a.maxRate)
        return Vec3(min(max(error.x * levelStrength, -fastest), fastest), -yawRate * 0.6,
                    min(max(error.z * levelStrength, -fastest), fastest))
    }

    /// Advances the simulation by `dt` seconds. Meant to be called several hundred times
    /// per second: the flight controller inside runs once per call, as a real one does.
    public mutating func step(_ sticks: StickInput, mode: FlightMode, dt: Float) {
        let a = airframe
        let throttle = saturate(sticks.throttle)

        // ---- 1. the flight controller: what the pilot wants, compared with what the gyro says
        let wanted = wantedRates(sticks, mode)
        let previousGyro = gyro
        gyro += (angularVelocity - gyro) * blend(dt, 1 / (2 * Float.pi * 150))      // a 150 Hz low-pass, as on the real thing
        let error = wanted - gyro
        let slope = (gyro - previousGyro) / dt
        derivative += (slope - derivative) * blend(dt, 1 / (2 * Float.pi * 90))

        // At high throttle the same command moves more thrust: back off, as Betaflight's
        // "TPA" does, or the drone would shake.
        let attenuation = 1 - 0.45 * saturate((throttle - 0.4) / 0.6)
        var command = Vec3(0, 0, 0)
        for axis in 0..<3 {
            // The integral removes a steady error (a bent propeller, wind). It is left alone
            // during fast moves, when it would only wind up and cause a bounce at the end.
            if abs(error[axis]) < 2 { integral[axis] = min(max(integral[axis] + ki[axis] * error[axis] * dt, -0.12), 0.12) }
            command[axis] = (kp[axis] * error[axis] - kd[axis] * derivative[axis]) * attenuation + integral[axis]
        }
        command = Vec3(min(max(command.x, -0.6), 0.6), min(max(command.y, -0.4), 0.4), min(max(command.z, -0.6), 0.6))
        if !isArmed { integral = Vec3(0, 0, 0) }

        // ---- 2. the mixer: four motor commands from one throttle and three corrections
        var mix: [Float] = [0, 0, 0, 0]
        var lowest: Float = 0, highest: Float = 0
        for i in 0..<4 {
            mix[i] = command.x * mixPitch[i] + command.z * mixRoll[i] + command.y * mixYaw[i]
            lowest = min(lowest, mix[i])
            highest = max(highest, mix[i])
        }
        // No motor can go below zero or above full. Rather than clip one motor (which would
        // turn a roll into a roll and a yaw), shrink the corrections to fit and move the
        // throttle out of their way: "air mode". Control survives at zero and at full throttle.
        let span = highest - lowest
        if span > 1 {
            for i in 0..<4 { mix[i] /= span }
            lowest /= span
            highest /= span
        }
        let base = min(max(throttle, -lowest), 1 - highest)

        // ---- 3. motors: they chase their command, faster up than down, and no faster than the battery allows
        let voltageScale = min(max(battery.voltage / (nominalCell * Float(a.cells)), 0), 1.2)
        var acceleration: [Float] = [0, 0, 0, 0]
        for i in 0..<4 {
            let target = isArmed ? (a.idle + (1 - a.idle) * saturate(base + mix[i])) * voltageScale : 0
            let before = motors[i]
            motors[i] += (target - before) * blend(dt, target > before ? a.motorTimeUp : a.motorTimeDown)
            acceleration[i] = (motors[i] - before) / dt
        }

        // ---- 4. the air
        let toBody = rotation.inverse
        let airVelocity = toBody.act(velocity - wind)           // how the drone moves through the air, in its own axes
        let sideSpeed = (airVelocity.x * airVelocity.x + airVelocity.z * airVelocity.z).squareRoot()
        let motorSum = motors[0] + motors[1] + motors[2] + motors[3]
        propwash = propwashStrength(sinkSpeed: -airVelocity.y, sideSpeed: sideSpeed,
                                    inducedSpeed: inducedSpeed * max(motorSum, 0.4) / (4 * hoverSpeed))
        let cushion = lerp(1, groundEffect(height: heightAboveGround, propRadius: a.propRadius), saturate(up.y))

        var torque = Vec3(0, 0, 0)
        thrust = 0
        for i in 0..<4 {
            let x = sideX[i] * a.armX, z = sideZ[i] * a.armZ
            // Air already moving down through a propeller leaves it less to push against. Each
            // propeller sees the drone's motion plus its own, from the drone turning: that
            // is where most of a quad's resistance to spinning comes from.
            let inflow = airVelocity.y + angularVelocity.z * x - angularVelocity.x * z
            let bite = min(max(1 - inflow / (a.pitchSpeed * max(motors[i], 0.05)), 0), 1.25)
            // In its own wake a propeller meets air that is already swirling: less lift, and uneven.
            gust[i] += (random.range(-1, 1) * 2.2 - gust[i]) * blend(dt, 0.02)
            let wake = 1 - 0.15 * propwash + 0.5 * propwash * min(max(gust[i], -1), 1)

            let force = a.maxThrust * motors[i] * motors[i] * bite * cushion * wake
            thrust += force
            torque.x += -z * force
            torque.z += x * force
            // Yaw: the drag of the spinning propeller, and the kick of changing its speed.
            torque.y += mixYaw[i] * (a.torqueRatio * force + a.rotorInertia * (2 * Float.pi * a.maxRevs) * acceleration[i])
        }

        // Drag. The body's grows with the square of the speed and depends on which side
        // faces the wind; the propellers' grows in proportion and only acts sideways.
        var drag = -0.5 * airDensity * a.dragArea * simd_abs(airVelocity) * airVelocity
        let rotorDrag = a.rotorDrag * motorSum / (4 * hoverSpeed)
        drag.x -= rotorDrag * airVelocity.x
        drag.z -= rotorDrag * airVelocity.z

        // ---- 5. the body: Newton for the motion, Euler's equation for the rotation
        let force = rotation.act(Vec3(0, thrust, 0) + drag)
        velocity += (force / a.mass + Vec3(0, -gravity, 0)) * dt
        position += velocity * dt

        let momentum = a.inertia * angularVelocity
        angularVelocity += (torque - simd_cross(angularVelocity, momentum)) / a.inertia * dt
        angularVelocity = clampEach(angularVelocity, 60)        // nothing real spins faster; keeps a crash from blowing up
        let turnRate = simd_length(angularVelocity)
        if turnRate * dt > 1e-9 {
            rotation = simd_normalize(rotation * Quat(angle: turnRate * dt, axis: angularVelocity / turnRate))
        }

        // ---- 6. the battery: current rises steeply with motor speed (a little less than its
        // cube: motors waste more at low speed), and the voltage sags with the current
        var current = a.idleCurrent
        for motor in motors { current += a.maxCurrent * pow(max(motor, 0), 2.6) }
        battery.current = current
        battery.used = min(battery.used + current * dt / 3600, a.capacity)
        let loaded = restingCellVoltage(charge: charge) * Float(a.cells) - current * a.resistance
        battery.voltage += (max(loaded, 0) - battery.voltage) * blend(dt, 0.03)
    }
}
