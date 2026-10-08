import Foundation
import CryptoKit
import CommonCrypto
import Security

/// End-to-end encrypted topics, in the format of upstream ntfy's own E2E draft
/// (binwiederhier/ntfy#69, prototype PR #354: `crypto/crypto.go` and the PHP/Python publish examples).
///
/// - Key: PBKDF2-HMAC-SHA256(password, salt = SHA256(topic URL), 50 000 iterations, 32 bytes).
/// - Ciphertext: JWE compact serialization with the protected header `{"alg":"dir","enc":"A256GCM"}`,
///   an empty encrypted-key segment, a 96-bit IV, the encoded header as AAD and a 128-bit tag.
/// - Plaintext: a JSON object with the ntfy publish fields (`EncryptedPayload`).
///
/// The sender puts the JWE in the message body. Stock ntfy servers store it as an ordinary message, so
/// the server, Firebase and APNs only ever see ciphertext. Detection is by shape (`parse`), never by the
/// `X-Encoding: jwe` header, which stock servers drop.
///
/// This file depends only on Foundation, CryptoKit and CommonCrypto so it compiles on its own:
/// `scripts/e2e-interop` builds it with `swiftc` to check the shipped code against an independent
/// implementation.
enum TopicEncryption {
    static let iterations: UInt32 = 50_000
    static let keyLength = 32
    static let ivLength = 12
    static let tagLength = 16
    /// The exact protected header upstream's implementations emit.
    static let protectedHeader = #"{"alg":"dir","enc":"A256GCM"}"#
    /// `Encoding` header value for publishing (upstream draft name; stock servers ignore it).
    /// The header upstream's Go client sends; servers read `X-Encoding` and `Encoding` alike.
    static let encodingHeaderName = "X-Encoding"
    static let encodingHeaderValue = "jwe"
    /// ntfy's default message size limit. A larger body becomes an attachment on a stock server, which
    /// would silently defeat detection, so encryption refuses to produce one.
    static let maxMessageBytes = 4096

    enum Failure: Error, Equatable {
        case keyDerivationFailed
        case invalidKey
        case notJWE
        case authenticationFailed
        case tooLarge(bytes: Int)
    }

    struct CompactJWE: Equatable {
        /// The header segment exactly as received; it is the AAD, so it must never be re-encoded.
        let encodedHeader: String
        let iv: Data
        let ciphertext: Data
        let tag: Data
    }

    // MARK: Key derivation

    static func deriveKey(password: String, topicUrl: String) -> Data? {
        let salt = Data(SHA256.hash(data: Data(topicUrl.utf8)))
        let passwordBytes = Array(password.utf8).map { CChar(bitPattern: $0) }
        var key = Data(count: keyLength)
        let status = key.withUnsafeMutableBytes { keyBuffer -> Int32 in
            salt.withUnsafeBytes { saltBuffer -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes, passwordBytes.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    keyBuffer.bindMemory(to: UInt8.self).baseAddress, keyLength
                )
            }
        }
        return status == kCCSuccess ? key : nil
    }

    // MARK: Shape detection

    /// Parses `text` as an upstream-format JWE, or returns nil when it is anything else. Strict on
    /// purpose: a plain message that merely contains dots (or a JWT, or a JWE with another algorithm)
    /// must keep rendering as text rather than turn into "Encrypted message".
    static func parse(_ text: String) -> CompactJWE? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[1].isEmpty, !parts[0].isEmpty, !parts[2].isEmpty, !parts[4].isEmpty,
              let headerData = base64urlDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header.count == 2,
              header["alg"] as? String == "dir",
              header["enc"] as? String == "A256GCM",
              let iv = base64urlDecode(parts[2]), iv.count == ivLength,
              let ciphertext = base64urlDecode(parts[3]),
              let tag = base64urlDecode(parts[4]), tag.count == tagLength
        else {
            return nil
        }
        return CompactJWE(encodedHeader: String(parts[0]), iv: iv, ciphertext: ciphertext, tag: tag)
    }

    static func isEncrypted(_ text: String?) -> Bool {
        guard let text else { return false }
        return parse(text) != nil
    }

    // MARK: Encrypt / decrypt

    static func encrypt(_ plaintext: Data, key: Data, iv: Data? = nil) throws -> String {
        guard key.count == keyLength else { throw Failure.invalidKey }
        let encodedHeader = base64urlEncode(Data(protectedHeader.utf8))
        let ivData = iv ?? randomBytes(ivLength)
        let nonce = try AES.GCM.Nonce(data: ivData)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: nonce,
            authenticating: Data(encodedHeader.utf8)
        )
        let jwe = [
            encodedHeader,
            "",
            base64urlEncode(ivData),
            base64urlEncode(sealed.ciphertext),
            base64urlEncode(sealed.tag),
        ].joined(separator: ".")
        guard jwe.utf8.count <= maxMessageBytes else { throw Failure.tooLarge(bytes: jwe.utf8.count) }
        return jwe
    }

    static func decrypt(_ text: String, key: Data) throws -> Data {
        guard key.count == keyLength else { throw Failure.invalidKey }
        guard let jwe = parse(text) else { throw Failure.notJWE }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: jwe.iv),
                ciphertext: jwe.ciphertext,
                tag: jwe.tag
            )
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(jwe.encodedHeader.utf8))
        } catch {
            throw Failure.authenticationFailed
        }
    }

    // MARK: Payload

    static func encrypt(_ payload: EncryptedPayload, key: Data) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encrypt(try encoder.encode(payload), key: key)
    }

    /// Decrypts and decodes. A payload that authenticates but is not a JSON object is shown as plain
    /// text: the tag proves it came from someone holding the password, so dropping it would only hide
    /// a genuine message (e.g. `echo hi | encrypt`).
    static func decryptPayload(_ text: String, key: Data) throws -> EncryptedPayload {
        let plaintext = try decrypt(text, key: key)
        if let payload = try? JSONDecoder().decode(EncryptedPayload.self, from: plaintext) {
            return payload
        }
        return EncryptedPayload(message: String(decoding: plaintext, as: UTF8.self))
    }

    /// 144 random bits, base64url: long enough that PBKDF2's modest cost does not matter.
    static func generatePassword() -> String {
        base64urlEncode(randomBytes(18))
    }

    // MARK: base64url (RFC 7515 §2: no padding)

    static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode<S: StringProtocol>(_ text: S) -> Data? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }), text.count % 4 != 1 else { return nil }
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
}

/// The plaintext inside an encrypted message: the fields of ntfy's JSON publish format. Unknown fields
/// are ignored; `priority` and `tags` also accept the header-style string forms ("4", "a,b").
struct EncryptedPayload: Codable, Equatable {
    var message: String
    var title: String?
    var tags: [String]?
    var priority: Int?
    var click: String?
    var icon: String?
    var markdown: Bool?
    var actions: [ActionPayload]?

    struct ActionPayload: Codable, Equatable {
        var action: String
        var label: String
        var url: String?
        var method: String?
        var headers: [String: String]?
        var body: String?
        var clear: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case message, title, tags, priority, click, icon, markdown, actions
    }

    init(message: String, title: String? = nil, tags: [String]? = nil, priority: Int? = nil,
         click: String? = nil, icon: String? = nil, markdown: Bool? = nil, actions: [ActionPayload]? = nil) {
        self.message = message
        self.title = title
        self.tags = tags
        self.priority = priority
        self.click = click
        self.icon = icon
        self.markdown = markdown
        self.actions = actions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        if let list = try? c.decodeIfPresent([String].self, forKey: .tags) {
            tags = list
        } else if let joined = try? c.decodeIfPresent(String.self, forKey: .tags) {
            tags = joined.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let number = try? c.decodeIfPresent(Int.self, forKey: .priority) {
            priority = number
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .priority) {
            priority = Int(text)
        }
        click = try? c.decodeIfPresent(String.self, forKey: .click)
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        markdown = try? c.decodeIfPresent(Bool.self, forKey: .markdown)
        actions = try? c.decodeIfPresent([ActionPayload].self, forKey: .actions)
    }
}
