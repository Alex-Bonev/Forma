import SwiftUI
import RoomPlan
import ARKit
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
    @State private var saving = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let scanner {
                RoomCaptureRepresentable(view: scanner.view)
                    .id(ObjectIdentifier(scanner))
                    .ignoresSafeArea()
                    // Tap anything RoomPlan doesn't recognize to mark it (saved as a "marked item").
                    .onTapGesture(coordinateSpace: .local) { p in
                        if scanner.phase == .scanning { scanner.mark(at: p) }
                    }
                    .sensoryFeedback(.impact(weight: .medium), trigger: scanner.markers.count)
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
            Button("Save") { Task { await save() } }
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
                if scanner.phase == .scanning, !scanner.photos.shots.isEmpty {
                    Label("\(scanner.photos.shots.count) photo\(scanner.photos.shots.count == 1 ? "" : "s")", systemImage: "camera")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                if scanner.phase == .scanning {
                    ScanChromeButton(title: "Done", prominent: true) { scanner.stop() }
                }
            }
            .padding()

            Spacer()

            switch scanner.phase {
            case .scanning:
                VStack(spacing: 8) {
                    if !scanner.markers.isEmpty || scanner.markMissed {
                        Text(scanner.markMissed ? "No surface there. Try again closer."
                                                : "\(scanner.markers.count) item\(scanner.markers.count == 1 ? "" : "s") marked")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Text("Move slowly around the room. Tap anything it misses to mark it.")
                        .scanCaption()
                }
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
                .disabled(saving)   // finish classification takes up to ~1.5 s
                .padding(.horizontal, 24).padding(.bottom, 24)
                .sensoryFeedback(.success, trigger: scanner.phase)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: scanner.phase)
    }

    private func save() async {
        guard !saving, let room = scanner?.result else { return }
        saving = true
        defer { saving = false }
        var model = RoomModel(room)
        let markers = scanner?.markers ?? []
        model.objects += zip(RoomModel.markedItems(markers.map(\.point), walls: model.walls), markers).map { box, m in
            var box = box
            if let s = m.suggestion { box.attributes = ["Vision.\(s.vision)", "Suggest.\(s.catalog)"] }
            return box
        }
        // Photos are in the raw ARSession world frame, so match against walls before axisAligned().
        // VERIFY on device: CapturedRoom transforms share the ARSession world frame (no re-anchoring after processing).
        let photos = scanner?.photos
        let paint = photos.flatMap { RoomPhotos.wallColor(walls: model.walls, objects: model.objects, photos: $0.shots) }
        let walls = model.walls, shots = photos?.shots.map { ($0.photo, $0.jpeg) } ?? []
        model = model.axisAligned()
        // RoomBuilder needs walls to find the floor and room bounds.
        guard !model.walls.isEmpty else {
            error = "No walls were detected. Point at every wall while scanning."
            return
        }
        // Brick walls / wood floor from the photos (Vision, on device, off main).
        let finishes = await Task.detached(priority: .userInitiated) {
            SceneClassifier.finishes(walls: walls, photos: shots)
        }.value
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var project = try store.addRoom(name: trimmed.isEmpty ? "Room" : trimmed, model: model) { dir in
                // Raw RoomPlan output kept for later (model substitution, sharing, QuickLook).
                // Note: these are in RoomPlan's original frame; room.json is rotated by axisAligned().
                try JSONEncoder().encode(room).write(to: dir.appending(path: "captured.json"))
                try? room.export(to: dir.appending(path: "room.usdz"))
                try? photos?.write(to: dir)   // nice-to-have: never fail the scan over photos
            }
            let wall = finishes.brickWalls ? "brick" : paint.map(Finish.paintID)
            if wall != nil || finishes.woodFloor {
                if let wall { project.wallFinish = wall }
                if finishes.woodFloor { project.floorFinish = "oak" }
                store.update(project)
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
    let photos = RoomPhotos()

    override init() {
        super.init()
        view.delegate = self
    }

    // RoomCaptureViewDelegate inherits NSCoding; never archived.
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    func start() {
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        photos.start(view.captureSession.arSession)
    }

    func stop() {
        phase = .processing
        photos.stop()
        view.captureSession.stop()
    }

    /// A point the user tapped during the scan (something RoomPlan doesn't detect) and what Vision thinks it is.
    struct Marker { var point: SIMD3<Float>; var suggestion: SceneClassifier.Suggestion? }
    private(set) var markers: [Marker] = []
    private(set) var markMissed = false

    /// Raycast from a tap on the capture view into the AR scene (RoomPlan exposes its ARSession).
    /// VERIFY on device: CapturedRoom transforms share this ARSession's world frame.
    func mark(at point: CGPoint) {
        let session = view.captureSession.arSession
        guard let frame = session.currentFrame, view.bounds.width > 0 else { return }
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        // View point -> normalized image coordinates (inverse of the camera image's display transform).
        let normalized = CGPoint(x: point.x / view.bounds.width, y: point.y / view.bounds.height)
        let imagePoint = normalized.applying(frame.displayTransform(for: orientation, viewportSize: view.bounds.size).inverted())
        let query = frame.raycastQuery(from: imagePoint, allowing: .estimatedPlane, alignment: .any)
        guard let hit = session.raycast(query).first else { markMissed = true; return }
        markMissed = false
        let t = hit.worldTransform.columns.3
        markers.append(Marker(point: [t.x, t.y, t.z]))
        // Classify a square around the tap. Keep only the pixel buffer, not the ARFrame (ARKit recycles frames).
        // VERIFY on device: the crop frames the tapped thing and the portrait orientation reads upright.
        let i = markers.count - 1, buffer = frame.capturedImage, camera = frame.camera.transform
        Task.detached(priority: .userInitiated) {
            let suggestion = SceneClassifier.crop(buffer, around: imagePoint).flatMap {
                SceneClassifier.suggestion(SceneClassifier.classify($0, orientation: SceneClassifier.orientation(camera: camera)))
            }
            await MainActor.run { self.markers[i].suggestion = suggestion }
        }
    }

    /// Stop without processing: the scan is being thrown away.
    func cancel() {
        cancelled = true
        photos.stop()
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
