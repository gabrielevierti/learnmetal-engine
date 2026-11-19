// What happens in the 3D view: outlines, the grid, picking with the mouse, the gizmo.
#include "Editor.hpp"

#include <algorithm>
#include <cmath>

using namespace lm;

namespace {

const Vec4 kAxisColors[3] = {rgb(0xe5484d), rgb(0x46a758), rgb(0x3e7bfa)};        // x red, y green, z blue
const Vec3 kAxes[3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};

float distanceToSegment(Vec2 p, Vec2 a, Vec2 b) {
    Vec2 ab = b - a;
    float lengthSquared = simd::dot(ab, ab);
    float t = lengthSquared > 0 ? std::clamp(simd::dot(p - a, ab) / lengthSquared, 0.0f, 1.0f) : 0.0f;
    return simd::length(p - (a + ab * t));
}

}  // namespace

/// Where a point of the world appears on screen, in points. False if it is behind the camera.
bool Editor::project(Engine& engine, Vec3 world, Vec2& screen) const {
    const Transform* transform = engine.scene.get<Transform>(camera_);
    const Camera* camera = engine.scene.get<Camera>(camera_);
    if (!transform || !camera) return false;
    Vec2 size = engine.screenSize();
    Mat4 view = simd::inverse(compose(transform->position, transform->rotation, Vec3{1, 1, 1}));
    Vec4 clip = camera->projection(size.x / size.y) * view * vec4(world, 1);
    if (clip.w <= 0.001f) return false;
    screen = Vec2{(clip.x / clip.w * 0.5f + 0.5f) * size.x, (0.5f - clip.y / clip.w * 0.5f) * size.y};
    return true;
}

/// The entity under a point of the screen: the nearest one hit by the ray through it.
Entity Editor::pick(Engine& engine, Vec2 point) const {
    Ray ray = engine.screenRay(point);
    Entity best;
    float bestDistance = std::numeric_limits<float>::max();
    for (Entity entity : entities_) {
        const Transform* transform = engine.scene.get<Transform>(entity);
        const MeshRenderer* renderer = engine.scene.get<MeshRenderer>(entity);
        std::optional<float> hit;
        if (renderer && renderer->mesh) {
            // Test against the mesh's box in the mesh's own space: bring the ray there.
            // The direction is left unnormalized, so the distance keeps its world scale.
            Mat4 toLocal = simd::inverse(transform->world);
            Ray local{transformPoint(toLocal, ray.origin), transformDirection(toLocal, ray.direction)};
            hit = intersectAABB(local, renderer->mesh->bounds());
        } else {
            hit = intersectSphere(ray, transform->worldPosition(), 0.35f);     // lights and cameras: their icon
        }
        if (hit && *hit < bestDistance) {
            bestDistance = *hit;
            best = entity;
        }
    }
    return best;
}

void Editor::drawGrid(Engine& engine) {
    DebugDraw& lines = engine.debug();
    const int half = 10;
    for (int i = -half; i <= half; i++) {
        Vec4 color = i == 0 ? Vec4{0.5f, 0.5f, 0.5f, 1} : Vec4{0.22f, 0.24f, 0.27f, 1};
        lines.line(Vec3{float(i), 0.002f, float(-half)}, Vec3{float(i), 0.002f, float(half)}, color);
        lines.line(Vec3{float(-half), 0.002f, float(i)}, Vec3{float(half), 0.002f, float(i)}, color);
    }
}

/// Lines around the selected entity: the box of its mesh, and what its other components mean in space.
void Editor::drawOutline(Engine& engine, Entity entity) {
    DebugDraw& lines = engine.debug();
    const Transform* transform = engine.scene.get<Transform>(entity);
    if (!transform) return;
    const Vec4 orange{1.0f, 0.55f, 0.24f, 1};
    Vec3 position = transform->worldPosition();

    const MeshRenderer* renderer = engine.scene.get<MeshRenderer>(entity);
    if (renderer && renderer->mesh) {
        // The eight corners of the mesh's box, moved to the world, joined by twelve edges.
        const AABB& box = renderer->mesh->bounds();
        Vec3 corners[8];
        for (int i = 0; i < 8; i++) {
            Vec3 corner{i & 1 ? box.max.x : box.min.x, i & 2 ? box.max.y : box.min.y, i & 4 ? box.max.z : box.min.z};
            corners[i] = transformPoint(transform->world, corner);
        }
        for (int i = 0; i < 8; i++) {
            for (int bit = 1; bit <= 4; bit <<= 1) {
                if (!(i & bit)) lines.line(corners[i], corners[i | bit], orange);
            }
        }
    }
    if (const Light* light = engine.scene.get<Light>(entity)) {
        Vec4 color = vec4(light->color, 1);
        Vec3 forward = safeNormalize(transformDirection(transform->world, Vec3{0, 0, -1}));
        if (light->type == LightType::Point) lines.sphere(position, light->range, color, 32);
        else lines.line(position, position + forward * (light->type == LightType::Spot ? light->range : 3.0f), color);
    }
    if (engine.scene.has<Camera>(entity)) lines.axes(transform->world, 1.0f);
    if (const Collider* collider = engine.scene.get<Collider>(entity)) {
        const Vec4 green{0.3f, 1.0f, 0.4f, 1};
        Vec3 center = transform->position + rotate(transform->rotation, collider->offset);
        if (collider->shape == ColliderShape::Sphere) {
            lines.sphere(center, collider->radius, green);
        } else if (collider->shape == ColliderShape::Box) {
            lines.box(center, collider->halfExtents, transform->rotation, green);
        } else {
            Vec3 axis = rotate(transform->rotation, Vec3{0, collider->halfHeight, 0});
            lines.sphere(center + axis, collider->radius, green, 16);
            lines.sphere(center - axis, collider->radius, green, 16);
        }
    }
}

/// Draws the three handles of the current tool on the selected entity and applies a drag
/// on one of them. Returns true if the mouse is on the gizmo, so that the click is not
/// also taken as "select what is behind it".
bool Editor::updateGizmo(Engine& engine, Canvas& canvas) {
    const Input& input = engine.input;
    Transform* transform = engine.scene.get<Transform>(selected_);
    if (!transform) {
        dragAxis_ = -1;
        return false;
    }
    Vec3 origin = transform->worldPosition();
    Vec2 center;
    if (!project(engine, origin, center)) return false;
    // The same size on screen however far away the entity is.
    float size = simd::distance(cameraPosition_, origin) * 0.16f;

    if (dragAxis_ >= 0 && !input.isDown(MouseButton::Left)) {
        dragAxis_ = -1;
        touched_ = true;                    // the drag is over: one step for Undo
    }

    bool mouseFree = !gui_.wantsMouse() && !input.isDown(MouseButton::Right);
    bool onGizmo = dragAxis_ >= 0;
    for (int i = 0; i < 3; i++) {
        // Moving and rotating use the axes of the world; scaling stretches the entity
        // along its own axes, because that is what Transform::scale means.
        Vec3 axis = tool == Tool::Scale ? safeNormalize(transformDirection(transform->world, kAxes[i])) : kAxes[i];
        Vec2 tip;
        if (!project(engine, origin + axis * size, tip)) continue;
        bool hot = dragAxis_ == i || (dragAxis_ < 0 && mouseFree && distanceToSegment(input.mousePosition(), center, tip) < 9.0f);
        if (hot) onGizmo = true;

        if (hot && dragAxis_ < 0 && input.wasPressed(MouseButton::Left)) {
            dragAxis_ = i;
            Vec2 along = tip - center;
            float length = simd::length(along);
            dragDirection_ = length > 1 ? along / length : Vec2{1, 0};
            dragPointsPerUnit_ = std::max(length / size, 1.0f);
        }
        if (dragAxis_ == i) {
            // How far the pointer moved along the handle, in points.
            float travel = simd::dot(input.mouseDelta(), dragDirection_);
            if (tool == Tool::Move) {
                Vec3 delta = axis * (travel / dragPointsPerUnit_);
                // Transform::position is relative to the parent: express the step there.
                if (const Transform* parent = engine.scene.get<Transform>(transform->parent)) {
                    delta = transformDirection(simd::inverse(parent->world), delta);
                }
                transform->position += delta;
            } else if (tool == Tool::Rotate) {
                transform->rotation = simd::normalize(axisAngle(axis, travel * 0.012f) * transform->rotation);
            } else {
                transform->scale[i] = std::max(0.01f, transform->scale[i] * (1.0f + travel * 0.01f));
            }
        }

        canvas.line(center, tip, hot ? 5.0f : 3.0f, kAxisColors[i]);
        if (tool == Tool::Move) {
            canvas.circle(tip, hot ? 8.0f : 6.0f, kAxisColors[i], 16);
        } else if (tool == Tool::Scale) {
            float h = hot ? 7.0f : 5.5f;
            canvas.rect(tip - Vec2{h, h}, Vec2{h * 2, h * 2}, kAxisColors[i]);
        } else {
            canvas.circle(tip, hot ? 9.0f : 7.0f, kAxisColors[i]);
            canvas.circle(tip, hot ? 5.5f : 4.0f, rgb(0x14181f));          // a ring: this handle turns
        }
    }
    canvas.circle(center, 4, rgb(0xffffff));
    return onGizmo;
}

void Editor::drawViewport(Engine& engine, Canvas& canvas) {
    const Input& input = engine.input;
    drawGrid(engine);
    if (engine.scene.isAlive(selected_)) drawOutline(engine, selected_);

    // Lights, cameras and emitters have no mesh to see or click: give them a small disc.
    for (Entity entity : entities_) {
        const MeshRenderer* renderer = engine.scene.get<MeshRenderer>(entity);
        if (renderer && renderer->mesh) continue;
        const Light* light = engine.scene.get<Light>(entity);
        const char* letter = light ? "L" : engine.scene.has<Camera>(entity) ? "C" : engine.scene.has<ParticleEmitter>(entity) ? "P" : nullptr;
        Vec2 at;
        if (!letter || !project(engine, engine.scene.get<Transform>(entity)->worldPosition(), at)) continue;
        canvas.circle(at, 11, entity == selected_ ? rgb(0xfe8b3c) : rgb(0x14181f, 0.85f), 20);
        canvas.circle(at, 8.5f, light ? Vec4{saturate(light->color.x), saturate(light->color.y), saturate(light->color.z), 1} : rgb(0x8d96a3), 20);
        canvas.text(letter, at + Vec2{0, -7}, 11, rgb(0x14181f), TextAlign::Center);
    }

    bool onGizmo = updateGizmo(engine, canvas);
    if (!onGizmo && !gui_.wantsMouse() && input.wasPressed(MouseButton::Left)) selected_ = pick(engine, input.mousePosition());
}
