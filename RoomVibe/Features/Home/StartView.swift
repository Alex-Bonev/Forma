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

/// Splash and busy screen (Paper "0b · Loading"). The sage square slides clockwise around the inside of the ring,
/// keeping the logo's 14-unit gap to the ring, 1.2 s linear, loops. Reduced motion holds it still.
struct LoadingView: View {
    var status: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let period = 1.2

    /// Center of the sage square on the logo's 200-unit grid after `loops` laps. The ring's inner edge spans
    /// 28...172, the square is 60 wide and keeps the logo's 14-unit gap (resting center 128), so its center runs
    /// along the 72...128 rectangle. Starts bottom-right,
    /// then bottom-left, top-left, top-right (clockwise on screen).
    static func position(at loops: Double) -> CGPoint {
        let lo = 72.0, hi = 128.0
        let u = (loops - loops.rounded(.down)) * 4   // 0..<4: which side, and how far along it
        let f = u - u.rounded(.down)
        switch Int(u) {
        case 0: return CGPoint(x: hi - (hi - lo) * f, y: hi)   // bottom edge, moving left
        case 1: return CGPoint(x: lo, y: hi - (hi - lo) * f)   // left edge, moving up
        case 2: return CGPoint(x: lo + (hi - lo) * f, y: lo)   // top edge, moving right
        default: return CGPoint(x: hi, y: lo + (hi - lo) * f)  // right edge, moving down
        }
    }

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                Logo(size: 96, square: Self.position(at: t / Self.period))
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
