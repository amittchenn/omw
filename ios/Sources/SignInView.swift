// Signing in: Sign in with Apple (Apple asks for it), or email for the demo account App Review uses.
// Same accounts as the web app (Firebase Auth).
import SwiftUI
import AuthenticationServices
import CryptoKit
import FirebaseAuth

struct SignInView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var nonce = ""
    @State private var usingEmail = false
    @State private var email = ""
    @State private var password = ""
    @State private var creating = false
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 10) {
                Text("omw!")
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .foregroundStyle(.black)
                Text("Plan hangouts. Show up on time.")
                    .font(.headline)
                    .foregroundStyle(.black.opacity(0.7))
            }
            Spacer()

            VStack(spacing: 12) {
                if usingEmail {
                    emailForm
                } else {
                    SignInWithAppleButton(.continue) { request in
                        nonce = Nonce.random()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = Nonce.sha256(nonce)
                    } onCompletion: { result in
                        apple(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 54)
                    .clipShape(.rect(cornerRadius: 14))

                    Button("Use email") { withAnimation { usingEmail = true } }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(.white.opacity(0.65), in: .rect(cornerRadius: 14))
                        .foregroundStyle(.black)
                }
                if !message.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.black.opacity(0.8)).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .disabled(busy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sun.ignoresSafeArea())
        .environment(\.colorScheme, .light)  // the sign-in screen is always the yellow one
    }

    private var emailForm: some View {
        VStack(spacing: 10) {
            TextField("Email", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 16).frame(height: 52)
                .background(.white, in: .rect(cornerRadius: 14))
            SecureField("Password", text: $password)
                .textContentType(creating ? .newPassword : .password)
                .padding(.horizontal, 16).frame(height: 52)
                .background(.white, in: .rect(cornerRadius: 14))
            Button {
                emailSignIn()
            } label: {
                Text(busy ? "One moment…" : creating ? "Create account" : "Sign in")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .background(.black, in: .rect(cornerRadius: 14))
            .foregroundStyle(.white)
            HStack {
                Button(creating ? "I have an account" : "New here? Create an account") { creating.toggle(); message = "" }
                Spacer()
                Button("Back") { withAnimation { usingEmail = false; message = "" } }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
        }
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
                    if let error { message = error.localizedDescription }
                }
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled { message = error.localizedDescription }
        }
    }

    private func emailSignIn() {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty, password.count >= 6 else { message = "Enter your email and a password of at least 6 characters."; return }
        busy = true; message = ""
        let done: (AuthDataResult?, Error?) -> Void = { _, error in
            MainActor.assumeIsolated {
                busy = false
                if let error { message = error.localizedDescription }
            }
        }
        if creating {
            Auth.auth().createUser(withEmail: email, password: password, completion: done)
        } else {
            Auth.auth().signIn(withEmail: email, password: password, completion: done)
        }
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
