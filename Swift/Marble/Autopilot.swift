// Autopilot.swift
// Plays the course by itself: `Marble --demo`.
//
// It exists for two reasons. Watching the game play is a nice way to see the engine
// work; and "the autopilot reaches the goal" is a test of everything at once (physics,
// triggers, the level itself) that can run unattended on a build machine.
//
// The autopilot is a list of waypoints and a steering rule. It reads the same things a
// player sees (where the marble is, where the ferry is) and produces the same thing a
// player produces: a stick direction.

import LMEngine
import simd

struct Autopilot {
    struct Command {
        var push = Vec2(0, 0)       // on the ground plane: x is east, y is north (toward -z). Length at most 1
        var jump = false
    }

    private enum Action {
        case go             // roll to the point
        case waitForFerry   // stay at the point until the ferry is docked nearby
        case board          // roll onto the ferry
        case ride           // stay on the ferry until it is close to the point
    }

    private struct Waypoint {
        var action: Action
        var point: Vec3
        var speed: Float            // top speed on the way there, in meters per second
    }

    // The route: through every gem, across on the ferry, to the goal.
    private static let route: [Waypoint] = [
        Waypoint(action: .go, point: Vec3(0, 0, -7), speed: 5), Waypoint(action: .go, point: Vec3(0, 0, -11), speed: 5),
        Waypoint(action: .go, point: Vec3(2.2, 0, -16), speed: 5), Waypoint(action: .go, point: Vec3(2.5, 0, -18), speed: 4),
        Waypoint(action: .go, point: Vec3(14.5, 0, -18), speed: 5), Waypoint(action: .go, point: Vec3(17, 0, -20), speed: 4),
        Waypoint(action: .waitForFerry, point: Vec3(17, 0, -15.6), speed: 3), Waypoint(action: .board, point: Vec3(0, 0, 0), speed: 3),
        Waypoint(action: .ride, point: Vec3(17, 0, -6.6), speed: 3), Waypoint(action: .go, point: Vec3(17, 0, -2), speed: 3),
        Waypoint(action: .go, point: Vec3(17, 0, 4.5), speed: 3), Waypoint(action: .go, point: Vec3(17, 0, 8), speed: 2.5),
        Waypoint(action: .go, point: Vec3(13, 0, 8), speed: 2.5), Waypoint(action: .go, point: Vec3(13, 0, 11.5), speed: 2.5),
        Waypoint(action: .go, point: Vec3(13, 0, 18.5), speed: 3),
    ]

    // One gem hangs above the ferry's path, out of reach unless the marble jumps. The
    // autopilot jumps when the ferry carries it past this z coordinate.
    private static let jumpAtZ: Float = -9.9

    private var step = 0
    private var hasJumped = false

    mutating func reset() {
        step = 0
        hasJumped = false
    }

    private static func flatDistance(_ a: Vec3, _ b: Vec3) -> Float {
        simd_length(Vec2(a.x - b.x, a.z - b.z))
    }

    /// What the autopilot wants to do during this physics step.
    @MainActor
    mutating func steer(_ engine: Engine, _ level: Level) -> Command {
        var command = Command()
        guard let marble = engine.scene[level.marble, RigidBody.self], let ferry = engine.scene[level.ferry, RigidBody.self],
              step < Autopilot.route.count else { return command }

        let waypoint = Autopilot.route[step]
        var target = waypoint.point
        var isDone = false
        switch waypoint.action {
        case .go:
            isDone = Autopilot.flatDistance(marble.position, target) < 0.45
        case .waitForFerry:
            // Docked means: at the near end of its trip and almost standing still.
            isDone = Autopilot.flatDistance(marble.position, target) < 0.6 && ferry.position.z < -12.2
                && simd_length(ferry.velocity) < 0.5
        case .board:
            target = ferry.position
            isDone = Autopilot.flatDistance(marble.position, target) < 0.5
        case .ride:
            target = ferry.position
            isDone = ferry.position.z > waypoint.point.z - 0.35
            if !hasJumped && marble.position.z > Autopilot.jumpAtZ && ferry.velocity.z > 0 {
                command.jump = true
                hasJumped = true
            }
        }
        if isDone {
            step += 1
            return command
        }

        // Steering: decide the velocity we would like (toward the target, slower when close),
        // then push in proportion to how far the real velocity is from it. On the ferry the
        // velocity we want is the ferry's own, plus whatever keeps us near its center.
        let toTarget = target - marble.position
        var wanted = Vec3(toTarget.x, 0, toTarget.z) * 2.5
        let wantedSpeed = simd_length(wanted)
        if wantedSpeed > waypoint.speed { wanted *= waypoint.speed / wantedSpeed }
        if waypoint.action == .board || waypoint.action == .ride { wanted += ferry.velocity }
        let correction = (wanted - marble.velocity) * 0.6
        command.push = Vec2(correction.x, -correction.z)       // north is -z
        let length = simd_length(command.push)
        if length > 1 { command.push /= length }
        return command
    }
}
