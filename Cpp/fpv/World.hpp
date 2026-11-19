// World.hpp
// The place to fly: a mowed field ringed by hills and trees, the gates of the course,
// an unfinished concrete building to thread, and the pilot's tent by the start.
// Everything is made in code from boxes, cylinders, cones and noise: no model files.
#pragma once

#include "FlightModel.hpp"
#include "LMEngine.hpp"
#include "Track.hpp"

#include <memory>
#include <vector>

namespace fpv {

/// The height of the ground under a point. The field is flat, at zero; hills rise around it.
float groundHeight(float x, float z);
/// Which way the ground faces there.
lm::Vec3 groundNormal(float x, float z);

struct World {
    std::vector<std::vector<lm::Entity>> gateParts;         // the bars that make up each gate
    std::shared_ptr<lm::Material> gateMaterial, nextGateMaterial;
    lm::Vec3 pilot{14.0f, 1.6f, 4.0f};                      // the radio link is measured from the pilot's hands
    lm::Vec3 start{0, 0, 0};                                // the launch mat
};

World buildWorld(lm::Engine& engine);

/// The drone as something to look at: frame, motors, battery, camera, spinning propellers.
/// It is rebuilt when the pilot chooses another airframe.
struct DroneModel {
    lm::Entity root;
    std::vector<lm::Entity> parts;
    lm::Entity blades[4], discs[4];
    float bladeAngle[4] = {0, 0, 0, 0};

    static DroneModel build(lm::Engine& engine, const Airframe& airframe);
    /// Moves the model to where the drone is and turns the propellers.
    void update(lm::Engine& engine, const Drone& drone, float dt);
    void destroy(lm::Engine& engine);
};

}  // namespace fpv
