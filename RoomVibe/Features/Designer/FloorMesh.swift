import simd

/// Triangulates a scanned floor polygon (x/z), so L-shaped rooms get an L-shaped floor.
enum FloorMesh {
    /// Ear clipping. Returns triangle indices into `poly`, counter-clockwise seen from above (+Y), or [] if it fails.
    /// ponytail: O(n³), fine for RoomPlan outlines (< 30 corners).
    static func triangulate(_ poly: [SIMD2<Float>]) -> [UInt32] {
        guard poly.count >= 3 else { return [] }
        // Seen from +Y looking down, x right and z toward the viewer: positive shoelace area here = clockwise on screen.
        let area = poly.indices.reduce(Float(0)) { a, i in
            let p = poly[i], q = poly[(i + 1) % poly.count]
            return a + (p.x * q.y - q.x * p.y)
        }
        var idx = Array(poly.indices)
        if area > 0 { idx.reverse() }   // work in one winding (signed area < 0)
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var out: [UInt32] = []
        var guardCount = 0
        while idx.count > 3, guardCount < poly.count * poly.count {
            guardCount += 1
            var clipped = false
            for k in idx.indices {
                let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                let a = poly[i0], b = poly[i1], c = poly[i2]
                guard cross(a, b, c) < 0 else { continue }   // reflex or flat corner: not an ear
                let inside = idx.contains { j in
                    guard j != i0, j != i1, j != i2 else { return false }
                    let p = poly[j]
                    return cross(a, b, p) < 0 && cross(b, c, p) < 0 && cross(c, a, p) < 0
                }
                guard !inside else { continue }
                out += [UInt32(i0), UInt32(i1), UInt32(i2)]
                idx.remove(at: k)
                clipped = true
                break
            }
            if !clipped { return [] }
        }
        if idx.count == 3 { out += idx.map(UInt32.init) }
        return out
    }
}
