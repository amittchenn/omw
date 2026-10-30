// Chats, like Instagram's DMs: one inbox with your DMs, group chats and every plan's group chat (the people going).
// Same documents as the web app (web/dms.js, web/chat.js):
//   chats/{id}             { members, group, title, createdBy, names, photos, last, read }   a DM's id is dm_<uid>_<uid>
//   chats/{id}/messages    { from, name, text, at, kind? }   kind "system" = "Priya created the group"
//   hangouts/{id}/messages { from, name, text, kind, at, expireAt }   gone a day after the plan
import SwiftUI
import FirebaseFirestore

/// a conversation: a DM or group (chats/{id}) or a plan's group chat (hangouts/{id})
enum ChatRef: Hashable {
    case chat(String)
    case plan(String)
}

// ---------- reading and writing ----------
extension Session {
    func chat(_ id: String) -> Chat? { chats.first { $0.id == id } }

    func chatName(_ c: Chat, _ u: String) -> String {
        u == uid ? "You" : person(u)?.name ?? c.names[u] ?? "Friend"
    }

    func chatPhoto(_ c: Chat, _ u: String) -> String { person(u)?.photo ?? c.photos[u] ?? "" }

    /// a group's name, or who's in it; a DM is the other person
    func chatTitle(_ c: Chat) -> String {
        let others = c.others(uid ?? "")
        if c.group { return c.title.isEmpty ? (others.isEmpty ? "Just you" : others.map { chatName(c, $0) }.joined(separator: ", ")) : c.title }
        return others.first.map { chatName(c, $0) } ?? "Chat"
    }

    /// plans you're going to whose chat is still open
    var planChats: [Hangout] { hangouts.filter(\.chatOpen) }

    func planUnread(_ id: String) -> Int {
        let seen = planSeen[id] ?? .distantPast
        return (planMessages[id] ?? []).filter { $0.from != uid && $0.at > seen }.count
    }

    /// how many conversations have something new (the badge on the Chats button)
    var unreadChats: Int {
        guard let uid else { return 0 }
        return chats.filter { $0.unread(for: uid) }.count + planChats.filter { planUnread($0.id) > 0 }.count
    }

    func markRead(_ ref: ChatRef) {
        guard let uid else { return }
        switch ref {
        case .chat(let id):
            guard let c = chat(id), c.unread(for: uid) else { return }
            db.collection("chats").document(id).updateData(["read.\(uid)": When.string(.now)])
        case .plan(let id):
            planSeen[id] = .now
            UserDefaults.standard.set(planSeen.mapValues(\.timeIntervalSince1970), forKey: "planSeen.\(uid)")
        }
    }

    /// your DM with a friend (made the first time), so you both always land in the same one
    func openDM(with friend: String) async throws -> String {
        guard let uid else { throw ChatError.signedOut }
        let members = [uid, friend].sorted()
        let id = "dm_" + members.joined(separator: "_")
        if chat(id) != nil { return id }
        let ref = db.collection("chats").document(id)
        let exists: Bool = try await withCheckedThrowingContinuation { done in
            ref.getDocument { snap, error in
                if let error { done.resume(throwing: error) } else { done.resume(returning: snap?.exists ?? false) }
            }
        }
        if !exists {
            try await setDocument(ref, ["members": members, "group": false, "createdBy": uid, "createdAt": When.string(.now),
                                "names": [uid: me?.name ?? "Friend", friend: person(friend)?.name ?? "Friend"],
                                "photos": [String: String](), "read": [String: String]()])
        }
        return id
    }

    /// a group chat with you and these friends
    func createGroup(_ uids: [String], title: String) async throws -> String {
        guard let uid else { throw ChatError.signedOut }
        let myName = me?.name ?? "Friend", at = When.string(.now)
        var names = [uid: myName]
        for u in uids { names[u] = person(u)?.name ?? "Friend" }
        let note: [String: Any] = ["text": "\(myName) created the group", "from": uid, "name": myName, "at": at, "kind": "system"]
        let ref = db.collection("chats").document()
        try await setDocument(ref, ["members": [uid] + uids, "group": true, "title": String(title.prefix(40)), "createdBy": uid, "createdAt": at,
                            "names": names, "photos": [String: String](), "last": note, "read": [uid: at]])
        _ = try await ref.collection("messages").addDocument(data: note)
        return ref.documentID
    }

    func send(_ text: String, in ref: ChatRef) {
        guard let uid else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let name = String((me?.name ?? "Friend").prefix(60)), at = When.string(.now)
        switch ref {
        case .chat(let id):
            let m: [String: Any] = ["from": uid, "name": name, "text": String(text.prefix(1000)), "at": at]
            let chatRef = db.collection("chats").document(id)
            chatRef.collection("messages").addDocument(data: m)
            chatRef.updateData(["last": m, "read.\(uid)": at])
        case .plan(let id):
            guard let h = hangout(id) else { return }
            db.collection("hangouts").document(id).collection("messages").addDocument(data: [
                "from": uid, "name": name, "text": String(text.prefix(500)), "kind": "text", "at": at,
                "expireAt": Timestamp(date: h.chatExpires),
            ])
            markRead(ref)
        }
    }

    // ---------- groups ----------
    func renameGroup(_ c: Chat, to title: String) {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        db.collection("chats").document(c.id).updateData(["title": title])
        let myName = me?.name ?? "Friend"
        systemNote(c, title.isEmpty ? "\(myName) removed the group name" : "\(myName) named the group \"\(title)\"")
    }

    func addToGroup(_ c: Chat, _ friend: String) {
        let name = person(friend)?.name ?? "Friend"
        db.collection("chats").document(c.id).updateData(["members": FieldValue.arrayUnion([friend]), "names.\(friend)": name])
        systemNote(c, "\(me?.name ?? "Friend") added \(name)")
    }

    func leaveGroup(_ c: Chat) async throws {
        guard let uid else { return }
        systemNote(c, "\(me?.name ?? "Friend") left the group")
        try await write(db.collection("chats").document(c.id), ["members": FieldValue.arrayRemove([uid])])
    }

    private func systemNote(_ c: Chat, _ text: String) {
        guard let uid else { return }
        let m: [String: Any] = ["from": uid, "name": me?.name ?? "Friend", "text": text, "at": When.string(.now), "kind": "system"]
        let ref = db.collection("chats").document(c.id)
        ref.collection("messages").addDocument(data: m) { error in if error == nil { ref.updateData(["last": m]) } }
    }

    private func setDocument(_ ref: DocumentReference, _ data: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            ref.setData(data) { error in if let error { done.resume(throwing: error) } else { done.resume() } }
        }
    }
}

enum ChatError: LocalizedError {
    case signedOut
    var errorDescription: String? { "Sign in again to chat." }
}

/// a DM's or group's messages, live while it's open (a plan's chat is always live in Session.planMessages)
@MainActor @Observable
final class Conversation {
    var messages: [ChatMessage] = []
    @ObservationIgnored private var stop: ListenerRegistration?

    func listen(_ id: String, db: Firestore) {
        stop?.remove()
        stop = db.collection("chats").document(id).collection("messages").order(by: "at").limit(toLast: 300)
            .addSnapshotListener { [weak self] snap, _ in
                MainActor.assumeIsolated {
                    guard let self, let snap else { return }
                    self.messages = snap.documents.map { ChatMessage(id: $0.documentID, data: $0.data()) }
                }
            }
    }

    func end() { stop?.remove(); stop = nil }
}

// ---------- the inbox ----------
struct ChatsView: View {
    @Environment(Session.self) private var session
    @State private var query = ""
    @State private var starting = false
    @State private var opened: ChatRef?

    private struct Row: Identifiable {
        let ref: ChatRef
        let title: String
        let line: String
        let at: Date
        let unread: Bool
        var id: ChatRef { ref }
    }

    private var rows: [Row] {
        let uid = session.uid ?? ""
        let mine = session.chats.map { c in
            let line: String
            if let last = c.last {
                let who = last.from == uid ? "You: " : c.group && last.kind != "system" ? "\(last.name.split(separator: " ").first ?? ""): " : ""
                line = who + last.text
            } else {
                line = c.group ? "New group" : "Say hi!"
            }
            return Row(ref: .chat(c.id), title: session.chatTitle(c), line: line, at: c.lastAt, unread: c.unread(for: uid))
        }
        let plans = session.planChats.map { h in
            let last = session.planMessages[h.id]?.last
            let line = last.map { m in
                let who = m.from == uid ? "You" : m.name.split(separator: " ").first.map(String.init) ?? m.name
                return m.isText ? "\(who): \(m.text)" : "\(who) \(m.text)"
            } ?? "Plan chat"
            return Row(ref: .plan(h.id), title: h.title, line: line, at: last?.at ?? .distantPast, unread: session.planUnread(h.id) > 0)
        }
        let all = (mine + plans).sorted { $0.at > $1.at }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) }
    }

    /// friends you haven't messaged yet, along the top: tap one to start
    private var fresh: [Person] {
        let uid = session.uid ?? ""
        let talked = Set(session.chats.filter { !$0.group }.flatMap { $0.others(uid) })
        return session.friends.filter { !talked.contains($0.id) }
    }

    var body: some View {
        List {
            if query.isEmpty, !fresh.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(fresh) { f in
                            NavigationLink { DirectChat(uid: f.id) } label: {
                                VStack(spacing: 5) {
                                    Avatar(f, size: 60, showStatus: true)
                                    Text(f.firstName).font(.caption).lineLimit(1)
                                }
                                .frame(width: 70)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
            if rows.isEmpty {
                ContentUnavailableView(query.isEmpty ? (session.friends.isEmpty ? "Add friends to start chatting" : "No chats yet") : "No chats match that",
                                       systemImage: "bubble.left.and.bubble.right")
                    .listRowSeparator(.hidden)
            }
            ForEach(rows) { r in
                NavigationLink(value: r.ref) { row(r) }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { starting = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New chat")
            }
        }
        .sheet(isPresented: $starting) { NewChatSheet { opened = $0 }.withOmw() }
        .navigationDestination(item: $opened) { ConversationView(ref: $0) }
    }

    private func row(_ r: Row) -> some View {
        HStack(spacing: 12) {
            ChatFace(ref: r.ref, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.subheadline.weight(r.unread ? .bold : .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(r.line).lineLimit(1)
                    if r.at > .distantPast { Text("· \(When.ago(r.at))").layoutPriority(1) }
                }
                .font(.subheadline.weight(r.unread ? .semibold : .regular))
                .foregroundStyle(r.unread ? .primary : .secondary)
            }
            Spacer(minLength: 0)
            if r.unread { Circle().fill(Color.omwBlue).frame(width: 9, height: 9) }
        }
        .padding(.vertical, 2)
    }
}

/// a chat's picture: the other person, two overlapping faces for a group, a calendar for a plan
struct ChatFace: View {
    let ref: ChatRef
    var size: CGFloat = 52
    @Environment(Session.self) private var session

    var body: some View {
        switch ref {
        case .plan:
            Image(systemName: "calendar")
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
                .background(Color.sun.opacity(0.35), in: Circle())
        case .chat(let id):
            if let c = session.chat(id) {
                let others = c.others(session.uid ?? "")
                if c.group {
                    let a = others.first ?? "", b = others.dropFirst().first
                    ZStack(alignment: .bottomTrailing) {
                        Avatar(photo: session.chatPhoto(c, a), name: session.chatName(c, a), size: size * 0.72)
                            .frame(width: size, height: size, alignment: .topLeading)
                        Group {
                            if let b { Avatar(photo: session.chatPhoto(c, b), name: session.chatName(c, b), size: size * 0.72) }
                            else { Avatar(session.me, size: size * 0.72) }
                        }
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    }
                    .frame(width: size, height: size)
                } else {
                    let u = others.first ?? ""
                    Avatar(photo: session.chatPhoto(c, u), name: session.chatName(c, u), size: size)
                }
            } else {
                Avatar(photo: "", name: "?", size: size)
            }
        }
    }
}

// ---------- starting a chat: one friend for a DM, more for a group ----------
struct NewChatSheet: View {
    var started: (ChatRef) -> Void
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var picked: [String] = []
    @State private var title = ""
    @State private var working = false
    @State private var problem: String?

    private var shown: [Person] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? session.friends : session.friends.filter { "\($0.name) \($0.code)".lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if picked.count > 1 {
                    TextField("Group name (optional)", text: $title)
                        .onChange(of: title) { if title.count > 40 { title = String(title.prefix(40)) } }
                }
                if session.friends.isEmpty {
                    ContentUnavailableView("Add friends to start chatting", systemImage: "person.2")
                }
                ForEach(shown) { f in
                    Button { toggle(f.id) } label: {
                        HStack(spacing: 12) {
                            Avatar(f, size: 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.subheadline.weight(.semibold))
                                Text(f.handle).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: picked.contains(f.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(picked.contains(f.id) ? Color.omwBlue : Color(.tertiaryLabel))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .navigationTitle(picked.count > 1 ? "New group" : "New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: start) {
                    Text(picked.count > 1 ? "Create group (\(picked.count + 1))" : "Chat")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.omwBlue)
                .disabled(picked.isEmpty || working)
                .padding(.horizontal, 16).padding(.bottom, 8)
                .background(.bar)
            }
            .sensoryFeedback(.selection, trigger: picked)
            .alert("Couldn't start the chat", isPresented: .constant(problem != nil)) {
                Button("OK") { problem = nil }
            } message: { Text(problem ?? "") }
        }
    }

    private func toggle(_ id: String) {
        if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
    }

    private func start() {
        working = true
        Task {
            do {
                let id: String
                if picked.count == 1 { id = try await session.openDM(with: picked[0]) }
                else { id = try await session.createGroup(picked, title: title) }
                dismiss()
                started(.chat(id))
            } catch { problem = error.localizedDescription }
            working = false
        }
    }
}

/// "Message" on someone's profile: finds (or makes) your DM, then shows it
struct DirectChat: View {
    let uid: String
    @Environment(Session.self) private var session
    @State private var id: String?
    @State private var problem: String?

    var body: some View {
        Group {
            if let id { ConversationView(ref: .chat(id)) }
            else if let problem { ContentUnavailableView("Couldn't open the chat", systemImage: "exclamationmark.bubble", description: Text(problem)) }
            else { Color.clear }  // a moment while the chat's found (or made)
        }
        .task {
            do { id = try await session.openDM(with: uid) } catch { problem = error.localizedDescription }
        }
    }
}

// ---------- one conversation ----------
struct ConversationView: View {
    let ref: ChatRef
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var conversation = Conversation()
    @State private var text = ""
    @State private var sent = 0
    @State private var info = false
    @FocusState private var typing: Bool

    private var uid: String { session.uid ?? "" }
    private var chat: Chat? { if case .chat(let id) = ref { session.chat(id) } else { nil } }
    private var plan: Hangout? { if case .plan(let id) = ref { session.hangout(id) } else { nil } }
    private var gone: Bool { chat == nil && plan == nil }

    private var messages: [ChatMessage] {
        switch ref {
        case .chat: conversation.messages
        case .plan(let id): session.planMessages[id] ?? []
        }
    }

    private var title: String { chat.map(session.chatTitle) ?? plan?.title ?? "Chat" }
    private var subtitle: String {
        if let chat { return chat.group ? "\(chat.members.count) people" : "@\(session.person(chat.others(uid).first ?? "")?.handle ?? "friend")" }
        if let plan { return "\(plan.attendees.count) going · \(plan.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" }
        return ""
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if messages.isEmpty {
                        VStack(spacing: 10) {
                            ChatFace(ref: ref, size: 80)
                            Text(title).font(.headline)
                            Text(chat?.group == false ? "This is the start of your chat." : "Say hi to the group!")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.top, 60)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                        bubble(m, after: i > 0 ? messages[i - 1] : nil, before: i + 1 < messages.count ? messages[i + 1] : nil)
                            .id(m.id)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) {
                if let last = messages.last { withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                session.markRead(ref)
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { info = true } label: {
                    HStack(spacing: 8) {
                        ChatFace(ref: ref, size: 30)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(isPresented: $info) { infoScreen }
        .sensoryFeedback(.impact(weight: .light), trigger: sent)
        .onAppear {
            if case .chat(let id) = ref { conversation.listen(id, db: session.db) }
            session.markRead(ref)
        }
        .onDisappear { conversation.end() }
        .onChange(of: gone) { if gone { dismiss() } }  // you left the group, or the plan's chat closed
    }

    @ViewBuilder private var infoScreen: some View {
        if let chat, chat.group { GroupInfoView(id: chat.id) }
        else if let chat { ProfileView(uid: chat.others(uid).first ?? "") }
        else if let plan { PlanDetailView(id: plan.id) }
    }

    @ViewBuilder
    private func bubble(_ m: ChatMessage, after prev: ChatMessage?, before next: ChatMessage?) -> some View {
        let mine = m.from == uid
        // a new day, or an hour's gap: the time, centered, like iMessage
        if prev.map({ m.at.timeIntervalSince($0.at) > 3600 }) ?? true {
            let style: Date.FormatStyle = Calendar.current.isDateInToday(m.at) ? .dateTime.hour().minute()
                                                                          : .dateTime.weekday(.abbreviated).month().day().hour().minute()
            Text(m.at.formatted(style))
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 14).padding(.bottom, 6)
        }
        if !m.isText {
            // "Priya created the group", "Sam arrived · 2 min early"
            let who = mine ? "You" : m.name.split(separator: " ").first.map(String.init) ?? m.name
            Text(m.kind == "system" ? m.text : "\(who) \(mine ? m.text.replacingOccurrences(of: "is ", with: "are ", options: .anchored) : m.text)")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.vertical, 6).frame(maxWidth: .infinity)
        } else {
            let group = chat?.group ?? (plan != nil)
            let firstOfRun = prev?.from != m.from || prev?.isText == false
            let lastOfRun = next?.from != m.from || next?.isText == false
            HStack(alignment: .bottom, spacing: 8) {
                if mine { Spacer(minLength: 60) }
                if !mine && group {
                    // their face on the last message of a run, like Instagram
                    Group {
                        if lastOfRun { Avatar(session.person(m.from), fallback: m.name, size: 28).opensProfile(m.from) } else { Color.clear }
                    }
                    .frame(width: 28, height: 28)
                }
                VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                    if !mine && group && firstOfRun {
                        Text(session.person(m.from)?.firstName ?? m.name.split(separator: " ").first.map(String.init) ?? "Friend")
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 12)
                    }
                    Text(m.text)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .foregroundStyle(mine ? Color.white : Color.primary)
                        .background(mine ? Color.omwBlue : Color(.secondarySystemBackground), in: .rect(cornerRadius: 19))
                        .textSelection(.enabled)
                }
                if !mine { Spacer(minLength: 60) }
            }
            .padding(.top, firstOfRun ? 6 : 0)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).foregroundStyle(Color.omwBlue)
                }
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Send")
            }
        }
        .animation(.snappy(duration: 0.18), value: text.isEmpty)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .disabled(gone)
    }

    private func send() {
        session.send(text, in: ref)
        text = ""
        sent += 1
    }
}

// ---------- group info: name, who's in it, add people, leave ----------
struct GroupInfoView: View {
    let id: String
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var leaving = false
    @State private var problem: String?

    var body: some View {
        if let c = session.chat(id) {
            let addable = session.friends.filter { !c.members.contains($0.id) }
            List {
                Section("Group name") {
                    HStack {
                        TextField(session.chatTitle(Chat(id: c.id, data: ["members": c.members, "group": true, "names": c.names])), text: $name)
                            .onChange(of: name) { if name.count > 40 { name = String(name.prefix(40)) } }
                        if name != c.title {
                            Button("Save") { session.renameGroup(c, to: name) }.fontWeight(.semibold)
                        }
                    }
                }
                Section("\(c.members.count) people") {
                    ForEach(c.members, id: \.self) { u in
                        NavigationLink(value: ProfileRoute(uid: u)) {
                            HStack(spacing: 12) {
                                Avatar(photo: session.chatPhoto(c, u), name: session.chatName(c, u), size: 40)
                                Text(session.chatName(c, u)).font(.subheadline.weight(.semibold))
                            }
                        }
                        .disabled(u == session.uid)
                    }
                }
                if !addable.isEmpty {
                    Section("Add people") {
                        ForEach(addable) { f in
                            Button { session.addToGroup(c, f.id) } label: {
                                HStack(spacing: 12) {
                                    Avatar(f, size: 40)
                                    Text(f.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.omwBlue)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Leave group", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { leaving = true }
                }
            }
            .navigationTitle("Group info")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { name = c.title }
            .confirmationDialog("Leave \(session.chatTitle(c))?", isPresented: $leaving, titleVisibility: .visible) {
                Button("Leave group", role: .destructive) {
                    Task {
                        do { try await session.leaveGroup(c) } catch { problem = error.localizedDescription }
                    }
                }
            } message: { Text("You won't get its messages anymore.") }
            .alert("Couldn't leave", isPresented: .constant(problem != nil)) { Button("OK") { problem = nil } } message: { Text(problem ?? "") }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}
