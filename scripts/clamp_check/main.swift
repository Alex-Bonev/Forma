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
print("clamp_check ok", sofa, notch, out)
