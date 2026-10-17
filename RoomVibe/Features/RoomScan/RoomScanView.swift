import SwiftUI
import RoomPlan

/// Full-screen RoomPlan capture: scan -> Done -> Apple's processed preview -> Save + name -> Designer.
struct RoomScanView: View {
    var onSaved: (Project) -> Void
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    // Created once on appear: a @State default would build a new RoomCaptureView on every parent re-render.
    @State private var scanner: RoomScanner?
    @State private var naming = false
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let scanner {
                RoomCaptureRepresentable(view: scanner.view).ignoresSafeArea()
                controls(scanner)
            }
        }
        .onAppear {
            guard scanner == nil else { return }
            let s = RoomScanner()
            scanner = s
            s.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            scanner?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scanner?.error) { _, new in error = new }
        .alert("Name this room", isPresented: $naming) {
            TextField("Living Room", text: $name)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't save the scan", isPresented: .constant(error != nil)) {
            Button("OK") { dismiss() }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private func controls(_ scanner: RoomScanner) -> some View {
        VStack {
            HStack {
                Button(scanner.result == nil ? "Cancel" : "Discard") { dismiss() }
                Spacer()
                if scanner.phase == .scanning {
                    Button("Done") { scanner.stop() }.bold()
                }
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .padding()

            Spacer()

            switch scanner.phase {
            case .scanning:
                hint("Move slowly around the room. Point at every wall and piece of furniture.")
            case .processing:
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Building your room…")
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 40)
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

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 24).padding(.bottom, 40)
    }

    private func save() {
        guard let room = scanner?.result else { return }
        let model = RoomModel(room)
        // RoomBuilder needs walls to find the floor and room bounds.
        guard !model.walls.isEmpty else {
            error = "No walls were detected. Try scanning again and point at every wall."
            return
        }
        do {
            let project = try store.addRoom(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Room" : name,
                                            model: model) { dir in
                // Raw RoomPlan output kept for later (model substitution, sharing, QuickLook).
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

@Observable
final class RoomScanner: NSObject, RoomCaptureViewDelegate {
    enum Phase { case scanning, processing, review }

    let view = RoomCaptureView(frame: .zero)
    private(set) var phase = Phase.scanning
    private(set) var result: CapturedRoom?
    private(set) var error: String?

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

    func cancel() {
        if phase == .scanning { view.captureSession.stop() }
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
        if let error { self.error = error.localizedDescription; return false }
        return true
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
            objects: room.objects.map {
                Box(label: String(describing: $0.category), dimensions: $0.dimensions, transform: $0.transform)
            }
        )
    }
}
