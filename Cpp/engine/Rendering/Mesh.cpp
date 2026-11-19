#include "Rendering/Mesh.hpp"

namespace lm {

Mesh::Mesh(GraphicsDevice& device, const MeshData& data) {
    std::vector<float> vertices = data.interleaved();
    vertexBuffer_ = NS::TransferPtr(device.device()->newBuffer(vertices.data(), vertices.size() * sizeof(float),
                                                               MTL::ResourceStorageModeShared));
    indexBuffer_ = NS::TransferPtr(device.device()->newBuffer(data.indices.data(), data.indices.size() * sizeof(uint32_t),
                                                              MTL::ResourceStorageModeShared));
    indexCount_ = uint32_t(data.indices.size());
    bounds_ = data.bounds();
}

}  // namespace lm
