// The LearnMetal Editor: builds and edits the scenes in Assets/Scenes.
//
//   swift run Editor            starts with a new scene
//   swift run Editor demo       opens Assets/Scenes/demo.scene
//
// Right mouse button + W A S D   look around and fly      W / E / R   move, rotate, scale
// Left click                     select                   F           look at the selection
// Ctrl+S save   Ctrl+Z undo   Ctrl+Y redo   Ctrl+D duplicate   Backspace delete   F5 play / stop

import Foundation
import LMEngine

var defaults = EngineConfig()
defaults.title = "LearnMetal Editor"
defaults.width = 1440
defaults.height = 860
let config = EngineConfig.fromArguments(CommandLine.arguments, defaults: defaults)
let engine = Engine(config: config)
let editor = Editor()
for argument in config.arguments where !argument.hasPrefix("-") {
    editor.sceneName = argument
}
exit(engine.run(editor))
