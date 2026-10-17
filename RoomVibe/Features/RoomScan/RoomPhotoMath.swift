import simd

/// One photo taken during a room scan, saved in photos/photos.json next to its JPEG.
/// Pixels are in the camera sensor's native landscape orientation (ARFrame.capturedImage, unrotated).
/// Pure math (no ARKit) so scripts/photo_check can test it on the Mac.
struct RoomPhoto: Codable {
    var file: String
    var imageSize: SIMD2<Float>      // ARCamera.imageResolution, pixels
    var intrinsics: [SIMD3<Float>]   // ARCamera.intrinsics columns (fx, fy, cx, cy in imageSize pixels)
    var columns: [SIMD4<Float>]      // ARCamera.transform columns: camera -> ARSession world

    var transform: simd_float4x4 { .init(columns[0], columns[1], columns[2], columns[3]) }
    var k: simd_float3x3 { .init(intrinsics[0], intrinsics[1], intrinsics[2]) }

    /// World point -> pixel (v down, origin top-left of the landscape image), nil if behind the camera.
    /// ARKit camera space: +X right, +Y up, looking down -Z. The intrinsics expect +Y down, +Z forward,
    /// so flip Y and Z first; same as Apple's point-cloud sample (world = transform * flipYZ * K⁻¹[u v 1] * depth).
    func project(_ world: SIMD3<Float>) -> SIMD2<Float>? {
        let c = transform.inverse * SIMD4(world, 1)
        guard -c.z > 0.1 else { return nil }
        let p = k * SIMD3(c.x, -c.y, -c.z)
        return SIMD2(p.x, p.y) / p.z
    }

    var position: SIMD3<Float> { SIMD3(columns[3].x, columns[3].y, columns[3].z) }

    /// Keep a new photo only when the camera moved > 0.5 m or turned > 25° since the last kept one.
    static func movedEnough(from a: simd_float4x4, to b: simd_float4x4) -> Bool {
        let d = simd_distance(SIMD3(a.columns.3.x, a.columns.3.y, a.columns.3.z), SIMD3(b.columns.3.x, b.columns.3.y, b.columns.3.z))
        let r = simd_quatf(a).inverse * simd_quatf(b)
        return d > 0.5 || r.angle > 25 * .pi / 180
    }
}

/// Small RGBA8 (sRGB) copy of a photo kept in memory for color sampling; same framing as the JPEG.
struct PhotoPixels {
    var width: Int, height: Int
    var rgba: [UInt8]

    /// Mean color (0...1) of a (2r+1)² patch around a pixel.
    func mean(x: Int, y: Int, r: Int = 2) -> SIMD3<Float> {
        var sum = SIMD3<Float>(), n: Float = 0
        for yy in max(y - r, 0)...min(y + r, height - 1) {
            for xx in max(x - r, 0)...min(x + r, width - 1) {
                let i = (yy * width + xx) * 4
                sum += SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]))
                n += 1
            }
        }
        return sum / (n * 255)
    }
}

extension RoomPhoto {
    /// Typical wall color across all photos: per-channel median of patches sampled on a grid in each wall's
    /// middle (skipping the outer 15% of width where corners/furniture sit and the bottom/top 20%).
    /// Walls and photos must share a frame (raw RoomPlan / ARSession world, before axisAligned()).
    /// ponytail: no occlusion test, furniture in front of a wall is sampled too; median absorbs a minority of it.
    static func wallRGB(walls: [RoomModel.Box], shots: [(photo: RoomPhoto, pixels: PhotoPixels)]) -> SIMD3<Float>? {
        var samples: [SIMD3<Float>] = []
        for wall in walls where wall.dimensions.x > 0.3 {
            let t = wall.transform
            let normal = simd_normalize(SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
            for fx in stride(from: Float(0.15), through: 0.85, by: 0.14) {
                for fy in [Float(0.3), 0.5, 0.7] {
                    let local = SIMD4((fx - 0.5) * wall.dimensions.x, (fy - 0.5) * wall.dimensions.y, 0, 1)
                    let w4 = t * local, world = SIMD3(w4.x, w4.y, w4.z)
                    for (photo, pixels) in shots {
                        // Facing check: walls have no inside/outside, so either side of the normal counts.
                        guard abs(simd_dot(normal, simd_normalize(photo.position - world))) > 0.3,
                              let uv = photo.project(world) else { continue }
                        let m = uv / photo.imageSize   // 0...1, margin keeps patches off the edge
                        guard m.x > 0.05, m.x < 0.95, m.y > 0.05, m.y < 0.95 else { continue }
                        samples.append(pixels.mean(x: Int(m.x * Float(pixels.width)), y: Int(m.y * Float(pixels.height))))
                    }
                }
            }
        }
        guard samples.count >= 5 else { return nil }
        func median(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }
        return SIMD3(median(samples.map(\.x)), median(samples.map(\.y)), median(samples.map(\.z)))
    }
}
