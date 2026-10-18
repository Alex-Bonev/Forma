import simd

/// Keeps a point inside the scanned floor polygon (x/z), so drags can't leave L-shaped rooms.
enum FloorClamp {
    /// `p` if inside `outline`, else the nearest point on its edges pushed `inset` m inward along that edge's normal.
    static func clamp(_ p: SIMD2<Float>, to outline: [SIMD2<Float>], inset: Float) -> SIMD2<Float> {
        guard outline.count >= 3, !contains(p, outline) else { return p }
        var best: (q: SIMD2<Float>, n: SIMD2<Float>, d: Float)?
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count], ab = b - a
            let t = simd_clamp(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-6), 0, 1)
            let q = a + ab * t, d = simd_distance(p, q)
            guard d < best?.d ?? .greatestFiniteMagnitude else { continue }
            var n = simd_normalize(SIMD2(-ab.y, ab.x))
            if !contains(a + ab / 2 + n * 0.01, outline) { n = -n }   // point it into the room
            best = (q, n, d)
        }
        guard let best else { return p }
        let pushed = best.q + best.n * inset
        // ponytail: in a tight corner the push can cross the neighbour wall; then stay 1 cm inside. Exact = polygon offset.
        return contains(pushed, outline) ? pushed : best.q + best.n * 0.01
    }

    static func contains(_ p: SIMD2<Float>, _ poly: [SIMD2<Float>]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
