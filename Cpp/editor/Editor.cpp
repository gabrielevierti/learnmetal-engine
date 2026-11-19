#include "Editor.hpp"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <sstream>

using namespace lm;

namespace {
const float kToolbarHeight = 64;
const float kLeftWidth = 250;
const float kRightWidth = 320;
const size_t kUndoLevels = 100;
}

// ---------------------------------------------------------------- start

void Editor::start(Engine& engine) {
    engine.isSimulationPaused = true;       // nothing falls while it is being placed
    std::error_code ignored;
    std::filesystem::create_directories(engine.assets().path("Scenes"), ignored);
    refreshLists(engine);
    if (sceneName.empty() || !openScene(engine, sceneName)) newScene(engine);
}

void Editor::refreshLists(Engine& engine) {
    meshNames_ = {"cube", "sphere", "plane", "cylinder"};
    for (const std::string& file : engine.assets().listFiles("Models", ".obj")) meshNames_.push_back(file);
    textureNames_ = engine.assets().listFiles("Textures", ".png");
    for (const std::string& file : engine.assets().listFiles("Textures", ".jpg")) textureNames_.push_back(file);
    sceneNames_.clear();
    for (const std::string& file : engine.assets().listFiles("Scenes", ".scene")) {
        sceneNames_.push_back(file.substr(7, file.size() - 7 - 6));        // "Scenes/demo.scene" -> "demo"
    }
}

void Editor::say(const std::string& message) {
    status_ = message;
    statusUntil_ = now_ + 4;
}

int Editor::indexOf(Entity entity) const {
    for (size_t i = 0; i < entities_.size(); i++) {
        if (entities_[i] == entity) return int(i);
    }
    return -1;
}

std::shared_ptr<Material> Editor::defaultMaterial() {
    if (materials_.empty()) materials_.push_back(NamedMaterial{"Default", std::make_shared<Material>()});
    selectedMaterial_ = std::clamp(selectedMaterial_, 0, int(materials_.size()) - 1);
    return materials_[size_t(selectedMaterial_)].material;
}

void Editor::createCamera(Engine& engine) {
    camera_ = engine.scene.create("Editor camera");
    Transform transform;
    transform.position = cameraPosition_;
    transform.rotation = eulerAngles(cameraPitch_, cameraYaw_);
    engine.scene.add(camera_, transform);
    engine.scene.add(camera_, Camera{});
    engine.scene.add(camera_, EditorOnly{});
    engine.renderer().cameraOverride = isPlaying_ ? Entity{} : camera_;
}

// ---------------------------------------------------------------- files

/// Replaces the scene with the one described by `text`, keeping the selection if it can.
void Editor::restore(Engine& engine, const std::string& text) {
    int selectedIndex = indexOf(selected_);
    engine.scene.clear();
    engine.physics.reset();
    createCamera(engine);
    readScene(text, engine.scene, materials_, engine.renderer().settings, sceneAssets(engine.assets()));
    defaultMaterial();

    entities_.clear();
    engine.scene.each<Transform>([&](Entity entity, Transform&) {
        if (!engine.scene.has<EditorOnly>(entity)) entities_.push_back(entity);
    });
    selected_ = selectedIndex >= 0 && selectedIndex < int(entities_.size()) ? entities_[size_t(selectedIndex)] : Entity{};
    engine.scene.updateTransforms();
}

void Editor::newScene(Engine& engine) {
    sceneName = "untitled";
    engine.scene.clear();
    engine.physics.reset();
    engine.renderer().settings = RenderSettings{};
    materials_.clear();
    selectedMaterial_ = 0;
    createCamera(engine);

    // A floor, something on it, a sun and a camera: enough to see the lighting.
    auto ground = std::make_shared<Material>();
    ground->baseColor = Vec4{0.55f, 0.57f, 0.6f, 1};
    ground->roughness = 0.9f;
    materials_ = {{"Default", std::make_shared<Material>()}, {"Ground", ground}};

    Entity sun = engine.scene.create("Sun");
    Transform sunTransform;
    sunTransform.position = Vec3{0, 6, 0};
    sunTransform.rotation = lookRotation(Vec3{0.5f, -0.8f, -0.35f});
    engine.scene.add(sun, sunTransform);
    Light light;
    light.type = LightType::Directional;
    light.color = Vec3{1.0f, 0.95f, 0.85f};
    light.intensity = 3.5f;
    light.castsShadows = true;
    engine.scene.add(sun, light);

    Entity floor = engine.scene.create("Floor");
    Transform floorTransform;
    floorTransform.scale = Vec3{20, 1, 20};
    engine.scene.add(floor, floorTransform);
    engine.scene.add(floor, MeshRenderer{engine.assets().plane(), ground});
    Collider floorCollider = Collider::box(Vec3{10, 0.5f, 10});
    floorCollider.offset = Vec3{0, -0.5f, 0};
    engine.scene.add(floor, floorCollider);

    Entity cube = engine.scene.create("Cube");
    Transform cubeTransform;
    cubeTransform.position = Vec3{0, 0.5f, 0};
    engine.scene.add(cube, cubeTransform);
    engine.scene.add(cube, MeshRenderer{engine.assets().cube(), materials_[0].material});
    engine.scene.add(cube, Collider::box(Vec3{0.5f, 0.5f, 0.5f}));

    Entity camera = engine.scene.create("Camera");
    Transform cameraTransform;
    cameraTransform.position = Vec3{0, 2, 7};
    cameraTransform.rotation = lookRotation(Vec3{0, -0.2f, -1});
    engine.scene.add(camera, cameraTransform);
    engine.scene.add(camera, Camera{});

    selected_ = cube;
    engine.scene.updateTransforms();
    current_ = writeScene(engine.scene, materials_, engine.renderer().settings);
    undo_.clear();
    redo_.clear();
    say("New scene");
}

bool Editor::openScene(Engine& engine, const std::string& name) {
    std::ifstream file(engine.assets().path("Scenes/" + name + ".scene"), std::ios::binary);
    std::ostringstream text;
    if (file) text << file.rdbuf();
    // Read it into a scratch scene first: a file that cannot be read must not cost the open scene.
    Scene probe;
    std::vector<NamedMaterial> probeMaterials;
    RenderSettings probeSettings;
    if (!file || !readScene(text.str(), probe, probeMaterials, probeSettings, SceneAssets{})) {
        say("Cannot open " + name);
        return false;
    }
    sceneName = name;
    selected_ = Entity{};
    entities_.clear();
    engine.renderer().settings = RenderSettings{};
    restore(engine, text.str());
    current_ = writeScene(engine.scene, materials_, engine.renderer().settings);
    undo_.clear();
    redo_.clear();
    say("Opened " + name);
    return true;
}

bool Editor::saveScene(Engine& engine) {
    if (isPlaying_) return false;
    std::string path = engine.assets().path("Scenes/" + sceneName + ".scene");
    bool saved = saveSceneFile(path, engine.scene, materials_, engine.renderer().settings);
    say(saved ? "Saved Scenes/" + sceneName + ".scene" : "Could not save " + sceneName);
    refreshLists(engine);
    return saved;
}

// ---------------------------------------------------------------- editing

Vec3 Editor::spawnPoint(Engine& engine) const {
    // Where the camera looks at the ground; or a few meters ahead if it looks at the sky.
    Vec3 forward = rotate(eulerAngles(cameraPitch_, cameraYaw_), Vec3{0, 0, -1});
    float distance = forward.y < -0.05f ? std::min(-cameraPosition_.y / forward.y, 30.0f) : 8.0f;
    Vec3 point = cameraPosition_ + forward * distance;
    return Vec3{std::round(point.x * 2) / 2, 0, std::round(point.z * 2) / 2};     // on a half-meter grid
}

Entity Editor::addEntity(Engine& engine, Shape shape) {
    static const char* const names[] = {"Empty", "Cube", "Sphere", "Plane", "Cylinder", "Light", "Camera"};
    Scene& scene = engine.scene;
    Entity entity = scene.create(names[int(shape)]);
    Transform transform;
    transform.position = spawnPoint(engine);
    std::shared_ptr<Material> material = defaultMaterial();
    switch (shape) {
        case Shape::Empty:
            break;
        case Shape::Cube:
            transform.position.y = 0.5f;
            scene.add(entity, MeshRenderer{engine.assets().cube(), material});
            scene.add(entity, Collider::box(Vec3{0.5f, 0.5f, 0.5f}));
            break;
        case Shape::Sphere:
            transform.position.y = 0.5f;
            scene.add(entity, MeshRenderer{engine.assets().sphere(), material});
            scene.add(entity, Collider::sphere(0.5f));
            break;
        case Shape::Plane:
            transform.position.y = 0.01f;
            scene.add(entity, MeshRenderer{engine.assets().plane(), material});
            break;
        case Shape::Cylinder:
            transform.position.y = 0.5f;
            scene.add(entity, MeshRenderer{engine.assets().cylinder(), material});
            scene.add(entity, Collider::capsule(0.5f, 0.0f));
            break;
        case Shape::PointLight: {
            transform.position.y = 2.0f;
            Light light;
            light.intensity = 8;
            light.range = 8;
            scene.add(entity, light);
            break;
        }
        case Shape::Camera: {
            transform.position = cameraPosition_;
            transform.rotation = eulerAngles(cameraPitch_, cameraYaw_);     // looks where the editor looks now
            Camera camera;
            camera.isActive = scene.count<Camera>() <= 1;                   // the first one becomes the game's camera
            scene.add(entity, camera);
            break;
        }
    }
    scene.add(entity, transform);
    selected_ = entity;
    touched_ = true;
    return entity;
}

Entity Editor::addModel(Engine& engine, const std::string& meshName) {
    std::shared_ptr<Mesh> mesh = engine.assets().mesh(meshName);
    if (!mesh) {
        say("Cannot load " + meshName);
        return Entity{};
    }
    // Name the entity after the file: "Models/gem.obj" -> "gem".
    std::string name = std::filesystem::path(meshName).stem().string();
    Entity entity = engine.scene.create(name);
    Transform transform;
    transform.position = spawnPoint(engine);
    transform.position.y = -mesh->bounds().min.y;          // standing on the ground
    engine.scene.add(entity, transform);
    engine.scene.add(entity, MeshRenderer{mesh, defaultMaterial()});
    selected_ = entity;
    touched_ = true;
    return entity;
}

void Editor::duplicateSelected(Engine& engine) {
    Scene& scene = engine.scene;
    if (!scene.isAlive(selected_)) return;
    const Name* name = scene.get<Name>(selected_);
    Entity copy = scene.create(name ? name->value : std::string());
    Transform transform = *scene.get<Transform>(selected_);
    transform.position += Vec3{1, 0, 0};                    // beside the original, so that both can be seen
    scene.add(copy, transform);
    // Components are plain values: copying an entity is copying each one.
    if (const MeshRenderer* c = scene.get<MeshRenderer>(selected_)) scene.add(copy, *c);
    if (const Light* c = scene.get<Light>(selected_)) scene.add(copy, *c);
    if (const Camera* c = scene.get<Camera>(selected_)) {
        Camera camera = *c;
        camera.isActive = false;
        scene.add(copy, camera);
    }
    if (const Collider* c = scene.get<Collider>(selected_)) scene.add(copy, *c);
    if (const RigidBody* c = scene.get<RigidBody>(selected_)) scene.add(copy, *c);
    if (const ParticleEmitter* c = scene.get<ParticleEmitter>(selected_)) {
        ParticleEmitter emitter = *c;
        emitter.particles.clear();
        scene.add(copy, emitter);
    }
    selected_ = copy;
    touched_ = true;
}

void Editor::deleteSelected(Engine& engine) {
    Scene& scene = engine.scene;
    if (!scene.isAlive(selected_)) return;
    // Children of the deleted entity stay, and become independent.
    Entity gone = selected_;
    scene.each<Transform>([&](Entity, Transform& transform) {
        if (transform.parent == gone) transform.parent = Entity{};
    });
    scene.destroy(gone);
    selected_ = Entity{};
    touched_ = true;
}

// ---------------------------------------------------------------- undo and play

/// Called at the end of every frame. When an edit has just been finished, the scene as
/// it was before becomes the next thing Undo goes back to.
void Editor::recordUndo(Engine& engine) {
    if (!touched_ || isPlaying_ || gui_.isBusy() || dragAxis_ >= 0) return;
    touched_ = false;
    std::string state = writeScene(engine.scene, materials_, engine.renderer().settings);
    if (state == current_) return;
    undo_.push_back(std::move(current_));
    if (undo_.size() > kUndoLevels) undo_.erase(undo_.begin());
    redo_.clear();
    current_ = std::move(state);
}

void Editor::undo(Engine& engine) {
    if (undo_.empty() || isPlaying_) return;
    redo_.push_back(std::move(current_));
    current_ = std::move(undo_.back());
    undo_.pop_back();
    restore(engine, current_);
    say("Undo");
}

void Editor::redo(Engine& engine) {
    if (redo_.empty() || isPlaying_) return;
    undo_.push_back(std::move(current_));
    current_ = std::move(redo_.back());
    redo_.pop_back();
    restore(engine, current_);
    say("Redo");
}

/// Play runs the scene: physics starts and the scene's own camera takes over. Stop puts
/// everything back exactly as it was, from the text the scene was saved to in memory.
void Editor::setPlaying(Engine& engine, bool playing) {
    if (playing == isPlaying_) return;
    if (playing) {
        beforePlay_ = writeScene(engine.scene, materials_, engine.renderer().settings);
        isPlaying_ = true;
        engine.physics.reset();
        // Without a camera of its own the scene is watched through the editor's.
        bool hasCamera = false;
        engine.scene.each<Camera>([&](Entity entity, Camera& camera) {
            hasCamera = hasCamera || (entity != camera_ && camera.isActive);
        });
        engine.renderer().cameraOverride = hasCamera ? Entity{} : camera_;
        if (Camera* own = engine.scene.get<Camera>(camera_)) own->isActive = !hasCamera;
        engine.isSimulationPaused = false;
        say("Playing. Press F5 or Stop to go back to editing");
    } else {
        isPlaying_ = false;
        engine.isSimulationPaused = true;
        restore(engine, beforePlay_);
        say("Stopped");
    }
}

// ---------------------------------------------------------------- the frame

void Editor::handleShortcuts(Engine& engine) {
    const Input& input = engine.input;
    if (gui_.wantsKeyboard()) return;
    if (input.wasPressed(Key::F5)) setPlaying(engine, !isPlaying_);
    if (isPlaying_) {
        if (input.wasPressed(Key::Escape)) setPlaying(engine, false);
        return;
    }
    bool control = input.isDown(Key::LeftControl) || input.isDown(Key::RightControl);
    bool looking = input.isDown(MouseButton::Right);        // W, E and R then move the camera instead
    if (control) {
        if (input.wasPressed(Key::S)) saveScene(engine);
        if (input.wasPressed(Key::Z)) undo(engine);
        if (input.wasPressed(Key::Y)) redo(engine);
        if (input.wasPressed(Key::D)) duplicateSelected(engine);
    } else if (!looking) {
        if (input.wasPressed(Key::W)) tool = Tool::Move;
        if (input.wasPressed(Key::E)) tool = Tool::Rotate;
        if (input.wasPressed(Key::R)) tool = Tool::Scale;
        if (input.wasPressed(Key::Backspace)) deleteSelected(engine);
        if (input.wasPressed(Key::Escape)) selected_ = Entity{};
        if (input.wasPressed(Key::F)) {
            // Frame the selection: step back from it along the view direction.
            if (const Transform* transform = engine.scene.get<Transform>(selected_)) {
                Vec3 forward = rotate(eulerAngles(cameraPitch_, cameraYaw_), Vec3{0, 0, -1});
                float size = std::max({transform->scale.x, transform->scale.y, transform->scale.z, 1.0f});
                cameraPosition_ = transform->worldPosition() - forward * (size * 4.0f);
            }
        }
    }
}

void Editor::updateCamera(Engine& engine, float dt) {
    const Input& input = engine.input;
    // Hold the right button to look around and fly, as in most 3D editors.
    if (input.isDown(MouseButton::Right) && !gui_.wantsMouse()) {
        cameraYaw_ -= input.mouseDelta().x * 0.005f;
        cameraPitch_ = std::clamp(cameraPitch_ - input.mouseDelta().y * 0.005f, -1.5f, 1.5f);
        Quat rotation = eulerAngles(cameraPitch_, cameraYaw_);
        Vec3 move{0, 0, 0};
        if (input.isDown(Key::W)) move += rotate(rotation, Vec3{0, 0, -1});
        if (input.isDown(Key::S)) move += rotate(rotation, Vec3{0, 0, 1});
        if (input.isDown(Key::A)) move += rotate(rotation, Vec3{-1, 0, 0});
        if (input.isDown(Key::D)) move += rotate(rotation, Vec3{1, 0, 0});
        if (input.isDown(Key::E)) move += Vec3{0, 1, 0};
        if (input.isDown(Key::Q)) move += Vec3{0, -1, 0};
        float speed = input.isDown(Key::LeftShift) ? 18.0f : 6.0f;
        cameraPosition_ += move * (speed * dt);
    }
    if (!gui_.wantsMouse() && input.scrollDelta() != 0) {
        cameraPosition_ += rotate(eulerAngles(cameraPitch_, cameraYaw_), Vec3{0, 0, -1}) * input.scrollDelta();
    }
    if (Transform* transform = engine.scene.get<Transform>(camera_)) {
        transform->position = cameraPosition_;
        transform->rotation = eulerAngles(cameraPitch_, cameraYaw_);
    }
}

void Editor::draw(Engine& engine, Canvas& canvas) {
    now_ = engine.time.elapsed;
    Vec2 screen = canvas.size();

    entities_.clear();
    engine.scene.each<Transform>([&](Entity entity, Transform&) {
        if (!engine.scene.has<EditorOnly>(entity)) entities_.push_back(entity);
    });
    if (!engine.scene.isAlive(selected_)) selected_ = Entity{};

    gui_.begin(canvas, engine.input);
    handleShortcuts(engine);

    if (isPlaying_) {
        // While playing the editor steps aside: one small panel to stop.
        gui_.beginPanel("Playing", Vec2{screen.x * 0.5f - 90, 8}, Vec2{180, 64});
        if (gui_.button("Stop (F5)")) setPlaying(engine, false);
        gui_.endPanel();
        gui_.end();
        return;
    }

    updateCamera(engine, engine.time.unscaledDelta);
    drawViewport(engine, canvas);           // under the panels

    drawToolbar(engine, screen);
    float leftHeight = screen.y - kToolbarHeight;
    float sceneHeight = std::floor(leftHeight * 0.58f);
    drawScenePanel(engine, Vec2{0, kToolbarHeight}, Vec2{kLeftWidth, sceneHeight});
    drawAssetsPanel(engine, Vec2{0, kToolbarHeight + sceneHeight}, Vec2{kLeftWidth, leftHeight - sceneHeight});

    static const char* const titles[] = {"Inspector", "Materials", "Scene settings"};
    gui_.beginPanel(titles[rightTab_], Vec2{screen.x - kRightWidth, kToolbarHeight}, Vec2{kRightWidth, leftHeight});
    gui_.tabs({"Inspector", "Materials", "Scene"}, rightTab_);
    gui_.separator();
    if (rightTab_ == 0) drawInspector(engine);
    else if (rightTab_ == 1) drawMaterials(engine);
    else drawSettings(engine);
    gui_.endPanel();

    gui_.end();
    if (gui_.changed()) touched_ = true;
    recordUndo(engine);
    // What was created or moved in this frame is drawn in this frame: bring the world
    // matrices up to date again.
    engine.scene.updateTransforms();
}
