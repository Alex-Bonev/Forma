import SwiftUI
import RealityKit

/// Apple's guided Object Capture flow, then on-device PhotogrammetrySession -> USDZ.
/// Pattern follows Apple's "Scanning objects using Object Capture" sample, stripped down.
struct ObjectScanView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model = ObjectScanModel()
    @State private var name = ""

    var body: some View {
        ZStack {
            switch model.phase {
            case .capturing:
                ObjectCaptureView(session: model.session)
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) { captureControls }
            case .reconstructing(let fraction):
                VStack(spacing: 16) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 240)
                    Text("Reconstructing… \(Int(fraction * 100))%").font(.headline).monospacedDigit()
                    Text("Takes a few minutes. Keep the app open.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .done:
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                    TextField("Store chair", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Button("Save to Library") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                }
                .sensoryFeedback(.success, trigger: model.phase)
            case .failed(let message):
                ContentUnavailableView("Capture failed", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .overlay(alignment: .topLeading) {
            Button("Cancel") { model.cancel(); dismiss() }
                .buttonStyle(.borderedProminent).tint(.black.opacity(0.5)).padding()
        }
        .task { model.start() }
    }

    @ViewBuilder private var captureControls: some View {
        Group {
            switch model.session.state {
            case .ready:
                Button("Continue") { _ = model.session.startDetecting() }
            case .detecting:
                Button("Start Capture") { model.session.startCapturing() }
            case .capturing:
                Button("Finish") { model.session.finish() }
            default:
                EmptyView()
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.bottom, 40)
    }

    private func save() async {
        let size = await model.boundingBox()
        try? store.addObject(ScannedObject(id: model.id, name: name.isEmpty ? "Object" : name,
                                           modelFile: ObjectScanModel.modelName, boundingBox: size))
        dismiss()
    }
}

@Observable
@MainActor
final class ObjectScanModel {
    enum Phase: Equatable { case capturing, reconstructing(Double), done, failed(String) }

    static let modelName = "model.usdz"
    let id = UUID()
    let session = ObjectCaptureSession()
    var phase = Phase.capturing

    private var dir: URL { ProjectStore.objectDir(id) }
    private var images: URL { dir.appending(path: "Images/") }
    private var checkpoint: URL { dir.appending(path: "Checkpoint/") }
    private var modelURL: URL { dir.appending(path: Self.modelName) }
    private var photogrammetry: PhotogrammetrySession?

    func start() {
        do {
            for d in [images, checkpoint] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            var config = ObjectCaptureSession.Configuration()
            config.checkpointDirectory = checkpoint
            session.start(imagesDirectory: images, configuration: config)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        Task {
            for await state in session.stateUpdates {
                switch state {
                case .completed: await reconstruct()
                case .failed(let error): phase = .failed(error.localizedDescription)
                default: break
                }
            }
        }
    }

    func cancel() {
        session.cancel()
        photogrammetry?.cancel()
        // Unsaved scan: drop its files. Saved scans keep the same folder (id is reused).
        if phase != .done { try? FileManager.default.removeItem(at: dir) }
    }

    private func reconstruct() async {
        phase = .reconstructing(0)
        do {
            var config = PhotogrammetrySession.Configuration()
            config.checkpointDirectory = checkpoint
            let ps = try PhotogrammetrySession(input: images, configuration: config)
            photogrammetry = ps
            try ps.process(requests: [.modelFile(url: modelURL)])
            for try await output in ps.outputs {
                switch output {
                case .requestProgress(_, let fraction): phase = .reconstructing(fraction)
                case .requestError(_, let error): phase = .failed(error.localizedDescription)
                case .processingComplete:
                    if case .reconstructing = phase { phase = .done }
                    // Photos are no longer needed once the USDZ exists.
                    try? FileManager.default.removeItem(at: images)
                    try? FileManager.default.removeItem(at: checkpoint)
                default: break
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func boundingBox() async -> SIMD3<Float> {
        guard let entity = try? await Entity(contentsOf: modelURL) else { return [0.5, 0.5, 0.5] }
        return entity.visualBounds(relativeTo: nil).extents
    }
}
