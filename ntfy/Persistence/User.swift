import Foundation

extension User {
    func toBasicUser(credentialStore: CredentialStoring) -> ServerCredential? {
        if let baseUrl,
           case .found(let credential) = credentialStore.readCredential(baseUrl: baseUrl, username: username ?? "?") {
            return credential
        }
        // Pre-Keychain stores still authenticate until their migration succeeds.
        guard let password, !password.isEmpty else { return nil }
        return .basic(username: username ?? "?", password: password)
    }
}
