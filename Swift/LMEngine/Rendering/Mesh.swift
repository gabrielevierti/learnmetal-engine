// Mesh.swift
// A mesh on the GPU: a vertex buffer, an index buffer, and the box that encloses it.

import Metal

public final class Mesh {
    public let vertexBuffer: MTLBuffer
    public let indexBuffer: MTLBuffer
    public let indexCount: Int
    /// In the mesh's own space. The renderer transforms it to cull against the view.
    public let bounds: AABB
    /// Where the mesh came from: a file name in the Assets folder, or "cube", "sphere",
    /// "plane", "cylinder". Empty for meshes made in code. Scene files store this name.
    public var name = ""

    public init(_ device: GraphicsDevice, _ data: MeshData) {
        let vertices = data.interleaved()
        guard let vertexBuffer = device.device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride,
                                                          options: .storageModeShared),
              let indexBuffer = device.device.makeBuffer(bytes: data.indices, length: data.indices.count * MemoryLayout<UInt32>.stride,
                                                         options: .storageModeShared) else {
            fatalError("cannot create the buffers of a mesh (is it empty?)")
        }
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        indexCount = data.indices.count
        bounds = data.bounds
    }
}
