// Picking photos for a post, like Instagram: your camera roll in a grid under a big preview, tap up to 4 (numbered in
// the order you picked), then Next. Seeing the whole camera roll needs your OK (iOS asks once); if you'd rather not,
// Apple's own picker works without it.
import SwiftUI
import Photos
import PhotosUI

@MainActor @Observable
final class Album {
    var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var assets: [PHAsset] = []
    @ObservationIgnored let images = PHCachingImageManager()

    var allowed: Bool { status == .authorized || status == .limited }

    func load() async {
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard allowed else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 500
        let result = PHAsset.fetchAssets(with: .image, options: options)
        assets = result.count > 0 ? result.objects(at: IndexSet(integersIn: 0..<result.count)) : []
    }

    /// the full photo, for posting (from iCloud if it's only there)
    func full(_ asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat  // one answer, the real photo
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return await withCheckedContinuation { done in
            images.requestImage(for: asset, targetSize: CGSize(width: 2048, height: 2048), contentMode: .aspectFit, options: options) { image, _ in
                done.resume(returning: image)
            }
        }
    }
}

struct AlbumPicker: View {
    var picked: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var album = Album()
    @State private var chosen: [PHAsset] = []
    @State private var focus: PHAsset?
    @State private var loading = false
    @State private var fallback: [PhotosPickerItem] = []

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1.5), count: 4)

    var body: some View {
        NavigationStack {
            Group {
                if album.allowed {
                    library
                } else if album.status == .notDetermined {
                    Color.clear
                } else {
                    noAccess
                }
            }
            .navigationTitle("New post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loading ? "…" : "Next", action: next).fontWeight(.semibold).disabled(chosen.isEmpty || loading)
                }
            }
        }
        .task { await album.load() }
        .onChange(of: fallback) {
            let items = fallback
            guard !items.isEmpty else { return }
            loading = true
            Task {
                var list: [UIImage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { list.append(image) }
                }
                loading = false
                if !list.isEmpty { picked(list); dismiss() }
            }
        }
    }

    private var library: some View {
        VStack(spacing: 0) {
            // the one you're looking at, big
            Color(.secondarySystemBackground)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let focus = focus ?? album.assets.first {
                        AssetImage(asset: focus, manager: album.images, size: 1080).id(focus.localIdentifier)
                    }
                }
                .clipped()
            HStack {
                Text("Recents").font(.headline)
                Spacer()
                Text(chosen.isEmpty ? "Pick up to 4" : "\(chosen.count) of 4").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if album.status == .limited {
                Button("omw! can see only some photos. Change in Settings") { openSettings() }
                    .font(.footnote).padding(.bottom, 8)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 1.5) {
                    ForEach(album.assets, id: \.localIdentifier) { asset in
                        Button { tap(asset) } label: {
                            Color(.secondarySystemFill)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay { AssetImage(asset: asset, manager: album.images, size: 300) }
                                .clipped()
                                .overlay { if focus == asset { Color.white.opacity(0.35) } }
                                .overlay(alignment: .topTrailing) { badge(asset).padding(6) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .overlay { if album.assets.isEmpty { ContentUnavailableView("No photos yet", systemImage: "photo") } }
        }
        .sensoryFeedback(.selection, trigger: chosen.count)
    }

    @ViewBuilder private func badge(_ asset: PHAsset) -> some View {
        if let i = chosen.firstIndex(of: asset) {
            Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.omwBlue, in: Circle())
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
        } else {
            Circle().strokeBorder(.white, lineWidth: 1.5).background(Circle().fill(.black.opacity(0.15))).frame(width: 24, height: 24)
        }
    }

    private var noAccess: some View {
        ContentUnavailableView {
            Label("Your photos", systemImage: "photo.on.rectangle")
        } description: {
            Text("Allow omw! to see your photos to pick from your camera roll here, or choose them with Apple's picker.")
        } actions: {
            Button("Allow in Settings", action: openSettings).buttonStyle(.borderedProminent).tint(Color.omwBlue)
            PhotosPicker(selection: $fallback, maxSelectionCount: 4, selectionBehavior: .ordered, matching: .images) {
                Text("Choose photos")
            }
        }
    }

    /// tap: pick it (and look at it); tap the one you're looking at again to un-pick it
    private func tap(_ asset: PHAsset) {
        if let i = chosen.firstIndex(of: asset) {
            if focus == asset { chosen.remove(at: i); focus = chosen.last } else { focus = asset }
        } else if chosen.count < 4 {
            chosen.append(asset)
            focus = asset
        } else {
            focus = asset
        }
    }

    private func next() {
        loading = true
        let picks = chosen
        Task {
            var list: [UIImage] = []
            for asset in picks { if let image = await album.full(asset) { list.append(image) } }
            loading = false
            guard !list.isEmpty else { return }
            picked(list)
            dismiss()
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// one photo from the library, sharp enough for `size` points across
struct AssetImage: View {
    let asset: PHAsset
    let manager: PHImageManager
    let size: CGFloat
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?

    var body: some View {
        GeometryReader { g in
            if let image {
                Image(uiImage: image).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
            }
        }
        .onAppear {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic  // a quick blurry one, then the sharp one
            options.isNetworkAccessAllowed = true
            let px = size * UIScreen.main.scale
            request = manager.requestImage(for: asset, targetSize: CGSize(width: px, height: px), contentMode: .aspectFill, options: options) { result, _ in
                MainActor.assumeIsolated { if let result { image = result } }
            }
        }
        .onDisappear {
            if let request { manager.cancelImageRequest(request) }
        }
    }
}
