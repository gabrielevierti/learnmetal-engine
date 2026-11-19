import XCTest
import simd
@testable import LMEngine

/// Every triangle must be counter-clockwise seen from outside, that is, its geometric
/// normal must agree with the vertex normals.
private func windingMatchesNormals(_ mesh: MeshData) -> Bool {
    var i = 0
    while i + 2 < mesh.indices.count {
        let a = Int(mesh.indices[i]), b = Int(mesh.indices[i + 1]), c = Int(mesh.indices[i + 2])
        i += 3
        let face = simd_cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a])
        if simd_length(face) < 1e-9 { continue }
        if simd_dot(face, mesh.normals[a] + mesh.normals[b] + mesh.normals[c]) <= 0 { return false }
    }
    return true
}

private func tangentsAreValid(_ mesh: MeshData) -> Bool {
    for i in 0..<mesh.vertexCount {
        let t = xyz(mesh.tangents[i])
        if abs(simd_length(t) - 1) > 1e-3 { return false }
        if abs(simd_dot(t, mesh.normals[i])) > 1e-3 { return false }
        if abs(abs(mesh.tangents[i].w) - 1) > 1e-6 { return false }
    }
    return true
}

final class MeshTests: XCTestCase {
    func testComputeNormalsMatchesSphereNormals() {
        var sphere = MeshData.sphere(radius: 1, segments: 32, rings: 16)
        let exact = sphere.normals
        sphere.computeNormals()
        for i in 0..<sphere.vertexCount {
            if abs(exact[i].y) > 0.99 { continue }          // the seam and the poles are not shared, skip them
            XCTAssertGreaterThan(simd_dot(exact[i], sphere.normals[i]), 0.95)
        }
    }

    func testCubeCanRepeatItsTexturePerWorldUnit() {
        let box = MeshData.cube(size: Vec3(2, 1, 4), uvPerUnit: 0.5)
        XCTAssertTrue(windingMatchesNormals(box))
        XCTAssertTrue(tangentsAreValid(box))
        // The top face (+Y, the third one) is 2 wide and 4 deep: 1 repeat by 2 repeats.
        var largest = Vec2(0, 0)
        for i in 8..<12 { largest = simd_max(largest, box.uvs[i]) }
        XCTAssertEqual(largest.x, 1, accuracy: 1e-6)
        XCTAssertEqual(largest.y, 2, accuracy: 1e-6)
        // The +X face is 4 wide (along z) and 1 tall.
        largest = Vec2(0, 0)
        for i in 0..<4 { largest = simd_max(largest, box.uvs[i]) }
        XCTAssertEqual(largest.x, 2, accuracy: 1e-6)
        XCTAssertEqual(largest.y, 0.5, accuracy: 1e-6)
    }

    func testCubeHas24VerticesAndOutwardFaces() {
        let cube = MeshData.cube(size: Vec3(2, 4, 6))
        XCTAssertEqual(cube.vertexCount, 24)
        XCTAssertEqual(cube.indices.count, 36)
        XCTAssertTrue(windingMatchesNormals(cube))
        XCTAssertTrue(tangentsAreValid(cube))
        XCTAssertEqual(cube.bounds.max.x, 1, accuracy: 1e-6)
        XCTAssertEqual(cube.bounds.max.y, 2, accuracy: 1e-6)
        XCTAssertEqual(cube.bounds.min.z, -3, accuracy: 1e-6)
        XCTAssertEqual(cube.interleaved().count, 24 * MeshData.floatsPerVertex)
    }

    func testPrimitivesHaveConsistentWindingAndTangents() {
        let meshes = [MeshData.plane(width: 4, depth: 4, subdivisions: 3, uvScale: 2),
                      MeshData.sphere(radius: 1.5, segments: 24, rings: 12),
                      MeshData.cylinder(radius: 1, height: 2, segments: 20),
                      MeshData.cone(radius: 1, height: 2, segments: 20),
                      MeshData.heightfield(width: 12, depth: 8, columns: 24, rows: 16, uvScale: 3) { x, z in
                          sin(x * 0.7) * 0.8 + cos(z * 0.5) * 0.6
                      }]
        for mesh in meshes {
            XCTAssertTrue(windingMatchesNormals(mesh))
            XCTAssertTrue(tangentsAreValid(mesh))
            XCTAssertTrue(mesh.normals.count == mesh.vertexCount && mesh.uvs.count == mesh.vertexCount)
            XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < mesh.vertexCount })
        }
        for p in meshes[1].positions { XCTAssertEqual(simd_length(p), 1.5, accuracy: 1e-4) }
        XCTAssertEqual(meshes[1].indices.count, 24 * (2 * 12 - 2) * 3)
    }

    func testHeightfieldFollowsItsFunctionAndLeansItsNormalsDownhill() {
        // A ramp that rises one unit for every two units of x.
        let ramp = MeshData.heightfield(width: 10, depth: 6, columns: 5, rows: 3) { x, _ in x * 0.5 }
        XCTAssertEqual(ramp.vertexCount, 6 * 4)
        XCTAssertEqual(ramp.indices.count, 5 * 3 * 6)
        for i in 0..<ramp.vertexCount {
            XCTAssertEqual(ramp.positions[i].y, ramp.positions[i].x * 0.5, accuracy: 1e-5)
            XCTAssertEqual(ramp.normals[i].x, -0.4472, accuracy: 1e-3)      // perpendicular to the slope: (-1, 2, 0) / sqrt(5)
            XCTAssertEqual(ramp.normals[i].y, 0.8944, accuracy: 1e-3)
        }
        let bounds = ramp.bounds
        XCTAssertEqual(bounds.min.x, -5, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.z, 3, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.y, 2.5, accuracy: 1e-5)

        let cone = MeshData.cone(radius: 1, height: 2, segments: 16)
        XCTAssertEqual(cone.bounds.max.y, 1, accuracy: 1e-6)
        XCTAssertEqual(cone.bounds.min.y, -1, accuracy: 1e-6)
    }

    func testTangentFramesPointAlongUAndUpTheTexture() {
        // For every built-in primitive, the tangents written by hand must agree with the
        // ones derived from the texture coordinates.
        let meshes = [MeshData.cube(), MeshData.plane(width: 2, depth: 2, subdivisions: 2),
                      MeshData.sphere(radius: 1, segments: 16, rings: 8), MeshData.cylinder(radius: 1, height: 2, segments: 16)]
        for original in meshes {
            var mesh = original
            mesh.computeTangents()
            var compared = 0
            for i in 0..<mesh.vertexCount {
                // Skip the poles and cap centers, where the direction of u is not defined.
                if abs(mesh.normals[i].y) > 0.999 && abs(mesh.positions[i].x) < 1e-4 && abs(mesh.positions[i].z) < 1e-4 { continue }
                XCTAssertGreaterThan(simd_dot(xyz(original.tangents[i]), xyz(mesh.tangents[i])), 0.9)
                XCTAssertEqual(original.tangents[i].w, mesh.tangents[i].w, accuracy: 1e-6)
                compared += 1
            }
            XCTAssertGreaterThan(compared, 0)
        }
    }

    func testOBJParserReadsQuadsAndAllIndexForms() {
        let text = """
        # a unit quad and a triangle
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        vt 0 0
        vt 1 0
        vt 1 1
        vt 0 1
        vn 0 0 1
        f 1/1/1 2/2/1 3/3/1 4/4/1
        f -4//1 -3//1 -2//1
        """
        guard let mesh = MeshData.parseOBJ(text) else { return XCTFail("the file has faces") }
        XCTAssertEqual(mesh.indices.count, 9)            // the quad becomes two triangles
        XCTAssertEqual(mesh.vertexCount, 7)              // 4 + 3: different texture coordinates, different vertices
        XCTAssertEqual(mesh.uvs[0].y, 1, accuracy: 1e-6) // v is flipped: OBJ's origin is at the bottom
        XCTAssertEqual(mesh.normals[0].z, 1, accuracy: 1e-6)
        XCTAssertTrue(windingMatchesNormals(mesh))
        XCTAssertEqual(mesh.tangents.count, mesh.vertexCount)
        XCTAssertEqual(mesh.tangents[0].x, 1, accuracy: 1e-4)        // u grows along +x
        XCTAssertEqual(mesh.tangents[0].w, 1, accuracy: 1e-6)
    }

    func testOBJParserComputesMissingNormalsAndRejectsEmptyFiles() {
        let mesh = MeshData.parseOBJ("v 0 0 0\nv 1 0 0\nv 0 0 -1\nf 1 2 3\n")
        XCTAssertEqual(mesh?.normals[0].y ?? 0, 1, accuracy: 1e-5)
        XCTAssertNil(MeshData.parseOBJ("v 0 0 0\n# no faces\n"))
    }
}
