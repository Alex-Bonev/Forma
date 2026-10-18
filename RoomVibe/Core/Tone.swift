import SwiftUI
import ModelIO
import CoreGraphics

/// Fullscreen backdrop that contrasts with what it frames: dark subject on a light palette color, light on a dark one.
enum Tone {
    nonisolated(unsafe) fileprivate static var textureCache: [String: Double] = [:]   // body-thread only

    static func backdrop(subjectLuminance l: Double?) -> Color {
        (l ?? 0.7) < 0.5 ? Theme.ground : Theme.wood
    }

    /// Floating-chrome colors that stay visible on `backdrop`: palette-light pills on the dark backdrop, dark pills on the light one.
    static func chrome(on backdrop: Color) -> (fill: Color, ink: Color) {
        backdrop == Theme.ground ? (Theme.wood, Theme.ground) : (Theme.ground.opacity(0.9), Theme.ink)
    }

    /// Mean Rec. 709 luma (0...1) of a texture file, by drawing it into one pixel.
    static func luminance(ofImageNamed name: String) -> Double? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return luminance(of: image)
    }

    static func luminance(of image: CGImage) -> Double {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.interpolationQuality = .medium
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255
    }

    static func luminance(of color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Mean base-color luma over a model's materials (texture or flat color); nil if none could be read.
    static func luminance(ofModelAt url: URL) -> Double? {
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        var sum = 0.0, n = 0.0
        func visit(_ o: MDLObject) {
            if let mesh = o as? MDLMesh {
                for case let sub as MDLSubmesh in mesh.submeshes ?? [] {
                    guard let p = sub.material?.property(with: .baseColor) else { continue }
                    if p.type == .texture, let tex = p.textureSamplerValue?.texture,
                       let img = tex.imageFromTexture()?.takeUnretainedValue() {
                        sum += luminance(of: img); n += 1
                    } else if p.type == .color || p.type == .float3, let c = p.color ?? nil {
                        sum += luminance(of: UIColor(cgColor: c)); n += 1
                    }
                }
            }
            o.children.objects.forEach(visit)
        }
        asset.childObjects(of: MDLObject.self).forEach(visit)
        return n > 0 ? sum / n : nil
    }
}

extension Finish {
    /// Mean brightness of the finish as rendered (texture average, else its flat color).
    var luminance: Double {
        guard let texture else { return Tone.luminance(of: color) }
        if let l = Tone.textureCache[texture] { return l }
        let l = Tone.luminance(ofImageNamed: texture) ?? Tone.luminance(of: color)
        Tone.textureCache[texture] = l
        return l
    }
}
