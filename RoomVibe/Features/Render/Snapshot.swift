import UIKit

/// Screenshot of the Designer's 3D view, without the SwiftUI chrome around it (toolbar, tray, labels).
/// Call while the Designer is on screen, e.g. from its "Make it real" button, before presenting RenderView.
///
/// Finds the view that hosts RealityKit's Metal layer and draws only that view, so the AI gets the room
/// and nothing else. Falls back to the whole key window if no Metal view is found (unless told not to).
// VERIFY: confirmed in Simulator (iOS 26) that drawHierarchy captures the RealityView content; re-check on device.
@MainActor
/// `opaque: false` keeps the empty background transparent (room thumbnails draw it over their own color).
/// `size`: the 3D view's size as SwiftUI measured it. On device, glass/blur chrome is Metal-backed too, so the
/// biggest Metal view can be the whole screen; matching the size picks the RealityView. `fallbackToWindow: false`
/// returns nil instead of a full-screen capture (room thumbnails must show only the room).
func captureDesignerSnapshot(opaque: Bool = true, size: CGSize? = nil, fallbackToWindow: Bool = true) -> UIImage? {
    guard let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap(\.windows)
        .first(where: \.isKeyWindow) else { return nil }
    guard let target = metalView(in: window, size: size) ?? (fallbackToWindow ? window : nil),
          target.bounds.width > 0, target.bounds.height > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.opaque = opaque
    return UIGraphicsImageRenderer(bounds: target.bounds, format: format).image { _ in
        target.drawHierarchy(in: target.bounds, afterScreenUpdates: true)
    }
}

/// On-screen view with a CAMetalLayer in its layer tree (a few levels deep): the one matching `size` if given,
/// else the biggest.
@MainActor
private func metalView(in root: UIView, size: CGSize?) -> UIView? {
    var best: UIView?
    func area(_ v: UIView) -> CGFloat { v.bounds.width * v.bounds.height }
    func hasMetal(_ layer: CALayer, depth: Int = 0) -> Bool {
        layer is CAMetalLayer || (depth < 3 && (layer.sublayers ?? []).contains { hasMetal($0, depth: depth + 1) })
    }
    func fits(_ v: UIView) -> Bool {
        guard let size else { return true }
        return abs(v.bounds.width - size.width) < 4 && abs(v.bounds.height - size.height) < 4
    }
    func visit(_ v: UIView) {
        guard !v.isHidden, v.alpha > 0 else { return }
        if hasMetal(v.layer), fits(v) {
            // With a size: the innermost match (smallest); without: the biggest, as before.
            if best == nil || (size == nil ? area(v) > area(best!) : area(v) <= area(best!)) { best = v }
        }
        v.subviews.forEach(visit)
    }
    visit(root)
    return best
}
