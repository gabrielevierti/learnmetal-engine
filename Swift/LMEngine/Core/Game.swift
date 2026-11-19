// Game.swift
// What a game provides: a handful of functions the engine calls at the right moments.
// Implement the ones you need; the others do nothing.
//
//     final class MyGame: Game {
//         func start(_ engine: Engine) { /* build the scene */ }
//         func update(_ engine: Engine, dt: Float) { /* every frame */ }
//     }
//
//     let engine = Engine(config: EngineConfig.fromArguments(CommandLine.arguments))
//     exit(engine.run(MyGame()))

@MainActor
public protocol Game: AnyObject {
    /// Once, when everything is ready: load assets and create entities here.
    func start(_ engine: Engine)

    /// At a fixed rate (60 times per second), just before each physics step. Apply forces
    /// and change velocities here. A frame may run this zero, one or several times, so do
    /// not look for key presses here: read input in update() and remember what you need.
    func fixedUpdate(_ engine: Engine, dt: Float)

    /// Once per frame, before drawing. `dt` is the duration of the frame in seconds.
    func update(_ engine: Engine, dt: Float)

    /// Once per frame, after update(): draw the interface, in points from the top left.
    func draw(_ engine: Engine, canvas: Canvas)

    /// Once, when the game is closing.
    func shutdown(_ engine: Engine)
}

public extension Game {
    func start(_ engine: Engine) {}
    func fixedUpdate(_ engine: Engine, dt: Float) {}
    func update(_ engine: Engine, dt: Float) {}
    func draw(_ engine: Engine, canvas: Canvas) {}
    func shutdown(_ engine: Engine) {}
}
