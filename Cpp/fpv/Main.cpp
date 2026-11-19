// FPV, a drone racing game made with the LearnMetal Engine.
//
//   fpv                    the menu
//   fpv --race             straight into a race        --free   straight into free flight
//   fpv --whoop            the small drone             --acro   rates instead of self-leveling
//   fpv --chase            seen from behind            --sticks draw the stick positions
#include "FPVGame.hpp"

int main(int argc, char** argv) {
    lm::EngineConfig defaults;
    defaults.title = "FPV";
    lm::Engine engine(lm::EngineConfig::fromArguments(argc, argv, defaults));
    FPVGame game;
    return engine.run(game);
}
