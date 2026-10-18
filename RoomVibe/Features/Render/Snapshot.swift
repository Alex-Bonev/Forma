import UIKit

/// Screenshot of the Designer's 3D view, without the SwiftUI chrome around it (toolbar, tray, labels).
/// Call while the Designer is on screen, e.g. from its "Make it real" button, before presenting RenderView.
///
/// Finds the view that hosts RealityKit's Metal layer and draws only that view, so the AI gets the room
/// and nothing else. Falls back to the whole key window if no Metal view is found.
// VERIFY: confirmed in Simulator (iOS 26) that drawHierarchy captures the RealityView content; re-check on device.
@MainActor
/// `opaque: false` keeps the empty background transparent (room thumbnails draw it over their own color).
func captureDesignerSnapshot(opaque: Bool = true) -> UIImage? {
    guard let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap(\.windows)
        .first(where: \.isKeyWindow) else { return nil }
    let target = largestMetalView(in: window) ?? window
    guard target.bounds.width > 0, target.bounds.height > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.opaque = opaque
    return UIGraphicsImageRenderer(bounds: target.bounds, format: format).image { _ in
        target.drawHierarchy(in: target.bounds, afterScreenUpdates: true)
    }
}

/// Biggest on-screen view whose layer tree contains a CAMetalLayer.
@MainActor
private func largestMetalView(in root: UIView) -> UIView? {
    var best: UIView?
    func area(_ v: UIView) -> CGFloat { v.bounds.width * v.bounds.height }
    func hasMetal(_ layer: CALayer) -> Bool {
        layer is CAMetalLayer || (layer.sublayers ?? []).contains { $0 is CAMetalLayer }
    }
    func visit(_ v: UIView) {
        guard !v.isHidden, v.alpha > 0 else { return }
        if hasMetal(v.layer), area(v) > (best.map(area) ?? 0) { best = v }
        v.subviews.forEach(visit)
    }
    visit(root)
    return best
}
