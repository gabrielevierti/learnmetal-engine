// Marble, a small game made with the LearnMetal Engine.
//
//   ./marble                       plays the game
//   ./marble --fullscreen
//   ./marble --demo                the autopilot plays
//   ./marble --capture shot.png    renders 90 frames without a window and saves the last one
//   ./marble --demo --capture shot.png --frames 3600
//                                  a whole unattended run; the exit code says whether the autopilot won
#include "MarbleGame.hpp"

int main(int argc, char** argv) {
    lm::EngineConfig defaults;
    defaults.title = "Marble";
    lm::Engine engine(lm::EngineConfig::fromArguments(argc, argv, defaults));
    MarbleGame game;
    int result = engine.run(game);
    if (result == 0 && game.isDemo && engine.window() == nullptr && !game.hasWon()) {
        lm::logError("the autopilot did not finish the course");
        return 1;
    }
    return result;
}
