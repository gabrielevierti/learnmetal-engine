// Sounds.hpp
// The game's sound effects. None of them is a file: each is computed when the game
// starts from a few numbers (a waveform, a pitch that may slide, a duration).
#pragma once

#include "LMEngine.hpp"

struct Sounds {
    std::shared_ptr<lm::AudioClip> collect;     // a gem was picked up
    std::shared_ptr<lm::AudioClip> jump;
    std::shared_ptr<lm::AudioClip> land;        // the marble hit something
    std::shared_ptr<lm::AudioClip> fall;        // the marble fell off the level
    std::shared_ptr<lm::AudioClip> win;
    std::shared_ptr<lm::AudioClip> roll;        // loops while the marble rolls

    static Sounds make();
};
