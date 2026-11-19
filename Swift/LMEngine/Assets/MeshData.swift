// MeshData.swift
// A mesh on the CPU: positions, normals, tangents, texture coordinates and triangle
// indices. It knows nothing about Metal, so it can be built, edited and tested
// anywhere. Rendering/Mesh uploads it to the GPU.
//
// Triangles are counter-clockwise when seen from outside. Texture coordinates have
// their origin at the top left. A tangent points toward increasing u; its w is the
// sign that makes  cross(normal, tangent) * w  point toward the top of the texture.

import Foundation
import simd

public struct MeshData {
    public var positions: [Vec3] = []
    public var normals: [Vec3] = []
    public var tangents: [Vec4] = []
    public var uvs: [Vec2] = []
    public var indices: [UInt32] = []

    /// Floats per vertex in interleaved(): position 3, normal 3, tangent 4, uv 2.
    public static let floatsPerVertex = 12

    public init() {}

    public var vertexCount: Int { positions.count }

    public var bounds: AABB {
        var box = AABB()
        for p in positions { box.expand(p) }
        return box
    }

    /// The vertex buffer contents, in the layout the mesh shaders expect.
    public func interleaved() -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(positions.count * MeshData.floatsPerVertex)
        for i in 0..<positions.count {
            let p = positions[i]
            let n = i < normals.count ? normals[i] : Vec3(0, 1, 0)
            let t = i < tangents.count ? tangents[i] : Vec4(1, 0, 0, 1)
            let uv = i < uvs.count ? uvs[i] : Vec2(0, 0)
            out.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z, t.x, t.y, t.z, t.w, uv.x, uv.y])
        }
        return out
    }

    /// Smooth normals from the triangles, weighted by triangle area.
    public mutating func computeNormals() {
        normals = [Vec3](repeating: Vec3(0, 0, 0), count: positions.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            // The cross product's length is twice the triangle's area, which is the weight we want.
            let faceNormal = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += faceNormal
            normals[b] += faceNormal
            normals[c] += faceNormal
            i += 3
        }
        for j in 0..<normals.count { normals[j] = safeNormalize(normals[j]) }
    }

    /// Tangents from the texture coordinates. Needs normals.
    public mutating func computeTangents() {
        let count = positions.count
        if uvs.count != count { uvs = [Vec2](repeating: Vec2(0, 0), count: count) }
        var tan = [Vec3](repeating: Vec3(0, 0, 0), count: count)
        var bitan = [Vec3](repeating: Vec3(0, 0, 0), count: count)

        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            i += 3
            let e1 = positions[b] - positions[a], e2 = positions[c] - positions[a]
            // v runs down the image, so flip it: we want the bitangent to point to the top of the texture.
            let du1 = uvs[b].x - uvs[a].x, dv1 = uvs[a].y - uvs[b].y
            let du2 = uvs[c].x - uvs[a].x, dv2 = uvs[a].y - uvs[c].y
            let determinant = du1 * dv2 - du2 * dv1
            if abs(determinant) < 1e-12 { continue }
            let r = 1 / determinant
            let t = (e1 * dv2 - e2 * dv1) * r
            let bt = (e2 * du1 - e1 * du2) * r
            for v in [a, b, c] {
                tan[v] += t
                bitan[v] += bt
            }
        }

        tangents = [Vec4](repeating: Vec4(1, 0, 0, 1), count: count)
        for v in 0..<count {
            let n = v < normals.count ? normals[v] : Vec3(0, 1, 0)
            var t = tan[v] - n * simd_dot(n, tan[v])                  // Gram-Schmidt: make it perpendicular to n
            if simd_length_squared(t) < 1e-12 {
                // No usable texture coordinates here: any direction perpendicular to n will do.
                t = simd_cross(abs(n.y) < 0.99 ? Vec3(0, 1, 0) : Vec3(1, 0, 0), n)
            }
            t = simd_normalize(t)
            let w: Float = simd_dot(simd_cross(n, t), bitan[v]) < 0 ? -1 : 1
            tangents[v] = Vec4(t, w)
        }
    }

    // MARK: - Primitives, centered on the origin

    /// A box. Normally every face shows the whole texture once. With `uvPerUnit` above zero
    /// the texture instead repeats that many times per world unit, so that boxes of
    /// different sizes can share one material without stretching it.
    public static func cube(size: Vec3 = Vec3(1, 1, 1), uvPerUnit: Float = 0) -> MeshData {
        var mesh = MeshData()
        let h = size * 0.5
        // Each face: its normal and the direction of increasing u.
        let faces: [(Vec3, Vec3)] = [
            (Vec3(1, 0, 0), Vec3(0, 0, -1)), (Vec3(-1, 0, 0), Vec3(0, 0, 1)),
            (Vec3(0, 1, 0), Vec3(1, 0, 0)), (Vec3(0, -1, 0), Vec3(1, 0, 0)),
            (Vec3(0, 0, 1), Vec3(1, 0, 0)), (Vec3(0, 0, -1), Vec3(-1, 0, 0)),
        ]
        let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]     // counter-clockwise from the bottom left
        for (n, t) in faces {
            let b = simd_cross(n, t)                                  // b points to the top of the texture
            let base = UInt32(mesh.positions.count)
            // How many times the texture repeats across this face, horizontally and vertically.
            var repeats = Vec2(1, 1)
            if uvPerUnit > 0 {
                repeats = Vec2(simd_dot(simd_abs(t), size), simd_dot(simd_abs(b), size)) * uvPerUnit
            }
            for (cu, cv) in corners {
                mesh.positions.append((n + t * cu + b * cv) * h)
                mesh.normals.append(n)
                mesh.tangents.append(Vec4(t, 1))
                mesh.uvs.append(Vec2(cu * 0.5 + 0.5, 0.5 - cv * 0.5) * repeats)
            }
            mesh.indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        return mesh
    }

    /// A flat grid in the XZ plane, facing +Y. `uvScale` repeats the texture that many times.
    public static func plane(width: Float = 1, depth: Float = 1, subdivisions: Int = 1, uvScale: Float = 1) -> MeshData {
        var mesh = MeshData()
        let n = max(subdivisions, 1)
        for j in 0...n {
            for i in 0...n {
                let u = Float(i) / Float(n), v = Float(j) / Float(n)
                mesh.positions.append(Vec3((u - 0.5) * width, 0, (v - 0.5) * depth))
                mesh.normals.append(Vec3(0, 1, 0))
                mesh.tangents.append(Vec4(1, 0, 0, 1))
                mesh.uvs.append(Vec2(u * uvScale, v * uvScale))
            }
        }
        let stride = UInt32(n + 1)
        for j in 0..<UInt32(n) {
            for i in 0..<UInt32(n) {
                let a = j * stride + i, b = a + stride, c = b + 1, d = a + 1
                mesh.indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }
        return mesh
    }

    public static func sphere(radius: Float = 0.5, segments: Int = 32, rings: Int = 16) -> MeshData {
        var mesh = MeshData()
        let segments = max(segments, 3), rings = max(rings, 2)
        for r in 0...rings {
            let v = Float(r) / Float(rings), phi = v * Float.pi       // 0 at the north pole
            // Exact values at the poles, so that every pole vertex sits on the same point.
            let sinPhi: Float = (r == 0 || r == rings) ? 0 : sin(phi)
            let cosPhi: Float = r == 0 ? 1 : (r == rings ? -1 : cos(phi))
            for s in 0...segments {
                let u = Float(s) / Float(segments), theta = u * 2 * Float.pi
                let n = Vec3(sinPhi * sin(theta), cosPhi, sinPhi * cos(theta))
                mesh.positions.append(n * radius)
                mesh.normals.append(n)
                mesh.tangents.append(Vec4(cos(theta), 0, -sin(theta), 1))
                mesh.uvs.append(Vec2(u, v))
            }
        }
        let stride = UInt32(segments + 1)
        for r in 0..<UInt32(rings) {
            for s in 0..<UInt32(segments) {
                let a = r * stride + s, b = a + stride, c = b + 1, d = a + 1
                // At a pole one of the two triangles of the quad has no area: leave it out.
                if r != UInt32(rings) - 1 { mesh.indices.append(contentsOf: [a, b, c]) }
                if r != 0 { mesh.indices.append(contentsOf: [a, c, d]) }
            }
        }
        return mesh
    }

    /// A capped cylinder around the Y axis.
    public static func cylinder(radius: Float = 0.5, height: Float = 1, segments: Int = 32) -> MeshData {
        var mesh = MeshData()
        let segments = max(segments, 3)
        let h = height * 0.5

        // Side: two rings that share positions with the caps but not normals.
        for ring in 0..<2 {
            for s in 0...segments {
                let u = Float(s) / Float(segments), theta = u * 2 * Float.pi
                let n = Vec3(sin(theta), 0, cos(theta))
                mesh.positions.append(Vec3(n.x * radius, ring == 0 ? h : -h, n.z * radius))
                mesh.normals.append(n)
                mesh.tangents.append(Vec4(cos(theta), 0, -sin(theta), 1))
                mesh.uvs.append(Vec2(u, Float(ring)))
            }
        }
        let stride = UInt32(segments + 1)
        for s in 0..<UInt32(segments) {
            let a = s, b = a + stride, c = b + 1, d = a + 1
            mesh.indices.append(contentsOf: [a, b, c, a, c, d])
        }

        // Caps: a center vertex and a ring, as a triangle fan.
        for cap in 0..<2 {
            let y: Float = cap == 0 ? h : -h, ny: Float = cap == 0 ? 1 : -1
            let center = UInt32(mesh.positions.count)
            mesh.positions.append(Vec3(0, y, 0))
            mesh.normals.append(Vec3(0, ny, 0))
            mesh.tangents.append(Vec4(1, 0, 0, ny))
            mesh.uvs.append(Vec2(0.5, 0.5))
            for s in 0...segments {
                let theta = Float(s) / Float(segments) * 2 * Float.pi
                let x = sin(theta), z = cos(theta)
                mesh.positions.append(Vec3(x * radius, y, z * radius))
                mesh.normals.append(Vec3(0, ny, 0))
                mesh.tangents.append(Vec4(1, 0, 0, ny))
                mesh.uvs.append(Vec2(x * 0.5 + 0.5, z * 0.5 + 0.5))
            }
            for s in 0..<UInt32(segments) {
                let a = center + 1 + s, b = a + 1
                mesh.indices.append(contentsOf: cap == 0 ? [center, a, b] : [center, b, a])
            }
        }
        return mesh
    }

    // MARK: - Wavefront OBJ

    /// Parses Wavefront OBJ text: v, vt, vn and f records, polygons of any size,
    /// negative indices. Materials and groups are ignored. Returns nil if the text
    /// contains no faces.
    public static func parseOBJ(_ text: String) -> MeshData? {
        var filePositions: [Vec3] = [], fileNormals: [Vec3] = []
        var fileUVs: [Vec2] = []
        var mesh = MeshData()
        var vertexLookup: [Substring: UInt32] = [:]         // "v/vt/vn" as written -> output vertex
        var hasNormals = true

        func number(_ fields: [Substring], _ i: Int) -> Float {
            i < fields.count ? (Float(fields[i]) ?? 0) : 0
        }

        /// OBJ indices start at 1; negative ones count back from the end. Returns nil for "absent".
        func resolveIndex(_ token: Substring?, _ count: Int) -> Int? {
            guard let token = token, let index = Int(token), index != 0 else { return nil }
            let resolved = index > 0 ? index - 1 : count + index
            return resolved >= 0 && resolved < count ? resolved : nil
        }

        for line in text.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let keyword = fields.first else { continue }
            switch keyword {
            case "v":
                filePositions.append(Vec3(number(fields, 1), number(fields, 2), number(fields, 3)))
            case "vn":
                fileNormals.append(Vec3(number(fields, 1), number(fields, 2), number(fields, 3)))
            case "vt":
                fileUVs.append(Vec2(number(fields, 1), 1 - number(fields, 2)))     // OBJ puts v = 0 at the bottom
            case "f":
                var corners: [UInt32] = []
                for corner in fields.dropFirst() {
                    if let known = vertexLookup[corner] {
                        corners.append(known)
                        continue
                    }
                    // A corner is "v", "v/vt", "v//vn" or "v/vt/vn".
                    let parts = corner.split(separator: "/", omittingEmptySubsequences: false)
                    guard let p = resolveIndex(parts.first, filePositions.count) else { continue }
                    let t = resolveIndex(parts.count > 1 ? parts[1] : nil, fileUVs.count)
                    let n = resolveIndex(parts.count > 2 ? parts[2] : nil, fileNormals.count)

                    let index = UInt32(mesh.positions.count)
                    mesh.positions.append(filePositions[p])
                    mesh.uvs.append(t.map { fileUVs[$0] } ?? Vec2(0, 0))
                    if let n = n {
                        mesh.normals.append(simd_normalize(fileNormals[n]))
                    } else {
                        mesh.normals.append(Vec3(0, 1, 0))
                        hasNormals = false
                    }
                    vertexLookup[corner] = index
                    corners.append(index)
                }
                // A polygon with n corners becomes a fan of n - 2 triangles.
                if corners.count >= 3 {
                    for i in 1..<(corners.count - 1) {
                        mesh.indices.append(contentsOf: [corners[0], corners[i], corners[i + 1]])
                    }
                }
            default:
                break
            }
        }

        if mesh.indices.isEmpty { return nil }
        if !hasNormals { mesh.computeNormals() }
        mesh.computeTangents()
        return mesh
    }
}
