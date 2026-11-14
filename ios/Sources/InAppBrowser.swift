// Web links (Terms, Privacy Policy, Help, links in chats) open in a sheet inside omw! instead of throwing you out to
// Safari. Other links (maps://, tel:, mailto:, omw://) still go to the system.
import SwiftUI
import SafariServices

private struct WebPage: Identifiable { let url: URL; var id: String { url.absoluteString } }

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Color.coral)
        vc.dismissButtonStyle = .close
        return vc
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

private struct InAppBrowser: ViewModifier {
    @State private var page: WebPage?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .systemAction }
                if url.path().hasPrefix("/terms") || url.path().hasPrefix("/privacy") || url.path().hasPrefix("/support") {
                    API.wake()  // the legal pages live on our server: start waking it right away
                }
                page = WebPage(url: url)
                return .handled
            })
            .sheet(item: $page) { SafariView(url: $0.url).ignoresSafeArea() }
    }
}

extension View {
    /// open web links in an in-app Safari sheet
    func inAppBrowser() -> some View { modifier(InAppBrowser()) }
}
