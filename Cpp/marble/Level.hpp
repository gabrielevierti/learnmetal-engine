// Level.hpp
// The level: what is in it and where. Also the game's own components, which shows that
// a component can be any plain struct: the engine does not need to know about them.
#pragma once

#include "LMEngine.hpp"

/// Something to collect. The entity also carries a mesh, a light and a trigger collider.
struct Gem {
    lm::Vec3 home{0, 0, 0};         // the gem bobs up and down around this point
    float phase = 0;                // so that the gems do not all move in step
    lm::Vec3 color{1, 1, 1};
};

/// A platform that glides back and forth between two points.
struct MovingPlatform {
    lm::Vec3 from{0, 0, 0};
    lm::Vec3 to{0, 0, 0};
    float period = 6;               // seconds for a round trip
};

/// Destroys its entity when the time runs out: for one-shot effects.
struct Lifetime {
    float seconds = 1;
};

struct Level {
    lm::Entity marble;
    lm::Entity camera;
    lm::Entity goal;
    lm::Entity ferry;               // the moving platform
    lm::Vec3 start{0, 1, 0};        // where the marble begins
    int gemCount = 0;
    std::shared_ptr<lm::Material> goalMaterial;     // changes color when the goal opens

    static constexpr float kMarbleRadius = 0.5f;
};

/// Fills the scene (which must be empty) and says where the important things are.
Level buildLevel(lm::Engine& engine);
