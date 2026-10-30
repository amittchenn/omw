// Signing in: Google, Apple (Apple asks for it when there's another sign-in), or email (also the demo account App
// Review uses). Same accounts as the web app (Firebase Auth), so you land in the same account whichever app you use.
// The omw! clock up top, the buttons at the bottom, email in its own sheet.
import SwiftUI
import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
#if canImport(GoogleSignIn)
import GoogleSignIn  // the GoogleSignIn package (ios/README.md); without it the app still builds, minus the Google button
#endif

struct SignInView: View {
    @State private var nonce = ""
    @State private var emailing = false
    @State private var busy = false
    @State private var message = ""
    @State private var shown = false

    private static let legal = (try? AttributedString(markdown:
        "By continuing, you agree to the [Terms](\(API.base.appending(path: "terms").absoluteString)) and [Privacy Policy](\(API.base.appending(path: "privacy").absoluteString))."))
        ?? AttributedString("By continuing, you agree to the Terms and Privacy Policy.")

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 6) {
                Ticki(mood: .wave)
                    .frame(width: 190, height: 190)
                    .rotationEffect(.degrees(shown ? 0 : -14))
                    .scaleEffect(shown ? 1 : 0.7)
                    .padding(.bottom, 8)
                Text("omw!")
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .tracking(-1.5)
                Text("Hang out. Show up on time.")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.6))
            }
            .foregroundStyle(.black)
            .opacity(shown ? 1 : 0)
            Spacer()
            Spacer()

            VStack(spacing: 10) {
                Button(action: google) {
                    Label { Text("Continue with Google") } icon: { GoogleG().frame(width: 19, height: 19) }
                        .labelStyle(SignInLabel())
                        .background(.white, in: .rect(cornerRadius: 16))
                        .foregroundStyle(.black)
                }
                SignInWithAppleButton(.continue) { request in
                    nonce = Nonce.random()
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = Nonce.sha256(nonce)
                } onCompletion: { result in
                    apple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 56)
                .clipShape(.rect(cornerRadius: 16))

                Button { emailing = true } label: {
                    Label("Continue with email", systemImage: "envelope.fill")
                        .labelStyle(SignInLabel())
                        .foregroundStyle(.black)
                        .background(.black.opacity(0.07), in: .rect(cornerRadius: 16))
                }

                if !message.isEmpty {
                    Text(message)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.black.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                        .transition(.opacity)
                }

                Text(Self.legal)
                    .font(.caption)
                    .foregroundStyle(.black.opacity(0.5))
                    .tint(.black)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .buttonStyle(Pressable())
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
            .disabled(busy)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sun.ignoresSafeArea())
        .environment(\.colorScheme, .light)  // the sign-in screen is always the yellow one
        .animation(.snappy(duration: 0.2), value: message)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { shown = true } }
        .sheet(isPresented: $emailing) {
            EmailSignIn()
                .presentationDetents([.height(440)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
    }

    /// Google's sign-in sheet, then into Firebase with what it hands back
    private func google() {
        #if canImport(GoogleSignIn)
        guard let clientID = FirebaseApp.app()?.options.clientID,
              let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController
        else { message = "Google sign-in isn't set up in this build."; return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        message = ""
        GIDSignIn.sharedInstance.signIn(withPresenting: root) { result, error in
            MainActor.assumeIsolated {
                if let error {
                    if (error as NSError).code != GIDSignInError.Code.canceled.rawValue { message = SignIn.friendly(error) }
                    return
                }
                guard let user = result?.user, let idToken = user.idToken?.tokenString else { message = "Google didn't send a sign-in. Try again."; return }
                busy = true
                let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: user.accessToken.tokenString)
                Auth.auth().signIn(with: credential) { _, error in
                    MainActor.assumeIsolated {
                        busy = false
                        if let error { message = SignIn.friendly(error) }
                    }
                }
            }
        }
        #else
        message = "Add the GoogleSignIn package in Xcode to sign in with Google (see ios/README.md)."
        #endif
    }

    private func apple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                message = "Apple didn't send a sign-in. Try again."; return
            }
            busy = true
            let firebase = OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce, fullName: credential.fullName)
            Auth.auth().signIn(with: firebase) { _, error in
                MainActor.assumeIsolated {
                    busy = false
                    if let error { message = SignIn.friendly(error) }
                }
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled { message = SignIn.friendly(error) }
        }
    }
}

/// Email and password, in a sheet: sign in, create an account, or get a reset link
struct EmailSignIn: View {
    @State private var email = ""
    @State private var password = ""
    @State private var creating = false
    @State private var busy = false
    @State private var message = ""
    @FocusState private var field: Field?

    enum Field { case email, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(creating ? "Create your account" : "Sign in with email")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .padding(.top, 28)
            Picker("", selection: $creating) {
                Text("Sign in").tag(false)
                Text("Create account").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            TextField("Email", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($field, equals: .email)
                .submitLabel(.next)
                .onSubmit { field = .password }
                .modifier(SignInField())
            SecureField(creating ? "Password (6+ characters)" : "Password", text: $password)
                .textContentType(creating ? .newPassword : .password)
                .focused($field, equals: .password)
                .submitLabel(.go)
                .onSubmit(submit)
                .modifier(SignInField())

            Button(action: submit) {
                Text(busy ? "One moment…" : creating ? "Create account" : "Sign in")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.primary, in: .rect(cornerRadius: 16))
                    .foregroundStyle(Color(.systemBackground))
            }
            .buttonStyle(Pressable())
            .disabled(busy)

            if !creating {
                Button("Forgot password?", action: forgot)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
            if !message.isEmpty {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .animation(.snappy(duration: 0.2), value: creating)
        .animation(.snappy(duration: 0.2), value: message)
        .onChange(of: creating) { message = "" }
        .onAppear { field = .email }
    }

    private func submit() {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { message = "Enter your email."; field = .email; return }
        guard password.count >= 6 else { message = "Passwords are at least 6 characters."; field = .password; return }
        busy = true; message = ""
        let done: (AuthDataResult?, Error?) -> Void = { _, error in
            MainActor.assumeIsolated {
                busy = false
                if let error { message = SignIn.friendly(error) }
            }
        }
        if creating { Auth.auth().createUser(withEmail: email, password: password, completion: done) }
        else { Auth.auth().signIn(withEmail: email, password: password, completion: done) }
    }

    private func forgot() {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { message = "Type your email first, then tap Forgot password."; field = .email; return }
        Auth.auth().sendPasswordReset(withEmail: email) { error in
            MainActor.assumeIsolated {
                message = error.map(SignIn.friendly) ?? "Check your email for a link to reset your password."
            }
        }
    }
}

enum SignIn {
    /// Firebase's messages in plain words ("The supplied auth credential is malformed or has expired" means a wrong password)
    nonisolated static func friendly(_ error: Error) -> String {
        switch AuthErrorCode(rawValue: (error as NSError).code) {
        case .wrongPassword, .invalidCredential, .userNotFound:
            "Wrong email or password. If you signed up with Google or Apple, use that button instead."
        case .emailAlreadyInUse: "That email already has an account. Sign in instead."
        case .invalidEmail: "That doesn't look like an email address."
        case .weakPassword: "Pick a password with at least 6 characters."
        case .networkError: "No connection. Check your internet and try again."
        case .tooManyRequests: "Too many tries. Wait a minute and try again."
        case .accountExistsWithDifferentCredential: "That email already signs in another way. Try Google, Apple or email."
        default: error.localizedDescription
        }
    }
}

// ---------- the pieces ----------

/// a sign-in button's inside: icon and words centered, full width, 56 tall
private struct SignInLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
            configuration.title
        }
        .font(.system(size: 18, weight: .semibold))
        .frame(maxWidth: .infinity, minHeight: 56)
    }
}

/// buttons give a little when pressed
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

private struct SignInField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16).frame(height: 52)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
    }
}

/// omw!'s clock, the app icon's sticker (the same drawing as the web app's logo), drawn so it's sharp at any size
struct OmwMark: View {
    private let ink = Color(red: 0.067, green: 0.067, blue: 0.078)

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 512
            ctx.scaleBy(x: k, y: k)

            var clock = Path()
            clock.addEllipse(in: CGRect(x: 90, y: 100, width: 116, height: 116))    // bells
            clock.addEllipse(in: CGRect(x: 266, y: 100, width: 116, height: 116))
            clock.addPath(Self.leg(x: 154, degrees: 24, about: CGPoint(x: 176, y: 400)))  // legs
            clock.addPath(Self.leg(x: 276, degrees: -24, about: CGPoint(x: 298, y: 400)))
            clock.addEllipse(in: CGRect(x: 86, y: 122, width: 300, height: 300))     // body

            var tilted = ctx
            tilted.translateBy(x: 236, y: 272)
            tilted.rotate(by: .degrees(-16))
            tilted.translateBy(x: -232, y: -266)  // back, plus the drawing's (4, 6) nudge
            tilted.stroke(clock, with: .color(.white), style: StrokeStyle(lineWidth: 34, lineJoin: .round))  // sticker edge
            tilted.fill(clock, with: .color(.white))
            tilted.fill(clock, with: .color(ink))
            tilted.fill(Path(ellipseIn: CGRect(x: 112, y: 148, width: 248, height: 248)), with: .color(.white))  // face
            let marks = [CGRect(x: 229, y: 160, width: 14, height: 30), CGRect(x: 229, y: 354, width: 14, height: 30),
                         CGRect(x: 124, y: 265, width: 30, height: 14), CGRect(x: 318, y: 265, width: 30, height: 14)]
            for r in marks { tilted.fill(Path(roundedRect: r, cornerRadius: 7), with: .color(ink)) }  // hour marks
            var hands = Path()
            hands.move(to: CGPoint(x: 236, y: 272)); hands.addLine(to: CGPoint(x: 222, y: 182))
            hands.move(to: CGPoint(x: 236, y: 272)); hands.addLine(to: CGPoint(x: 304, y: 258))
            tilted.stroke(hands, with: .color(ink), style: StrokeStyle(lineWidth: 18, lineCap: .round))
            tilted.fill(Path(ellipseIn: CGRect(x: 216, y: 252, width: 40, height: 40)), with: .color(ink))
            tilted.fill(Path(ellipseIn: CGRect(x: 229, y: 265, width: 14, height: 14)), with: .color(Color.sun))

            // speed lines: on my way
            let speed: [(CGPoint, CGPoint, CGPoint, CGPoint, CGFloat)] = [
                (CGPoint(x: 404, y: 206), CGPoint(x: 436, y: 212), CGPoint(x: 462, y: 226), CGPoint(x: 482, y: 250), 20),
                (CGPoint(x: 412, y: 268), CGPoint(x: 442, y: 278), CGPoint(x: 464, y: 296), CGPoint(x: 478, y: 322), 20),
                (CGPoint(x: 404, y: 338), CGPoint(x: 424, y: 350), CGPoint(x: 438, y: 366), CGPoint(x: 446, y: 386), 18),
            ]
            for (from, c1, c2, to, width) in speed {
                var line = Path()
                line.move(to: from)
                line.addCurve(to: to, control1: c1, control2: c2)
                ctx.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// one leg: a rounded bar, turned about its middle
    private static func leg(x: CGFloat, degrees: CGFloat, about p: CGPoint) -> Path {
        let bar = Path(roundedRect: CGRect(x: x, y: 376, width: 44, height: 74), cornerRadius: 22)
        let turn = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: degrees * .pi / 180).translatedBy(x: -p.x, y: -p.y)
        return bar.applying(turn)
    }
}

/// Google's "G", drawn (four colored arcs and the bar), so there's no image to add
struct GoogleG: View {
    var body: some View {
        GeometryReader { g in
            let w = min(g.size.width, g.size.height), line = w * 0.2, r = (w - line) / 2
            ZStack {
                arc(0.0, 0.13, Color(red: 0.26, green: 0.52, blue: 0.96), line)    // blue, right
                arc(0.13, 0.38, Color(red: 0.20, green: 0.66, blue: 0.33), line)   // green, bottom
                arc(0.38, 0.62, Color(red: 0.98, green: 0.74, blue: 0.02), line)   // yellow, left
                arc(0.62, 0.875, Color(red: 0.92, green: 0.26, blue: 0.21), line)  // red, top
                Rectangle().fill(Color(red: 0.26, green: 0.52, blue: 0.96))
                    .frame(width: r + line / 2, height: line)
                    .offset(x: (r + line / 2) / 2)
            }
            .frame(width: w, height: w)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func arc(_ from: CGFloat, _ to: CGFloat, _ color: Color, _ line: CGFloat) -> some View {
        Circle().trim(from: from, to: to).stroke(color, style: StrokeStyle(lineWidth: line)).padding(line / 2)
    }
}

/// The one-time code Sign in with Apple needs (Firebase checks it against Apple's answer)
enum Nonce {
    static func random(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
