import CoreGraphics
import CoreImage
import ImageIO
import Vision
import simd

/// On-device Apple Vision classification for room scans: what a marked item is, and brick walls / wood floors.
/// Nonisolated and synchronous: call from a background task. No UIKit/ARKit, so scripts/scene_check
/// compiles it with swiftc on the Mac (VNClassifyImageRequest works there too).
enum SceneClassifier {
    /// Vision identifier -> CatalogItem.id. Order breaks confidence ties. Chosen from supportedIdentifiers()
    /// and Mac runs on Commons CC0 photos (see docs/specs/scan-intelligence.md for the evidence).
    /// Left out: "armchair" (Vision gives it the same score as "chair" on every chair), "textile" (fires on
    /// sofas, beds and boxes too, so it is no evidence of a rug).
    static let catalogMap: [(vision: String, catalog: String)] = [
        ("trash_can", "trash"),
        ("plant", "plant"), ("decorative_plant", "plant"),
        ("lamp", "floor_lamp"),
        ("sofa", "sofa"),
        ("chair", "chair"), ("folding_chair", "chair"), ("chair_other", "chair"), ("swivel_chair", "desk_chair"),
        ("stool", "side_table"), ("table", "side_table"),   // a marked item is small: a 35 cm box
        ("bench", "bench"),
        ("television", "tv"), ("computer_monitor", "tv"),
        ("bookshelf", "bookshelf"), ("cabinet", "cabinet"), ("desk", "desk"), ("bed", "bed"),
        ("cardboard_box", "box"), ("carton", "box"), ("crate", "box"), ("basket_container", "box"), ("luggage", "box"),
    ]
    /// Spec says about 0.3; floor lamps scored 0.28 and 0.34 on the Mac, and a wrong guess only costs one button.
    static let suggestThreshold: Float = 0.25

    struct Suggestion: Equatable { var vision: String; var catalog: String }

    /// Best mapped label at or above the threshold.
    static func suggestion(_ results: [(String, Float)]) -> Suggestion? {
        var best: (Suggestion, Float)?
        for (vision, catalog) in catalogMap {
            guard let c = results.first(where: { $0.0 == vision })?.1, c >= suggestThreshold, c > (best?.1 ?? 0) else { continue }
            best = (Suggestion(vision: vision, catalog: catalog), c)
        }
        return best?.0
    }

    /// True when at least `share` of the crops have any of `labels` at >= `min`.
    static func vote(_ crops: [[(String, Float)]], labels: Set<String>, min: Float, share: Float = 0.3) -> Bool {
        guard !crops.isEmpty else { return false }
        let hits = crops.filter { $0.contains { labels.contains($0.0) && $0.1 >= min } }.count
        return Float(hits) >= share * Float(crops.count)
    }

    static func isBrick(_ wallCrops: [[(String, Float)]]) -> Bool { vote(wallCrops, labels: ["brick"], min: 0.5) }
    static func isWood(_ floorCrops: [[(String, Float)]]) -> Bool { vote(floorCrops, labels: ["wood_processed", "wood_natural"], min: 0.3) }

    // MARK: Vision

    /// Labels with confidence > 0.05, best first. `crop` is normalized (0...1, origin top-left) in the stored
    /// pixels; `orientation` says how those pixels are turned relative to upright.
    /// Only the centered square of the crop (or image) is classified: on the Mac a 1:2 input took 19 ms against
    /// 6.6 ms for a square, so Vision seems to tile non-square inputs.
    static func classify(_ image: CGImage, crop: CGRect? = nil, orientation: CGImagePropertyOrientation = .up) -> [(String, Float)] {
        let r = (crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let px = CGRect(x: r.minX * CGFloat(image.width), y: r.minY * CGFloat(image.height),
                        width: r.width * CGFloat(image.width), height: r.height * CGFloat(image.height))
        let side = min(px.width, px.height).rounded(.down)
        let square = CGRect(x: (px.midX - side / 2).rounded(.down), y: (px.midY - side / 2).rounded(.down), width: side, height: side)
        guard side >= 16, let image = square.size == CGSize(width: image.width, height: image.height) ? image : image.cropping(to: square)
        else { return [] }
        let request = VNClassifyImageRequest()
        do { try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request]) } catch { return [] }
        return (request.results ?? []).filter { $0.confidence > 0.05 }.map { ($0.identifier, $0.confidence) }
    }

    /// JPEG decoded straight to <= 512 px on the long edge (ImageIO thumbnails skip the full-size decode).
    static func decode(_ jpeg: Data, maxPixels: Int = 512) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary)
    }

    private static let context = CIContext()

    /// Square crop of a camera buffer around a normalized point (origin top-left), side = `fraction` of the
    /// short side, scaled to <= 512 px.
    static func crop(_ buffer: CVPixelBuffer, around p: CGPoint, fraction: CGFloat = 0.35) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer), e = image.extent
        let s = fraction * min(e.width, e.height)
        let x = min(max(p.x * e.width - s / 2, 0), e.width - s)
        let y = min(max((1 - p.y) * e.height - s / 2, 0), e.height - s)   // Core Image: origin bottom-left
        let square = image.cropped(to: CGRect(x: x, y: y, width: s, height: s))
        let scaled = square.transformed(by: .init(scaleX: min(1, 512 / s), y: min(1, 512 / s)))
        return context.createCGImage(scaled, from: scaled.extent.integral)
    }

    /// Orientation of an unrotated ARKit camera image, from where world up points in the camera frame.
    /// The sensor image is upright in landscape-right (+X right, +Y up); portrait reads as .right.
    static func orientation(camera: simd_float4x4) -> CGImagePropertyOrientation {
        let up = SIMD2(camera.columns.0.y, camera.columns.1.y)   // world +Y in camera axes (row 1 of the rotation)
        if abs(up.y) >= abs(up.x) { return up.y >= 0 ? .up : .down }
        return up.x < 0 ? .right : .left
    }
}

extension RoomPhoto {
    /// Normalized crop (origin top-left) of each wall facing this camera: the projected bounding box of the
    /// wall's middle (inset like wallRGB), clipped to the image; skipped when under 10% of the frame.
    /// ponytail: no occlusion test, furniture in front of a wall is classified too; the 30% vote absorbs some of it.
    func wallCrops(_ walls: [RoomModel.Box]) -> [CGRect] {
        walls.compactMap { wall in
            guard wall.dimensions.x > 0.3 else { return nil }
            let t = wall.transform
            let normal = simd_normalize(SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
            let center = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            guard abs(simd_dot(normal, simd_normalize(position - center))) > 0.3 else { return nil }
            var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
            for (fx, fy) in [(Float(0.15), Float(0.2)), (0.85, 0.2), (0.15, 0.8), (0.85, 0.8)] {
                let w = t * SIMD4((fx - 0.5) * wall.dimensions.x, (fy - 0.5) * wall.dimensions.y, 0, 1)
                // ponytail: a corner behind the camera drops the wall; clip in 3D if close-up walls matter.
                guard let uv = project(SIMD3(w.x, w.y, w.z)) else { return nil }
                lo = simd_min(lo, uv / imageSize); hi = simd_max(hi, uv / imageSize)
            }
            lo = simd_clamp(lo, .zero, .one); hi = simd_clamp(hi, .zero, .one)
            guard (hi.x - lo.x) * (hi.y - lo.y) >= 0.1 else { return nil }
            return CGRect(x: CGFloat(lo.x), y: CGFloat(lo.y), width: CGFloat(hi.x - lo.x), height: CGFloat(hi.y - lo.y))
        }
    }

    /// Bottom third of the upright picture when the camera pitches down more than ~20°, else nil.
    /// VERIFY on device: the bottom third of a downward photo is mostly floor, not furniture.
    var floorCrop: CGRect? {
        let forward = -SIMD3(columns[2].x, columns[2].y, columns[2].z)
        guard forward.y < -0.35 else { return nil }
        switch SceneClassifier.orientation(camera: transform) {
        case .up: return CGRect(x: 0, y: 2 / 3.0, width: 1, height: 1 / 3.0)
        case .down: return CGRect(x: 0, y: 0, width: 1, height: 1 / 3.0)
        case .right: return CGRect(x: 2 / 3.0, y: 0, width: 1 / 3.0, height: 1)   // up is the stored left edge
        default: return CGRect(x: 0, y: 0, width: 1 / 3.0, height: 1)
        }
    }
}

extension SceneClassifier {
    struct Finishes: Equatable { var brickWalls: Bool; var woodFloor: Bool }

    /// Classifies wall and floor crops of every photo. `walls` must share the photos' frame (raw ARSession
    /// world, before axisAligned()). Slow (Vision per crop): call off the main thread.
    /// Mac M5: ~6 ms per crop, ~0.75 s for 40 photos x 3 crops. The deadline keeps a slower device under the
    /// 1.5 s budget; photos go even-then-odd so a cut-off run still covers the whole walk around the room.
    static func finishes(walls: [RoomModel.Box], photos: [(photo: RoomPhoto, jpeg: Data)], deadline: TimeInterval = 1.2) -> Finishes {
        var wallResults: [[(String, Float)]] = [], floorResults: [[(String, Float)]] = []
        let start = Date()
        let order = photos.indices.filter { $0 % 2 == 0 } + photos.indices.filter { $0 % 2 == 1 }
        for (photo, jpeg) in order.map({ photos[$0] }) {
            // VERIFY on device: how many photos fit before the deadline (log wallResults.count if brick is missed).
            if Date().timeIntervalSince(start) > deadline { break }
            let walls = photo.wallCrops(walls), floor = photo.floorCrop
            guard !walls.isEmpty || floor != nil, let image = decode(jpeg) else { continue }
            let o = orientation(camera: photo.transform)
            wallResults += walls.map { classify(image, crop: $0, orientation: o) }
            if let floor { floorResults.append(classify(image, crop: floor, orientation: o)) }
        }
        return Finishes(brickWalls: isBrick(wallResults), woodFloor: isWood(floorResults))
    }
}
