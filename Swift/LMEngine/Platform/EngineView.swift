// EngineView.swift
// The iPhone's and iPad's side of the platform layer: a view controller that shows the
// game full screen and turns touches into the engine's Input.
//
// An iOS app does not own its main loop. So instead of calling engine.run(), the app
// creates this view controller and makes it the root of its window:
//
//     window.rootViewController = EngineViewController(game: MyGame())
//
// MetalKit's view then calls draw(in:) once per display refresh, and each call is one
// frame of the engine.

#if os(iOS)
import GameController
import MetalKit
import UIKit

@MainActor
public final class EngineViewController: UIViewController, MTKViewDelegate, Surface {
    public let engine: Engine
    private let game: Game
    private var metalView: MTKView?
    private var hasStarted = false
    private var primaryTouch: UITouch?          // the finger that also acts as the mouse, for the Gui

    public init(game: Game, config: EngineConfig = EngineConfig()) {
        self.game = game
        engine = Engine(config: config)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EngineViewController is created in code")
    }

    public override func loadView() {
        let view = MTKView(frame: UIScreen.main.bounds, device: engine.graphicsDevice.device)
        view.colorPixelFormat = .bgra8Unorm_srgb        // 8 bits per channel, sRGB-encoded: what the renderer's last pass expects
        view.depthStencilPixelFormat = .invalid         // the renderer brings its own depth textures
        view.framebufferOnly = true
        view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        view.isMultipleTouchEnabled = true              // two thumbs on two sticks
        view.delegate = self
        metalView = view
        self.view = view
        engine.attach(self)
    }

    // A game wants the whole screen, sideways, and no accidental swipes to the home screen.
    public override var prefersStatusBarHidden: Bool { true }
    public override var prefersHomeIndicatorAutoHidden: Bool { true }
    public override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    // MARK: - Surface

    public var sizeInPoints: Vec2 { Vec2(Float(view.bounds.width), Float(view.bounds.height)) }
    public var contentScale: Float { Float(view.contentScaleFactor) }
    public var safeArea: Vec4 {
        let insets = view.safeAreaInsets
        return Vec4(Float(insets.left), Float(insets.top), Float(insets.right), Float(insets.bottom))
    }
    public func nextDrawable() -> CAMetalDrawable? { metalView?.currentDrawable }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        if !hasStarted {
            // The first frame: by now the view has its real size, which a game may want in start().
            hasStarted = true
            engine.begin(game)
        }
        engine.input.handleGamepad(readGamepad())
        engine.step(game)
    }

    // MARK: - Touches

    private func report(_ touches: Set<UITouch>, _ phase: TouchPhase) {
        for touch in touches {
            let point = touch.location(in: view)
            let position = Vec2(Float(point.x), Float(point.y))        // UIKit already measures from the top left
            engine.input.handleTouch(id: ObjectIdentifier(touch).hashValue, position: position, phase: phase)

            // The first finger down doubles as the mouse, so that buttons and panels made
            // for a pointer work under a finger too.
            if phase == .began && primaryTouch == nil {
                primaryTouch = touch
                engine.input.handleMouseMove(position: position, delta: Vec2(0, 0))
                engine.input.handleMouseButton(.left, down: true)
            } else if touch === primaryTouch {
                let before = touch.previousLocation(in: view)
                engine.input.handleMouseMove(position: position, delta: position - Vec2(Float(before.x), Float(before.y)))
                if phase == .ended {
                    engine.input.handleMouseButton(.left, down: false)
                    primaryTouch = nil
                }
            }
        }
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .began) }
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .moved) }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .ended) }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .ended) }
}
#endif
