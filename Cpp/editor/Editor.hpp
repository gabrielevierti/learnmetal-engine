// Editor.hpp
// The scene editor of the LearnMetal Engine.
//
// It is an ordinary program made with the engine: a Game whose "gameplay" is editing
// the scene it shows. Everything on screen is drawn with the engine's own Gui and Canvas.
//
//   Editor.cpp          the frame, the camera, files, undo, play mode
//   EditorViewport.cpp  what happens in the 3D view: picking, the gizmo, outlines
//   EditorPanels.cpp    the panels: scene list, assets, inspector, materials, settings
#pragma once

#include "LMEngine.hpp"

#include <string>
#include <vector>

class Editor : public lm::Game {
public:
    /// The scene to open, as a name in Assets/Scenes without ".scene". Empty starts a new scene.
    std::string sceneName;

    void start(lm::Engine& engine) override;
    void draw(lm::Engine& engine, lm::Canvas& canvas) override;

    // ---- what the panels and shortcuts do. Public so that tests can drive the editor.
    enum class Tool { Move, Rotate, Scale };
    enum class Shape { Empty, Cube, Sphere, Plane, Cylinder, PointLight, Camera };

    void newScene(lm::Engine& engine);
    bool openScene(lm::Engine& engine, const std::string& name);
    bool saveScene(lm::Engine& engine);
    lm::Entity addEntity(lm::Engine& engine, Shape shape);
    lm::Entity addModel(lm::Engine& engine, const std::string& meshName);
    void duplicateSelected(lm::Engine& engine);
    void deleteSelected(lm::Engine& engine);
    void undo(lm::Engine& engine);
    void redo(lm::Engine& engine);
    void setPlaying(lm::Engine& engine, bool playing);

    lm::Entity selected() const { return selected_; }
    void select(lm::Entity entity) { selected_ = entity; }
    bool isPlaying() const { return isPlaying_; }
    Tool tool = Tool::Move;

private:
    // Editor.cpp
    void refreshLists(lm::Engine& engine);
    void restore(lm::Engine& engine, const std::string& text);
    void createCamera(lm::Engine& engine);
    void updateCamera(lm::Engine& engine, float dt);
    void handleShortcuts(lm::Engine& engine);
    void recordUndo(lm::Engine& engine);
    void say(const std::string& message);
    int indexOf(lm::Entity entity) const;
    std::shared_ptr<lm::Material> defaultMaterial();
    lm::Vec3 spawnPoint(lm::Engine& engine) const;

    // EditorViewport.cpp
    void drawViewport(lm::Engine& engine, lm::Canvas& canvas);
    bool project(lm::Engine& engine, lm::Vec3 world, lm::Vec2& screen) const;
    lm::Entity pick(lm::Engine& engine, lm::Vec2 point) const;
    void drawOutline(lm::Engine& engine, lm::Entity entity);
    void drawGrid(lm::Engine& engine);
    bool updateGizmo(lm::Engine& engine, lm::Canvas& canvas);

    // EditorPanels.cpp
    void drawToolbar(lm::Engine& engine, lm::Vec2 screen);
    void drawScenePanel(lm::Engine& engine, lm::Vec2 position, lm::Vec2 size);
    void drawAssetsPanel(lm::Engine& engine, lm::Vec2 position, lm::Vec2 size);
    void drawInspector(lm::Engine& engine);
    void drawMaterials(lm::Engine& engine);
    void drawSettings(lm::Engine& engine);
    bool textureSlot(lm::Engine& engine, const std::string& label, std::shared_ptr<lm::Texture>& slot, lm::TextureFormat format);

    lm::Gui gui_;
    std::vector<lm::NamedMaterial> materials_;
    std::vector<lm::Entity> entities_;          // everything in the scene, in file order
    lm::Entity selected_;
    int selectedMaterial_ = 0;
    int rightTab_ = 0;                          // inspector, materials, scene settings

    // The editor's own camera. It is in the scene (the renderer needs it there) but
    // marked EditorOnly, so it is never saved.
    lm::Entity camera_;
    lm::Vec3 cameraPosition_{6, 5, 9};
    float cameraYaw_ = 0.6f, cameraPitch_ = -0.42f;

    // The gizmo: which axis is being dragged (-1 for none), and how screen movement maps to it.
    int dragAxis_ = -1;
    lm::Vec2 dragDirection_{1, 0};
    float dragPointsPerUnit_ = 1;
    lm::Vec3 shownAngles_{0, 0, 0};             // the rotation of the selection as the inspector shows it
    lm::Quat shownRotation_{};

    // Undo: the scene as text after every finished edit.
    std::vector<std::string> undo_, redo_;
    std::string current_;
    bool touched_ = false;

    bool isPlaying_ = false;
    std::string beforePlay_;

    std::vector<std::string> meshNames_, textureNames_, sceneNames_;
    std::string status_;
    double statusUntil_ = 0;
    double now_ = 0;
};
