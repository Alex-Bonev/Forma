import SwiftUI
import RoomPlan
import simd

/// Full-screen RoomPlan capture: scan -> Done -> Apple's processed preview -> Save + name -> Designer.
struct RoomScanView: View {
    var onSaved: (Project) -> Void
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    // Created on appear (and on "Scan Again"): a @State default would build a new RoomCaptureView
    // on every parent re-render.
    @State private var scanner: RoomScanner?
    @State private var naming = false
    @State private var confirmDiscard = false
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let scanner {
                RoomCaptureRepresentable(view: scanner.view)
                    .id(ObjectIdentifier(scanner))
                    .ignoresSafeArea()
                controls(scanner)
            }
        }
        .environment(\.colorScheme, .dark)   // camera UI: legible chrome over any feed
        .onAppear {
            if scanner == nil { startScanner() }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            scanner?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scanner?.error) { _, new in if let new { error = new } }
        .alert("Name this room", isPresented: $naming) {
            TextField("Living Room", text: $name)
            Button("Save") { DispatchQueue.main.async { save() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Scan failed", isPresented: .constant(error != nil)) {
            Button("Scan Again") { error = nil; startScanner() }
            Button("Close", role: .cancel) { error = nil; dismiss() }
        } message: { Text(error ?? "") }
        .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Scan", role: .destructive) { dismiss() }
        }
    }

    private func startScanner() {
        scanner?.cancel()
        let s = RoomScanner()
        scanner = s
        s.start()
    }

    @ViewBuilder private func controls(_ scanner: RoomScanner) -> some View {
        VStack {
            HStack {
                ScanChromeButton(title: scanner.result == nil ? "Cancel" : "Discard") {
                    if scanner.result == nil { dismiss() } else { confirmDiscard = true }
                }
                Spacer()
                if scanner.phase == .scanning {
                    ScanChromeButton(title: "Done", prominent: true) { scanner.stop() }
                }
            }
            .padding()

            Spacer()

            switch scanner.phase {
            case .scanning:
                Text("Move slowly around the room. Point at every wall and piece of furniture.")
                    .scanCaption()
            case .processing:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Building your room…")
                }
                .scanCaption()
            case .review:
                Button { naming = true } label: {
                    Label("Save Room", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24).padding(.bottom, 24)
                .sensoryFeedback(.success, trigger: scanner.phase)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: scanner.phase)
    }

    private func save() {
        guard let room = scanner?.result else { return }
        let model = RoomModel(room).axisAligned()
        // RoomBuilder needs walls to find the floor and room bounds.
        guard !model.walls.isEmpty else {
            error = "No walls were detected. Point at every wall while scanning."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let project = try store.addRoom(name: trimmed.isEmpty ? "Room" : trimmed, model: model) { dir in
                // Raw RoomPlan output kept for later (model substitution, sharing, QuickLook).
                // Note: these are in RoomPlan's original frame; room.json is rotated by axisAligned().
                try JSONEncoder().encode(room).write(to: dir.appending(path: "captured.json"))
                try? room.export(to: dir.appending(path: "room.usdz"))
            }
            dismiss()
            onSaved(project)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Shared camera-screen chrome (room + object scan)

/// Text button on a material capsule: readable over bright walls and dark rooms alike.
struct ScanChromeButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(prominent ? .semibold : .regular))
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Instruction / status text floating over the camera feed.
    func scanCaption() -> some View {
        font(.footnote.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 24).padding(.bottom, 32)
    }
}

@MainActor
@Observable
final class RoomScanner: NSObject, @preconcurrency RoomCaptureViewDelegate {
    enum Phase { case scanning, processing, review }

    let view = RoomCaptureView(frame: .zero)
    private(set) var phase = Phase.scanning
    private(set) var result: CapturedRoom?
    private(set) var error: String?
    private var cancelled = false

    override init() {
        super.init()
        view.delegate = self
    }

    // RoomCaptureViewDelegate inherits NSCoding; never archived.
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    func start() { view.captureSession.run(configuration: RoomCaptureSession.Configuration()) }

    func stop() {
        phase = .processing
        view.captureSession.stop()
    }

    /// Stop without processing: the scan is being thrown away.
    func cancel() {
        cancelled = true
        if phase == .scanning { view.captureSession.stop() }
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
        // Errors here (tracking lost, device too hot, room too big) end the session.
        if let error, !cancelled { self.error = error.localizedDescription }
        return error == nil && !cancelled
    }

    func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {
        if let error {
            self.error = error.localizedDescription
        } else {
            result = processedResult
            phase = .review
        }
    }
}

struct RoomCaptureRepresentable: UIViewRepresentable {
    let view: RoomCaptureView
    func makeUIView(context: Context) -> RoomCaptureView { view }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

extension RoomModel {
    init(_ room: CapturedRoom) {
        func box(_ s: CapturedRoom.Surface, _ label: String) -> Box {
            Box(label: label, dimensions: s.dimensions, transform: s.transform)
        }
        self.init(
            walls: room.walls.map { box($0, "wall") },
            doors: room.doors.map { box($0, "door") },
            windows: room.windows.map { box($0, "window") },
            openings: room.openings.map { box($0, "opening") },
            objects: room.objects.map { o in
                var b = Box(label: String(describing: o.category), dimensions: o.dimensions, transform: o.transform)
                // Type-qualified so "existing" (arm vs back) and "lShaped" (sofa vs table) stay unambiguous.
                b.attributes = o.attributes.map { "\(type(of: $0)).\($0.rawValue)" }
                return b
            },
            floorOutline: Self.outline(of: room.floors)
        )
    }

    /// Largest floor's polygon in world space (polygonCorners are in the surface's own frame).
    private static func outline(of floors: [CapturedRoom.Surface]) -> [SIMD3<Float>]? {
        guard let f = floors.max(by: { $0.dimensions.x * $0.dimensions.y < $1.dimensions.x * $1.dimensions.y })
        else { return nil }
        return f.polygonCorners.map { c in
            let p = f.transform * SIMD4(c, 1)
            return SIMD3(p.x, p.y, p.z)
        }
    }
}
