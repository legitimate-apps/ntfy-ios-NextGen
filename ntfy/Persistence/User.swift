import Foundation

extension User {
    func toBasicUser(credentialStore: CredentialStoring) -> BasicUser {
        // Prefer the Keychain; fall back to the Core Data column only for a store that hasn't been
        // migrated yet (see Store.migrateCredentialsToKeychain), so an un-migrated user still
        // authenticates instead of silently failing every read-protected topic.
        let keychainPassword = baseUrl.flatMap { credentialStore.password(baseUrl: $0) }
        // An empty column means "migrated" — the real secret lives in the Keychain.
        let legacy = (password?.isEmpty ?? true) ? nil : password
        return BasicUser(username: username ?? "?",
                         password: keychainPassword ?? legacy ?? "?")
    }
}
