// The group photo, like BeReal (the web app's memories.js): once everyone's arrived, one person takes a photo of the
// whole group. It's saved for everyone who went (memories/{hangout id}) and shared to the feed (feed/{hangout id}), with
// who was late. Posted within 10 minutes of the last person arriving counts as on time.
import SwiftUI
import PhotosUI
import FirebaseFirestore
import CoreLocation
#if canImport(LocationEssentials)
import LocationEssentials  // where iOS 26 keeps coordinates and distances
#endif

extension Hangout {
    var everyoneHere: Bool { !attendees.isEmpty && attendees.allSatisfy { arrivals[$0] != nil } }
    var allHereAt: Date? { everyoneHere ? attendees.compactMap { arrivals[$0] }.max() : nil }
    /// minutes late each person arrived (never below 0), for the feed's "Sam 8 min late"
    var lateMinutes: [String: Int] {
        var out: [String: Int] = [:]
        for u in attendees { if let at = arrivals[u] { out[u] = max(0, Int((at.timeIntervalSince(start) / 60).rounded())) } }
        return out
    }
}

extension Session {
    func postGroupPhoto(_ image: UIImage, for h: Hangout) async throws {
        guard let uid, let me else { return }
        let (big, small) = await Task.detached(priority: .userInitiated) {
            (Session.jpegDataURL(image, maxChars: 900_000), Session.jpegDataURL(image, maxChars: 380_000))
        }.value
        guard let big, let small else { throw API.Failure(message: "That photo is too big. Try another one.") }
        var names = h.names
        names[uid] = names[uid] ?? me.name
        let at = When.string(.now)
        let memory: [String: Any] = [
            "members": h.attendees, "names": names, "by": uid, "byName": me.name, "photo": big, "at": at,
            "allHereAt": When.string(h.allHereAt ?? .now), "title": h.title, "venueName": h.venueName, "address": h.address,
            "start": When.string(h.start),
        ]
        let post: [String: Any] = [
            "by": uid, "byName": me.name, "members": h.attendees, "names": names, "photo": small, "at": at, "start": When.string(h.start),
            "title": h.title, "venueName": h.venueName, "address": h.address,
            "venue": h.venue.map { [$0.latitude, $0.longitude] } ?? NSNull(), "late": h.lateMinutes,
            "likes": [String](), "ratings": [String: Double](), "viewers": Array(Set(h.attendees + friends.map(\.id))),
        ]
        // the memory first: the database lets the feed post exist only once the memory says you took it
        for (collection, data) in [("memories", memory), ("feed", post)] {
            let ref = db.collection(collection).document(h.id)
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                ref.setData(data) { error in if let error { done.resume(throwing: error) } else { done.resume() } }
            }
        }
        _ = try? await db.collection("hangouts").document(h.id).collection("messages").addDocument(data: [
            "from": uid, "name": me.name, "text": "posted the group photo", "kind": "photo", "at": at,
            "expireAt": Timestamp(date: h.chatExpires),
        ])
    }
}

/// on a plan, once everyone's there: take or pick the group photo (or see it once it's posted)
struct GroupPhotoSection: View {
    let hangout: Hangout
    @Environment(Session.self) private var session
    @State private var photo: String?
    @State private var checked = false
    @State private var camera = false
    @State private var item: PhotosPickerItem?
    @State private var posting = false
    @State private var problem: String?

    var body: some View {
        Group {
            if let photo {
                Section("Group photo") {
                    RemoteImage(source: photo)
                        .aspectRatio(4 / 5, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 14))
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            } else if checked, hangout.everyoneHere {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("You all made it!", systemImage: "party.popper.fill").font(.headline)
                        Text(minutesLeft > 0 ? "Snap the group · \(minutesLeft) min left to post on time" : "Add a group photo to your memories")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                Button { camera = true } label: { Label("Take photo", systemImage: "camera.fill").frame(maxWidth: .infinity, minHeight: 44) }
                                    .buttonStyle(.borderedProminent).tint(Color.primary).foregroundStyle(Color(.systemBackground))
                            }
                            PhotosPicker(selection: $item, matching: .images) {
                                Label("Upload", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                        }
                        .disabled(posting)
                        if posting {
                            HStack(spacing: 8) {
                                OmwMark().frame(width: 24, height: 24).modifier(Wiggle())
                                Text("Posting…").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task(id: hangout.id) { load() }
        .onChange(of: hangout.everyoneHere) { load() }
        .fullScreenCover(isPresented: $camera) {
            CameraView { image in camera = false; if let image { post(image) } }.ignoresSafeArea()
        }
        .onChange(of: item) {
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { post(image) }
                self.item = nil
            }
        }
        .alert("Couldn't post it", isPresented: .constant(problem != nil)) { Button("OK") { problem = nil } } message: { Text(problem ?? "") }
    }

    private var minutesLeft: Int {
        guard let all = hangout.allHereAt else { return 0 }
        return max(0, Int(ceil(10 - Date.now.timeIntervalSince(all) / 60)))
    }

    private func load() {
        session.db.collection("memories").document(hangout.id).getDocument { snap, _ in
            MainActor.assumeIsolated {
                photo = (snap?.data()?["photo"] as? String).map(Person.safePhoto).flatMap { $0.isEmpty ? nil : $0 }
                checked = true
            }
        }
    }

    private func post(_ image: UIImage) {
        posting = true
        Task {
            do { try await session.postGroupPhoto(image, for: hangout); load() }
            catch { problem = (error as NSError).domain == FirestoreErrorDomain ? "Someone else just posted the photo for this one." : error.localizedDescription }
            posting = false
        }
    }
}

/// the iPhone camera (needs "Privacy - Camera Usage Description" in Info)
struct CameraView: UIViewControllerRepresentable {
    var done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
