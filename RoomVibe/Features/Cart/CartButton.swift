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
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beam = 0

    private struct Beam { var scale = 1.0; var ring = 0.0 }

    var body: some View {
        Button(action: action) {
            Image(systemName: "cart").font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(ink)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
                .overlay(Circle().strokeBorder(stroke, lineWidth: lineWidth))
                .overlay(alignment: .topTrailing) {
                    Text("\(count)").font(.forma(11, bold: true)).foregroundStyle(Theme.onSage)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                        .background(Theme.sage, in: Capsule())
                        .offset(x: 4, y: -4)
                        .contentTransition(.numericText(value: Double(count)))
                }
        }
        .buttonStyle(.plain)
        .keyframeAnimator(initialValue: Beam(), trigger: beam) { view, v in
            view.scaleEffect(v.scale)
                .background {
                    Circle().strokeBorder(Theme.sage, lineWidth: 2)
                        .scaleEffect(1 + v.ring).opacity(0.5 * (1 - v.ring)).allowsHitTesting(false)
                }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.18, duration: 0.13)
                SpringKeyframe(1, duration: 0.2)
            }
            KeyframeTrack(\.ring) { LinearKeyframe(1, duration: 0.6) }
        }
        .onChange(of: count) { old, new in if new > old && !reduceMotion { beam += 1 } }
        .accessibilityLabel("Cart, \(count) item\(count == 1 ? "" : "s")")
        .accessibilityIdentifier("cartButton")
    }
}
