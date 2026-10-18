// swiftc RoomVibe/Features/Designer/FloorMesh.swift scripts/floor_check/main.swift -o build/floor_check && build/floor_check
import simd
func area(_ p: [SIMD2<Float>], _ t: [UInt32]) -> Float {
    stride(from: 0, to: t.count, by: 3).reduce(0) { s, i in
        let a = p[Int(t[i])], b = p[Int(t[i + 1])], c = p[Int(t[i + 2])]
        return s + abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
    }
}
// UCLA dorm outline (x, z) from a real scan: L-shape with a small jog.
let dorm: [SIMD2<Float>] = [[-2.55, 2.16], [-2.67, -1.58], [4.29, -1.58], [4.29, 0.09], [0.97, 0.09], [0.97, 1.88], [0.77, 1.88], [0.77, 2.16]]
let t = FloorMesh.triangulate(dorm)
assert(t.count == (dorm.count - 2) * 3, "n-2 triangles, got \(t.count / 3)")
let shoelace = abs(dorm.indices.reduce(Float(0)) { a, i in let p = dorm[i], q = dorm[(i + 1) % dorm.count]; return a + p.x * q.y - q.x * p.y }) / 2
assert(abs(area(dorm, t) - shoelace) < 1e-3, "triangles cover the polygon exactly: \(area(dorm, t)) vs \(shoelace)")
let square: [SIMD2<Float>] = [[0, 0], [0, 1], [1, 1], [1, 0]]
assert(abs(area(square, FloorMesh.triangulate(square)) - 1) < 1e-5)
assert(abs(area(square.reversed(), FloorMesh.triangulate(square.reversed())) - 1) < 1e-5, "either winding")
print("floor_check ok", t.count / 3, "triangles, area", shoelace)
