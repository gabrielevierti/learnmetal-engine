// FlightModel.swift
// How the drone flies. Pure math: no graphics, no input devices, so it can be tested
// by calling step() in a loop.
//
// The model is the one small FPV simulators use. The four motors are not simulated one
// by one; what they add up to is:
//   - a thrust along the drone's own "up", set by the throttle,
//   - a rate of rotation around each of the drone's three axes, set by the sticks.
// Gravity and air drag do the rest. There is no "forward" control: to go forward you
// tilt the drone, and part of the thrust then pushes it along. That is the whole skill
// of flying one.
//
// Axes, as everywhere in the engine: +X is the drone's right, +Y its up, -Z its nose.

import Foundation
import LMEngine
import simd

/// What the pilot asks for. Mode 2, like most radios: the left stick is throttle and yaw,
/// the right stick is pitch and roll.
public struct StickInput {
    public var throttle: Float = 0          // 0 motors idle, 1 full power
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
    /// The sticks set an angle and the drone levels itself when they are released. Easy.
    case angle
    /// The sticks set a rate of rotation and the drone keeps whatever attitude it has. This
    /// is how FPV drones are really flown: flips and rolls are possible, and so is crashing.
    case acro
}

public struct DroneSettings {
    public var mass: Float = 0.5                        // kilograms: a 5-inch quad without its battery's worth of excuses
    public var thrustToWeight: Float = 4.0              // full throttle lifts four times the drone's weight
    public var linearDrag: Float = 0.35                 // air resistance that grows with speed
    public var quadraticDrag: Float = 0.02              // and the part that grows with speed squared
    public var gravity: Float = 9.81

    // Acro: degrees per second at full stick, and near the center (lower = finer control).
    public var maxRate: Float = 670
    public var centerRate: Float = 200
    public var maxYawRate: Float = 420
    /// How quickly the drone reaches the rate that was asked for, in seconds. Real quads
    /// are fast but not instant, and the small delay is part of how they feel.
    public var responseTime: Float = 0.045

    // Angle mode.
    public var maxTilt: Float = 55                      // degrees at full stick
    public var levelStrength: Float = 9                 // how hard it steers toward the wanted angle
    public var angleYawRate: Float = 220

    public init() {}
}

public struct Drone {
    public var settings = DroneSettings()
    public var position = Vec3(0, 0, 0)
    public var velocity = Vec3(0, 0, 0)
    public var rotation = Quat.identity
    /// Rotation rates around the drone's own x, y and z axes, in radians per second.
    public var angularVelocity = Vec3(0, 0, 0)

    public init() {}

    public var forward: Vec3 { rotation.act(Vec3(0, 0, -1)) }
    public var up: Vec3 { rotation.act(Vec3(0, 1, 0)) }
    public var speed: Float { simd_length(velocity) }
    /// The compass direction of the nose, in radians: 0 looks down -Z, positive turns left.
    public var heading: Float { rotation.eulerAngles.y }

    /// The curve between stick and rate: gentle around the center, steep at the edges.
    /// Returns degrees per second for a stick position from -1 to 1.
    public static func rate(_ stick: Float, center: Float, maximum: Float) -> Float {
        let x = min(max(stick, -1), 1)
        return center * x + (maximum - center) * x * x * x
    }

    /// The rotation rates the pilot is asking for, around the drone's own axes.
    ///
    /// The signs follow from the axes. Turning by a positive angle around +X lifts the
    /// nose, so "nose down" is negative; around +Y it turns the nose left, so "yaw right"
    /// is negative; around +Z it lifts the right side, so "roll right" is negative.
    func wantedRates(_ input: StickInput, _ mode: FlightMode) -> Vec3 {
        switch mode {
        case .acro:
            return Vec3(-radians(Drone.rate(input.pitch, center: settings.centerRate, maximum: settings.maxRate)),
                        -radians(Drone.rate(input.yaw, center: settings.centerRate * 0.8, maximum: settings.maxYawRate)),
                        -radians(Drone.rate(input.roll, center: settings.centerRate, maximum: settings.maxRate)))
        case .angle:
            // The attitude the sticks describe: keep the heading, lean by the stick angles.
            let tilt = radians(settings.maxTilt)
            let wanted = Quat(pitch: -input.pitch * tilt, yaw: heading, roll: -input.roll * tilt)
            // The rotation that would take the drone from where it is to there, seen from
            // the drone itself, as an axis scaled by an angle.
            var error = rotation.inverse * wanted
            if error.real < 0 { error = Quat(vector: -error.vector) }          // the short way round
            let sinHalf = simd_length(error.imag)
            var correction = Vec3(0, 0, 0)
            if sinHalf > 1e-5 {
                let angle = 2 * atan2(sinHalf, error.real)
                correction = error.imag / sinHalf * angle
            }
            var rates = correction * settings.levelStrength
            let limit = radians(settings.maxRate)
            let length = simd_length(rates)
            if length > limit { rates *= limit / length }
            rates.y = -radians(settings.angleYawRate) * min(max(input.yaw, -1), 1)      // yaw stays a rate
            return rates
        }
    }

    /// Advances the drone by `dt` seconds. Call it with small steps (the game uses 1/240 s).
    public mutating func step(_ input: StickInput, mode: FlightMode, dt: Float) {
        // ---- rotation: move the actual rates toward the wanted ones, then turn by them
        let wanted = wantedRates(input, mode)
        let blend = 1 - exp(-dt / max(settings.responseTime, 1e-4))
        angularVelocity += (wanted - angularVelocity) * blend
        let turned = simd_length(angularVelocity) * dt
        if turned > 1e-7 {
            // The rates are around the drone's own axes, so the new rotation is applied
            // on the right: "first this small turn, then the attitude we had".
            rotation = simd_normalize(rotation * Quat(angle: turned, axis: simd_normalize(angularVelocity)))
        }

        // ---- forces: thrust along the drone's up, gravity down, drag against the motion
        let throttle = min(max(input.throttle, 0), 1)
        let thrust = throttle * settings.thrustToWeight * settings.gravity             // as an acceleration
        var acceleration = up * thrust + Vec3(0, -settings.gravity, 0)
        acceleration -= velocity * (settings.linearDrag + settings.quadraticDrag * speed)
        velocity += acceleration * dt
        position += velocity * dt
    }

    /// The throttle at which a level drone neither climbs nor sinks.
    public var hoverThrottle: Float { 1 / settings.thrustToWeight }
}
