// FPVGame.swift
// FPV: fly a racing drone through a course of gates, seen from its own camera.
//
// The game is a few small parts:
//   FlightModel.swift   how the drone moves (pure math)
//   Track.swift         gates, laps and the clock (pure logic)
//   World.swift         the field, the trees, the gates, the drone to look at
//   Controls.swift      thumbs, controller or keyboard -> stick positions
//   Sounds.swift        motors, wind, beeps
//   FPVGame.swift       this file: the flight, collisions, crashes, the radio link, the camera
//   FPVHud.swift        what is drawn over the picture: the OSD, the menu, the results
//
// It runs on iPhone and iPad (see the iOS folder) and on a Mac (`swift run FPV`).

import Foundation
import LMEngine
import simd

public final class FPVGame: Game {
    enum Screen {
        case menu, flying, finished
    }
    enum Mode {
        case race, free
    }
    enum View {
        case onboard, chase
    }

    static let laps = 2
    private static let substeps = 8                 // the flight model runs at 480 steps per second

    var screen = Screen.menu
    var mode = Mode.race
    var view = View.onboard
    var flightMode = FlightMode.angle
    var drone = Drone()
    var sticks = StickInput()
    var race = Race(gateCount: courseGates.count, laps: FPVGame.laps)
    let controls = Controls()
    var windSetting = 1                             // 0 calm, 1 a breeze, 2 gusty
    var cameraTilt: Float = 30                      // degrees
    var link: Float = 1                             // the radio link: 1 perfect, 0 lost
    var isCrashed = false                           // tumbling or lying on the ground, motors off
    var isWaitingToArm = false                      // back on its feet: the throttle must come down before the motors start
    var bestTime: Float = 0                         // 0: no time yet
    var isNewBest = false
    var lostSignal = false                          // the crash in progress began with the radio link dropping
    var flightTime: Float = 0
    var flashTimer: Float = 0                       // a gate was just passed
    var notice = ""                                 // a line shown for a few seconds
    var noticeTimer: Float = 0
    var airframeIndex = 0

    var world = World()
    var camera = Entity.invalid
    private var model = DroneModel()
    private var sounds = Sounds()
    private var chaseEye = Vec3(0, 3, 6)
    private var motorSounds: [SoundHandle] = []
    private var windSound: SoundHandle = 0
    private var random = Random(seed: 99)

    private var isOnGround = true
    private var isBlocked = false                   // something stands between the pilot and the drone
    private var crashTimer: Float = 0               // seconds since the crash
    private var restTimer: Float = 0                // seconds the wreck has been lying still
    private var linkLostTimer: Float = 0
    private var glitch: Float = 0                   // a burst of video noise, after a knock
    private var alarmTimer: Float = 0
    private var stepCount = 0

    public init() {}

    // MARK: - Setting up

    public func start(_ engine: Engine) {
        let saved = UserDefaults.standard
        bestTime = saved.float(forKey: "fpv.bestTime")
        if saved.object(forKey: "fpv.fullStick") != nil { controls.throttleUsesFullStick = saved.bool(forKey: "fpv.fullStick") }
        if saved.bool(forKey: "fpv.acro") { flightMode = .acro }
        if saved.object(forKey: "fpv.wind") != nil { windSetting = min(max(saved.integer(forKey: "fpv.wind"), 0), 2) }
        engine.input.stickDeadZone = 0.03           // radios are precise around the center: keep almost all of it

        var look = engine.renderer.settings
        look.cascades.shadowDistance = 130
        look.fogDensity = 0.0022
        look.fogColor = look.sky.horizonColor
        look.sky.cloudCoverage = 0.5
        look.sky.cloudScale = 1.1
        look.bloomIntensity = 0.05
        #if os(iOS)
        // A phone has three pixels per point: render a little smaller and skip the most
        // expensive effect. The picture changes little, the frame rate a lot.
        look.renderScale = 0.75
        look.ambientOcclusionEnabled = false
        look.cascades.resolution = 1024
        #endif
        engine.renderer.settings = look

        world = buildWorld(engine)
        sounds = Sounds.make()
        for i in 0..<4 {
            motorSounds.append(engine.audio.play(sounds.motor, options: PlayOptions(volume: 0, pan: i % 2 == 0 ? 0.3 : -0.3, loops: true)))
        }
        windSound = engine.audio.play(sounds.wind, options: PlayOptions(volume: 0, loops: true))

        camera = engine.scene.create("Camera")
        engine.scene.add(camera, Transform())
        engine.scene.add(camera, Camera(fovY: radians(60), nearPlane: 0.02, farPlane: 1200))

        let config = engine.config
        if config.hasArgument("--acro") { flightMode = .acro }
        if config.hasArgument("--chase") { view = .chase }
        if config.hasArgument("--sticks") { controls.showsSticks = true }
        chooseAirframe(engine, config.hasArgument("--whoop") ? 1 : saved.integer(forKey: "fpv.drone"))
        // These skip the menu: used when a picture of the game is captured without a screen.
        if config.hasArgument("--race") { begin(.race) }
        if config.hasArgument("--free") { begin(.free) }
    }

    func chooseAirframe(_ engine: Engine, _ index: Int) {
        airframeIndex = index == 1 ? 1 : 0
        drone = Drone(airframeIndex == 1 ? .whoop : .fiveInch)
        cameraTilt = drone.airframe.cameraTilt
        if engine.scene.isAlive(model.root) { model.destroy(engine) }
        model = DroneModel.build(engine, drone.airframe)
        placeAtStart()
        UserDefaults.standard.set(airframeIndex, forKey: "fpv.drone")
    }

    /// How high the drone's center is when it sits on its belly.
    private var restHeight: Float { 0.035 * drone.airframe.armX / 0.0795 + 0.005 }

    /// On the launch mat, with a fresh battery, facing the first gate.
    private func placeAtStart() {
        drone.place(at: world.start + Vec3(0, restHeight + 0.02, 0), heading: courseGates[0].yaw)
        drone.chargeBattery()
        drone.isArmed = true
        controls.reset()
        isCrashed = false
        isWaitingToArm = false
        lostSignal = false
        isOnGround = true
        crashTimer = 0
        restTimer = 0
        linkLostTimer = 0
        flightTime = 0
        link = 1
        chaseEye = drone.position + Vec3(0, 0.4, 1.2)
    }

    func begin(_ newMode: Mode) {
        mode = newMode
        race = Race(gateCount: courseGates.count, laps: FPVGame.laps)
        isNewBest = false
        screen = .flying
        placeAtStart()
    }

    func toggleFlightMode() {
        flightMode = flightMode == .angle ? .acro : .angle
        UserDefaults.standard.set(flightMode == .acro, forKey: "fpv.acro")
    }

    /// The wind at a moment and a height: steady, with gusts that come and go, and weaker
    /// close to the ground, where the grass and the trees slow it down.
    private func wind(at time: Double, height: Float) -> Vec3 {
        let speeds: [Float] = [0, 3, 7]
        let speed = speeds[min(max(windSetting, 0), 2)]
        if speed <= 0 { return Vec3(0, 0, 0) }
        let t = Float(time)
        let gust = windSetting == 2 ? 0.55 + 0.9 * valueNoise(Vec2(t * 0.45, 3)) : 0.85 + 0.3 * valueNoise(Vec2(t * 0.2, 3))
        let swing = (valueNoise(Vec2(t * 0.13, 9)) - 0.5) * 1.2                 // the direction wanders
        let direction = Vec3(cos(0.35 + swing), 0, sin(0.35 + swing))
        let lift = windSetting == 2 ? (valueNoise(Vec2(t * 0.7, 21)) - 0.5) * 0.25 * speed : 0
        return (direction * (speed * gust) + Vec3(0, lift, 0)) * saturate(0.35 + height / 10)
    }

    // MARK: - Flying

    public func fixedUpdate(_ engine: Engine, dt: Float) {
        guard screen == .flying else { return }
        stepCount += 1

        // The race: three beeps and a long one, like start lights.
        if mode == .race {
            let before = Int(race.countdown.rounded(.up))
            let wasCounting = race.phase == .countdown
            race.update(dt: dt)
            if wasCounting && race.phase == .running {
                engine.audio.play(sounds.go)
            } else if wasCounting && Int(race.countdown.rounded(.up)) != before {
                engine.audio.play(sounds.beep)
            }
        }
        // During the countdown the drone sits armed on its mat, propellers idling.
        var input = sticks
        if mode == .race && race.phase == .countdown { input = StickInput() }

        // A flight controller refuses to start the motors with the throttle up.
        if isWaitingToArm && sticks.throttle < 0.08 {
            isWaitingToArm = false
            drone.isArmed = true
        }

        let h = dt / Float(FPVGame.substeps)
        for i in 0..<FPVGame.substeps {
            let previous = drone.position
            let ground = groundHeight(drone.position.x, drone.position.z)
            drone.heightAboveGround = drone.position.y - ground
            drone.wind = wind(at: engine.time.elapsed, height: drone.heightAboveGround)
            drone.step(input, mode: flightMode, dt: h)
            collide(engine, previous: previous, dt: h, testSolids: i % 2 == 0)

            if mode == .race && race.phase == .running {
                let gate = courseGates[race.nextGate]
                if gate.isPassed(from: previous, to: drone.position) && race.pass(gate: race.nextGate) {
                    flashTimer = 0.25
                    engine.audio.play(race.nextGate == 0 ? sounds.lap : sounds.gate)
                    if race.phase == .finished {
                        finish(engine)
                        return
                    }
                }
            }
        }
        if drone.isArmed && !isOnGround { flightTime += dt }

        // ---- the radio link: it weakens with distance, and with anything solid in the way
        let toDrone = drone.position - world.pilot
        let distance = simd_length(toDrone)
        if stepCount % 10 == 0 && distance > 1 {
            let ray = Ray(origin: world.pilot, direction: toDrone / distance)
            isBlocked = engine.physics.raycast(engine.scene, ray, maxDistance: distance - drone.airframe.radius * 2) != nil
        }
        var quality = 1 - saturate((distance / drone.airframe.range - 0.45) / 0.55)
        if isBlocked { quality *= 0.6 }
        link += (quality - link) * min(1, dt * 5)
        // No signal for half a second: the receiver gives up and stops the motors. "Failsafe".
        linkLostTimer = link < 0.03 ? linkLostTimer + dt : 0
        if linkLostTimer > 0.5 && !isCrashed {
            lostSignal = true
            crash(engine, impact: 0)
        }
        if drone.charge <= 0 && !isCrashed && isOnGround && drone.speed < 0.5 {
            notice = "Battery empty. A fresh one is in."
            noticeTimer = 4
            placeAtStart()
        }

        if isCrashed { recover(engine) }
    }

    /// Keeps the drone out of the ground and out of solid things, and decides whether a
    /// touch was a bump or a crash.
    private func collide(_ engine: Engine, previous: Vec3, dt: Float, testSolids: Bool) {
        let a = drone.airframe
        isOnGround = false

        // ---- the ground. Upright, the drone sits on its belly; tumbling, it is a ball.
        let ground = groundHeight(drone.position.x, drone.position.z)
        let upright = saturate(drone.up.y)
        let clearance = lerp(a.radius * 0.6, restHeight, upright * upright)
        if drone.position.y < ground + clearance {
            let normal = groundNormal(drone.position.x, drone.position.z)
            let into = -simd_dot(drone.velocity, normal)
            let along = drone.velocity + normal * into              // the part of the motion that slides
            let sliding = simd_length(along)
            let isHard = into > a.crashSpeed * 1.4 || (upright < 0.35 && drone.speed > 1.5) || (sliding > 11 && into > 0.3)
            if drone.isArmed && isHard { crash(engine, impact: max(into, sliding * 0.4)) }
            drone.position.y = ground + clearance
            let bounce: Float = into > 1.5 ? 0.25 : 0
            drone.velocity = along * (1 - min(1, (drone.isArmed ? 3 : 9) * dt)) + normal * (max(into, 0) * bounce)
            isOnGround = true
            if !drone.isArmed {
                drone.angularVelocity *= 1 - min(1, 10 * dt)
            } else if drone.thrust < a.mass * 9.81 * 0.6 && drone.speed < 2 {
                // Landed: sit flat. (Otherwise the flight controller would fight the ground.)
                let nose = drone.forward
                let flat = Quat(angle: atan2(-nose.x, -nose.z), axis: Vec3(0, 1, 0))
                drone.rotation = simd_slerp(drone.rotation, flat, min(1, 12 * dt))
                drone.angularVelocity = Vec3(0, 0, 0)
                // And it stays put: a breeze does not push a drone along the grass.
                if drone.speed < 0.6 { drone.velocity = Vec3(0, 0, 0) }
            }
        }

        // ---- everything else that is solid: gates, trees, the building
        if !testSolids { return }
        if engine.physics.overlapSphere(engine.scene, center: drone.position, radius: a.radius * 0.75).isEmpty { return }
        // Which way does the surface face? Ask a ray along the path that led here.
        let motion = drone.position - previous
        let travelled = simd_length(motion)
        var normal = -safeNormalize(drone.velocity, fallback: Vec3(0, 1, 0))
        if travelled > 1e-5 {
            let ray = Ray(origin: previous, direction: motion / travelled)
            if let hit = engine.physics.raycast(engine.scene, ray, maxDistance: travelled + a.radius * 2) { normal = hit.normal }
        }
        let into = -simd_dot(drone.velocity, normal)
        if into > 0 {
            if drone.isArmed && into > a.crashSpeed { crash(engine, impact: into) }
            // Bounce off, losing most of the speed that went into the surface.
            drone.velocity = (drone.velocity + normal * (into * 1.3)) * 0.9
            if drone.isArmed { drone.angularVelocity += random.onUnitSphere() * (into * 0.6) }
            glitch = max(glitch, saturate(into / 6) * 0.5)
        }
        drone.position = previous + normal * 0.004
    }

    private func crash(_ engine: Engine, impact: Float) {
        if isCrashed { return }
        isCrashed = true
        drone.isArmed = false
        crashTimer = 0
        restTimer = 0
        drone.angularVelocity += random.onUnitSphere() * min(impact * 2.5, 25)      // it tumbles
        glitch = 1
        controls.reset()
        if impact > 0 { engine.audio.play(sounds.crash, options: PlayOptions(volume: saturate(0.4 + impact / 12))) }
    }

    /// After a crash the wreck tumbles until it lies still. Then it is turned back onto its
    /// feet where it stopped, as "turtle mode" does on a real quad, and the race goes on.
    private func recover(_ engine: Engine) {
        let dt = engine.time.fixedDelta
        crashTimer += dt
        restTimer = isOnGround && drone.speed < 0.5 ? restTimer + dt : 0
        if restTimer < 0.8 && crashTimer < 6 { return }

        if lostSignal {
            // Too far to walk: the pilot carries it back.
            notice = "Signal lost. Back at the start."
            noticeTimer = 4
            placeAtStart()
            return
        }
        let nose = drone.forward
        var place = drone.position
        place.y = groundHeight(place.x, place.z) + restHeight
        drone.place(at: place, heading: atan2(-nose.x, -nose.z))
        isCrashed = false
        isWaitingToArm = true
    }

    private func finish(_ engine: Engine) {
        screen = .finished
        engine.audio.play(sounds.finish)
        if bestTime <= 0 || race.time < bestTime {
            bestTime = race.time
            isNewBest = true
            UserDefaults.standard.set(bestTime, forKey: "fpv.bestTime")
        }
    }

    // MARK: - Every frame

    public func update(_ engine: Engine, dt: Float) {
        let input = engine.input
        sticks = screen == .flying ? controls.read(engine, dt: dt, topBar: engine.safeArea.y + 56) : StickInput()
        flashTimer = max(0, flashTimer - dt)
        noticeTimer = max(0, noticeTimer - dt)
        glitch = max(0, glitch - dt * 2.5)

        // Controller buttons and keys, for those who are not touching the screen.
        if screen == .flying {
            if input.wasPressed(GamepadButton.a) || input.wasPressed(Key.r) { begin(mode) }
            if input.wasPressed(GamepadButton.x) || input.wasPressed(Key.m) { toggleFlightMode() }
            if input.wasPressed(GamepadButton.y) || input.wasPressed(Key.c) { view = view == .onboard ? .chase : .onboard }
            if input.wasPressed(GamepadButton.b) || input.wasPressed(Key.escape) { screen = .menu }
        } else if input.wasPressed(GamepadButton.start) || input.wasPressed(Key.enter) {
            begin(.race)
        }

        // The gate to fly through next is green.
        for (index, parts) in world.gateParts.enumerated() {
            let isNext = mode == .race && screen == .flying && index == race.nextGate
            for part in parts { engine.scene[part, MeshRenderer.self]?.material = isNext ? world.nextGateMaterial : world.gateMaterial }
        }

        model.update(engine, drone, dt: dt)
        updateCamera(engine, dt: dt)
        updateSound(engine, dt: dt)
    }

    private func updateCamera(_ engine: Engine, dt: Float) {
        guard var transform = engine.scene[camera, Transform.self], var lens = engine.scene[camera, Camera.self] else { return }
        var look = engine.renderer.settings
        let size = engine.screenSize
        let aspect = size.x / max(size.y, 1)
        let isOnboard = screen != .menu && view == .onboard

        if screen == .menu {
            // The menu looks at the field from a slow circle above it.
            let angle = Float(engine.time.elapsed) * 0.1 + 0.6
            let eye = Vec3(-25 + cos(angle) * 72, 24, -18 + sin(angle) * 72)
            transform.position = eye
            transform.rotation = .lookRotation(forward: Vec3(-25, 3, -18) - eye)
            lens.fovY = radians(55)
        } else if isOnboard {
            // The camera sits at the front of the drone, tilted up: flying fast means flying
            // nose down, and the tilt is what keeps the horizon in the picture.
            let s = drone.airframe.armX / 0.0795
            transform.position = drone.position + drone.rotation.act(Vec3(0, 0.022 * s, -0.094 * s))
            transform.rotation = drone.rotation * Quat(angle: radians(cameraTilt), axis: Vec3(1, 0, 0))
            // FPV lenses are very wide: 125 degrees from side to side, whatever the shape of the screen.
            lens.fovY = min(2 * atan(tan(radians(62.5)) / aspect), radians(112))
        } else {
            // From behind and above, following the way the drone points.
            let s = 0.45 + 0.55 * drone.airframe.armX / 0.0795
            let nose = drone.forward
            let behind = -safeNormalize(Vec3(nose.x, 0, nose.z), fallback: Vec3(0, 0, -1))
            let wanted = drone.position + behind * (1.0 * s) + Vec3(0, 0.32 * s, 0)
            chaseEye = damp(chaseEye, wanted, sharpness: 9, dt: dt)
            chaseEye.y = max(chaseEye.y, groundHeight(chaseEye.x, chaseEye.z) + 0.15)
            transform.position = chaseEye
            transform.rotation = .lookRotation(forward: drone.position - chaseEye)
            lens.fovY = radians(62)
        }
        engine.scene[camera, Transform.self] = transform
        engine.scene[camera, Camera.self] = lens

        // The onboard picture comes through a small wide lens and a radio link, and shows it.
        look.lensDistortion = isOnboard ? 0.38 : 0
        look.chromaticAberration = isOnboard ? 0.007 : 0
        look.filmGrain = isOnboard ? 0.022 : 0
        look.vignette = isOnboard ? 0.4 : 0.25
        let weak = saturate((0.5 - link) / 0.5)
        look.interference = isOnboard ? saturate(weak * weak.squareRoot() * 0.9 + glitch * 0.6) : 0
        engine.renderer.settings = look
    }

    private func updateSound(_ engine: Engine, dt: Float) {
        let mixer = engine.audio.mixer
        let isFlying = screen == .flying
        // Four motors, four voices: each a little out of tune with the others, as real ones are.
        let detune: [Float] = [1.0, 1.017, 0.985, 1.008]
        for i in 0..<min(4, motorSounds.count) {
            let speed = drone.motors[i]
            mixer.setPitch(motorSounds[i], max(speed * drone.airframe.maxRevs / 100, 0.05) * detune[i])
            mixer.setVolume(motorSounds[i], isFlying && speed > 0.01 ? 0.03 + 0.22 * pow(speed, 1.5) : 0)
        }
        let airspeed = simd_length(drone.velocity - drone.wind)
        mixer.setVolume(windSound, isFlying ? min(0.5, airspeed * airspeed / 1600 * 0.6) : 0)
        mixer.setPitch(windSound, 0.7 + airspeed / 45)

        // The buzzer, when a cell is below 3.5 volts.
        alarmTimer -= dt
        if isFlying && drone.isArmed && drone.cellVoltage < 3.5 && alarmTimer <= 0 {
            engine.audio.play(sounds.alarm)
            alarmTimer = 2.5
        }
    }
}
