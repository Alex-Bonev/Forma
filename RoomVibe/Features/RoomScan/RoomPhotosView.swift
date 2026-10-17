import SwiftUI

/// Sheet: photos taken while the room was scanned, one per page.
struct RoomPhotosView: View {
    let projectID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var urls: [URL] = []

    var body: some View {
        NavigationStack {
            Group {
                if urls.isEmpty {
                    ContentUnavailableView("No Room Photos", systemImage: "photo.on.rectangle",
                                           description: Text("Photos are taken automatically while you scan a room."))
                } else {
                    TabView {
                        ForEach(urls, id: \.self) { RoomPhotoPage(url: $0) }
                    }
                    .tabViewStyle(.page)
                    .background(.black)
                }
            }
            .navigationTitle("Room Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .environment(\.colorScheme, .dark)   // photo viewer: legible chrome over the black backdrop
        .onAppear { urls = RoomPhotos.photoURLs(projectDir: ProjectStore.projectDir(projectID)) }
    }
}

private struct RoomPhotoPage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Stored in the sensor's landscape orientation; .right rotates it upright for a portrait phone.
            let url = url
            image = await Task.detached {
                UIImage(contentsOfFile: url.path(percentEncoded: false))
                    .flatMap { $0.cgImage }
                    .map { UIImage(cgImage: $0, scale: 1, orientation: .right) }
            }.value
        }
    }
}
