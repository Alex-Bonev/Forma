import SwiftUI

/// Cart icon with a count badge (Paper "cart exists" frames). Beams once when the count goes up: the icon scales
/// 1 to 1.18 and back, and a sage ring grows and fades (Paper motion spec "Add to cart"). Reduced motion: no beam.
struct CartButton: View {
    let count: Int
    var size: CGFloat = 48
    var fill: Color = .clear
    var ink: Color = Theme.ink
    var stroke: Color = Theme.ink
    var lineWidth: CGFloat = 1
    /// Inside a toolbar item the system already draws the glass circle: no fill or stroke, everything stays in the frame.
    var plain = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beam = 0

    private struct Beam { var scale = 1.0; var ring = 0.0 }

    var body: some View {
        Button(action: action) {
            disc
                .keyframeAnimator(initialValue: Beam(), trigger: beam) { view, v in
                    view.scaleEffect(v.scale)
                        .background {
                            // Plain: the ring starts at 60% of the frame and ends inside it, so the toolbar never clips it.
                            Circle().strokeBorder(Theme.sage, lineWidth: 2)
                                .frame(width: size * (plain ? 0.6 : 1), height: size * (plain ? 0.6 : 1))
                                .scaleEffect(1 + v.ring * (plain ? 0.6 : 1)).opacity(0.5 * (1 - v.ring)).allowsHitTesting(false)
                        }
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        SpringKeyframe(plain ? 1.12 : 1.18, duration: 0.13)
                        SpringKeyframe(1, duration: 0.2)
                    }
                    KeyframeTrack(\.ring) { LinearKeyframe(1, duration: 0.6) }
                }
                .overlay(alignment: .topTrailing) { badge }
                .padding(plain ? 0 : 6)   // room for the badge and ring inside the button's own frame
        }
        .buttonStyle(.plain)
        .padding(plain ? 0 : -6)   // keeps the visual layout size
        .onChange(of: count) { old, new in if new > old && !reduceMotion { beam += 1 } }
        .accessibilityLabel("Cart, \(count) item\(count == 1 ? "" : "s")")
        .accessibilityIdentifier("cartButton")
    }

    private var disc: some View {
        Image(systemName: "cart").font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(plain ? .clear : fill, in: Circle())
            .overlay { if !plain { Circle().strokeBorder(stroke, lineWidth: lineWidth) } }
    }

    private var badge: some View {
        Text("\(count)").font(.forma(plain ? 10 : 11, bold: true)).foregroundStyle(Theme.onSage)
            .padding(.horizontal, plain ? 3 : 6).frame(minWidth: plain ? 16 : 20, minHeight: plain ? 16 : 20)
            .background(Theme.sage, in: Capsule())
            .padding(plain ? 5 : 0)   // plain sits in the round glass, whose corner clips a badge flush to the square's edge
            .offset(x: plain ? 0 : 4, y: plain ? 0 : -4)
            .contentTransition(.numericText(value: Double(count)))
    }
}
