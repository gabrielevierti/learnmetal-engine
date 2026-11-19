// FPVGame.swift
// FPV: fly a racing drone through a course of gates, seen from its own camera.
//
// The game is a few small parts:
//   FlightModel.swift   how the drone moves (pure math)
//   Track.swift         gates, laps and the clock (pure logic)
//   Controls.swift      thumbs, controller or keyboard -> stick positions
//   FPVGame.swift       this file: the world, the frame, the screens
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

    private static let laps = 2
    private static let droneRadius: Float = 0.2
    private static let restHeight: Float = 0.12                 // the drone's center when it sits on the ground
    private static let cameraTilt: Float = radians(22)          // FPV cameras look up, because the drone flies nose down

    private var screen = Screen.menu
    private var mode = Mode.race
    private var flightMode = FlightMode.angle
    private var drone = Drone()
    private var previousPosition = Vec3(0, 0, 0)
    private var sticks = StickInput()
    private var race = Race(gateCount: courseGates.count, laps: FPVGame.laps)
    private let controls = Controls()

    private var crashTimer: Float = 0                           // above zero: just crashed, waiting to respawn
    private var bestTime: Float = 0                             // 0: no time yet
    private var isNewBest = false
    private var flashTimer: Float = 0                           // a gate was just passed

    private var camera = Entity.invalid
    private var gateMaterial = Material()
    private var nextGateMaterial = Material()
    private var gateParts: [[Entity]] = []                      // the boxes that make up each gate
    private var motorSound: SoundHandle = 0
    private var gateSound = AudioClip()
    private var crashSound = AudioClip()
    private var finishSound = AudioClip()

    public init() {}

    // MARK: - The world

    public func start(_ engine: Engine) {
        let settings = UserDefaults.standard
        bestTime = settings.float(forKey: "fpv.bestTime")
        if settings.object(forKey: "fpv.fullStick") != nil { controls.throttleUsesFullStick = settings.bool(forKey: "fpv.fullStick") }
        if settings.bool(forKey: "fpv.acro") { flightMode = .acro }
        engine.input.stickDeadZone = 0.03           // radios are precise around the center: keep almost all of it

        var look = engine.renderer.settings
        look.cascades.shadowDistance = 90
        look.fogDensity = 0.006
        look.fogColor = look.sky.horizonColor
        look.bloomIntensity = 0.07
        #if os(iOS)
        // A phone has three pixels per point: render a little smaller and skip the most
        // expensive effect. The picture changes little, the frame rate a lot.
        look.renderScale = 0.75
        look.ambientOcclusionEnabled = false
        look.cascades.resolution = 1024
        #endif
        engine.renderer.settings = look

        buildWorld(engine)
        makeSounds(engine)
        resetDrone(toStart: true)
        // `--race` skips the menu: used when a picture of the game is captured without a screen.
        if engine.config.hasArgument("--race") { begin(.race) }
    }

    private func buildWorld(_ engine: Engine) {
        let scene = engine.scene
        let assets = engine.assets

        let sun = scene.create("Sun")
        scene.add(sun, Transform(rotation: .lookRotation(forward: Vec3(0.45, -0.8, -0.4))))
        scene.add(sun, Light(type: .directional, color: Vec3(1.0, 0.95, 0.85), intensity: 3.5, castsShadows: true))

        // The field: one big textured plane.
        let grass = Material()
        grass.baseColor = Vec4(0.62, 0.72, 0.52, 1)
        grass.metallic = 1                           // factors of 1 let the texture maps decide
        grass.roughness = 1
        grass.uvScale = Vec2(150, 150)
        grass.baseColorTexture = assets.texture("Textures/tiles_basecolor.png")
        grass.normalTexture = assets.texture("Textures/tiles_normal.png", format: .rgba8)
        grass.metallicRoughnessTexture = assets.texture("Textures/tiles_orm.png", format: .rgba8)
        let ground = scene.create("Ground")
        scene.add(ground, Transform(position: Vec3(-25, 0, -18), scale: Vec3(300, 1, 300)))
        scene.add(ground, MeshRenderer(mesh: assets.plane, material: grass))

        // Gates glow: orange, and green for the one to fly through next.
        gateMaterial = assets.makeMaterial(baseColor: Vec4(0.08, 0.04, 0.02, 1), metallic: 0, roughness: 0.5)
        gateMaterial.emissive = Vec3(2.4, 0.75, 0.15)
        nextGateMaterial = assets.makeMaterial(baseColor: Vec4(0.02, 0.08, 0.03, 1), metallic: 0, roughness: 0.5)
        nextGateMaterial.emissive = Vec3(0.3, 2.6, 0.6)
        gateParts = courseGates.map { gate in buildGate(engine, gate) }

        // Things to fly around: columns and stacks of crates, scattered by a fixed seed so
        // that the field is the same every time.
        let concrete = assets.makeMaterial(baseColor: Vec4(0.7, 0.7, 0.72, 1), metallic: 0, roughness: 0.85)
        let wood = assets.makeMaterial(baseColor: Vec4(0.72, 0.5, 0.28, 1), metallic: 0, roughness: 0.8)
        wood.baseColorTexture = assets.texture("Textures/checker_basecolor.png")
        var random = Random(seed: 7)
        var placed = 0
        while placed < 26 {
            let spot = Vec3(random.range(-85, 35), 0, random.range(-85, 45))
            // Keep the start and the racing line (the straight path from each gate to the next) clear.
            if simd_length(Vec2(spot.x, spot.z)) < 12 || distanceToCourse(Vec2(spot.x, spot.z)) < 9 { continue }
            placed += 1
            let entity = scene.create(placed % 2 == 0 ? "Column" : "Crates")
            if placed % 2 == 0 {
                let height = random.range(4, 11)
                scene.add(entity, Transform(position: spot + Vec3(0, height * 0.5, 0), scale: Vec3(1.4, height, 1.4)))
                scene.add(entity, MeshRenderer(mesh: assets.cylinder, material: concrete))
                scene.add(entity, Collider.capsule(radius: 0.7, halfHeight: max(height * 0.5 - 0.7, 0)))
            } else {
                let size = Vec3(random.range(2, 4), random.range(1.5, 4), random.range(2, 4))
                let turn = Quat(angle: random.range(0, Float.pi), axis: Vec3(0, 1, 0))
                scene.add(entity, Transform(position: spot + Vec3(0, size.y * 0.5, 0), rotation: turn, scale: size))
                scene.add(entity, MeshRenderer(mesh: assets.cube, material: wood))
                scene.add(entity, Collider.box(halfExtents: size * 0.5))
            }
        }

        camera = scene.create("FPV camera")
        scene.add(camera, Transform())
        scene.add(camera, Camera(fovY: radians(100), nearPlane: 0.05, farPlane: 700))
    }

    /// A gate is a frame of boxes around its opening: two posts and a bar on top, and a
    /// bar below if the opening does not reach the ground.
    private func buildGate(_ engine: Engine, _ gate: Gate) -> [Entity] {
        let thickness: Float = 0.3
        let top = gate.center.y + gate.height * 0.5
        let bottom = gate.center.y - gate.height * 0.5
        var boxes: [(center: Vec3, size: Vec3)] = []
        for side: Float in [-1, 1] {
            let x = side * (gate.width + thickness) * 0.5
            boxes.append((Vec3(x, (top + thickness) * 0.5 - gate.center.y, 0), Vec3(thickness, top + thickness, thickness)))
        }
        boxes.append((Vec3(0, gate.height * 0.5 + thickness * 0.5, 0), Vec3(gate.width, thickness, thickness)))
        if bottom > 0.6 {
            boxes.append((Vec3(0, -gate.height * 0.5 - thickness * 0.5, 0), Vec3(gate.width, thickness, thickness)))
        }
        return boxes.map { box in
            let entity = engine.scene.create("Gate")
            // The box is given in the gate's own space: turn it to face along the course.
            engine.scene.add(entity, Transform(position: gate.center + gate.rotation.act(box.center), rotation: gate.rotation, scale: box.size))
            engine.scene.add(entity, MeshRenderer(mesh: engine.assets.cube, material: gateMaterial))
            engine.scene.add(entity, Collider.box(halfExtents: box.size * 0.5))
            return entity
        }
    }

    private func makeSounds(_ engine: Engine) {
        // The motors: half a second of a buzzing wave, looped. Its pitch follows the throttle.
        let buzz = synthesize(SynthParams(waveform: .sawtooth, frequency: 100, duration: 0.5, attack: 0, release: 0, volume: 0.35))
        motorSound = engine.audio.play(buzz, options: PlayOptions(volume: 0, pitch: 1, loops: true))
        gateSound = synthesize(SynthParams(waveform: .triangle, frequency: 1320, duration: 0.09, release: 0.06, volume: 0.3))
        crashSound = synthesize(SynthParams(waveform: .noise, frequency: 0, duration: 0.35, attack: 0.001, release: 0.3, volume: 0.5, seed: 3))
        finishSound = synthesizeSequence([523.25, 659.25, 783.99, 1046.5].map {
            SynthParams(waveform: .triangle, frequency: $0, duration: 0.13, release: 0.08, volume: 0.3)
        })
    }

    // MARK: - Flying

    /// Puts the drone on the ground: at the start, or just past the last gate it flew through.
    private func resetDrone(toStart: Bool) {
        drone = Drone()
        var position = Vec3(0, FPVGame.restHeight, 0)
        var heading: Float = courseGates[0].yaw
        if !toStart && mode == .race && (race.lap > 0 || race.nextGate > 0) {
            let gate = courseGates[race.lastGate]
            let next = courseGates[race.nextGate]
            position = gate.center + gate.forward * 4
            position.y = FPVGame.restHeight
            // Face the gate to fly through next.
            heading = atan2(-(next.center.x - position.x), -(next.center.z - position.z))
        }
        drone.position = position
        drone.rotation = Quat(angle: heading, axis: Vec3(0, 1, 0))
        previousPosition = position
        controls.reset()
        crashTimer = 0
    }

    private func begin(_ newMode: Mode) {
        mode = newMode
        race = Race(gateCount: courseGates.count, laps: FPVGame.laps)
        isNewBest = false
        screen = .flying
        resetDrone(toStart: true)
    }

    private func crash(_ engine: Engine) {
        crashTimer = 1.1
        drone.velocity = Vec3(0, 0, 0)
        drone.angularVelocity = Vec3(0, 0, 0)
        engine.audio.play(crashSound)
    }

    public func fixedUpdate(_ engine: Engine, dt: Float) {
        guard screen == .flying else { return }
        if crashTimer > 0 {
            crashTimer -= dt
            if crashTimer <= 0 { resetDrone(toStart: false) }
            return
        }
        if mode == .race { race.update(dt: dt) }
        // During the countdown the motors stay off.
        var input = sticks
        if mode == .race && race.phase == .countdown { input.throttle = 0 }

        // Four small steps per physics step: at 670 degrees per second, a sixtieth of a
        // second is too coarse.
        let substeps = 4
        for _ in 0..<substeps {
            previousPosition = drone.position
            drone.step(input, mode: flightMode, dt: dt / Float(substeps))

            // The ground: a hard arrival is a crash, a gentle one is a landing.
            if drone.position.y < FPVGame.restHeight {
                if drone.velocity.y < -5 || drone.speed > 10 || drone.up.y < 0.3 {
                    crash(engine)
                    return
                }
                drone.position.y = FPVGame.restHeight
                drone.velocity = Vec3(drone.velocity.x * 0.9, max(drone.velocity.y, 0), drone.velocity.z * 0.9)
            }
            // Everything else that is solid: gates, columns, crates.
            if !engine.physics.overlapSphere(engine.scene, center: drone.position, radius: FPVGame.droneRadius).isEmpty {
                crash(engine)
                return
            }
            if mode == .race && race.phase == .running {
                let gate = courseGates[race.nextGate]
                if gate.isPassed(from: previousPosition, to: drone.position) && race.pass(gate: race.nextGate) {
                    flashTimer = 0.25
                    engine.audio.play(gateSound, options: PlayOptions(pitch: race.nextGate == 0 ? 1.5 : 1))
                    if race.phase == .finished { finish(engine) }
                }
            }
        }
    }

    private func finish(_ engine: Engine) {
        screen = .finished
        engine.audio.play(finishSound)
        if bestTime <= 0 || race.time < bestTime {
            bestTime = race.time
            isNewBest = true
            UserDefaults.standard.set(bestTime, forKey: "fpv.bestTime")
        }
    }

    public func update(_ engine: Engine, dt: Float) {
        let input = engine.input
        sticks = screen == .flying ? controls.read(engine, dt: dt, topBar: engine.safeArea.y + 60) : StickInput()
        flashTimer = max(0, flashTimer - dt)

        // Controller buttons and keys, for those who are not touching the screen.
        if screen == .flying {
            if input.wasPressed(GamepadButton.a) || input.wasPressed(Key.r) { resetDrone(toStart: false) }
            if input.wasPressed(GamepadButton.x) || input.wasPressed(Key.m) { toggleFlightMode() }
            if input.wasPressed(GamepadButton.b) || input.wasPressed(Key.escape) { screen = .menu }
        } else if input.wasPressed(GamepadButton.start) || input.wasPressed(Key.enter) {
            begin(.race)
        }

        // The gate to fly through next is green.
        for (index, parts) in gateParts.enumerated() {
            let isNext = mode == .race && screen == .flying && index == race.nextGate
            for part in parts { engine.scene[part, MeshRenderer.self]?.material = isNext ? nextGateMaterial : gateMaterial }
        }

        // The camera rides on the drone, tilted up. In the menu it circles the field instead.
        if screen == .menu {
            let angle = Float(engine.time.elapsed) * 0.12
            let eye = Vec3(-25 + cos(angle) * 60, 22, -18 + sin(angle) * 60)
            engine.scene[camera, Transform.self] = Transform(position: eye, rotation: .lookRotation(forward: Vec3(-25, 2, -18) - eye))
        } else {
            let rotation = drone.rotation * Quat(angle: FPVGame.cameraTilt, axis: Vec3(1, 0, 0))
            engine.scene[camera, Transform.self] = Transform(position: drone.position + drone.up * 0.05, rotation: rotation)
        }

        // Motors: louder and higher with the throttle, silent in the menu and after a crash.
        let isRunning = screen == .flying && crashTimer <= 0
        engine.audio.mixer.setVolume(motorSound, isRunning ? 0.04 + 0.2 * sticks.throttle : 0)
        engine.audio.mixer.setPitch(motorSound, 0.9 + 2.4 * sticks.throttle)
    }

    private func toggleFlightMode() {
        flightMode = flightMode == .angle ? .acro : .angle
        UserDefaults.standard.set(flightMode == .acro, forKey: "fpv.acro")
    }

    // MARK: - Screens

    /// A button for fingers and for the mouse. Returns true in the frame it is pressed.
    private func button(_ engine: Engine, _ canvas: Canvas, _ label: String, _ position: Vec2, _ size: Vec2, highlighted: Bool = false) -> Bool {
        func isInside(_ p: Vec2) -> Bool {
            p.x >= position.x && p.y >= position.y && p.x < position.x + size.x && p.y < position.y + size.y
        }
        let input = engine.input
        // Any finger counts, not only the first: one thumb may already be holding a stick.
        let touched = input.touches.contains { $0.phase == .began && isInside($0.position) }
        let clicked = input.touches.isEmpty && input.wasPressed(MouseButton.left) && isInside(input.mousePosition)
        canvas.rect(position, size, highlighted ? rgb(0xfe8b3c, alpha: 0.9) : Vec4(0.04, 0.06, 0.1, 0.62))
        canvas.rectOutline(position, size, thickness: 1, Vec4(1, 1, 1, 0.25))
        let textSize = min(size.y * 0.42, 20)
        canvas.text(label, position + Vec2(size.x * 0.5, (size.y - textSize) * 0.5 - 1), size: textSize,
                    highlighted ? rgb(0x14181f) : Vec4(1, 1, 1, 0.95), align: .center)
        return touched || clicked
    }

    public func draw(_ engine: Engine, canvas: Canvas) {
        switch screen {
        case .menu: drawMenu(engine, canvas)
        case .flying: drawFlying(engine, canvas)
        case .finished: drawFinished(engine, canvas)
        }
    }

    private func drawMenu(_ engine: Engine, _ canvas: Canvas) {
        let size = canvas.size
        let center = size.x * 0.5
        canvas.rect(Vec2(0, 0), size, Vec4(0.02, 0.03, 0.06, 0.45))
        canvas.text("FPV", Vec2(center, size.y * 0.10), size: 64, rgb(0xfe8b3c), align: .center)
        canvas.text(bestTime > 0 ? "Best race: " + formatTime(bestTime) : "No race time yet", Vec2(center, size.y * 0.10 + 74),
                    size: 17, Vec4(1, 1, 1, 0.8), align: .center)

        let width: Float = 280, height: Float = 46, gap: Float = 10
        var y = size.y * 0.10 + 112
        if button(engine, canvas, "Race, \(FPVGame.laps) laps", Vec2(center - width * 0.5, y), Vec2(width, height), highlighted: true) { begin(.race) }
        y += height + gap
        if button(engine, canvas, "Free flight", Vec2(center - width * 0.5, y), Vec2(width, height)) { begin(.free) }
        y += height + gap
        if button(engine, canvas, flightMode == .angle ? "Mode: Angle (self-leveling)" : "Mode: Acro (rates)",
                  Vec2(center - width * 0.5, y), Vec2(width, height)) { toggleFlightMode() }
        y += height + gap
        if button(engine, canvas, controls.throttleUsesFullStick ? "Controller throttle: whole stick" : "Controller throttle: upper half",
                  Vec2(center - width * 0.5, y), Vec2(width, height)) {
            controls.throttleUsesFullStick.toggle()
            UserDefaults.standard.set(controls.throttleUsesFullStick, forKey: "fpv.fullStick")
        }
        let hint = engine.input.isGamepadConnected ? "Controller connected. Left stick: throttle and yaw. Right stick: pitch and roll."
            : "Left thumb: throttle and yaw. Right thumb: pitch and roll. A controller or an RC radio works too."
        canvas.text(hint, Vec2(center, size.y - engine.safeArea.w - 34), size: 14, Vec4(1, 1, 1, 0.75), align: .center)
    }

    private func drawFlying(_ engine: Engine, _ canvas: Canvas) {
        let size = canvas.size, safe = engine.safeArea
        let white = Vec4(1, 1, 1, 0.95)
        let top = safe.y + 10
        let left = safe.x + 14, right = size.x - safe.z - 14

        // The strip of buttons at the top.
        if button(engine, canvas, "Menu", Vec2(left, top), Vec2(74, 40)) { screen = .menu }
        if button(engine, canvas, "Reset", Vec2(left + 82, top), Vec2(74, 40)) { resetDrone(toStart: false) }
        if button(engine, canvas, flightMode == .angle ? "Angle" : "Acro", Vec2(right - 84, top), Vec2(84, 40), highlighted: flightMode == .acro) {
            toggleFlightMode()
        }

        // Speed and height, bottom center: between the sticks, out of the way.
        let kmh = Int(drone.speed * 3.6)
        canvas.text("\(kmh) km/h    \(String(format: "%.1f", Double(max(drone.position.y, 0)))) m", Vec2(size.x * 0.5, size.y - safe.w - 30),
                    size: 16, Vec4(1, 1, 1, 0.85), align: .center)

        if mode == .race {
            canvas.text(formatTime(race.time), Vec2(size.x * 0.5, top + 2), size: 28, white, align: .center)
            canvas.text("Lap \(min(race.lap + 1, race.laps)) / \(race.laps)    Gate \(race.nextGate + 1) / \(race.gateCount)",
                        Vec2(size.x * 0.5, top + 36), size: 15, Vec4(1, 1, 1, 0.8), align: .center)
            if race.phase == .countdown {
                canvas.text("\(Int(race.countdown.rounded(.up)))", Vec2(size.x * 0.5, size.y * 0.32), size: 96, rgb(0xfe8b3c), align: .center)
            }
            drawGateMarker(engine, canvas, courseGates[race.nextGate])
        }
        if flashTimer > 0 { canvas.rect(Vec2(0, 0), size, Vec4(0.3, 1, 0.5, 0.25 * flashTimer / 0.25)) }
        if crashTimer > 0 {
            canvas.rect(Vec2(0, 0), size, Vec4(0.5, 0.05, 0.02, 0.45))
            canvas.text("Crashed", Vec2(size.x * 0.5, size.y * 0.36), size: 44, white, align: .center)
        }
        controls.draw(engine, canvas)
    }

    /// Shows where the next gate is: a ring on it when it is in view, an arrow at the edge
    /// of the screen when it is not.
    private func drawGateMarker(_ engine: Engine, _ canvas: Canvas, _ gate: Gate) {
        guard let transform = engine.scene[camera, Transform.self], let lens = engine.scene[camera, Camera.self] else { return }
        let size = canvas.size
        // The gate as the camera sees it: x right, y up, -z ahead.
        let local = transform.rotation.inverse.act(gate.center - transform.position)
        let green = rgb(0x7dff9a)
        let tangent = tan(lens.fovY * 0.5)
        if local.z < -0.5 {
            let x = local.x / (-local.z * tangent * size.x / size.y), y = local.y / (-local.z * tangent)
            if abs(x) < 0.95 && abs(y) < 0.95 {
                let point = Vec2((x * 0.5 + 0.5) * size.x, (0.5 - y * 0.5) * size.y)
                canvas.circle(center: point, radius: 9, green, segments: 20)
                canvas.circle(center: point, radius: 6, Vec4(0, 0, 0, 0.5), segments: 20)
                canvas.text("\(Int(simd_length(local))) m", point + Vec2(0, 12), size: 13, green, align: .center)
                return
            }
        }
        // Out of view: point toward it from the middle of the nearer side.
        let isLeft = local.x < 0
        let tip = Vec2(isLeft ? engine.safeArea.x + 26 : size.x - engine.safeArea.z - 26, size.y * 0.42)
        let back: Float = isLeft ? 18 : -18
        canvas.line(from: tip + Vec2(back, -14), to: tip, thickness: 4, green)
        canvas.line(from: tip + Vec2(back, 14), to: tip, thickness: 4, green)
    }

    private func drawFinished(_ engine: Engine, _ canvas: Canvas) {
        let size = canvas.size
        let center = size.x * 0.5
        canvas.rect(Vec2(0, 0), size, Vec4(0.02, 0.03, 0.06, 0.6))
        var y = size.y * 0.14
        canvas.text("Finished", Vec2(center, y), size: 46, rgb(0xfe8b3c), align: .center)
        y += 62
        canvas.text(formatTime(race.time), Vec2(center, y), size: 38, Vec4(1, 1, 1, 1), align: .center)
        y += 50
        canvas.text(isNewBest ? "New best time" : "Best: " + formatTime(bestTime), Vec2(center, y), size: 18,
                    isNewBest ? rgb(0x7dff9a) : Vec4(1, 1, 1, 0.8), align: .center)
        y += 30
        for (index, lapTime) in race.lapTimes.enumerated() {
            canvas.text("Lap \(index + 1)   " + formatTime(lapTime), Vec2(center, y), size: 16, Vec4(1, 1, 1, 0.8), align: .center)
            y += 22
        }
        y += 14
        if button(engine, canvas, "Race again", Vec2(center - 150, y), Vec2(144, 46), highlighted: true) { begin(.race) }
        if button(engine, canvas, "Menu", Vec2(center + 6, y), Vec2(144, 46)) { screen = .menu }
    }
}
