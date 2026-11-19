// Track.swift
// The race: gates to fly through in order, laps, and the clock. Pure logic, like the
// flight model, so the rules can be tested without flying.

import Foundation
import LMEngine
import simd

/// A rectangular opening to fly through, in one direction.
public struct Gate {
    public var center: Vec3
    public var yaw: Float               // radians: the direction to fly through it. 0 is toward -Z
    public var width: Float
    public var height: Float

    public init(center: Vec3, yawDegrees: Float, width: Float = 3.2, height: Float = 2.4) {
        self.center = center
        yaw = radians(yawDegrees)
        self.width = width
        self.height = height
    }

    public var rotation: Quat { Quat(angle: yaw, axis: Vec3(0, 1, 0)) }
    /// The direction of flight through the gate.
    public var forward: Vec3 { rotation.act(Vec3(0, 0, -1)) }
    public var right: Vec3 { rotation.act(Vec3(1, 0, 0)) }

    /// Did something that moved from `start` to `end` go through the opening, the right way?
    ///
    /// The gate is a rectangle in a plane. The path crosses the plane where its distance
    /// to it changes sign; what is left is to see whether that point is inside the rectangle.
    public func isPassed(from start: Vec3, to end: Vec3) -> Bool {
        let before = simd_dot(start - center, forward)
        let after = simd_dot(end - center, forward)
        if !(before < 0 && after >= 0) { return false }             // not crossing, or crossing backwards
        let t = before / (before - after)
        let crossing = start + (end - start) * t - center
        return abs(simd_dot(crossing, right)) <= width * 0.5 && abs(crossing.y) <= height * 0.5
    }
}

/// Where a race stands.
public struct Race {
    public enum Phase {
        case countdown          // 3, 2, 1: the drone cannot take off yet
        case running
        case finished
    }

    public let gateCount: Int
    public let laps: Int
    public private(set) var phase = Phase.countdown
    public private(set) var countdown: Float = 3
    public private(set) var nextGate = 0
    public private(set) var lap = 0                     // laps completed
    public private(set) var time: Float = 0
    public private(set) var lapTimes: [Float] = []

    public init(gateCount: Int, laps: Int) {
        self.gateCount = gateCount
        self.laps = laps
    }

    public mutating func update(dt: Float) {
        switch phase {
        case .countdown:
            countdown -= dt
            if countdown <= 0 { phase = .running }
        case .running:
            time += dt
        case .finished:
            break
        }
    }

    /// Tells the race that gate number `index` was flown through. Only the next gate in
    /// order counts; returns true if it did.
    @discardableResult
    public mutating func pass(gate index: Int) -> Bool {
        guard phase == .running, index == nextGate else { return false }
        nextGate += 1
        if nextGate == gateCount {
            nextGate = 0
            lap += 1
            lapTimes.append(time - lapTimes.reduce(0, +))
            if lap == laps { phase = .finished }
        }
        return true
    }

    /// The last gate that was passed.
    public var lastGate: Int { (nextGate + gateCount - 1) % gateCount }
}

/// How far a point on the ground is from the racing line: the straight paths that join
/// each gate to the next, seen from above.
public func distanceToCourse(_ point: Vec2) -> Float {
    var nearest = Float.greatestFiniteMagnitude
    for (index, gate) in courseGates.enumerated() {
        let next = courseGates[(index + 1) % courseGates.count]
        let a = Vec2(gate.center.x, gate.center.z), b = Vec2(next.center.x, next.center.z)
        let ab = b - a
        let t = min(max(simd_dot(point - a, ab) / simd_dot(ab, ab), 0), 1)
        nearest = min(nearest, simd_length(point - (a + ab * t)))
    }
    return nearest
}

/// 83.5 seconds -> "1:23.50"
public func formatTime(_ seconds: Float) -> String {
    let minutes = Int(seconds) / 60
    return String(format: "%ld:%05.2f", minutes, Double(seconds - Float(minutes * 60)))
}

/// The course: a loop of gates around a field, with climbs, a dive and a hairpin.
public let courseGates: [Gate] = [
    Gate(center: Vec3(0, 1.8, -18), yawDegrees: 0),
    Gate(center: Vec3(-6, 2.6, -42), yawDegrees: 25),
    Gate(center: Vec3(-26, 5.0, -58), yawDegrees: 75),
    Gate(center: Vec3(-50, 2.6, -46), yawDegrees: 140),
    Gate(center: Vec3(-56, 1.8, -16), yawDegrees: 185),
    Gate(center: Vec3(-44, 6.0, 12), yawDegrees: 225, width: 4.2, height: 3.2),
    Gate(center: Vec3(-18, 1.8, 22), yawDegrees: 270),
    Gate(center: Vec3(4, 2.2, 8), yawDegrees: 330),
]
