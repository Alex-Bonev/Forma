import SwiftUI
import Network

/// First-launch screen (Paper "0 · Start").
struct StartView: View {
    let start: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Logo(size: 112)
            Wordmark(size: 56).padding(.top, 40)
            Text("Scan a room. Scan an object.\nSee if it fits.")
                .font(.forma(14)).multilineTextAlignment(.center).foregroundStyle(Theme.ink)
                .lineSpacing(6).padding(.top, 28)
            Spacer()
            Button(action: start) { HStack(spacing: 10) { Text("Start now"); Image(systemName: "arrow.right") } }
                .buttonStyle(PillButtonStyle())
                .frame(height: 56)
            Text("Scanning needs an iPhone Pro with LiDAR").font(.forma(11)).foregroundStyle(Theme.ink)
                .padding(.top, 14)
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
    }
}

/// Splash and busy screen (Paper "0b · Loading"). The sage square circles the ring clockwise:
/// path radius 40 of 200, 1.2 s linear, loops. Reduced motion holds it still.
struct LoadingView: View {
    /// Small line under the wordmark; nil shows just "forma".
    var status: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let period = 1.2

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let a = t / Self.period * 2 * .pi + .pi / 4   // starts bottom-right; +angle is clockwise on screen
                Logo(size: 96, square: CGPoint(x: 100 + 40 * cos(a), y: 100 + 40 * sin(a)))
            }
            VStack(spacing: 4) {
                Spacer()
                Text("forma").font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
                if let status { Text(status).font(.forma(12)).foregroundStyle(Theme.muted) }
            }
            .padding(.bottom, 56)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.map { "Loading. \($0)" } ?? "Loading")
    }
}

/// Live connectivity, for the splash's "No connection · retrying" line.
@MainActor @Observable
final class Connectivity {
    private(set) var online = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.online = path.status == .satisfied }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    deinit { monitor.cancel() }
}
