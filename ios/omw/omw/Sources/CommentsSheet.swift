// Comments on a post, like Instagram: a sheet with everyone's comments and your box at the bottom.
// Press and hold a comment to delete it (yours, or any on your post) or report it.
import SwiftUI

struct CommentsSheet: View {
    let post: Post
    @Environment(Session.self) private var session
    @State private var text = ""
    @FocusState private var typing: Bool

    private var list: [Comment] { session.comments[post.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            Text("Comments").font(.headline).padding(.top, 20).padding(.bottom, 12)
            Divider()
            if list.isEmpty {
                ContentUnavailableView("No comments yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Start the conversation."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(list) { c in row(c).id(c.id) }
                        }
                        .padding(16)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: list.count) { if let last = list.last { withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) } } }
                    .onAppear { if let last = list.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Avatar(session.me, size: 34)
                TextField("Add a comment…", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .overlay(Capsule().strokeBorder(Color(.separator)))
                Button("Post", action: send)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.omwBlue)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .onAppear { session.watchComments(post.id) }
    }

    private func row(_ c: Comment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(session.person(c.from), fallback: c.name, size: 34).opensProfile(c.from)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(session.handle(c.from, name: c.name)).font(.footnote.weight(.semibold)).opensProfile(c.from)
                    Text(When.ago(c.at)).font(.footnote).foregroundStyle(.secondary)
                }
                Text(c.text).font(.subheadline)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if c.from == session.uid || post.by == session.uid {
                Button("Delete comment", systemImage: "trash", role: .destructive) { session.deleteComment(c, on: post.id) }
            } else {
                Button("Report comment", systemImage: "exclamationmark.bubble", role: .destructive) { session.reportComment(c, on: post.id) }
            }
        }
    }

    private func send() {
        session.addComment(text, to: post.id)
        text = ""
    }
}
