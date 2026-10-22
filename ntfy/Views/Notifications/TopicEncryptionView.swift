import SwiftUI
import UIKit

/// How hard a typed password is to guess, as a rough hint. Generated passwords skip this: they carry
/// 144 random bits, which is what makes PBKDF2's modest iteration count irrelevant.
enum TopicPasswordStrength: Equatable {
    case weak, fair, good, strong

    /// Estimated bits: length × log2(size of the character classes used). Deliberately simple; it is a
    /// nudge toward "Generate", not a guarantee.
    static func estimateBits(_ password: String) -> Double {
        guard !password.isEmpty else { return 0 }
        var pool = 0
        let scalars = password.unicodeScalars
        if scalars.contains(where: { CharacterSet.lowercaseLetters.contains($0) && $0.isASCII }) { pool += 26 }
        if scalars.contains(where: { CharacterSet.uppercaseLetters.contains($0) && $0.isASCII }) { pool += 26 }
        if scalars.contains(where: { CharacterSet.decimalDigits.contains($0) && $0.isASCII }) { pool += 10 }
        if scalars.contains(where: { $0.isASCII && !CharacterSet.alphanumerics.contains($0) }) { pool += 33 }
        if scalars.contains(where: { !$0.isASCII }) { pool += 100 }
        return Double(password.count) * log2(Double(max(pool, 2)))
    }

    init(_ password: String) {
        let bits = Self.estimateBits(password)
        switch bits {
        case ..<50: self = .weak
        case ..<70: self = .fair
        case ..<100: self = .good
        default: self = .strong
        }
    }

    var hint: String {
        switch self {
        case .weak: return String(localized: "Weak: easy to guess for someone who copies the encrypted messages. Use Generate, or a much longer password.")
        case .fair: return String(localized: "Fair. A longer password, or Generate, is safer.")
        case .good: return String(localized: "Good.")
        case .strong: return String(localized: "Strong.")
        }
    }
}

/// Copies a secret so it stays on this device (no Universal Clipboard) and clears itself.
enum SecretPasteboard {
    static let lifetime: TimeInterval = 120

    static func options(now: Date = Date()) -> [UIPasteboard.OptionsKey: Any] {
        [.localOnly: true, .expirationDate: now.addingTimeInterval(lifetime)]
    }

    static func copy(_ text: String, to pasteboard: UIPasteboard = .general) {
        pasteboard.setItems([["public.utf8-plain-text": text]], options: options())
    }
}

/// Topic menu → "End-to-end encryption": set, show, copy, change or remove a topic's password.
struct TopicEncryptionView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject var subscription: Subscription

    @State private var currentPassword: String?
    /// Encryption is on, but the password can't be read on this device right now.
    @State private var passwordUnreadable = false
    @State private var draft = ""
    /// The last generated password; the strength hint is skipped while the draft still equals it.
    @State private var generatedPassword: String?
    @State private var isEditing = false
    @State private var revealPassword = false
    @State private var confirmRemove = false
    @State private var status: String?
    @State private var didLoad = false

    private var topicUrlString: String { subscription.urlString() }
    private var trimmedDraft: String { TopicEncryption.normalizedPassword(draft) }
    private var draftIsGenerated: Bool { generatedPassword != nil && draft == generatedPassword }

    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text(String(localized: "End-to-end encryption")),
                    footer: Text(String(localized: "With a password, messages are encrypted by whoever sends them, in transit and on the server: the server, Google and Apple see only ciphertext. Once they arrive they are stored readable on this device. The password stays on this device only and isn't backed up, so a restored or new phone needs it entered again. Senders need the same password; see \"How to send encrypted messages\"."))
                ) {
                    if let currentPassword, !isEditing {
                        Label(String(localized: "On for this topic"), systemImage: "lock.fill")
                        HStack {
                            Text(revealPassword ? currentPassword : String(repeating: "•", count: 12))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .accessibilityLabel(revealPassword ? currentPassword : String(localized: "Password hidden"))
                            Spacer()
                            Button(revealPassword ? String(localized: "Hide") : String(localized: "Show")) { revealPassword.toggle() }
                                .buttonStyle(.borderless)
                        }
                        Button(String(localized: "Copy password")) {
                            SecretPasteboard.copy(currentPassword)
                            status = String(localized: "Password copied. It stays on this device and clears in 2 minutes.")
                        }
                        Button(String(localized: "Change password")) {
                            draft = ""
                            generatedPassword = nil
                            isEditing = true
                        }
                        Button(String(localized: "Remove password"), role: .destructive) { confirmRemove = true }
                    } else {
                        if passwordUnreadable && !isEditing {
                            Label(String(localized: "On, but the password can't be read right now"), systemImage: "lock.trianglebadge.exclamationmark")
                            Text(String(localized: "Encrypted messages stay locked and plain ones are marked \"Not encrypted\". If this persists after unlocking your phone, set the password again or remove it."))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Button(String(localized: "Remove password"), role: .destructive) { confirmRemove = true }
                        } else if currentPassword == nil {
                            Label(String(localized: "Off for this topic"), systemImage: "lock.open")
                        }
                        TextField(String(localized: "Password"), text: $draft)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        Button(String(localized: "Generate strong password")) {
                            let generated = TopicEncryption.generatePassword()
                            generatedPassword = generated
                            draft = generated
                        }
                        Text(String(localized: "Spaces at the start and end are removed."))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        if !trimmedDraft.isEmpty && !draftIsGenerated {
                            Text(TopicPasswordStrength(trimmedDraft).hint)
                                .font(.footnote)
                                .foregroundColor(TopicPasswordStrength(trimmedDraft) == .weak ? .orange : .secondary)
                        }
                        Button(String(localized: "Save password")) { save() }
                            .disabled(trimmedDraft.isEmpty)
                        if isEditing {
                            Button(String(localized: "Cancel")) {
                                isEditing = false
                                draft = ""
                            }
                        }
                    }
                    if let status {
                        Text(status)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    NavigationLink(destination: TopicEncryptionHelpView(topicUrl: topicUrlString, password: currentPassword)) {
                        Text(String(localized: "How to send encrypted messages"))
                    }
                }
            }
            .navigationTitle(String(localized: "Encryption"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "Done")) { presentationMode.wrappedValue.dismiss() }
                }
            }
            .alert(isPresented: $confirmRemove) {
                Alert(
                    title: Text(String(localized: "Remove password?")),
                    message: Text(String(localized: "Messages you already received stay readable. New encrypted messages will show as \"Encrypted message\" until you set the password again.")),
                    primaryButton: .destructive(Text(String(localized: "Remove"))) {
                        if store.removeEncryptionPassword(for: subscription) {
                            currentPassword = nil
                            passwordUnreadable = false
                            revealPassword = false
                            status = String(localized: "Password removed.")
                        } else {
                            status = String(localized: "Could not remove the password. Encryption is still on.")
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                switch store.encryptionPasswordState(for: subscription) {
                case .off: currentPassword = nil
                case .on(let password): currentPassword = password
                case .unreadable: passwordUnreadable = true
                }
            }
        }
    }

    private func save() {
        let password = trimmedDraft
        guard let opened = store.setEncryptionPassword(password, for: subscription) else {
            status = String(localized: "Could not save the password. Nothing was changed.")
            return
        }
        currentPassword = password
        passwordUnreadable = false
        revealPassword = draftIsGenerated
        isEditing = false
        draft = ""
        status = opened > 0
            ? String(localized: "Encryption on. \(opened) earlier encrypted messages unlocked.")
            : String(localized: "Encryption on.")
    }
}

/// Sender snippets for this topic. The password is left out unless the user explicitly inserts it.
struct TopicEncryptionHelpView: View {
    let topicUrl: String
    let password: String?

    private enum Language: String, CaseIterable, Identifiable {
        case node = "Node.js"
        case python = "Python"
        var id: String { rawValue }
    }

    @State private var language: Language = .node
    @State private var includePassword = false
    @State private var copied = false

    private var snippet: String {
        let pw = includePassword ? password : nil
        switch language {
        case .node: return TopicEncryptionSnippets.node(topicUrl: topicUrl, password: pw)
        case .python: return TopicEncryptionSnippets.python(topicUrl: topicUrl, password: pw)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "Encrypt on the sending side with the topic's password, then publish the result as the message body. The app decrypts it when it arrives. Plain `curl -d` messages still arrive, marked \"Not encrypted\", because anyone who knows the topic name can send them."))
                Text(verbatim: topicUrl)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)

                Picker(String(localized: "Language"), selection: $language) {
                    ForEach(Language.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if password != nil {
                    Toggle(String(localized: "Put the password in the snippet"), isOn: $includePassword)
                } else {
                    Text(String(localized: "Set a password first. The snippet reads it from NTFY_TOPIC_PASSWORD."))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Text(verbatim: snippet)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(8)

                Button(copied ? String(localized: "Copied") : String(localized: "Copy snippet")) {
                    if includePassword {
                        SecretPasteboard.copy(snippet)
                    } else {
                        UIPasteboard.general.string = snippet
                    }
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.borderedProminent)

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Good to know")).font(.headline)
                    Text(String(localized: "• Only the message, title, tags, priority, click link, icon and action buttons are encrypted. Attachments aren't supported: one sent with an encrypted message is dropped, since nothing proves it came from the sender."))
                    Text(String(localized: "• The server still sees the topic name, when messages are sent and roughly how long they are."))
                    Text(String(localized: "• Keep message and title under about 2.9 KB; the snippets refuse anything larger."))
                    Text(String(localized: "• \"Send test notification\" in the topic menu sends an encrypted message when a password is set."))
                    Text(String(localized: "• The format is the one from ntfy's end-to-end encryption draft (JWE with AES-256-GCM, key from PBKDF2-SHA256 over the password and the topic URL)."))
                }
                .font(.footnote)
                .foregroundColor(.secondary)
            }
            .padding()
        }
        .navigationTitle(String(localized: "Send encrypted"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
