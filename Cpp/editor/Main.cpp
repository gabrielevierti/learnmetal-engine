// The LearnMetal Editor: builds and edits the scenes in Assets/Scenes.
//
//   ./editor            starts with a new scene
//   ./editor demo       opens Assets/Scenes/demo.scene
//
// Right mouse button + W A S D   look around and fly      W / E / R   move, rotate, scale
// Left click                     select                   F           look at the selection
// Ctrl+S save   Ctrl+Z undo   Ctrl+Y redo   Ctrl+D duplicate   Backspace delete   F5 play / stop
#include "Editor.hpp"

int main(int argc, char** argv) {
    lm::EngineConfig defaults;
    defaults.title = "LearnMetal Editor";
    defaults.width = 1440;
    defaults.height = 860;
    lm::EngineConfig config = lm::EngineConfig::fromArguments(argc, argv, defaults);
    lm::Engine engine(config);
    Editor editor;
    for (const std::string& argument : config.arguments) {
        if (!argument.empty() && argument[0] != '-') editor.sceneName = argument;
    }
    return engine.run(editor);
}
