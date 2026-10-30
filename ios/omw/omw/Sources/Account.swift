// Your account, the same way the web app sets it up (web/friends.js setUp, web/feed.js syncCard):
//   a friend ID that's yours alone (codes/{ID} = { uid, name }; the database refuses one that's taken),
//   your public card (publicProfiles/{uid} = { name, photo, code, public }: what people who aren't your friends see),
//   and your Google or Apple picture if you don't have one yet.
// Plus Edit profile: picture, name, friend ID, how you get around.
import SwiftUI
import PhotosUI
import FirebaseFirestore
import FirebaseAuth

extension Session {
    static let idChars = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")  // no 0/O or 1/I/L, easy to read out loud

    /// once per sign-in, after your profile loads
    func setUpAccount() {
        guard let uid, let me else { return }
        let fresh = newAccount
        Task {
            var photo = me.photo
            if photo.isEmpty, let url = user?.photoURL?.absoluteString, url.hasPrefix("https://") {
                photo = url
                try? await put(db.collection("users").document(uid), ["photo": url])
            }
            let code = await ensureCode() ?? me.code
            var card: [String: Any] = ["name": String(me.name.prefix(60)), "photo": photo.count < 300_000 ? photo : "", "code": code]
            if fresh { card["public"] = true }  // a new account starts public, like the web app; Settings can make it private
            try? await put(db.collection("publicProfiles").document(uid), card)
        }
    }

    /// keep your username if it's yours; otherwise claim a random free one
    private func ensureCode() async -> String? {
        guard let uid, let me else { return nil }
        if !me.code.isEmpty {
            do { if try await codeOwner(me.code) == uid { return me.code } }
            catch { return me.code }  // offline: keep it, check next time
        }
        for _ in 0..<5 {
            let code = String((0..<6).map { _ in Self.idChars.randomElement() ?? "X" })
            do {
                try await put(db.collection("codes").document(code), ["uid": uid, "name": String(me.name.prefix(60))], merge: false)
                try await put(db.collection("users").document(uid), ["code": code])
                self.me?.code = code
                return code
            } catch { continue }  // taken: try another
        }
        return nil
    }

    /// who owns a friend ID (nil: nobody)
    func codeOwner(_ code: String) async throws -> String? {
        let ref = db.collection("codes").document(code)
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<String?, Error>) in
            ref.getDocument { snap, error in
                if let error { done.resume(throwing: error) } else { done.resume(returning: snap?.data()?["uid"] as? String) }
            }
        }
    }

    /// a new username: 3 to 15 letters, numbers or _, and nobody else's
    func changeCode(to code: String) async throws {
        guard let uid, let me else { return }
        let old = me.code
        var oldMine = false
        if !old.isEmpty, let owner = try? await codeOwner(old) { oldMine = owner == uid }
        let batch = db.batch()
        batch.setData(["uid": uid, "name": String(me.name.prefix(60))], forDocument: db.collection("codes").document(code))
        batch.setData(["code": code], forDocument: db.collection("users").document(uid), merge: true)
        batch.setData(["code": code], forDocument: db.collection("publicProfiles").document(uid), merge: true)
        if oldMine { batch.deleteDocument(db.collection("codes").document(old)) }
        try await commit(batch)  // all or nothing: if someone grabbed it a moment ago, nothing changes
        self.me?.code = code
    }

    func saveProfile(name: String, travelMode: String, photo: String?) async throws {
        guard let uid, let me else { return }
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        var mine: [String: Any] = ["travelMode": travelMode]
        var card: [String: Any] = [:]
        if !name.isEmpty { mine["name"] = name; card["name"] = name }
        if let photo { mine["photo"] = photo; card["photo"] = photo }
        let batch = db.batch()
        batch.setData(mine, forDocument: db.collection("users").document(uid), merge: true)
        if !card.isEmpty { batch.setData(card, forDocument: db.collection("publicProfiles").document(uid), merge: true) }
        if !me.code.isEmpty, !name.isEmpty { batch.setData(["name": name], forDocument: db.collection("codes").document(me.code), merge: true) }
        try await commit(batch)
        if !name.isEmpty { self.me?.name = name }
        if let photo { self.me?.photo = photo }
        self.me?.travelMode = travelMode
    }

    private func put(_ ref: DocumentReference, _ data: [String: Any], merge: Bool = true) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            ref.setData(data, merge: merge) { error in if let error { done.resume(throwing: error) } else { done.resume() } }
        }
    }

    private func commit(_ batch: WriteBatch) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            batch.commit { error in if let error { done.resume(throwing: error) } else { done.resume() } }
        }
    }

    /// a profile picture: the middle square, 400 px, as a small JPEG (what the database allows)
    nonisolated static func avatarDataURL(_ image: UIImage) -> String? {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        for (px, quality) in [(400.0, 0.82), (320, 0.75), (256, 0.7)] {
            let size = CGSize(width: px, height: px), k = px / side
            let square = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(x: (px - image.size.width * k) / 2, y: (px - image.size.height * k) / 2,
                                      width: image.size.width * k, height: image.size.height * k))
            }
            guard let data = square.jpegData(compressionQuality: quality) else { continue }
            let url = "data:image/jpeg;base64," + data.base64EncodedString()
            if url.count < 150_000 { return url }
        }
        return nil
    }
}

// ---------- Edit profile ----------
struct EditProfileView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var code = ""
    @State private var mode = "driving"
    @State private var pick: PhotosPickerItem?
    @State private var newPhoto: String?
    @State private var codeNote = ""
    @State private var codeOK = false
    @State private var saving = false
    @State private var problem: String?
    @State private var home: PlaceHit?

    private struct Travel: Identifiable { let id: String, name: String, symbol: String }
    private static let modes = [Travel(id: "driving", name: "Drive", symbol: "car.fill"), Travel(id: "walking", name: "Walk", symbol: "figure.walk"),
                                Travel(id: "cycling", name: "Bike", symbol: "bicycle"), Travel(id: "transit", name: "Transit", symbol: "tram.fill")]

    private var myCode: String { session.me?.code ?? "" }
    private var homeLabel: String {
        if let name = home?.name { return name }
        guard let me = session.me, me.home != nil else { return "Set your home" }
        return me.homeName.isEmpty ? "Home set" : me.homeName
    }
    private var codeChanged: Bool { !code.isEmpty && code != myCode }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Avatar(photo: newPhoto ?? session.me?.photo ?? "", name: name.isEmpty ? "?" : name, size: 96)
                    PhotosPicker(selection: $pick, matching: .images) {
                        Text("Change picture").font(.subheadline.weight(.semibold)).foregroundStyle(Color.omwBlue)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section("Name") {
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .onChange(of: name) { if name.count > 60 { name = String(name.prefix(60)) } }
            }

            Section {
                HStack(spacing: 2) {
                    Text("@").foregroundStyle(.secondary)
                    // usernames are stored in capitals (like the web app) and shown in lowercase
                    TextField("username", text: Binding(get: { code.lowercased() }, set: { code = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: code) {
                            let clean = String(code.uppercased().filter { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "_" }.prefix(15))
                            if clean != code { code = clean }
                        }
                }
            } header: {
                Text("Username")
            } footer: {
                Text(codeNote)
                    .foregroundStyle(codeChanged && !codeOK && !codeNote.isEmpty && codeNote != "Checking…" ? Color.red : Color.secondary)
            }

            Section {
                NavigationLink { PlacePicker(selection: $home) } label: {
                    HStack {
                        Image(systemName: "house.fill").foregroundStyle(.secondary)
                        Text(homeLabel)
                            .foregroundStyle(home == nil && session.me?.home == nil ? Color.secondary : Color.primary)
                    }
                }
            } header: {
                Text("Home")
            }

            Section("How you get around") {
                Picker("Travel", selection: $mode) {
                    ForEach(Self.modes) { m in Label(m.name, systemImage: m.symbol).tag(m.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Done", action: save)
                    .fontWeight(.semibold)
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || codeChanged && !codeOK)
            }
        }
        .onAppear {
            name = session.me?.name ?? ""
            code = myCode
            mode = session.me?.travelMode ?? "driving"
        }
        .task(id: code) { await check() }
        .onChange(of: pick) {
            guard let pick else { return }
            Task {
                if let data = try? await pick.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    let url = await Task.detached(priority: .userInitiated) { Session.avatarDataURL(image) }.value
                    if let url { newPhoto = url } else { problem = "That picture didn't work. Try another one." }
                }
            }
        }
        .alert("Couldn't save", isPresented: .constant(problem != nil)) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    /// is the friend ID you typed free? (after a short pause in typing)
    private func check() async {
        codeOK = false
        guard codeChanged else { codeNote = ""; return }
        guard code.count >= 3 else { codeNote = "At least 3 characters."; return }
        codeNote = "Checking…"
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        do {
            let owner = try await session.codeOwner(code)
            if Task.isCancelled { return }
            codeOK = owner == nil
            codeNote = owner == nil ? "@\(code.lowercased()) is available!" : "@\(code.lowercased()) is taken. Try another."
        } catch {
            codeNote = "Couldn't check right now."
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                if codeChanged { try await session.changeCode(to: code) }
                try await session.saveProfile(name: name, travelMode: mode, photo: newPhoto)
                if let home, home.lat != nil { session.setHome(home) }
                dismiss()
            } catch {
                problem = codeChanged ? "@\(code.lowercased()) was just taken. Try another." : error.localizedDescription
            }
            saving = false
        }
    }
}
