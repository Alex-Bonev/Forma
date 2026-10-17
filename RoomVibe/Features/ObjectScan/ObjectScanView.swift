import SwiftUI
import RealityKit
import QuickLook
import QuickLookThumbnailing

/// Apple's guided Object Capture flow, then on-device PhotogrammetrySession -> USDZ.
/// Follows Apple's "Scanning objects using Object Capture" sample: ready -> detecting (fit box) -> capturing
/// (scan passes, optional flip) -> finish -> reconstruct -> preview + name -> library.
struct ObjectScanView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    // Created once on appear: a @State default would build a new ObjectCaptureSession on every parent re-render.
    @State private var model: ObjectScanModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                ObjectScanContent(model: model) { object in
                    try? store.addObject(object)
                    dismiss()
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Button(model?.phase == .done ? "Discard" : "Cancel") { model?.cancel(); dismiss() }
                .buttonStyle(.bordered).tint(.white).padding()
        }
        .onAppear {
            guard model == nil else { return }
            let m = ObjectScanModel()
            model = m
            m.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

private struct ObjectScanContent: View {
    let model: ObjectScanModel
    var onSave: (ScannedObject) -> Void
    @State private var name = ""
    @State private var previewURL: URL?

    var body: some View {
        switch model.phase {
        case .capturing:
            if let session = model.session {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
                    .overlay { CaptureOverlay(session: session) }
            }
        case .reconstructing(let fraction, let remaining):
            VStack(spacing: 14) {
                ProgressView(value: fraction).frame(maxWidth: 240).tint(.white)
                Text("Building 3D model… \(Int(fraction * 100))%")
                    .font(.headline).monospacedDigit()
                Text(remaining.map { "About \(Duration.seconds($0).formatted(.units(allowed: [.minutes, .seconds], width: .wide, maximumUnitCount: 1))) left. Keep the app open." }
                     ?? "This takes a few minutes. Keep the app open.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding()
        case .done:
            VStack(spacing: 20) {
                Button { previewURL = model.modelURL } label: {
                    Group {
                        if let thumb = model.thumbnail {
                            Image(uiImage: thumb).resizable().scaledToFit()
                        } else {
                            Image(systemName: "cube.fill").font(.system(size: 64)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 220, height: 220)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arkit").padding(8).background(.ultraThinMaterial, in: Circle()).padding(10)
                    }
                }
                .accessibilityLabel("Preview in 3D")
                Text("Tap to preview in 3D or AR").font(.footnote).foregroundStyle(.secondary)
                TextField("Store chair", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .submitLabel(.done)
                Button {
                    onSave(model.scannedObject(named: name))
                } label: {
                    Label("Save to Library", systemImage: "checkmark").frame(maxWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .foregroundStyle(.white)
            .sensoryFeedback(.success, trigger: model.phase)
            .quickLookPreview($previewURL)
        case .failed(let message):
            ContentUnavailableView {
                Label("Scan failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            .foregroundStyle(.white)
        }
    }
}

/// Instructions, live feedback and the primary action for each capture state.
private struct CaptureOverlay: View {
    let session: ObjectCaptureSession
    @State private var pass = 1

    var body: some View {
        VStack {
            HStack {
                Spacer()
                if session.state == .capturing {
                    Text("Pass \(pass) · \(session.numberOfShotsTaken) photos")
                        .font(.footnote.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding()

            if let message = feedbackMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }

            Spacer()

            if session.state == .capturing && session.userCompletedScanPass {
                passComplete
            } else {
                VStack(spacing: 14) {
                    if let instruction { Text(instruction).font(.footnote.weight(.medium)).multilineTextAlignment(.center) }
                    actions
                }
                .padding(.horizontal, 24).padding(.bottom, 32)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: feedbackMessage)
        .animation(.spring(duration: 0.3, bounce: 0), value: session.userCompletedScanPass)
    }

    private var instruction: String? {
        switch session.state {
        case .initializing: "Starting camera…"
        case .ready: "Point the camera at the object and center it in the circle."
        case .detecting: "Drag the box edges so it fits the object snugly."
        case .capturing: "Walk slowly around the object. Keep it in frame."
        case .finishing: "Finishing capture…"
        default: nil
        }
    }

    @ViewBuilder private var actions: some View {
        switch session.state {
        case .ready:
            primary("Continue") { _ = session.startDetecting() }
        case .detecting:
            HStack(spacing: 12) {
                Button("Reset Box") { _ = session.resetDetection() }.buttonStyle(.bordered).controlSize(.large)
                primary("Start Capture") { session.startCapturing() }
            }
        case .capturing:
            // Finishing before one full pass gives a poor model; still allowed for demos under time pressure.
            Button("Finish Early") { session.finish() }.buttonStyle(.bordered).controlSize(.large)
        case .initializing, .finishing:
            ProgressView().tint(.white)
        default:
            EmptyView()
        }
    }

    /// Apple recommends up to three passes; flipping captures the underside.
    private var passComplete: some View {
        VStack(spacing: 12) {
            Text("Pass \(pass) complete").font(.headline)
            Text("More passes from different heights improve detail. Flip the object to capture its bottom.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if pass < 3 {
                HStack(spacing: 12) {
                    Button("Flip Object") { pass += 1; session.beginNewScanPassAfterFlip() }
                    Button("Don't Flip") { pass += 1; session.beginNewScanPass() }
                }
                .buttonStyle(.bordered)
            }
            primary("Finish") { session.finish() }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 16).padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(minWidth: 140) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }

    private var feedbackMessage: String? {
        let f = session.feedback
        if f.contains(.environmentTooDark) { return "Too dark. Add more light." }
        if f.contains(.environmentLowLight) { return "Low light. More light gives a better model." }
        if f.contains(.movingTooFast) { return "Slow down." }
        if f.contains(.objectTooClose) { return "Move farther away." }
        if f.contains(.objectTooFar) { return "Move closer." }
        if f.contains(.outOfFieldOfView) { return "Keep the object in frame." }
        if f.contains(.objectNotDetected) { return "Can't find the object. Center it in the circle." }
        if f.contains(.objectNotFlippable) { return "This object may not be flippable. Scan it again without flipping." }
        if f.contains(.overCapturing) { return "Enough photos here. Move to a new angle." }
        return nil
    }
}

@Observable
@MainActor
final class ObjectScanModel {
    enum Phase: Equatable { case capturing, reconstructing(Double, TimeInterval?), done, failed(String) }

    static let modelName = "model.usdz"
    static let thumbnailName = "thumb.jpg"   // Objects/<id>/thumb.jpg, read by the library UI
    let id = UUID()
    private(set) var session: ObjectCaptureSession?
    private(set) var phase = Phase.capturing
    private(set) var thumbnail: UIImage?
    private var boundingBox: SIMD3<Float> = [0.5, 0.5, 0.5]
    private var photogrammetry: PhotogrammetrySession?
    private var task: Task<Void, Never>?

    private var dir: URL { ProjectStore.objectDir(id) }
    private var images: URL { dir.appending(path: "Images/") }
    private var checkpoint: URL { dir.appending(path: "Checkpoint/") }
    var modelURL: URL { dir.appending(path: Self.modelName) }

    func start() {
        do {
            for d in [images, checkpoint] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        let session = ObjectCaptureSession()
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = checkpoint
        session.start(imagesDirectory: images, configuration: config)
        self.session = session
        task = Task {
            for await state in session.stateUpdates {
                switch state {
                case .completed:
                    // Release the capture session (camera + memory) before the heavy reconstruction step.
                    self.session = nil
                    await reconstruct()
                    return
                case .failed(let error):
                    self.session = nil
                    phase = .failed(error.localizedDescription)
                    return
                default: break
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        session?.cancel()
        photogrammetry?.cancel()
        // Saved scans keep their folder; anything else is dropped.
        if !saved { try? FileManager.default.removeItem(at: dir) }
    }

    private var saved = false

    func scannedObject(named name: String) -> ScannedObject {
        saved = true
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return ScannedObject(id: id, name: trimmed.isEmpty ? "Object" : trimmed, modelFile: Self.modelName, boundingBox: boundingBox)
    }

    private func reconstruct() async {
        phase = .reconstructing(0, nil)
        do {
            var config = PhotogrammetrySession.Configuration()
            config.checkpointDirectory = checkpoint
            let ps = try PhotogrammetrySession(input: images, configuration: config)
            photogrammetry = ps
            try ps.process(requests: [.modelFile(url: modelURL)])
            for try await output in ps.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    if case .reconstructing(_, let eta) = phase { phase = .reconstructing(fraction, eta) }
                case .requestProgressInfo(_, let info):
                    if case .reconstructing(let f, _) = phase { phase = .reconstructing(f, info.estimatedRemainingTime) }
                case .requestError(_, let error):
                    phase = .failed(error.localizedDescription)
                case .processingCancelled:
                    return
                case .processingComplete:
                    guard case .reconstructing = phase else { return }
                    await finishModel()
                default: break
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Thumbnail + real-world size, then drop the photos (only the USDZ is kept).
    private func finishModel() async {
        if let entity = try? await Entity(contentsOf: modelURL) {
            boundingBox = entity.visualBounds(relativeTo: nil).extents
        }
        let request = QLThumbnailGenerator.Request(fileAt: modelURL, size: CGSize(width: 512, height: 512),
                                                   scale: 1, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = rep.uiImage
            try? rep.uiImage.jpegData(compressionQuality: 0.85)?.write(to: dir.appending(path: Self.thumbnailName))
        }
        try? FileManager.default.removeItem(at: images)
        try? FileManager.default.removeItem(at: checkpoint)
        phase = .done
    }
}
