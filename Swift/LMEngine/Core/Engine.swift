// Engine.swift
// The engine in one object: it owns the window, the renderer, the scene, the physics
// world, input, audio and assets, and it runs the loop that ties them together.
//
// Every frame does the same things in the same order:
//
//   1. read input
//   2. zero or more fixed steps: Game.fixedUpdate, then physics
//   3. Game.update, then Behavior components
//   4. remove destroyed entities, compute world matrices, move particles
//   5. Game.draw fills the 2D canvas
//   6. the renderer draws the scene, then the canvas on top

#if os(macOS)
import AppKit
#endif
import ImageIO
import QuartzCore
import simd

public struct EngineConfig {
    public var title = "LearnMetal Engine"
    public var width = 1280                 // of the window, in points
    public var height = 720
    public var fullscreen = false
    public var vsync = true
    /// F1 statistics, F2 collider outlines, F3 full screen, F4 saves a screenshot.
    public var developerKeys = true

    /// If not empty, there is no window and no sound: the game runs `captureFrames` frames at
    /// exactly 60 per second, the last one is saved to this PNG file, and run() returns.
    /// This is how the engine is tested on machines nobody is looking at.
    public var capturePath = ""
    public var captureFrames = 90
    public var captureScale = 1             // pixels per point of the captured image: 2 gives a "Retina" picture

    /// Whatever fromArguments() did not recognize: a game's own options.
    public var arguments: [String] = []

    public init() {}

    public func hasArgument(_ name: String) -> Bool { arguments.contains(name) }

    /// Starts from `defaults` and applies --width N, --height N, --fullscreen,
    /// --capture FILE.png, --frames N and --scale N. Pass `CommandLine.arguments`.
    public static func fromArguments(_ arguments: [String], defaults: EngineConfig = EngineConfig()) -> EngineConfig {
        var config = defaults
        var i = 1                           // the first argument is the program's own path
        while i < arguments.count {
            let argument = arguments[i]
            let value: String? = i + 1 < arguments.count ? arguments[i + 1] : nil
            i += 1
            switch (argument, value) {
            case ("--fullscreen", _):
                config.fullscreen = true
            case ("--width", let value?):
                config.width = Int(value) ?? config.width
                i += 1
            case ("--height", let value?):
                config.height = Int(value) ?? config.height
                i += 1
            case ("--capture", let value?):
                config.capturePath = value
                i += 1
            case ("--frames", let value?):
                config.captureFrames = Int(value) ?? config.captureFrames
                i += 1
            case ("--scale", let value?):
                config.captureScale = Int(value) ?? config.captureScale
                i += 1
            default:
                config.arguments.append(argument)
            }
        }
        config.width = max(config.width, 16)
        config.height = max(config.height, 16)
        config.captureFrames = max(config.captureFrames, 1)
        config.captureScale = min(max(config.captureScale, 1), 4)
        return config
    }
}

@MainActor
public final class Engine {
    public let config: EngineConfig

    // MARK: The parts. A game uses them directly.

    public let scene = Scene()
    public let physics = Physics()
    public let input = Input()
    public var time = Time()
    public let renderer: Renderer
    public let assets: Assets
    public let audio: Audio
    /// Lines in 3D for the next frame: engine.debug.line(a, b, color).
    public var debug: DebugDraw { renderer.debug }
    #if os(macOS)
    /// nil when running without a window (EngineConfig.capturePath).
    public private(set) var window: Window?
    #endif
    /// What the engine draws into: the window on a Mac, the view on an iPhone or iPad.
    /// nil when running without one.
    public private(set) weak var surface: Surface?
    /// True when nothing is shown on a screen: the game is being captured to a file.
    public var isHeadless: Bool { surface == nil }
    /// The device, for a host that creates the view itself (see EngineViewController).
    public var graphicsDevice: GraphicsDevice { device }

    /// While true, physics stands still: bodies keep the place their Transform gives them.
    /// An editor sets this while a scene is being edited.
    public var isSimulationPaused = false

    public var showsStatistics = false      // F1
    public var showsColliders = false       // F2

    private let device: GraphicsDevice
    private let canvas = Canvas()
    private var font: Font?
    private var pendingScreenshot: String?
    private var isRunning = true
    private var previousTime = 0.0

    public init(config: EngineConfig = EngineConfig()) {
        self.config = config
        let isCapturing = !config.capturePath.isEmpty
        let root = findRootDirectory()
        logInfo("shaders and assets from \(root)")

        device = GraphicsDevice()
        renderer = Renderer(device: device, shaderDirectory: root + "/Shaders")
        assets = Assets(device: device, directory: root + "/Assets")
        audio = Audio(openDevice: !isCapturing)
        #if os(macOS)
        if !isCapturing {
            // A command-line program becomes a regular application: Dock icon, menu bar, windows.
            NSApplication.shared.setActivationPolicy(.regular)
            let window = Window(title: config.title, width: config.width, height: config.height, fullscreen: config.fullscreen,
                                device: device.device, input: input)
            window.setVSync(config.vsync)
            self.window = window
            surface = window
        }
        #endif
        setFont(assets.font("Fonts/Default"))
    }

    // MARK: - For a host that owns the screen (iOS)
    //
    // On a Mac the engine opens its own window and run() does everything. On iOS the
    // system owns the application and the screen: a view controller creates the engine,
    // hands it the view with attach(), calls begin() once and step() for every frame.

    public func attach(_ surface: Surface) {
        self.surface = surface
    }

    public func begin(_ game: Game) {
        autoreleasepool { game.start(self) }
        previousTime = CACurrentMediaTime()
    }

    public func step(_ game: Game) {
        frame(game)
    }

    // MARK: - The loop

    /// Runs the game until the window closes or quit() is called. Returns the exit code for the process.
    public func run(_ game: Game) -> Int32 {
        autoreleasepool { game.start(self) }
        #if os(macOS)
        guard let window = window else { return runCapture(game) }

        // The view calls back once per display refresh; AppKit's own loop does the waiting.
        previousTime = CACurrentMediaTime()
        window.onFrame = { [unowned self] in self.frame(game) }
        window.onClose = { [unowned self] in self.quit() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.run()          // returns once quit() has stopped it

        game.shutdown(self)
        window.close()
        renderer.waitUntilIdle()            // the GPU may still be drawing the last frames
        return 0
        #else
        // Without a host there is no screen here: only capturing to a file makes sense.
        return runCapture(game)
        #endif
    }

    public func quit() {
        isRunning = false
        #if os(macOS)
        guard window != nil else { return }
        NSApplication.shared.stop(nil)
        // stop() only takes effect after the next event has been handled: send one now.
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApplication.shared.postEvent(event, atStart: true)
        }
        #endif
    }

    private func frame(_ game: Game) {
        guard isRunning, let window = surface else { return }
        if config.developerKeys { handleDeveloperKeys() }

        let now = CACurrentMediaTime()
        simulate(game, realDelta: now - previousTime)
        previousTime = now

        if let drawable = window.nextDrawable() {
            renderer.render(scene: scene, canvas: canvas, target: RenderTarget(texture: drawable.texture, drawable: drawable),
                            time: time.elapsed)
        }
        if let path = pendingScreenshot {
            let size = screenSize * window.contentScale
            writeImage(path, width: Int(size.x), height: Int(size.y))
            pendingScreenshot = nil
        }
        input.endFrame()
    }

    /// No window: a fixed number of frames at a fixed step, so the picture is the same every time.
    private func runCapture(_ game: Game) -> Int32 {
        var saved = false
        let pixelWidth = config.width * config.captureScale, pixelHeight = config.height * config.captureScale
        var frame = 0
        while frame < config.captureFrames && isRunning {
            autoreleasepool {
                simulate(game, realDelta: 1.0 / 60.0)
                if frame == config.captureFrames - 1 {
                    saved = writeImage(config.capturePath, width: pixelWidth, height: pixelHeight)
                } else {
                    _ = renderer.renderToImage(scene: scene, canvas: canvas, width: pixelWidth, height: pixelHeight, time: time.elapsed)
                }
                input.endFrame()
            }
            frame += 1
        }
        game.shutdown(self)
        renderer.waitUntilIdle()
        return saved ? 0 : 1
    }

    private func simulate(_ game: Game, realDelta: Double) {
        // Physics and the game's fixedUpdate advance in steps of constant length.
        let steps = time.beginFrame(realDelta)
        for _ in 0..<steps {
            game.fixedUpdate(self, dt: time.fixedDelta)
            runBehaviors(isFixedStep: true, dt: time.fixedDelta)
            if !isSimulationPaused { physics.step(scene, dt: time.fixedDelta) }
            scene.flushDestroyed()
        }
        // Show bodies where they are between the last two steps, for smooth motion at any frame rate.
        if !isSimulationPaused { physics.writeTransforms(scene, alpha: time.alpha) }

        game.update(self, dt: time.delta)
        runBehaviors(isFixedStep: false, dt: time.delta)
        scene.flushDestroyed()
        scene.updateTransforms()
        updateParticles(scene, dt: time.delta)

        canvas.begin(size: screenSize, pixelsPerPoint: surface?.contentScale ?? Float(config.captureScale))
        game.draw(self, canvas: canvas)
        if showsColliders { drawColliders() }
        if showsStatistics { drawStatistics() }
    }

    private func runBehaviors(isFixedStep: Bool, dt: Float) {
        // A behavior may create or destroy entities, even itself. So: first note who has
        // one, then call each function, looking the component up again every time.
        var entities: [Entity] = []
        scene.each(Behavior.self) { entity, _ in entities.append(entity) }
        for entity in entities {
            guard let behavior = scene[entity, Behavior.self] else { continue }
            if let function = isFixedStep ? behavior.fixedUpdate : behavior.update { function(self, entity, dt) }
        }
    }

    // MARK: - Conveniences

    /// The drawable area in points: what canvas coordinates and the mouse position are measured in.
    public var screenSize: Vec2 {
        surface?.sizeInPoints ?? Vec2(Float(config.width), Float(config.height))
    }

    /// How far the interface must stay from each edge of the screen to avoid the notch,
    /// the rounded corners and the home indicator: left, top, right, bottom, in points.
    /// All zero on a Mac.
    public var safeArea: Vec4 { surface?.safeArea ?? Vec4(0, 0, 0, 0) }

    /// The font Canvas.text draws with. Starts as the engine's own font.
    public func setFont(_ font: Font?) {
        self.font = font
        canvas.setFont(font?.metrics, atlas: font?.atlas)
    }

    /// The entity of the camera the renderer is using, if the scene has one.
    public func activeCamera() -> Entity? {
        let chosen = renderer.cameraOverride
        if scene.has(Camera.self, chosen) && scene.has(Transform.self, chosen) { return chosen }
        var found: Entity?
        scene.each(Camera.self, Transform.self) { entity, camera, _ in
            if found == nil && camera.isActive { found = entity }
        }
        return found
    }

    /// The ray from the camera through a point of the screen: what the mouse is pointing at.
    public func screenRay(_ screenPoint: Vec2) -> Ray? {
        guard let cameraEntity = activeCamera(), let camera = scene[cameraEntity, Camera.self],
              let transform = scene[cameraEntity, Transform.self] else { return nil }

        // From points to normalized device coordinates, then back through the camera:
        // the same math as drawing, in reverse.
        let size = screenSize
        let ndc = Vec2(screenPoint.x / size.x * 2 - 1, 1 - screenPoint.y / size.y * 2)
        // The view matrix is the inverse of the camera's world matrix, so the inverse of
        // (projection * view) is world * inverse(projection).
        let inverseViewProjection = transform.world * camera.projection(aspect: size.x / size.y).inverse
        let nearPoint = inverseViewProjection * Vec4(ndc.x, ndc.y, 0, 1)
        let farPoint = inverseViewProjection * Vec4(ndc.x, ndc.y, 1, 1)
        let origin = xyz(nearPoint) / nearPoint.w
        return Ray(origin: origin, direction: safeNormalize(xyz(farPoint) / farPoint.w - origin, fallback: transform.forward))
    }

    /// Plays a sound as if it came from a place in the world, as heard from the camera.
    @discardableResult
    public func playSoundAt(_ clip: AudioClip, position: Vec3, volume: Float = 1, pitch: Float = 1) -> SoundHandle {
        var listener = matrix_identity_float4x4
        if let cameraEntity = activeCamera(), let transform = scene[cameraEntity, Transform.self] { listener = transform.world }
        let gain = spatialize(listenerWorld: listener, position: position)
        if gain.volume <= 0.001 { return 0 }            // too far away to hear
        return audio.play(clip, options: PlayOptions(volume: volume * gain.volume, pitch: pitch, pan: gain.pan))
    }

    /// Saves the next frame to a PNG file.
    public func saveScreenshot(_ path: String) { pendingScreenshot = path }

    @discardableResult
    private func writeImage(_ path: String, width: Int, height: Int) -> Bool {
        let pixels = renderer.renderToImage(scene: scene, canvas: canvas, width: width, height: height, time: time.elapsed)
        // Core Graphics wraps the bytes as an image; Image I/O writes it as a PNG file.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard pixels.count == width * height * 4,
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else {
            logError("cannot write \(path)")
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            logError("cannot write \(path)")
            return false
        }
        logInfo("saved \(path) (\(width) x \(height))")
        return true
    }

    // MARK: - Developer tools

    private func handleDeveloperKeys() {
        if input.wasPressed(Key.f1) { showsStatistics.toggle() }
        if input.wasPressed(Key.f2) { showsColliders.toggle() }
        #if os(macOS)
        if input.wasPressed(Key.f3), let window = window { window.setFullscreen(!window.isFullscreen) }
        #endif
        if input.wasPressed(Key.f4) { saveScreenshot("screenshot.png") }
    }

    private func drawStatistics() {
        let stats = renderer.stats                      // of the previous frame
        let text = String(format: "%.0f fps   %.1f ms\n%ld draw calls   %ld triangles\n%ld objects drawn   %ld culled\n%ld lights   %ld entities",
                          Double(time.framesPerSecond), Double(time.unscaledDelta) * 1000, stats.drawCalls, stats.triangles,
                          stats.visibleObjects, stats.culledObjects, stats.lights, scene.entityCount)
        let size = canvas.measureText(text, size: 14)
        canvas.rect(Vec2(8, 8), size + Vec2(20, 16), Vec4(0, 0, 0, 0.6))
        canvas.text(text, Vec2(18, 16), size: 14, Vec4(1, 1, 1, 1))
    }

    private func drawColliders() {
        let lines = renderer.debug
        scene.each(Collider.self, Transform.self) { _, collider, transform in
            let color = collider.isTrigger ? Vec4(1, 0.85, 0.2, 1) : Vec4(0.3, 1, 0.4, 1)
            let center = transform.position + transform.rotation.act(collider.offset)
            switch collider.shape {
            case .sphere:
                lines.sphere(center: center, radius: collider.radius, color)
            case .box:
                lines.box(center: center, halfExtents: collider.halfExtents, rotation: transform.rotation, color)
            case .capsule:
                let axis = transform.rotation.act(Vec3(0, collider.halfHeight, 0))
                lines.sphere(center: center + axis, radius: collider.radius, color, segments: 16)
                lines.sphere(center: center - axis, radius: collider.radius, color, segments: 16)
                for side in [Vec3(1, 0, 0), Vec3(-1, 0, 0), Vec3(0, 0, 1), Vec3(0, 0, -1)] {
                    let offset = transform.rotation.act(side * collider.radius)
                    lines.line(center + axis + offset, center - axis + offset, color)
                }
            }
        }
    }
}
