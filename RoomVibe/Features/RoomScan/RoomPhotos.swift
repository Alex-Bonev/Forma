import ARKit
import CoreImage
import UIKit

/// Keeps camera frames during a room scan: a visual record of the real room (photos/ in the project folder)
/// and the source for the matched wall paint. Polls RoomPlan's ARSession instead of becoming its delegate
/// (RoomPlan owns that).
@MainActor
@Observable
final class RoomPhotos {
    struct Shot { var photo: RoomPhoto; var jpeg: Data; var pixels: PhotoPixels }

    static let maxCount = 40
    private(set) var shots: [Shot] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var encoding = false
    @ObservationIgnored private var lastKept: simd_float4x4?
    @ObservationIgnored private weak var session: ARSession?

    func start(_ session: ARSession) {
        self.session = session
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !encoding, shots.count < Self.maxCount, let frame = session?.currentFrame,
              case .normal = frame.camera.trackingState else { return }
        let camera = frame.camera
        if let lastKept, !RoomPhoto.movedEnough(from: lastKept, to: camera.transform) { return }
        let t = camera.transform, k = camera.intrinsics
        var photo = RoomPhoto(file: "", imageSize: [Float(camera.imageResolution.width), Float(camera.imageResolution.height)],
                              intrinsics: [k.columns.0, k.columns.1, k.columns.2],
                              columns: [t.columns.0, t.columns.1, t.columns.2, t.columns.3])
        let buffer = frame.capturedImage   // keep only the pixel buffer, not the ARFrame (ARKit recycles frames)
        encoding = true
        Task {
            defer { encoding = false }
            guard let (jpeg, pixels) = await Self.encode(buffer) else { return }
            photo.file = String(format: "%03d.jpg", shots.count)
            shots.append(Shot(photo: photo, jpeg: jpeg, pixels: pixels))
            lastKept = t
        }
    }

    nonisolated private static let context = CIContext()

    /// YCbCr camera buffer -> JPEG (long edge <= 1280, sensor landscape orientation) + a 320 px sample copy.
    nonisolated private static func encode(_ buffer: CVPixelBuffer) async -> (Data, PhotoPixels)? {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
        let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
        guard let cg = context.createCGImage(scaled, from: scaled.extent.integral),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.6) else { return nil }
        let w = 320, h = max(1, w * cg.height / cg.width)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (jpeg, PhotoPixels(width: w, height: h, rgba: rgba)) : nil
    }

    /// Writes photos/000.jpg… + photos/photos.json into a project folder.
    func write(to projectDir: URL) throws {
        guard !shots.isEmpty else { return }
        let dir = projectDir.appending(path: "photos")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for s in shots { try s.jpeg.write(to: dir.appending(path: s.photo.file)) }
        try JSONEncoder().encode(shots.map(\.photo)).write(to: dir.appending(path: "photos.json"))
    }

    /// Saved photos of a project, in capture order.
    nonisolated static func photoURLs(projectDir: URL) -> [URL] {
        let dir = projectDir.appending(path: "photos")
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Matched paint: median wall color seen in the photos. `walls` must be in the ARSession world frame.
    static func wallColor(walls: [RoomModel.Box], objects: [RoomModel.Box] = [], photos: [Shot]) -> UIColor? {
        guard let c = RoomPhoto.wallRGB(walls: walls, objects: objects, shots: photos.map { ($0.photo, $0.pixels) }) else { return nil }
        return UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }
}
