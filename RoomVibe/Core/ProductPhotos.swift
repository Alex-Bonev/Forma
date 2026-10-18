import ImageIO
import UIKit

/// Listing photos of shopped products, kept per placement so "Make it real" can show the image model the real
/// piece: offline, after the listing image goes away, and after a reinstall moves the bundled demo images.
///   Projects/<projectID>/products/<placementID>.jpg (JPEG, ≤ 768 px)
enum ProductPhotos {
    private static let maxDownload = 15 * 1024 * 1024

    static func url(placement: UUID, project: UUID) -> URL {
        ProjectStore.projectDir(project).appending(path: "products/\(placement).jpg")
    }

    static func load(placement: UUID, project: UUID) -> UIImage? {
        (try? Data(contentsOf: url(placement: placement, project: project))).flatMap(UIImage.init(data:))
    }

    /// Downloads and stores the photo unless it's already there. Silent on failure: the product then renders as a
    /// stand-in named by its listing, as before.
    static func cache(_ product: ShopProduct, placement: UUID, project: UUID) async {
        let dest = url(placement: placement, project: project)
        guard !FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)), let src = product.imageURL else { return }
        let data: Data?
        if src.isFileURL {   // bundled demo image (VibeDemo); never any other file, since it gets uploaded
            data = bundled(src).flatMap { try? Data(contentsOf: $0) }
        } else if src.scheme == "https",
                  let (d, r) = try? await URLSession.shared.data(for: URLRequest(url: src, timeoutInterval: 10)),
                  (r as? HTTPURLResponse)?.statusCode == 200, d.count <= maxDownload {
            data = d
        } else {
            data = nil
        }
        guard let data, let jpeg = await Task.detached(operation: { downscaled(data) }).value else { return }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? jpeg.write(to: dest, options: .atomic)
    }

    /// Decodes at most 768 px (ImageIO thumbnail), so a 15 MB listing photo never becomes a full-size bitmap.
    private static func downscaled(_ data: Data) -> Data? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 768] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image).uploadJPEG(maxEdge: 768)
    }

    /// `url` if it's inside the app bundle. The stored path goes stale on reinstall (the bundle moves), so a
    /// missing file is looked up again by name; that result is checked too.
    private static func bundled(_ url: URL) -> URL? {
        func inBundle(_ url: URL) -> Bool {
            var root = Bundle.main.bundleURL.standardizedFileURL.path(percentEncoded: false)
            if !root.hasSuffix("/") { root += "/" }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.hasPrefix(root) && FileManager.default.fileExists(atPath: path)
        }
        if inBundle(url) { return url }
        let name = url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty, let found = Bundle.main.url(forResource: name, withExtension: url.pathExtension) else { return nil }
        return inBundle(found) ? found : nil
    }
}
