// Marble, a small game made with the LearnMetal Engine.
//
//   swift run Marble                       plays the game
//   swift run Marble --fullscreen
//   swift run Marble --demo                the autopilot plays
//   swift run Marble --capture shot.png    renders 90 frames without a window and saves the last one
//   swift run Marble --demo --capture shot.png --frames 3600
//                                          a whole unattended run; the exit code says whether the autopilot won

import Foundation
import LMEngine

// The engine lives on the main actor, and so does everything a program does with it.
let result: Int32 = MainActor.assumeIsolated {
    var defaults = EngineConfig()
    defaults.title = "Marble"
    let engine = Engine(config: EngineConfig.fromArguments(CommandLine.arguments, defaults: defaults))
    let game = MarbleGame()
    let result = engine.run(game)
    if result == 0 && game.isDemo && engine.window == nil && !game.hasWon {
        logError("the autopilot did not finish the course")
        return 1
    }
    return result
}
exit(result)
