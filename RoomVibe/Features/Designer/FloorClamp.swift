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

    /// Moves `center` so all four footprint corners (± `half`, x/z) sit inside `outline`.
    /// A center inside the room can still poke a wide object through an L-shaped room's inner corner.
    static func clamp(footprint center: SIMD2<Float>, half: SIMD2<Float>, to outline: [SIMD2<Float>], wall: Float) -> SIMD2<Float> {
        guard outline.count >= 3 else { return center }
        var c = clamp(center, to: outline, inset: max(half.x, half.y) + wall)
        for _ in 0..<3 {   // each pass fixes the worst corner; 3 covers a corner plus its two walls
            let corners = [SIMD2(-half.x, -half.y), SIMD2(half.x, -half.y), SIMD2(half.x, half.y), SIMD2(-half.x, half.y)].map { c + $0 }
            let moves = corners.map { clamp($0, to: outline, inset: wall) - $0 }
            guard let worst = moves.max(by: { simd_length($0) < simd_length($1) }), simd_length(worst) > 1e-4 else { break }
            c += worst
        }
        return c
    }

    /// The spot nearest `start` (0.1 m grid) where a footprint (± `half`, x/z) keeps `gap` from every `taken`
    /// rectangle and stays within ± `bounds` and inside `outline` (when it has 3+ points). `start` if nowhere fits.
    static func freeSpot(near start: SIMD2<Float>, half: SIMD2<Float>, taken: [(lo: SIMD2<Float>, hi: SIMD2<Float>)],
                         bounds: SIMD2<Float>, outline: [SIMD2<Float>]?, gap: Float = 0.1) -> SIMD2<Float> {
        let step: Float = 0.1
        let poly = (outline?.count ?? 0) >= 3 ? outline : nil
        func fits(_ c: SIMD2<Float>) -> Bool {
            guard abs(c.x) <= bounds.x - half.x, abs(c.y) <= bounds.y - half.y else { return false }
            if let poly {
                for d in [SIMD2(-half.x, -half.y), SIMD2(half.x, -half.y), SIMD2(half.x, half.y), SIMD2(-half.x, half.y)]
                where !contains(c + d, poly) { return false }
            }
            return !taken.contains { c.x - half.x < $0.hi.x + gap && c.x + half.x > $0.lo.x - gap &&
                                     c.y - half.y < $0.hi.y + gap && c.y + half.y > $0.lo.y - gap }
        }
        let rings = Int((max(bounds.x, bounds.y) * 2 / step).rounded(.up))
        for k in 0...max(rings, 0) {   // square rings around start, nearest point of each ring first
            var ring: [SIMD2<Float>] = []
            for i in -k...k { for j in -k...k where max(abs(i), abs(j)) == k { ring.append(start + SIMD2(Float(i), Float(j)) * step) } }
            if let c = ring.sorted(by: { simd_distance_squared($0, start) < simd_distance_squared($1, start) }).first(where: fits) {
                return c
            }
        }
        return start
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
