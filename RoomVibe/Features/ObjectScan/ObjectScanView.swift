import SwiftUI
import RealityKit
import QuickLook
import QuickLookThumbnailing

/// Apple's guided Object Capture flow, then on-device PhotogrammetrySession -> USDZ.
/// Follows Apple's "Scanning objects using Object Capture" sample: ready -> detecting (fit box) -> capturing
/// (scan passes, optional flip) -> finish -> reconstruct -> preview + name -> library.
struct ObjectScanView: View {
    /// Called after the scan is saved to the library (e.g. to swap it in for a placeholder).
    var onSaved: (ScannedObject) -> Void = { _ in }
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    // Created once on appear: a @State default would build a new ObjectCaptureSession on every parent re-render.
    @State private var model: ObjectScanModel?
    @State private var confirmDiscard = false
    @State private var saveError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                ObjectScanContent(model: model) { object in
                    do {
                        try store.addObject(object)
                        dismiss()
                        onSaved(object)
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .sensoryFeedback(.success, trigger: model.phase == .done)
            }
        }
        .environment(\.colorScheme, .dark)   // camera UI: legible chrome over any feed
        .overlay(alignment: .topLeading) {
            ScanChromeButton(title: closeTitle) {
                // Minutes of capture/reconstruction are at stake: confirm before throwing them away.
                if isInvested { confirmDiscard = true } else { model?.cancel(); dismiss() }
            }
            .padding()
            .environment(\.colorScheme, .dark)
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Scan", role: .destructive) { model?.cancel(); dismiss() }
        }
        .alert("Couldn't save", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
        .onAppear {
            guard model == nil else { return }
            let m = ObjectScanModel()
            model = m
            m.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var isInvested: Bool {
        switch model?.phase {
        case .reconstructing, .done: true
        default: false
        }
    }

    private var closeTitle: String {
        switch model?.phase {
        case .done: "Discard"
        case .failed: "Close"
        default: "Cancel"
        }
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
                ProgressView(value: fraction).frame(maxWidth: 240)
                Text("Building 3D model… \(Int(fraction * 100))%")
                    .font(.headline).monospacedDigit()
                Text(remaining.map { "About \(Duration.seconds($0).formatted(.units(allowed: [.minutes, .seconds], width: .wide, maximumUnitCount: 1))) left. Keep the app open." }
                     ?? "This takes a few minutes. Keep the app open.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
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
            .quickLookPreview($previewURL)
        case .failed(let message):
            ContentUnavailableView {
                Label("Scan failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if model.canRetryReconstruction {
                    Button("Try Again") { model.retryReconstruction() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// Instructions, live feedback and the primary action for each capture state.
private struct CaptureOverlay: View {
    let session: ObjectCaptureSession
    @State private var pass = 1
    @State private var detectionFailed = false
    private static let minShots = 10   // fewer photos than this won't reconstruct (Apple sample: minNumImages)

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
                    if let instruction {
                        Text(instruction)
                            .font(.footnote.weight(.medium))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
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
        case .ready: detectionFailed
            ? "Couldn't find the surface. Place the object on a flat, textured surface and center it."
            : "Point the camera at the object and center it in the circle."
        case .detecting: "Drag the box edges so it fits the object snugly."
        case .capturing: "Walk slowly around the object. Keep it in frame."
        case .finishing: "Finishing capture…"
        default: nil
        }
    }

    @ViewBuilder private var actions: some View {
        switch session.state {
        case .ready:
            primary("Continue") { detectionFailed = !session.startDetecting() }
        case .detecting:
            HStack(spacing: 12) {
                Button("Reset Box") { _ = session.resetDetection() }.buttonStyle(.bordered).controlSize(.large)
                primary("Start Capture") { session.startCapturing() }
            }
        case .capturing:
            // Finishing before one full pass gives a poor model; still allowed for demos under time pressure.
            let short = Self.minShots - session.numberOfShotsTaken
            Button(short > 0 ? "\(short) more photos to finish" : "Finish Early") { session.finish() }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(short > 0)
        case .initializing, .finishing:
            ProgressView()
        default:
            EmptyView()
        }
    }

    /// Apple recommends up to three passes; flipping captures the underside.
    private var passComplete: some View {
        VStack(spacing: 12) {
            Text("Pass \(pass) complete").font(.headline)
            Text(session.feedback.contains(.objectNotFlippable)
                 ? "This object shouldn't be flipped. Another pass from a lower or higher angle adds detail."
                 : "Another pass from a different height adds detail. Flip the object to capture its bottom.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if pass < 3 {
                HStack(spacing: 12) {
                    // Not flippable: Apple recommends more passes at other heights instead of flipping.
                    if !session.feedback.contains(.objectNotFlippable) {
                        Button("Flip Object") { pass += 1; detectionFailed = false; session.beginNewScanPassAfterFlip() }
                    }
                    Button("Another Pass") { pass += 1; session.beginNewScanPass() }
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
        if f.contains(.overCapturing) { return "Enough photos here. Move to a new angle." }
        return nil
    }
}

@Observable
@MainActor
final class ObjectScanModel {
    enum Phase: Equatable { case capturing, reconstructing(Double, TimeInterval?), done, failed(String) }

    static let modelName = "model.usdz"
    static let thumbnailName = "thumb.jpg"   // Objects/<id>/thumb.jpg, for the library UI (owner: Designer/Home)
    let id = UUID()
    private(set) var session: ObjectCaptureSession?
    private(set) var phase = Phase.capturing
    private(set) var thumbnail: UIImage?
    private var boundingBox: SIMD3<Float> = [0.5, 0.5, 0.5]
    private var photogrammetry: PhotogrammetrySession?
    private var saved = false
    private var cancelled = false
    private var reconstructionFailed = false   // only reconstruction errors are retryable

    private var dir: URL { ProjectStore.objectDir(id) }
    private var images: URL { dir.appending(path: "Images/") }
    private var checkpoint: URL { dir.appending(path: "Checkpoint/") }
    var modelURL: URL { dir.appending(path: Self.modelName) }

    var canRetryReconstruction: Bool {
        reconstructionFailed && session == nil && photogrammetry == nil
            && FileManager.default.fileExists(atPath: images.path(percentEncoded: false))
    }

    func start() {
        do {
            for d in [images, checkpoint] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            // Photos can be hundreds of MB; keep them out of iCloud backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = dir
            try url.setResourceValues(values)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        let session = ObjectCaptureSession()
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = checkpoint
        session.start(imagesDirectory: images, configuration: config)
        if case .failed(let error) = session.state {   // e.g. insufficient storage, fails immediately
            phase = .failed(error.localizedDescription)
            return
        }
        self.session = session
        Task {
            for await state in session.stateUpdates {
                switch state {
                case .completed:
                    // Release the capture session (camera, GPU, memory) before reconstruction. This loop must
                    // end too, or its `session` reference keeps it alive.
                    self.session = nil
                    if cancelled { cleanUp() } else { Task { await self.reconstruct() } }
                    return
                case .failed(let error):
                    self.session = nil
                    if cancelled { cleanUp() } else { phase = .failed(error.localizedDescription) }
                    return
                default: break
                }
            }
        }
    }

    /// Sessions finish asynchronously; files are deleted once they report back (see cleanUp call sites).
    func cancel() {
        cancelled = true
        if let session { session.cancel() }
        else if let photogrammetry { photogrammetry.cancel() }
        else { cleanUp() }
    }

    func retryReconstruction() {
        guard canRetryReconstruction else { return }
        phase = .reconstructing(0, nil)   // synchronously, so a double tap can't start a second session
        Task { await reconstruct() }      // same checkpoint dir: PhotogrammetrySession resumes where it can
    }

    func scannedObject(named name: String) -> ScannedObject {
        saved = true
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScannedObject(id: id, name: trimmed.isEmpty ? "Object" : trimmed, modelFile: Self.modelName, boundingBox: boundingBox)
    }

    private func cleanUp() {
        if !saved { try? FileManager.default.removeItem(at: dir) }
    }

    private func reconstruct() async {
        guard !cancelled else { return cleanUp() }
        phase = .reconstructing(0, nil)
        reconstructionFailed = false
        defer { photogrammetry = nil }
        do {
            var config = PhotogrammetrySession.Configuration()
            config.checkpointDirectory = checkpoint
            let ps = try PhotogrammetrySession(input: images, configuration: config)
            photogrammetry = ps
            // Iterator first so no early output is missed. The sequence never ends on its own: return explicitly.
            var outputs = ps.outputs.makeAsyncIterator()
            try ps.process(requests: [.modelFile(url: modelURL)])
            while let output = try await outputs.next() {
                switch output {
                case .requestProgress(_, let fraction):
                    if case .reconstructing(_, let eta) = phase { phase = .reconstructing(fraction, eta) }
                case .requestProgressInfo(_, let info):
                    if case .reconstructing(let f, _) = phase { phase = .reconstructing(f, info.estimatedRemainingTime) }
                case .requestError(_, let error):
                    reconstructionFailed = true
                    phase = .failed(Self.message(for: error))
                case .processingCancelled:
                    cleanUp()
                    return
                case .processingComplete:
                    if cancelled { cleanUp() } else if case .reconstructing = phase { await finishModel() }
                    return
                default: break
                }
            }
        } catch {
            if cancelled { cleanUp() } else { reconstructionFailed = true; phase = .failed(Self.message(for: error)) }
        }
    }

    /// Apple's public errors read fine. Anything else (e.g. "CoreOC.PhotogrammetrySession.Error 6") is the engine
    /// failing to match the photos into one shape, which retrying the same photos won't fix: say what scans well.
    static func message(for error: Error) -> String {
        if error is PhotogrammetrySession.Error { return error.localizedDescription }
        let code = "(\((error as NSError).domain) \((error as NSError).code))"
        return "These photos couldn't be matched into a 3D shape. See-through, mesh, very thin, shiny or plain black "
            + "objects don't scan well. Try a solid, textured object in even light, circling it fully at two heights. "
            + code
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
