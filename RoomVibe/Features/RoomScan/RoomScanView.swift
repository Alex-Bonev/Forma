import SwiftUI
import RoomPlan

/// Full-screen RoomPlan capture. Done -> Apple's processing preview -> name -> saved.
struct RoomScanView: View {
    var onSaved: (Project) -> Void
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var scanner = RoomScanner()
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        RoomCaptureRepresentable(view: scanner.view)
            .ignoresSafeArea()
            .onAppear { scanner.start() }
            .overlay(alignment: .top) {
                HStack {
                    Button("Cancel") { scanner.stop(); dismiss() }
                    Spacer()
                    if !scanner.stopped {
                        Button("Done") { scanner.stop() }.bold()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.black.opacity(0.5))
                .padding()
            }
            .alert("Name this room", isPresented: .constant(scanner.result != nil && error == nil)) {
                TextField("Living Room", text: $name)
                Button("Save") { save() }
                Button("Discard", role: .destructive) { dismiss() }
            }
            .alert("Scan failed", isPresented: .constant(error != nil)) {
                Button("OK") { dismiss() }
            } message: { Text(error ?? "") }
            .onChange(of: scanner.error) { error = scanner.error }
    }

    private func save() {
        guard let room = scanner.result else { return }
        do {
            let project = try store.addRoom(name: name.isEmpty ? "Room" : name, model: RoomModel(room)) { dir in
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
    let view = RoomCaptureView(frame: .zero)
    var result: CapturedRoom?
    var error: String?
    var stopped = false

    override init() {
        super.init()
        view.delegate = self
    }

    // RoomCaptureViewDelegate inherits NSCoding; never archived.
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    func start() { view.captureSession.run(configuration: RoomCaptureSession.Configuration()) }
    func stop() { stopped = true; view.captureSession.stop() }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {
        if let error { self.error = error.localizedDescription } else { result = processedResult }
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
