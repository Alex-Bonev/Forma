// swiftc RoomVibe/Features/Designer/FloorClamp.swift scripts/clamp_check/main.swift -o build/clamp_check && build/clamp_check
import simd
// L-shaped room: 4x4 with the top-right 2x2 cut out.
let L: [SIMD2<Float>] = [[0, 0], [4, 0], [4, 2], [2, 2], [2, 4], [0, 4]]
assert(FloorClamp.clamp([1, 1], to: L, inset: 0.3) == [1, 1], "inside stays")
let notch = FloorClamp.clamp([3, 3], to: L, inset: 0.3)
assert(FloorClamp.contains(notch, L), "point in the notch moves inside: \(notch)")
assert(simd_distance(notch, [3, 3]) < 1.5, "moves to the nearby edge, not far away: \(notch)")
let out = FloorClamp.clamp([-1, 1], to: L, inset: 0.3)
assert(FloorClamp.contains(out, L) && out.x > 0 && out.x < 0.5, "outside left wall clamps just inside: \(out)")
// 1.6 m wide sofa centered inside the L, near the notch: footprint must not cross the inner corner.
let sofa = FloorClamp.clamp(footprint: [2.6, 1.6], half: [0.8, 0.4], to: L, wall: 0.05)
for d in [SIMD2<Float>(-0.8, -0.4), [0.8, -0.4], [0.8, 0.4], [-0.8, 0.4]] {
    assert(FloorClamp.contains(sofa + d, L), "sofa corner \(sofa + d) outside")
}
assert(FloorClamp.clamp(footprint: [1, 1], half: [0.4, 0.4], to: L, wall: 0.05) == [1, 1], "fits, stays")
// Free spot: an empty 4x4 room keeps the center; a sofa there pushes a 0.85 m chair clear of it (0.1 m gap).
let room = SIMD2<Float>(2, 2), chair = SIMD2<Float>(0.425, 0.425)
assert(FloorClamp.freeSpot(near: .zero, half: chair, taken: [], bounds: room, outline: nil) == .zero, "empty room keeps center")
let taken: [(lo: SIMD2<Float>, hi: SIMD2<Float>)] = [([-1, -0.45], [1, 0.45])]
let free = FloorClamp.freeSpot(near: .zero, half: chair, taken: taken, bounds: room, outline: nil)
assert(abs(free.y) - chair.y >= 0.45 + 0.1 - 1e-4 || abs(free.x) - chair.x >= 1 + 0.1 - 1e-4, "clears the sofa: \(free)")
assert(abs(free.x) <= room.x - chair.x && abs(free.y) <= room.y - chair.y, "stays in the room: \(free)")
// L-shaped room centered on the origin: the notch (top right) is never chosen.
let Lc = L.map { $0 - SIMD2(2, 2) }
let inL = FloorClamp.freeSpot(near: [1, 1], half: chair, taken: [], bounds: room, outline: Lc)
for d in [SIMD2<Float>(-1, -1), [1, -1], [1, 1], [-1, 1]] { assert(FloorClamp.contains(inL + d * chair, Lc), "L corner \(inL + d * chair) outside") }
// Room too full: falls back to the start.
let full: [(lo: SIMD2<Float>, hi: SIMD2<Float>)] = [([-2, -2], [2, 2])]
assert(FloorClamp.freeSpot(near: .zero, half: chair, taken: full, bounds: room, outline: nil) == .zero, "no room: start")
print("clamp_check ok", sofa, notch, out, free, inL)
