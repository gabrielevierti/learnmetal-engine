// The panels: the toolbar, the list of entities, the assets, and on the right the
// inspector, the materials and the scene settings.
#include "Editor.hpp"

#include <algorithm>
#include <cmath>

using namespace lm;

namespace {

int indexOfName(const std::vector<std::string>& names, const std::string& name) {
    for (size_t i = 0; i < names.size(); i++) {
        if (names[i] == name) return int(i);
    }
    return -1;
}

/// An angle shown in degrees and kept in radians.
bool dragDegrees(Gui& gui, const std::string& label, float& radiansValue, float minimum, float maximum) {
    float shown = degrees(radiansValue);
    if (!gui.dragFloat(label, shown, 0.5f, minimum, maximum)) return false;
    radiansValue = radians(shown);
    return true;
}

/// The color part of a color with alpha.
bool colorOf(Gui& gui, const std::string& label, Vec4& value) {
    Vec3 color = xyz(value);
    if (!gui.color(label, color)) return false;
    value = vec4(color, value.w);
    return true;
}

}  // namespace

/// The bar along the top: what is open on the left, Play in the middle, and on the right
/// the things done to the whole scene or to the selection.
void Editor::drawToolbar(Engine& engine, Canvas& canvas, Vec2 screen, float height) {
    gui_.bar(Vec2{0, 0}, Vec2{screen.x, height});
    const Gui::Style& style = gui_.style;
    float middle = (height - style.fontSize) * 0.5f - 1;

    // The mark, the name of the scene, and a dot while there are changes to save.
    canvas.roundedRect(Vec2{12, height * 0.5f - 9}, Vec2{18, 18}, 5, style.accent);
    gui_.icon(Gui::Icon::Cube, Vec2{21, height * 0.5f}, 12, style.chrome);
    canvas.text("LearnMetal Editor", Vec2{40, middle}, style.fontSize, style.text);
    float nameX = 40 + canvas.measureText("LearnMetal Editor", style.fontSize).x + 16;
    canvas.text(sceneName + ".scene", Vec2{nameX, middle}, style.fontSize, style.textDim);
    if (hasUnsavedChanges_) {
        float dotX = nameX + canvas.measureText(sceneName + ".scene", style.fontSize).x + 9;
        canvas.circle(Vec2{dotX, height * 0.5f}, 3, style.accent);
    }

    float side = height - 14, top = 7;
    if (gui_.button("Play", Vec2{screen.x * 0.5f - 42, top}, Vec2{84, side}, false, Gui::Icon::Play)) setPlaying(engine, true);

    // From the right edge inward. A gap separates the three groups.
    struct Action {
        Gui::Icon icon;
        const char* tooltip;
        float gapAfter;
    };
    const Action actions[] = {{Gui::Icon::Trash, "Delete (Backspace)", 0}, {Gui::Icon::Copy, "Duplicate (Ctrl D)", 14},
                              {Gui::Icon::Redo, "Redo (Ctrl Y)", 0}, {Gui::Icon::Undo, "Undo (Ctrl Z)", 14},
                              {Gui::Icon::Save, "Save (Ctrl S)", 0},      {Gui::Icon::File, "New scene", 0}};
    float x = screen.x - 10;
    for (int i = 0; i < 6; i++) {
        x -= side;
        if (gui_.iconButton(actions[i].icon, Vec2{x, top}, Vec2{side, side}, actions[i].tooltip)) {
            switch (i) {
                case 0: deleteSelected(engine); break;
                case 1: duplicateSelected(engine); break;
                case 2: redo(engine); break;
                case 3: undo(engine); break;
                case 4: saveScene(engine); break;
                default: newScene(engine); break;
            }
        }
        x -= 2 + actions[i].gapAfter;
    }
}

/// The three tools, on a small card that floats over the top left corner of the view.
void Editor::drawTools(Vec2 position) {
    const float side = 30, gap = 2, padding = 4;
    gui_.card(position, Vec2{padding * 2 + side * 3 + gap * 2, padding * 2 + side});
    const Gui::Icon icons[3] = {Gui::Icon::Move, Gui::Icon::Rotate, Gui::Icon::Scale};
    const char* const tooltips[3] = {"Move (W)", "Rotate (E)", "Scale (R)"};
    for (int i = 0; i < 3; i++) {
        Vec2 at = position + Vec2{padding + float(i) * (side + gap), padding};
        if (gui_.iconButton(icons[i], at, Vec2{side, side}, tooltips[i], int(tool) == i)) tool = Tool(i);
    }
}

/// The bar along the bottom: the last thing the editor said, and what the renderer is drawing.
void Editor::drawStatusBar(Engine& engine, Canvas& canvas, Vec2 screen, float height) {
    Vec2 position{0, screen.y - height};
    gui_.bar(position, Vec2{screen.x, height});
    const Gui::Style& style = gui_.style;
    float y = position.y + (height - 12) * 0.5f - 1;
    bool hasMessage = now_ < statusUntil_;
    canvas.text(hasMessage ? status_ : "Right mouse button: look around. Wheel: closer and farther. Click: select.", Vec2{12, y}, 12,
                hasMessage ? style.text : style.textFaint);
    const RenderStats& stats = engine.renderer().stats;
    std::string right = std::to_string(entities_.size()) + " entities      " + std::to_string(stats.drawCalls) + " draw calls      " +
                        std::to_string(stats.triangles) + " triangles";
    canvas.text(right, Vec2{screen.x - 12, y}, 12, style.textFaint, TextAlign::Right);
}

void Editor::drawScenePanel(Engine& engine, Vec2 position, Vec2 size) {
    gui_.beginPanel("Scene", position, size);
    int add = -1;
    if (gui_.combo("Add", add, {"Empty", "Cube", "Sphere", "Plane", "Cylinder", "Light", "Camera"})) addEntity(engine, Shape(add));
    gui_.separator();

    for (Entity entity : entities_) {
        const Name* name = engine.scene.get<Name>(entity);
        // Children are indented under their parent, one step per level.
        float indent = 0;
        Entity parent = engine.scene.get<Transform>(entity)->parent;
        for (int depth = 0; depth < 8 && engine.scene.isAlive(parent); depth++) {
            indent += 14;
            parent = engine.scene.get<Transform>(parent)->parent;
        }
        std::string shown = name && !name->value.empty() ? name->value : "(no name)";
        // The icon says what kind of thing this is: the first of these it has.
        Gui::Icon icon = engine.scene.has<Light>(entity) ? Gui::Icon::Light : engine.scene.has<Camera>(entity) ? Gui::Icon::Camera
                         : engine.scene.has<MeshRenderer>(entity) ? Gui::Icon::Cube : Gui::Icon::Empty;
        if (gui_.selectable(shown, entity == selected_, indent, icon)) {
            selected_ = entity;
            rightTab_ = 0;
        }
    }
    gui_.endPanel();
}

void Editor::drawAssetsPanel(Engine& engine, Vec2 position, Vec2 size) {
    gui_.beginPanel("Assets", position, size);
    gui_.textField("Save as", sceneName);

    if (gui_.section("Scenes (click to open)")) {
        for (const std::string& name : sceneNames_) {
            if (gui_.selectable(name, name == sceneName, 0, Gui::Icon::File)) {
                openScene(engine, name);
                break;                          // the scene changed under our feet: stop drawing its list
            }
        }
    }
    if (gui_.section("Models (click to add)")) {
        for (size_t i = 4; i < meshNames_.size(); i++) {
            if (gui_.selectable(meshNames_[i].substr(7), false, 0, Gui::Icon::Cube)) addModel(engine, meshNames_[i]);
        }
    }
    if (gui_.section("Textures (click: base color)")) {
        for (const std::string& name : textureNames_) {
            if (gui_.selectable(name.substr(9), false, 0, Gui::Icon::Image)) {
                // Goes to the material being edited, as its color map.
                defaultMaterial()->baseColorTexture = engine.assets().texture(name, TextureFormat::RGBA8_sRGB);
                say(name.substr(9) + " is now the base color of " + materials_[size_t(selectedMaterial_)].name);
                rightTab_ = 1;
                touched_ = true;
            }
        }
        gui_.endPanel();
    }
}

// ---------------------------------------------------------------- inspector

void Editor::drawInspector(Engine& engine) {
    Scene& scene = engine.scene;
    Transform* transform = scene.get<Transform>(selected_);
    if (!transform) {
        gui_.label("Nothing selected.");
        gui_.label("Click something in the view or in the list.");
        return;
    }

    if (Name* name = scene.get<Name>(selected_)) {
        gui_.textField("Name", name->value);
    } else {
        std::string typed;
        if (gui_.textField("Name", typed)) scene.add(selected_, Name{typed});
    }

    // The parent: any other entity, as long as that does not close a loop.
    std::vector<std::string> parentNames = {"(none)"};
    std::vector<Entity> parentChoices = {Entity{}};
    for (Entity candidate : entities_) {
        bool isDescendant = false;
        Entity up = candidate;
        for (int depth = 0; depth < 64 && scene.isAlive(up); depth++) {
            if (up == selected_) isDescendant = true;
            up = scene.get<Transform>(up)->parent;
        }
        if (isDescendant) continue;
        const Name* name = scene.get<Name>(candidate);
        parentNames.push_back(name ? name->value : "(no name)");
        parentChoices.push_back(candidate);
    }
    int parentIndex = 0;
    for (size_t i = 1; i < parentChoices.size(); i++) {
        if (parentChoices[i] == transform->parent) parentIndex = int(i);
    }
    if (gui_.combo("Parent", parentIndex, parentNames)) transform->parent = parentChoices[size_t(parentIndex)];

    if (gui_.section("Transform")) {
        gui_.dragVec3("Position", transform->position, 0.02f);
        // Angles are shown in degrees and remembered while the selection stays the same:
        // converting the rotation back to angles every frame would make the numbers jump.
        if (simd::dot(shownRotation_.vector, transform->rotation.vector) < 0.999999f) {
            shownAngles_ = toEulerAngles(transform->rotation) * (180.0f / kPi);
            shownRotation_ = transform->rotation;
        }
        if (gui_.dragVec3("Rotation", shownAngles_, 0.5f)) {
            transform->rotation = eulerAngles(radians(shownAngles_.x), radians(shownAngles_.y), radians(shownAngles_.z));
            shownRotation_ = transform->rotation;
        }
        gui_.dragVec3("Scale", transform->scale, 0.01f);
    }

    if (MeshRenderer* renderer = scene.get<MeshRenderer>(selected_)) {
        if (gui_.section("Mesh")) {
            int meshIndex = renderer->mesh ? indexOfName(meshNames_, renderer->mesh->name) : -1;
            if (gui_.combo("Mesh", meshIndex, meshNames_)) renderer->mesh = engine.assets().mesh(meshNames_[size_t(meshIndex)]);
            std::vector<std::string> materialNames;
            int materialIndex = -1;
            for (size_t i = 0; i < materials_.size(); i++) {
                materialNames.push_back(materials_[i].name);
                if (materials_[i].material == renderer->material) materialIndex = int(i);
            }
            if (gui_.combo("Material", materialIndex, materialNames)) {
                renderer->material = materials_[size_t(materialIndex)].material;
                selectedMaterial_ = materialIndex;
            }
            colorOf(gui_, "Tint", renderer->tint);
            gui_.checkbox("Casts shadows", renderer->castsShadows);
            gui_.checkbox("Visible", renderer->isVisible);
            if (gui_.button("Remove mesh")) scene.remove<MeshRenderer>(selected_);
        }
    }

    if (Light* light = scene.get<Light>(selected_)) {
        if (gui_.section("Light")) {
            int type = int(light->type);
            if (gui_.combo("Type", type, {"Directional", "Point", "Spot"})) light->type = LightType(type);
            gui_.color("Color", light->color);
            gui_.dragFloat("Intensity", light->intensity, 0.05f, 0.0f, 1000.0f);
            if (light->type != LightType::Directional) gui_.dragFloat("Range", light->range, 0.05f, 0.1f, 500.0f);
            if (light->type == LightType::Spot) {
                dragDegrees(gui_, "Inner cone", light->innerConeAngle, 0.0f, 89.0f);
                dragDegrees(gui_, "Outer cone", light->outerConeAngle, 0.0f, 89.0f);
            }
            if (light->type == LightType::Directional) gui_.checkbox("Casts shadows", light->castsShadows);
            if (gui_.button("Remove light")) scene.remove<Light>(selected_);
        }
    }

    if (Camera* camera = scene.get<Camera>(selected_)) {
        if (gui_.section("Camera")) {
            dragDegrees(gui_, "Field of view", camera->fovY, 5.0f, 150.0f);
            gui_.dragFloat("Near", camera->nearPlane, 0.01f, 0.01f, 10.0f);
            gui_.dragFloat("Far", camera->farPlane, 1.0f, 1.0f, 5000.0f);
            gui_.checkbox("Used when playing", camera->isActive);
            if (gui_.button("Remove camera")) scene.remove<Camera>(selected_);
        }
    }

    if (Collider* collider = scene.get<Collider>(selected_)) {
        if (gui_.section("Collider")) {
            int shape = int(collider->shape);
            if (gui_.combo("Shape", shape, {"Sphere", "Box", "Capsule"})) collider->shape = ColliderShape(shape);
            if (collider->shape == ColliderShape::Box) {
                gui_.dragVec3("Half size", collider->halfExtents, 0.01f);
            } else {
                gui_.dragFloat("Radius", collider->radius, 0.01f, 0.01f, 100.0f);
                if (collider->shape == ColliderShape::Capsule) gui_.dragFloat("Half height", collider->halfHeight, 0.01f, 0.0f, 100.0f);
            }
            gui_.dragVec3("Offset", collider->offset, 0.01f);
            gui_.checkbox("Trigger", collider->isTrigger);
            const MeshRenderer* renderer = scene.get<MeshRenderer>(selected_);
            if (renderer && renderer->mesh && gui_.button("Fit to mesh")) {
                // Colliders ignore Transform::scale, so the scale goes into their size.
                const AABB& box = renderer->mesh->bounds();
                Vec3 half = box.halfExtents() * transform->scale;
                collider->halfExtents = half;
                collider->radius = collider->shape == ColliderShape::Sphere ? std::max({half.x, half.y, half.z}) : std::max(half.x, half.z);
                collider->halfHeight = std::max(half.y - collider->radius, 0.0f);
                collider->offset = box.center() * transform->scale;
                touched_ = true;
            }
            if (gui_.button("Remove collider")) scene.remove<Collider>(selected_);
        }
    }

    if (RigidBody* body = scene.get<RigidBody>(selected_)) {
        if (gui_.section("Body")) {
            int type = int(body->type);
            if (gui_.combo("Type", type, {"Static", "Kinematic", "Dynamic"})) body->type = BodyType(type);
            gui_.dragFloat("Mass", body->mass, 0.05f, 0.01f, 10000.0f);
            gui_.dragFloat("Bounce", body->restitution, 0.01f, 0.0f, 1.0f);
            gui_.dragFloat("Friction", body->friction, 0.01f, 0.0f, 2.0f);
            gui_.dragFloat("Air drag", body->linearDamping, 0.01f, 0.0f, 10.0f);
            gui_.dragFloat("Gravity", body->gravityScale, 0.01f, -10.0f, 10.0f);
            if (gui_.button("Remove body")) scene.remove<RigidBody>(selected_);
        }
    }

    if (ParticleEmitter* emitter = scene.get<ParticleEmitter>(selected_)) {
        if (gui_.section("Particles")) {
            gui_.dragFloat("Per second", emitter->rate, 0.5f, 0.0f, 5000.0f);
            gui_.dragFloat("Life, shortest", emitter->lifetimeMin, 0.01f, 0.01f, 60.0f);
            gui_.dragFloat("Life, longest", emitter->lifetimeMax, 0.01f, 0.01f, 60.0f);
            gui_.dragFloat("Speed, slowest", emitter->speedMin, 0.02f, 0.0f, 100.0f);
            gui_.dragFloat("Speed, fastest", emitter->speedMax, 0.02f, 0.0f, 100.0f);
            gui_.dragVec3("Direction", emitter->direction, 0.01f);
            dragDegrees(gui_, "Spread", emitter->spread, 0.0f, 180.0f);
            gui_.dragVec3("Gravity", emitter->gravity, 0.02f);
            gui_.dragFloat("Size at start", emitter->sizeStart, 0.005f, 0.0f, 10.0f);
            gui_.dragFloat("Size at end", emitter->sizeEnd, 0.005f, 0.0f, 10.0f);
            colorOf(gui_, "Color at start", emitter->colorStart);
            colorOf(gui_, "Color at end", emitter->colorEnd);
            gui_.checkbox("Additive", emitter->isAdditive);
            if (gui_.button("Remove particles")) scene.remove<ParticleEmitter>(selected_);
        }
    }

    // Only the components the entity does not have yet are offered.
    if (gui_.section("Add a component")) {
        std::vector<std::string> missing;
        if (!scene.has<MeshRenderer>(selected_)) missing.push_back("Mesh");
        if (!scene.has<Light>(selected_)) missing.push_back("Light");
        if (!scene.has<Camera>(selected_)) missing.push_back("Camera");
        if (!scene.has<Collider>(selected_)) missing.push_back("Collider");
        if (!scene.has<RigidBody>(selected_)) missing.push_back("Body");
        if (!scene.has<ParticleEmitter>(selected_)) missing.push_back("Particles");
        int choice = -1;
        if (gui_.combo("Component", choice, missing)) {
            const std::string& kind = missing[size_t(choice)];
            if (kind == "Mesh") scene.add(selected_, MeshRenderer{engine.assets().cube(), defaultMaterial()});
            else if (kind == "Light") scene.add(selected_, Light{});
            else if (kind == "Camera") scene.add(selected_, Camera{.isActive = false});
            else if (kind == "Collider") scene.add(selected_, Collider{});
            else if (kind == "Body") scene.add(selected_, RigidBody{});
            else scene.add(selected_, ParticleEmitter{});
        }
    }
}

// ---------------------------------------------------------------- materials

/// One texture of a material: a list of the image files, with "(none)" first.
bool Editor::textureSlot(Engine& engine, const std::string& label, std::shared_ptr<Texture>& slot, TextureFormat format) {
    std::vector<std::string> names = {"(none)"};
    for (const std::string& name : textureNames_) names.push_back(name.substr(9));       // without "Textures/"
    int index = slot ? indexOfName(textureNames_, slot->name) + 1 : 0;
    if (!gui_.combo(label, index, names)) return false;
    slot = index > 0 ? engine.assets().texture(textureNames_[size_t(index - 1)], format) : nullptr;
    return true;
}

void Editor::drawMaterials(Engine& engine) {
    defaultMaterial();
    for (size_t i = 0; i < materials_.size(); i++) {
        if (gui_.selectable(materials_[i].name, int(i) == selectedMaterial_, 0, Gui::Icon::Material)) selectedMaterial_ = int(i);
    }
    switch (gui_.buttonRow({"New", "Copy", "Delete", "Assign"})) {
        case 0:
            materials_.push_back(NamedMaterial{"Material " + std::to_string(materials_.size() + 1), std::make_shared<Material>()});
            selectedMaterial_ = int(materials_.size()) - 1;
            touched_ = true;
            break;
        case 1: {
            const NamedMaterial& source = materials_[size_t(selectedMaterial_)];
            materials_.push_back(NamedMaterial{source.name + " copy", std::make_shared<Material>(*source.material)});
            selectedMaterial_ = int(materials_.size()) - 1;
            touched_ = true;
            break;
        }
        case 2:
            if (materials_.size() > 1) {
                // Whatever used it falls back to the first material.
                std::shared_ptr<Material> gone = materials_[size_t(selectedMaterial_)].material;
                materials_.erase(materials_.begin() + selectedMaterial_);
                selectedMaterial_ = 0;
                engine.scene.each<MeshRenderer>([&](Entity, MeshRenderer& renderer) {
                    if (renderer.material == gone) renderer.material = materials_[0].material;
                });
                touched_ = true;
            }
            break;
        case 3:
            if (MeshRenderer* renderer = engine.scene.get<MeshRenderer>(selected_)) {
                renderer->material = materials_[size_t(selectedMaterial_)].material;
                touched_ = true;
            }
            break;
        default:
            break;
    }

    NamedMaterial& named = materials_[size_t(selectedMaterial_)];
    Material& material = *named.material;
    if (gui_.section("Surface")) {
        gui_.textField("Name", named.name);
        colorOf(gui_, "Base color", material.baseColor);
        float opacity = material.baseColor.w;        // a vector element cannot be passed by reference
        if (gui_.dragFloat("Opacity", opacity, 0.005f, 0.0f, 1.0f)) material.baseColor.w = opacity;
        gui_.dragFloat("Metallic", material.metallic, 0.005f, 0.0f, 1.0f);
        gui_.dragFloat("Roughness", material.roughness, 0.005f, 0.0f, 1.0f);
        gui_.color("Emissive", material.emissive);
        int alpha = int(material.alphaMode);
        if (gui_.combo("Transparency", alpha, {"Opaque", "Cut out", "Blend"})) material.alphaMode = AlphaMode(alpha);
        if (material.alphaMode == AlphaMode::Mask) gui_.dragFloat("Cut below", material.alphaCutoff, 0.005f, 0.0f, 1.0f);
        gui_.checkbox("Double sided", material.isDoubleSided);
        gui_.checkbox("Unlit", material.isUnlit);
    }

    if (gui_.section("Textures")) {
        textureSlot(engine, "Base color", material.baseColorTexture, TextureFormat::RGBA8_sRGB);
        textureSlot(engine, "Normal", material.normalTexture, TextureFormat::RGBA8);
        textureSlot(engine, "Rough / metal", material.metallicRoughnessTexture, TextureFormat::RGBA8);
        textureSlot(engine, "Occlusion", material.occlusionTexture, TextureFormat::RGBA8);
        textureSlot(engine, "Emissive", material.emissiveTexture, TextureFormat::RGBA8_sRGB);
        gui_.dragFloat("Normal strength", material.normalScale, 0.01f, 0.0f, 4.0f);
        float repeatX = material.uvScale.x, repeatY = material.uvScale.y;
        if (gui_.dragFloat("Repeat X", repeatX, 0.01f, 0.01f, 100.0f)) material.uvScale.x = repeatX;
        if (gui_.dragFloat("Repeat Y", repeatY, 0.01f, 0.01f, 100.0f)) material.uvScale.y = repeatY;
    }
}

// ---------------------------------------------------------------- scene settings

void Editor::drawSettings(Engine& engine) {
    RenderSettings& settings = engine.renderer().settings;
    if (gui_.section("Sky")) {
        gui_.color("Zenith", settings.sky.zenithColor);
        gui_.color("Horizon", settings.sky.horizonColor);
        gui_.color("Ground", settings.sky.groundColor);
        gui_.dragFloat("Sky brightness", settings.sky.intensity, 0.01f, 0.0f, 20.0f);
        gui_.dragFloat("Light from sky", settings.environmentIntensity, 0.01f, 0.0f, 10.0f);
    gui_.dragFloat("Clouds", settings.sky.cloudCoverage, 0.005f, 0.0f, 1.0f);
    gui_.dragFloat("Cloud size", settings.sky.cloudScale, 0.01f, 0.1f, 8.0f);
    }

    if (gui_.section("Camera")) {
        gui_.dragFloat("Exposure", settings.exposure, 0.01f, 0.01f, 20.0f);
        gui_.combo("Tone mapping", settings.toneMapper, {"ACES", "Reinhard", "None"});
        gui_.dragFloat("Vignette", settings.vignette, 0.005f, 0.0f, 1.0f);
    gui_.dragFloat("Lens bend", settings.lensDistortion, 0.005f, 0.0f, 1.0f);
    gui_.dragFloat("Color fringes", settings.chromaticAberration, 0.0005f, 0.0f, 0.05f);
    gui_.dragFloat("Grain", settings.filmGrain, 0.001f, 0.0f, 0.3f);
    }

    if (gui_.section("Effects")) {
        gui_.checkbox("Bloom", settings.bloomEnabled);
        gui_.dragFloat("Bloom strength", settings.bloomIntensity, 0.002f, 0.0f, 1.0f);
        gui_.dragFloat("Bloom from", settings.bloomThreshold, 0.01f, 0.0f, 20.0f);
        gui_.checkbox("Ambient occlusion", settings.ambientOcclusionEnabled);
        gui_.dragFloat("Occlusion radius", settings.ambientOcclusionRadius, 0.01f, 0.05f, 5.0f);
        gui_.dragFloat("Occlusion strength", settings.ambientOcclusionIntensity, 0.01f, 0.0f, 4.0f);
        gui_.checkbox("Sun shadows", settings.shadowsEnabled);
        gui_.dragFloat("Shadow distance", settings.cascades.shadowDistance, 0.5f, 5.0f, 500.0f);
    }

    if (gui_.section("Fog")) {
        gui_.color("Fog color", settings.fogColor);
        gui_.dragFloat("Fog density", settings.fogDensity, 0.0005f, 0.0f, 1.0f);
    }
}
