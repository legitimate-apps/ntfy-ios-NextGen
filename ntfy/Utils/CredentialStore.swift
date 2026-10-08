import Foundation
import Security

/// Keychain-backed storage for per-server passwords.
///
/// Passwords used to live as a plain `String` attribute on the Core Data `User` entity, which put
/// them in the app-group SQLite in the clear. That store is sandboxed and covered by file-level
/// encryption at rest, but it lacks per-item access control and it rides along in unencrypted local
/// device backups — the Keychain does not. Upstream ships the same plaintext model, so this is a
/// fork-original fix.
///
/// The app and the notification service extension both need these (`NotificationService.swift`
/// resolves a user to authenticate polls and attachment downloads), and an extension does *not*
/// share the app's default keychain access group — its default group is derived from its own bundle
/// id. So both targets declare the shared group below in their entitlements.
protocol CredentialStoring: AnyObject {
    @discardableResult
    func setPassword(_ password: String?, baseUrl: String) -> Bool
    func password(baseUrl: String) -> String?
    /// Like `password(baseUrl:)`, but tells "nothing stored" apart from "could not read" (e.g. a
    /// prewarmed launch before first unlock). Callers that decide something from absence use this.
    func readPassword(baseUrl: String) -> TopicSecretRead<String>
    @discardableResult
    func deletePassword(baseUrl: String) -> Bool
    @discardableResult
    func setHTTPHeaders(_ headers: [String: String], baseUrl: String) -> Bool
    func readHTTPHeaders(baseUrl: String) -> HTTPHeadersReadResult
    @discardableResult
    func deleteHTTPHeaders(baseUrl: String) -> Bool
}

/// Per-topic end-to-end encryption secrets: the password the user chose and the key derived from it.
///
/// The key is cached next to the password so the notification service extension never has to run
/// PBKDF2 inside its time and memory budget. Both live in the shared access group, so the extension
/// can read them, and both are available after first unlock, because pushes arrive on a locked phone.
///
/// Reads tell "nothing stored" apart from "could not read": before first unlock after a reboot, or on
/// errSecInteractionNotAllowed, a stored secret is unreadable, and treating that as "no password"
/// would show injected plaintext as an ordinary message.
protocol TopicSecretStoring: AnyObject {
    func topicPassword(topicUrl: String) -> TopicSecretRead<String>
    func topicKey(topicUrl: String) -> TopicSecretRead<Data>
    @discardableResult
    func setTopicSecret(password: String, key: Data, topicUrl: String) -> Bool
    @discardableResult
    func deleteTopicSecret(topicUrl: String) -> Bool
}

enum TopicSecretRead<Value: Equatable>: Equatable {
    case found(Value)
    /// errSecItemNotFound: nothing is stored.
    case notFound
    /// Any other Keychain status: something may be stored but could not be read right now.
    case failed(OSStatus)

    var value: Value? {
        if case .found(let value) = self { return value }
        return nil
    }
}

/// A successful empty dictionary means no headers are stored. A failure means storage could not be
/// read and callers that edit credentials must preserve their current state.
enum HTTPHeadersReadResult: Equatable {
    case success([String: String])
    case failure
}

extension CredentialStoring {
    /// Network requests fail closed when header storage cannot be read. Editors use
    /// `readHTTPHeaders` directly so they can distinguish that failure from an absent entry.
    func httpHeaders(baseUrl: String) -> [String: String] {
        guard case .success(let headers) = readHTTPHeaders(baseUrl: baseUrl) else { return [:] }
        return headers
    }
}

enum ServerCredentials {
    private static let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func validationError(headers: [String: String]) -> String? {
        var names = Set<String>()
        for (name, value) in headers {
            guard !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }) else {
                return "Header names may contain only valid HTTP token characters."
            }
            guard names.insert(name.lowercased()).inserted else {
                return "Header names must be unique, ignoring capitalization."
            }
            guard !value.unicodeScalars.contains(where: { $0.value == 0x0D || $0.value == 0x0A }) else {
                return "Header values cannot contain line breaks."
            }
        }
        return nil
    }

    static func apply(
        to request: inout URLRequest,
        baseUrl: String,
        authorizationHeader: String? = nil,
        credentialStore: CredentialStoring = KeychainCredentialStore.shared
    ) {
        guard request.url.map({ sameOrigin($0, URL(string: normalizeBaseUrl(baseUrl))) }) == true else {
            return
        }
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        for (name, value) in credentialStore.httpHeaders(baseUrl: baseUrl) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    static func removingCredentialsFromCrossOriginRedirect(
        _ request: URLRequest,
        baseUrl: String,
        customHeaderNames: [String]
    ) -> URLRequest {
        guard request.url.map({ sameOrigin($0, URL(string: normalizeBaseUrl(baseUrl))) }) != true else {
            return request
        }
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        for name in customHeaderNames {
            sanitized.setValue(nil, forHTTPHeaderField: name)
        }
        return sanitized
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs,
              let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased() else {
            return false
        }
        func effectivePort(_ url: URL, scheme: String) -> Int? {
            url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
        }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(lhs, scheme: lhsScheme) == effectivePort(rhs, scheme: rhsScheme)
    }
}

final class ServerCredentialRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let baseUrl: String
    private let headerNames: [String]

    init(baseUrl: String, credentialStore: CredentialStoring) {
        self.baseUrl = baseUrl
        self.headerNames = Array(credentialStore.httpHeaders(baseUrl: baseUrl).keys)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(ServerCredentials.removingCredentialsFromCrossOriginRedirect(
            request,
            baseUrl: baseUrl,
            customHeaderNames: headerNames
        ))
    }
}

final class KeychainCredentialStore: CredentialStoring, TopicSecretStoring {
    static let shared = KeychainCredentialStore()

    /// Shared keychain access group (`APP_KEYCHAIN_GROUP`), the same value both entitlements files
    /// expand. The `$(AppIdentifierPrefix)` team prefix is added by the system at runtime, so it is
    /// deliberately absent here.
    static let accessGroup = Config.keychainGroup
    // Service names are prefixed with the app's bundle id. Stored items are found by these exact
    // strings, so they must not change for a build that has shipped.
    private static let passwordService = Config.bundleIdBase + ".serverPassword"
    private static let headersService = Config.bundleIdBase + ".serverHTTPHeaders"
    private static let topicPasswordService = Config.bundleIdBase + ".topicPassword"
    private static let topicKeyService = Config.bundleIdBase + ".topicKey"
    /// Topic secrets never leave this device: not in backups, not restored to another phone. After
    /// first unlock, because the extension decrypts pushes on a locked phone.
    static let topicSecretAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    private static let tag = "CredentialStore"

    /// Whether this process may actually use the shared access group. Probed once: a binary built
    /// without the `keychain-access-groups` entitlement — the unit-test host, which is built with
    /// `CODE_SIGNING_ALLOWED=NO` and therefore has its entitlements stripped — gets
    /// `errSecMissingEntitlement` for every call that names a group.
    ///
    /// Falling back to the target's default access group keeps the app functional rather than
    /// failing every auth'd request. It does mean the app and the NSE would stop sharing, so the
    /// fallback is logged loudly; in a correctly-provisioned build it never triggers.
    private static let usesAccessGroup: Bool = {
        var probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordService,
            kSecAttrAccount as String: "__entitlement_probe__",
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: Data("probe".utf8),
        ]
        let status = SecItemAdd(probe as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            probe.removeValue(forKey: kSecValueData as String)
            SecItemDelete(probe as CFDictionary)
            return true
        }
        Log.w(tag, "Keychain access group unavailable (OSStatus \(status)) — falling back to this "
                 + "target's default group. In a shipped build this means the app and the "
                 + "notification extension are NOT sharing credentials.")
        return false
    }()

    private static func query(service: String, baseUrl: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: baseUrl,
        ]
        if usesAccessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    /// Stores (or replaces) the password for a server. Passing nil/empty deletes it.
    @discardableResult
    func setPassword(_ password: String?, baseUrl: String) -> Bool {
        guard let password = password, !password.isEmpty else {
            return deletePassword(baseUrl: baseUrl)
        }
        guard let data = password.data(using: .utf8) else { return false }

        return setData(data, service: Self.passwordService, baseUrl: baseUrl, valueDescription: "password")
    }

    private func setData(
        _ data: Data,
        service: String,
        baseUrl: String,
        valueDescription: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlock
    ) -> Bool {
        var attributes = Self.query(service: service, baseUrl: baseUrl)
        // Available whenever the device has been unlocked once — the NSE runs while the screen is
        // locked, so kSecAttrAccessibleWhenUnlocked would make pushes fail to authenticate.
        attributes[kSecAttrAccessible as String] = accessibility

        let status = SecItemCopyMatching(Self.query(service: service, baseUrl: baseUrl) as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessibility]
            let updateStatus = SecItemUpdate(Self.query(service: service, baseUrl: baseUrl) as CFDictionary, update as CFDictionary)
            if updateStatus != errSecSuccess {
                Log.w(Self.tag, "Cannot update \(valueDescription) for \(baseUrl) (OSStatus \(updateStatus))")
            }
            return updateStatus == errSecSuccess
        }

        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Log.w(Self.tag, "Cannot store \(valueDescription) for \(baseUrl) (OSStatus \(addStatus))")
        }
        return addStatus == errSecSuccess
    }

    func password(baseUrl: String) -> String? {
        guard let data = data(service: Self.passwordService, baseUrl: baseUrl, valueDescription: "password") else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func readPassword(baseUrl: String) -> TopicSecretRead<String> {
        switch read(service: Self.passwordService, baseUrl: baseUrl, valueDescription: "password") {
        case .found(let data):
            guard let password = String(data: data, encoding: .utf8) else { return .failed(errSecDecode) }
            return .found(password)
        case .notFound: return .notFound
        case .failed(let status): return .failed(status)
        }
    }

    private func data(service: String, baseUrl: String, valueDescription: String) -> Data? {
        var attributes = Self.query(service: service, baseUrl: baseUrl)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Log.w(Self.tag, "Cannot read \(valueDescription) for \(baseUrl) (OSStatus \(status))")
            }
            return nil
        }
        return data
    }

    @discardableResult
    func deletePassword(baseUrl: String) -> Bool {
        delete(service: Self.passwordService, baseUrl: baseUrl)
    }

    private func delete(service: String, baseUrl: String) -> Bool {
        let status = SecItemDelete(Self.query(service: service, baseUrl: baseUrl) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    func setHTTPHeaders(_ headers: [String: String], baseUrl: String) -> Bool {
        guard !headers.isEmpty else { return deleteHTTPHeaders(baseUrl: baseUrl) }
        guard ServerCredentials.validationError(headers: headers) == nil,
              let data = try? JSONEncoder().encode(headers) else { return false }
        return setData(data, service: Self.headersService, baseUrl: normalizeBaseUrl(baseUrl), valueDescription: "HTTP headers")
    }

    func readHTTPHeaders(baseUrl: String) -> HTTPHeadersReadResult {
        let normalized = normalizeBaseUrl(baseUrl)
        var attributes = Self.query(service: Self.headersService, baseUrl: normalized)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .success([:])
        }
        guard status == errSecSuccess, let data = item as? Data else {
            Log.w(Self.tag, "Cannot read HTTP headers for \(normalized) (OSStatus \(status))")
            return .failure
        }
        guard let headers = try? JSONDecoder().decode([String: String].self, from: data),
              ServerCredentials.validationError(headers: headers) == nil else {
            Log.w(Self.tag, "Stored HTTP headers for \(normalized) are invalid")
            return .failure
        }
        return .success(headers)
    }

    @discardableResult
    func deleteHTTPHeaders(baseUrl: String) -> Bool {
        delete(service: Self.headersService, baseUrl: normalizeBaseUrl(baseUrl))
    }

    // MARK: Topic encryption secrets (TopicSecretStoring)

    func topicPassword(topicUrl: String) -> TopicSecretRead<String> {
        switch read(service: Self.topicPasswordService, baseUrl: topicUrl, valueDescription: "topic password") {
        case .found(let data):
            guard let password = String(data: data, encoding: .utf8) else { return .failed(errSecDecode) }
            return .found(password)
        case .notFound: return .notFound
        case .failed(let status): return .failed(status)
        }
    }

    func topicKey(topicUrl: String) -> TopicSecretRead<Data> {
        read(service: Self.topicKeyService, baseUrl: topicUrl, valueDescription: "topic key")
    }

    private func read(service: String, baseUrl: String, valueDescription: String) -> TopicSecretRead<Data> {
        var attributes = Self.query(service: service, baseUrl: baseUrl)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .notFound
        }
        guard status == errSecSuccess, let data = item as? Data else {
            Log.w(Self.tag, "Cannot read \(valueDescription) for \(baseUrl) (OSStatus \(status))")
            return .failed(status == errSecSuccess ? errSecDecode : status)
        }
        return .found(data)
    }

    @discardableResult
    func setTopicSecret(password: String, key: Data, topicUrl: String) -> Bool {
        guard !password.isEmpty, let passwordData = password.data(using: .utf8) else { return false }
        // Key first: a password without its key still works (the key is re-derived), a key without its
        // password would leave settings unable to show what is in use.
        guard setData(key, service: Self.topicKeyService, baseUrl: topicUrl, valueDescription: "topic key",
                      accessibility: Self.topicSecretAccessibility) else {
            return false
        }
        guard setData(passwordData, service: Self.topicPasswordService, baseUrl: topicUrl, valueDescription: "topic password",
                      accessibility: Self.topicSecretAccessibility) else {
            // Don't leave a new key next to the old password: drop it so it is re-derived from the
            // password that is actually stored.
            _ = delete(service: Self.topicKeyService, baseUrl: topicUrl)
            return false
        }
        return true
    }

    @discardableResult
    func deleteTopicSecret(topicUrl: String) -> Bool {
        let keyDeleted = delete(service: Self.topicKeyService, baseUrl: topicUrl)
        let passwordDeleted = delete(service: Self.topicPasswordService, baseUrl: topicUrl)
        return keyDeleted && passwordDeleted
    }

    /// Whether this process can use the Keychain at all. Unsigned unit-test hosts have neither the
    /// shared access group nor a default `application-identifier` group, so even the fallback query
    /// is unavailable. A real-Keychain integration test uses this probe to report an honest skip;
    /// production credential reads and writes still use the methods above directly.
    var isAvailable: Bool {
        let probeBaseUrl = "__keychain_availability_\(UUID().uuidString)__"
        guard setPassword("probe", baseUrl: probeBaseUrl) else { return false }
        return deletePassword(baseUrl: probeBaseUrl)
    }
}
