import AuthenticationServices
import CryptoKit
import Security
import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var rawNonce = ""
    @State private var isWorking = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()
            VitalBrandLockup(layout: .stacked, markSize: 64)
            Text("Your private health tracker and coach.\nFor adults 18+. Educational, not medical advice.")
                .vitalFont(.body).foregroundStyle(VitalColors.textSecondary).multilineTextAlignment(.center)
            Spacer()
            if model.backend != nil {
                SignInWithAppleButton(.signIn) { request in
                    rawNonce = Self.randomNonce()
                    request.requestedScopes = [.fullName]
                    request.nonce = Self.sha256(rawNonce)
                } onCompletion: { result in
                    handle(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .disabled(isWorking)
                .accessibilityHint("Creates or opens your private VitalCoach account")
            } else {
                NoticeBanner(style: .warning, text: "Cloud accounts aren't set up in this build yet (see docs/SETUP.md). You can try the app with data stored only on this iPhone.")
            }
            Button(model.backend == nil ? "Try on this iPhone only" : "Use without an account (this iPhone only)") {
                Task { await model.startLocalOnly() }
            }
            .buttonStyle(VitalButtonStyle(kind: .tertiary))
            if isWorking { ProgressView().tint(VitalColors.accent) }
            Text("A PrecisionPeptidePens company")
                .vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
        }
        .padding(Theme.Spacing.xl)
        .vitalScreenBackground()
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                model.lastError = "Apple didn't return a sign-in token. Please try again."
                return
            }
            isWorking = true
            Task {
                await model.signInWithApple(idToken: token, rawNonce: rawNonce)
                isWorking = false
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            model.lastError = "Sign in with Apple failed: \(error.localizedDescription)"
        }
    }

    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        precondition(SecRandomCopyBytes(kSecRandomDefault, length, &bytes) == errSecSuccess)
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
