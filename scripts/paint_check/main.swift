// Matched Paint on a real scan pulled off a phone (Projects/<id>/ with captured.json + photos/).
// swiftc RoomVibe/Core/Models.swift RoomVibe/Features/RoomScan/RoomPhotoMath.swift scripts/paint_check/main.swift -o build/paint_check
// build/paint_check <project dir>
import Foundation
import ImageIO
import CoreGraphics
import simd

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let cap = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "captured.json"))) as! [String: Any]
func boxes(_ key: String) -> [RoomModel.Box] {
    (cap[key] as! [[String: Any]]).map { s in
        let t = (s["transform"] as! [NSNumber]).map(\.floatValue), d = (s["dimensions"] as! [NSNumber]).map(\.floatValue)
        let cols = (0..<4).map { SIMD4(t[$0 * 4], t[$0 * 4 + 1], t[$0 * 4 + 2], t[$0 * 4 + 3]) }
        return RoomModel.Box(label: key, dimensions: SIMD3(d[0], d[1], d[2]), columns: cols)
    }
}
let photos = try JSONDecoder().decode([RoomPhoto].self, from: Data(contentsOf: dir.appending(path: "photos/photos.json")))
let shots: [(photo: RoomPhoto, pixels: PhotoPixels)] = photos.compactMap { p in
    guard let src = CGImageSourceCreateWithURL(dir.appending(path: "photos/\(p.file)") as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = 320, h = max(1, w * cg.height / cg.width)   // same sample copy as RoomPhotos.encode
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (p, PhotoPixels(width: w, height: h, rgba: rgba))
}
func hex(_ c: SIMD3<Float>?) -> String {
    guard let c else { return "none" }
    return String(format: "#%02X%02X%02X", Int(c.x * 255), Int(c.y * 255), Int(c.z * 255))
}
let walls = boxes("walls"), objects = boxes("objects")
print("photos", shots.count, "walls", walls.count, "objects", objects.count)
print("matched paint:", hex(RoomPhoto.wallRGB(walls: walls, objects: objects, shots: shots)),
      " without occlusion:", hex(RoomPhoto.wallRGB(walls: walls, shots: shots)))
// Distribution of accepted samples (same loop as wallRGB), by brightness percentile.
var samples: [SIMD3<Float>] = []
for wall in walls where wall.dimensions.x > 0.3 {
    let t = wall.transform, n = simd_normalize(SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
    for fx in stride(from: Float(0.15), through: 0.85, by: 0.14) { for fy in [Float(0.6), 0.72, 0.84] {
        let w4 = t * SIMD4((fx - 0.5) * wall.dimensions.x, (fy - 0.5) * wall.dimensions.y, 0, 1), world = SIMD3(w4.x, w4.y, w4.z)
        for (p, px) in shots {
            guard abs(simd_dot(n, simd_normalize(p.position - world))) > 0.3,
                  !objects.contains(where: { RoomPhoto.blocks($0, from: p.position, to: world) }), let uv = p.project(world) else { continue }
            let m = uv / p.imageSize
            guard m.x > 0.05, m.x < 0.95, m.y > 0.05, m.y < 0.95 else { continue }
            samples.append(px.mean(x: Int(m.x * Float(px.width)), y: Int(m.y * Float(px.height))))
        }
    } }
}
let sorted = samples.sorted { simd_dot($0, [0.299, 0.587, 0.114]) < simd_dot($1, [0.299, 0.587, 0.114]) }
for q in [0.1, 0.3, 0.5, 0.6, 0.75, 0.85, 0.95] { print(q, hex(sorted[Int(Double(sorted.count - 1) * q)])) }
print("n", samples.count)
