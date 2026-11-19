// MarbleGame.swift
// Marble: roll through the course, collect every gem, reach the goal.
//
// The whole game is this one class. Read it as the answer to "how do I use the engine?":
// start() builds the scene, fixedUpdate() pushes the marble, update() does everything
// that follows the frame rate, draw() paints the interface.

import Foundation
import LMEngine
import simd

private let acceleration: Float = 22        // meters per second, per second
private let maxSpeed: Float = 9
private let jumpSpeed: Float = 6.2
private let airControl: Float = 0.35        // how much steering is left while in the air
private let fallHeight: Float = -12         // below this the marble is lost

final class MarbleGame: Game {
    /// Shows the whole course from above instead of following the marble. On by default
    /// when there is no window, so that a captured image shows the entire level.
    var showsOverview = false

    /// Lets the autopilot play (`--demo`).
    var isDemo = false
    private(set) var hasWon = false
    private(set) var collectedCount = 0

    private var level = Level()
    private var sounds = Sounds.make()
    private var autopilot = Autopilot()
    private var rollSound: SoundHandle = 0

    private var hasMoved = false                // the clock starts with the first input
    private var playTime: Float = 0
    private var collectPulse: Float = 0         // makes the counter jump when a gem is collected
    private var jumpBuffer: Float = 0           // a jump pressed slightly too early still counts
    private var wish = Vec2(0, 0)               // the stick, remembered for fixedUpdate
    private var lastSafePosition = Vec3(0, 1, 0)

    private var cameraYaw: Float = 0            // radians around the marble; 0 looks toward -z
    private var cameraPitch: Float = 0.45
    private var cameraDistance: Float = 9
    private var cameraTarget = Vec3(0, 0, 0)

    // MARK: - Setup

    func start(_ engine: Engine) {
        showsOverview = engine.window == nil
        isDemo = isDemo || engine.config.hasArgument("--demo")

        // Actions: the game asks "is jump pressed?" and never mentions a key or a button again.
        let input = engine.input
        input.bindAxis("moveX", negative: .a, positive: .d, gamepadAxis: .leftX)
        input.bindAxis("moveY", negative: .s, positive: .w, gamepadAxis: .leftY)
        input.bindAxis("lookX", negative: .left, positive: .right, gamepadAxis: .rightX)
        input.bindAxis("lookY", negative: .down, positive: .up, gamepadAxis: .rightY)
        input.bindButton("jump", keys: [.space], buttons: [.a])
        input.bindButton("restart", keys: [.r], buttons: [.start])
        input.bindButton("quit", keys: [.escape], buttons: [.back])

        // The look of the game.
        engine.renderer.settings.cascades.shadowDistance = 70
        engine.renderer.settings.fogDensity = 0.002         // a little haze, in the color of the horizon
        engine.renderer.settings.fogColor = engine.renderer.settings.sky.horizonColor
        engine.renderer.settings.bloomIntensity = 0.05

        // Physics events. They arrive at the end of a physics step.
        engine.physics.onTriggerEnter = { [unowned self, unowned engine] trigger, other in
            if other != self.level.marble { return }
            if engine.scene.has(Gem.self, trigger) {
                self.collect(engine, trigger)
            } else if trigger == self.level.goal && self.collectedCount == self.level.gemCount && !self.hasWon {
                self.hasWon = true
                engine.audio.play(self.sounds.win)
                if let goal = engine.scene[self.level.goal, Transform.self] {
                    self.spawnBurst(engine, position: goal.position + Vec3(0, 0.5, 0), color: Vec3(0.4, 1.0, 0.5))
                }
            }
        }
        engine.physics.onContactBegin = { [unowned self, unowned engine] contact in
            if contact.a != self.level.marble && contact.b != self.level.marble { return }
            if contact.impactSpeed < 2.5 { return }
            let volume = saturate(contact.impactSpeed / 12)     // harder hits are louder
            engine.audio.play(self.sounds.land, options: PlayOptions(volume: volume, pitch: 0.9 + 0.2 * volume))
        }

        restart(engine)
    }

    private func restart(_ engine: Engine) {
        engine.scene.clear()
        engine.physics.reset()
        level = buildLevel(engine)

        collectedCount = 0
        hasWon = false
        hasMoved = false
        playTime = 0
        collectPulse = 0
        jumpBuffer = 0
        wish = Vec2(0, 0)
        lastSafePosition = level.start
        cameraYaw = 0
        cameraPitch = 0.45
        cameraTarget = level.start
        autopilot.reset()

        // The rolling rumble plays all the time; update() only changes how loud it is.
        engine.audio.stop(rollSound)
        rollSound = engine.audio.play(sounds.roll, options: PlayOptions(volume: 0, pitch: 0.1, loops: true))
    }

    // MARK: - The fixed step: forces

    func fixedUpdate(_ engine: Engine, dt: Float) {
        let scene = engine.scene
        guard var body = scene[level.marble, RigidBody.self] else { return }

        // Push the marble where the stick points, relative to where the camera looks.
        // (The autopilot thinks in compass directions instead: east and north.)
        if !hasWon {
            var forward = Vec3(-sin(cameraYaw), 0, -cos(cameraYaw))
            var right = Vec3(cos(cameraYaw), 0, -sin(cameraYaw))
            if isDemo {
                let command = autopilot.steer(engine, level)
                wish = command.push
                if command.jump { jumpBuffer = 0.15 }
                forward = Vec3(0, 0, -1)
                right = Vec3(1, 0, 0)
                if simd_length(wish) > 0.1 { hasMoved = true }
            }
            let push = right * wish.x + forward * wish.y
            let control: Float = body.isGrounded ? 1 : airControl
            body.velocity += push * (acceleration * control * dt)

            // A speed limit on the ground plane only, so that falling stays fast.
            var flat = Vec3(body.velocity.x, 0, body.velocity.z)
            let speed = simd_length(flat)
            if speed > maxSpeed {
                flat *= maxSpeed / speed
                body.velocity = Vec3(flat.x, body.velocity.y, flat.z)
            }

            jumpBuffer -= dt
            if jumpBuffer > 0 && body.isGrounded {
                body.velocity.y = jumpSpeed
                jumpBuffer = 0
                engine.audio.play(sounds.jump)
            }
        }
        // Components are values: `body` is a copy, and this stores it back.
        scene[level.marble, RigidBody.self] = body

        // Remember the last place where the marble stood on solid, level, unmoving ground.
        for contact in engine.physics.contacts {
            let marbleIsB = contact.b == level.marble
            if !marbleIsB && contact.a != level.marble { continue }
            let ground = marbleIsB ? contact.a : contact.b
            let up = marbleIsB ? contact.normal.y : -contact.normal.y
            if up > 0.98 && !scene.has(RigidBody.self, ground) { lastSafePosition = body.position }
        }

        // Moving platforms: a kinematic body goes where its velocity takes it, so the
        // platform is steered by setting the velocity that leads to where it should be next.
        let time = Float(engine.time.elapsed)
        scene.each(MovingPlatform.self, RigidBody.self) { _, platform, platformBody in
            let t = 0.5 - 0.5 * cos((time + dt) / platform.period * 2 * Float.pi)      // 0 -> 1 -> 0, easing at the ends
            let target = lerp(platform.from, platform.to, t)
            platformBody.velocity = (target - platformBody.position) / dt
        }
    }

    // MARK: - Once per frame

    func update(_ engine: Engine, dt: Float) {
        let scene = engine.scene
        let input = engine.input

        if input.wasPressed("quit") { engine.quit() }
        if input.wasPressed("restart") {
            restart(engine)
            return
        }

        // Input is read here, once per frame, and remembered for the fixed steps.
        if !isDemo {
            wish = Vec2(input.axis("moveX"), input.axis("moveY"))
            let length = simd_length(wish)
            if length > 1 { wish /= length }                // diagonals are not faster
            if input.wasPressed("jump") { jumpBuffer = 0.15 }
            if length > 0.1 { hasMoved = true }
        }
        if hasMoved && !hasWon { playTime += dt }
        collectPulse = max(0, collectPulse - dt * 3)

        guard var body = scene[level.marble, RigidBody.self] else { return }
        if body.position.y < fallHeight {
            respawn(engine)
            body = scene[level.marble, RigidBody.self] ?? body
        }

        // The physics moves the marble but does not spin it. Turn it by the angle a ball of
        // this size rolls through when it travels this far: distance divided by radius.
        let flat = Vec3(body.velocity.x, 0, body.velocity.z)
        let speed = simd_length(flat)
        if speed > 0.05, let rotation = scene[level.marble, Transform.self]?.rotation {
            let axis = simd_normalize(simd_cross(Vec3(0, 1, 0), flat))
            let roll = Quat(angle: speed * dt / Level.marbleRadius, axis: axis)
            scene[level.marble, Transform.self]?.rotation = simd_normalize(roll * rotation)
        }

        // The rumble gets louder and higher with speed, and stops in the air.
        let rolling = body.isGrounded ? saturate(speed / maxSpeed) : 0
        engine.audio.mixer.setVolume(rollSound, 0.16 * rolling)
        engine.audio.mixer.setPitch(rollSound, 0.08 + 0.1 * rolling)

        // Gems turn and bob; their lights and triggers move with them.
        let time = Float(engine.time.elapsed)
        scene.each(Gem.self, Transform.self) { _, gem, transform in
            transform.position = gem.home + Vec3(0, 0.18 * sin(time * 2 + gem.phase), 0)
            transform.rotation = Quat(angle: time * 1.4 + gem.phase, axis: Vec3(0, 1, 0))
        }

        // The goal lights up green once every gem is collected.
        let isOpen = collectedCount == level.gemCount
        let glow = 1 + 0.3 * sin(time * 4)
        level.goalMaterial.emissive = (isOpen ? Vec3(0.2, 1.6, 0.4) : Vec3(1.2, 0.25, 0.1)) * glow
        scene[level.goal, Light.self]?.color = isOpen ? Vec3(0.3, 1.0, 0.4) : Vec3(1.0, 0.3, 0.15)

        scene.each(Lifetime.self) { entity, lifetime in
            lifetime.seconds -= dt
            if lifetime.seconds <= 0 { scene.destroy(entity) }     // takes effect at the end of the frame
        }

        updateCamera(engine, dt: dt)
    }

    private func updateCamera(_ engine: Engine, dt: Float) {
        let input = engine.input
        guard let marble = engine.scene[level.marble, Transform.self] else { return }

        if showsOverview {
            let position = Vec3(-13, 15, 21)
            engine.scene[level.camera, Transform.self]?.position = position
            engine.scene[level.camera, Transform.self]?.rotation = .lookRotation(forward: Vec3(8.5, 0, -2.5) - position)
            return
        }

        // Orbit with the right stick, the arrow keys, or by dragging the mouse.
        cameraYaw -= input.axis("lookX") * 2.2 * dt
        cameraPitch += input.axis("lookY") * 1.5 * dt
        if input.isDown(MouseButton.left) {
            cameraYaw -= input.mouseDelta.x * 0.006
            cameraPitch += input.mouseDelta.y * 0.006
        }
        cameraPitch = min(max(cameraPitch, 0.1), 1.35)
        cameraDistance = min(max(cameraDistance - input.scrollDelta * 0.8, 4), 18)

        // Follow the marble a little late: `damp` closes a fixed share of the gap per second,
        // whatever the frame rate.
        cameraTarget = damp(cameraTarget, marble.position + Vec3(0, 0.6, 0), sharpness: 10, dt: dt)
        let offset = Vec3(sin(cameraYaw) * cos(cameraPitch), sin(cameraPitch), cos(cameraYaw) * cos(cameraPitch))
        let position = cameraTarget + offset * cameraDistance
        engine.scene[level.camera, Transform.self]?.position = position
        engine.scene[level.camera, Transform.self]?.rotation = .lookRotation(forward: cameraTarget - position)
    }

    // MARK: - Events

    private func collect(_ engine: Engine, _ gem: Entity) {
        guard let data = engine.scene[gem, Gem.self], let transform = engine.scene[gem, Transform.self] else { return }
        collectedCount += 1
        collectPulse = 1
        spawnBurst(engine, position: transform.position, color: data.color)

        // Each gem rings a little higher than the one before.
        engine.audio.play(sounds.collect, options: PlayOptions(pitch: 1 + 0.06 * Float(collectedCount - 1)))
        engine.scene.destroy(gem)
    }

    private func spawnBurst(_ engine: Engine, position: Vec3, color: Vec3) {
        let burst = engine.scene.create("Burst")
        engine.scene.add(burst, Transform(position: position))
        var emitter = ParticleEmitter()
        emitter.rate = 0                            // nothing continuous: one burst
        emitter.spread = Float.pi                   // in every direction
        emitter.speedMin = 2
        emitter.speedMax = 5
        emitter.lifetimeMin = 0.4
        emitter.lifetimeMax = 0.9
        emitter.sizeStart = 0.22
        emitter.colorStart = Vec4(color * 4, 1)     // brighter than white: the bloom makes it glow
        emitter.colorEnd = Vec4(color, 0)
        emitter.burst(48)
        engine.scene.add(burst, emitter)
        engine.scene.add(burst, Lifetime(seconds: 1.2))
    }

    private func respawn(_ engine: Engine) {
        engine.physics.teleport(engine.scene, level.marble, to: lastSafePosition + Vec3(0, 0.3, 0))
        engine.scene[level.marble, RigidBody.self]?.velocity = Vec3(0, 0, 0)
        engine.audio.play(sounds.fall)
    }

    // MARK: - Interface

    func draw(_ engine: Engine, canvas: Canvas) {
        let size = canvas.size
        let white = Vec4(1, 1, 1, 1)
        let panel = Vec4(0.04, 0.06, 0.1, 0.6)

        // Gems, top left.
        canvas.rect(Vec2(16, 16), Vec2(132, 44), panel)
        canvas.circle(center: Vec2(40, 38), radius: 9, rgb(0x3fd0ff), segments: 6)     // six segments: a hexagon, close enough to a gem
        let pulse = 22 + 8 * collectPulse
        canvas.text("\(collectedCount) / \(level.gemCount)", Vec2(60, 38 - pulse * 0.6), size: pulse, white)

        // The clock, top right.
        let minutes = Int(playTime) / 60
        let seconds = playTime - Float(minutes * 60)
        let clock = String(format: "%ld:%05.2f", minutes, Double(seconds))
        canvas.rect(Vec2(size.x - 136, 16), Vec2(120, 44), panel)
        canvas.text(clock, Vec2(size.x - 28, 25), size: 22, white, align: .right)

        if isDemo {
            canvas.text("Demo: the autopilot is playing", Vec2(size.x * 0.5, size.y - 44), size: 16, Vec4(1, 1, 1, 0.85), align: .center)
        } else if !hasMoved {
            canvas.text("W A S D or left stick: roll     Space: jump     Arrows or drag: look     R: restart",
                        Vec2(size.x * 0.5, size.y - 44), size: 16, Vec4(1, 1, 1, 0.85), align: .center)
        }
        if collectedCount == level.gemCount && !hasWon {
            canvas.text("The goal is open", Vec2(size.x * 0.5, 28), size: 20, rgb(0x7dff9a), align: .center)
        }
        if hasWon {
            let box = Vec2(420, 150)
            let corner = (size - box) * 0.5
            canvas.rect(corner, box, Vec4(0.04, 0.06, 0.1, 0.8))
            canvas.rectOutline(corner, box, thickness: 2, rgb(0xfe8b3c))
            canvas.text("Course complete", Vec2(size.x * 0.5, corner.y + 20), size: 34, rgb(0xfe8b3c), align: .center)
            canvas.text("Time  " + clock, Vec2(size.x * 0.5, corner.y + 70), size: 22, white, align: .center)
            canvas.text("Press R to play again", Vec2(size.x * 0.5, corner.y + 108), size: 16, Vec4(1, 1, 1, 0.8), align: .center)
        }
    }
}
