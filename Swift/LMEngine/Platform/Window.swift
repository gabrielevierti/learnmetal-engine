// Window.swift
// The window, and the events that arrive through it.
//
// AppKit provides the window and the events; MetalKit's MTKView provides the drawable
// textures and calls us once per display refresh; the GameController framework reads
// gamepads (see Gamepads.swift). This file is the Mac's side of the platform layer;
// EngineView.swift is the iPhone's.
//
// AppKit must be used from the main thread. `@MainActor` tells the compiler so: it
// then checks that nothing here is reached from anywhere else.

#if os(macOS)
import AppKit
import Carbon.HIToolbox
import GameController
import MetalKit

@MainActor
public final class Window: NSObject, MTKViewDelegate, NSWindowDelegate, Surface {
    /// The pixel format of the drawable: 8 bits per channel, sRGB-encoded.
    public static let pixelFormat = MTLPixelFormat.bgra8Unorm_srgb

    private let window: NSWindow
    private let view: MTKView
    private let input: Input
    private var eventMonitor: Any?
    private var isCursorCaptured = false

    /// Called once per display refresh, when it is time to simulate and draw a frame.
    var onFrame: (() -> Void)?
    /// Called when the window is closed or "Quit" is chosen.
    var onClose: (() -> Void)?

    public init(title: String, width: Int, height: Int, fullscreen: Bool, device: MTLDevice, input: Input) {
        self.input = input
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        view = MTKView(frame: frame, device: device)
        super.init()

        view.colorPixelFormat = Window.pixelFormat
        view.depthStencilPixelFormat = .invalid         // the renderer brings its own depth textures
        view.framebufferOnly = true                     // drawables are only rendered to, never read
        view.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        view.delegate = self

        window.title = title
        window.contentView = view
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)

        // A minimal menu, so that Command-Q works.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit \(title)", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApplication.shared.mainMenu = mainMenu

        installEventMonitor()
        if fullscreen { window.toggleFullScreen(nil) }
    }

    /// Closes the window and stops listening for events. The engine calls this when the game ends.
    func close() {
        onFrame = nil
        onClose = nil
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        eventMonitor = nil
        setCursorCaptured(false)
        window.close()
    }

    // MARK: - What the engine asks

    /// The next texture to draw into. It reaches the screen when the frame presents it.
    /// May be nil while the window is hidden or being resized: skip the frame.
    public func nextDrawable() -> CAMetalDrawable? { view.currentDrawable }

    public var sizeInPoints: Vec2 { Vec2(Float(view.bounds.width), Float(view.bounds.height)) }

    /// Pixels per point: 2 on a Retina display.
    public var contentScale: Float { Float(window.backingScaleFactor) }

    public var safeArea: Vec4 { Vec4(0, 0, 0, 0) }

    /// Waits for the display's refresh before showing each frame. On by default.
    public func setVSync(_ enabled: Bool) {
        (view.layer as? CAMetalLayer)?.displaySyncEnabled = enabled
    }

    public var isFullscreen: Bool { window.styleMask.contains(.fullScreen) }

    public func setFullscreen(_ fullscreen: Bool) {
        if fullscreen != isFullscreen { window.toggleFullScreen(nil) }
    }

    /// Hides the pointer and lets it move without limits: for first-person cameras.
    public func setCursorCaptured(_ captured: Bool) {
        if captured == isCursorCaptured { return }
        isCursorCaptured = captured
        CGAssociateMouseAndMouseCursorPosition(captured ? 0 : 1)
        if captured { NSCursor.hide() } else { NSCursor.unhide() }
    }

    public func setTitle(_ title: String) { window.title = title }

    public func requestClose() { window.close() }

    // MARK: - MTKViewDelegate, NSWindowDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        input.handleGamepad(readGamepad())
        onFrame?()
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    @objc private func quitFromMenu() {
        window.close()
    }

    // MARK: - Input

    private func installEventMonitor() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                           .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
                                           .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self = self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Reports the event to the engine's Input. Returns true if the event should go no further.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown, .keyUp:
            if event.modifierFlags.contains(.command) { return false }     // menu shortcuts stay with the system
            if !event.isARepeat { input.handleKey(Window.key(for: event.keyCode), down: event.type == .keyDown) }
            if event.type == .keyDown, let characters = event.characters { input.handleText(characters) }
            return true                                                     // swallowed, so the system does not beep
        case .flagsChanged:
            // Shift, Control and Option do not send key-down events: they change the flags.
            let key = Window.key(for: event.keyCode)
            let flags = event.modifierFlags
            switch key {
            case .leftShift, .rightShift: input.handleKey(key, down: flags.contains(.shift))
            case .leftControl, .rightControl: input.handleKey(key, down: flags.contains(.control))
            case .leftAlt, .rightAlt: input.handleKey(key, down: flags.contains(.option))
            default: break
            }
        case .leftMouseDown, .leftMouseUp:
            input.handleMouseButton(.left, down: event.type == .leftMouseDown)
        case .rightMouseDown, .rightMouseUp:
            input.handleMouseButton(.right, down: event.type == .rightMouseDown)
        case .otherMouseDown, .otherMouseUp:
            input.handleMouseButton(.middle, down: event.type == .otherMouseDown)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // AppKit measures from the bottom left; the engine, like most 2D systems, from the top left.
            let point = view.convert(event.locationInWindow, from: nil)
            let position = Vec2(Float(point.x), Float(view.bounds.height - point.y))
            input.handleMouseMove(position: position, delta: Vec2(Float(event.deltaX), Float(event.deltaY)))
        case .scrollWheel:
            // Trackpads report pixels, mouse wheels report lines: bring both to "notches".
            let amount = Float(event.scrollingDeltaY)
            input.handleScroll(event.hasPreciseScrollingDeltas ? amount / 10 : amount)
        default:
            break
        }
        return false
    }

    private static func key(for code: UInt16) -> Key {
        switch Int(code) {
        case kVK_ANSI_A: return .a
        case kVK_ANSI_B: return .b
        case kVK_ANSI_C: return .c
        case kVK_ANSI_D: return .d
        case kVK_ANSI_E: return .e
        case kVK_ANSI_F: return .f
        case kVK_ANSI_G: return .g
        case kVK_ANSI_H: return .h
        case kVK_ANSI_I: return .i
        case kVK_ANSI_J: return .j
        case kVK_ANSI_K: return .k
        case kVK_ANSI_L: return .l
        case kVK_ANSI_M: return .m
        case kVK_ANSI_N: return .n
        case kVK_ANSI_O: return .o
        case kVK_ANSI_P: return .p
        case kVK_ANSI_Q: return .q
        case kVK_ANSI_R: return .r
        case kVK_ANSI_S: return .s
        case kVK_ANSI_T: return .t
        case kVK_ANSI_U: return .u
        case kVK_ANSI_V: return .v
        case kVK_ANSI_W: return .w
        case kVK_ANSI_X: return .x
        case kVK_ANSI_Y: return .y
        case kVK_ANSI_Z: return .z
        case kVK_ANSI_0: return .num0
        case kVK_ANSI_1: return .num1
        case kVK_ANSI_2: return .num2
        case kVK_ANSI_3: return .num3
        case kVK_ANSI_4: return .num4
        case kVK_ANSI_5: return .num5
        case kVK_ANSI_6: return .num6
        case kVK_ANSI_7: return .num7
        case kVK_ANSI_8: return .num8
        case kVK_ANSI_9: return .num9
        case kVK_Space: return .space
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Escape: return .escape
        case kVK_Tab: return .tab
        case kVK_Delete: return .backspace
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_Shift: return .leftShift
        case kVK_RightShift: return .rightShift
        case kVK_Control: return .leftControl
        case kVK_RightControl: return .rightControl
        case kVK_Option: return .leftAlt
        case kVK_RightOption: return .rightAlt
        case kVK_F1: return .f1
        case kVK_F2: return .f2
        case kVK_F3: return .f3
        case kVK_F4: return .f4
        case kVK_F5: return .f5
        case kVK_F6: return .f6
        case kVK_F7: return .f7
        case kVK_F8: return .f8
        case kVK_F9: return .f9
        case kVK_F10: return .f10
        case kVK_F11: return .f11
        case kVK_F12: return .f12
        default: return .unknown
        }
    }
}
#endif
