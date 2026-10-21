//
//  UserEditorView.swift
//  ntfy
//
//  Created by Alek Michelson on 4/10/26.
//

import SwiftUI

func passwordForUserEdit(enteredPassword: String, storedPassword: String?, isNewUser: Bool) -> String? {
    if !isNewUser && enteredPassword.isEmpty {
        return nil
    }
    return enteredPassword
}

struct UserEditorView: View {
    @EnvironmentObject private var store: Store
    
    let selectedUser: User?
    let onSave: (String, String, ServerCredential?) -> Bool
    let onDelete: (User) -> Bool
    let onCancel: () -> Void
    
    @State private var baseUrl: String
    @State private var login: ServerLoginInput
    @State private var originalMethod: ServerLoginMethod = .password
    @State private var didLoad = false
    @State private var editor = LoginEditorState()
    
    init(
        selectedUser: User?,
        onSave: @escaping (String, String, ServerCredential?) -> Bool,
        onDelete: @escaping (User) -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.selectedUser = selectedUser
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _baseUrl = State(initialValue: selectedUser?.baseUrl ?? "")
        _login = State(initialValue: ServerLoginInput(username: selectedUser?.username ?? ""))
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(
                    footer: isNewUser
                    ? Text("Choose a password or access token. All topics for this server use the same login.")
                    : Text("All topics for \(shortUrl(url: baseUrl)) use this login. Leave the secret blank to keep it unchanged. Enter a new secret when changing the sign-in method.")
                ) {
                    if isNewUser {
                        TextField("Service URL, e.g. https://ntfy.home.io", text: $baseUrl)
                            .disableAutocapitalization()
                            .disableAutocorrection(true)
                    }
                    ServerLoginFields(input: $login)
                }
                if (!login.username.isEmpty || !login.secret.isEmpty || !isNewUser),
                   let notice = UrlSecurityNotice.message(for: baseUrl, isAccessToken: login.method == .token) {
                    Text(notice).font(.footnote).foregroundColor(.secondary)
                }
                if editor.saveFailed {
                    Text(HardeningCopy.saveLoginFailed).foregroundColor(.secondary)
                        .accessibilityIdentifier("login-save-error")
                }
                if editor.deleteFailed {
                    Text(HardeningCopy.deleteLoginFailed).foregroundColor(.secondary)
                        .accessibilityIdentifier("login-delete-error")
                }
                if !isNewUser {
                    Button(HardeningCopy.deleteLogin, role: .destructive) { editor.requestDelete() }
                }
            }
            .alert(HardeningCopy.deleteTitle, isPresented: $editor.confirmingDelete) {
                Button(HardeningCopy.cancel, role: .cancel) { editor.finishDelete(confirmed: false) { true } }
                Button(HardeningCopy.deleteLogin, role: .destructive) {
                    editor.finishDelete(confirmed: true, delete: deleteAction)
                }
            } message: { Text(HardeningCopy.deleteMessage) }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                if let selectedUser,
                   let credential = store.getBasicUser(baseUrl: selectedUser.baseUrl ?? "") {
                    originalMethod = credential.isAccessToken ? .token : .password
                    login.method = originalMethod
                    login.username = credential.isAccessToken ? "" : credential.username
                }
            }
            .navigationTitle(isNewUser ? "Add user" : "Edit user")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(HardeningCopy.cancel, action: onCancel)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: saveAction) {
                        Text("Save")
                    }
                    .disabled(!isValid())
                }
            }
        }
    }
    
    private var isNewUser: Bool {
        selectedUser == nil
    }
    
    private func saveAction() {
        let enteredSecret = passwordForUserEdit(
            enteredPassword: login.secret, storedPassword: nil, isNewUser: isNewUser
        )
        let replacement = enteredSecret.map { _ in login.credential }
            ?? store.getBasicUser(baseUrl: baseUrl).map { current in
                current.isAccessToken ? current : .basic(username: login.username, password: current.password)
            }
        _ = editor.save { onSave(baseUrl, login.method == .token ? "" : login.username, replacement) }
    }
    
    private func deleteAction() -> Bool {
        guard let selectedUser = selectedUser else { return false }
        return onDelete(selectedUser)
    }
    
    private func isValid() -> Bool {
        if isNewUser {
            if baseUrl.range(of: "^https?://.+", options: .regularExpression, range: nil, locale: nil) == nil {
                return false
            } else if !login.isValid {
                return false
            } else if store.getUser(baseUrl: baseUrl) != nil {
                return false
            }
        }
        return login.canSave(isEditing: !isNewUser, originalMethod: originalMethod)
    }
}


/// New hardening copy stays together for the later localization pass.
enum HardeningCopy {
    static let saveLoginFailed = "Couldn't save this login securely. Try again."
    static let deleteLoginFailed = "Couldn't finish deleting this login. It is still listed. Try again."
    static let deleteLogin = "Delete login"
    static let deleteTitle = "Delete this login?"
    static let deleteMessage = "Topics on this server may need you to sign in again."
    static let cancel = "Cancel"
    static let close = "Close"
    static let httpPassword = "This server uses HTTP. Your password is sent without encryption."
}

enum UrlSecurityNotice {
    static func message(for baseUrl: String, isAccessToken: Bool = false) -> String? {
        guard URL(string: baseUrl)?.scheme?.lowercased() == "http" else { return nil }
        return isAccessToken ? "This server uses HTTP. Your access token is sent without encryption." : HardeningCopy.httpPassword
    }
}

struct LoginEditorState {
    var saveFailed = false
    var deleteFailed = false
    var confirmingDelete = false
    private var deletePending = false
    mutating func save(_ action: () -> Bool) -> Bool {
        let saved = action()
        saveFailed = !saved
        return saved
    }
    mutating func requestDelete() { confirmingDelete = true; deletePending = true }
    mutating func finishDelete(confirmed: Bool, delete: () -> Bool) {
        guard deletePending else { return }
        deletePending = false
        confirmingDelete = false
        if confirmed { deleteFailed = !delete() }
    }
}

enum ServerLoginMethod: String, CaseIterable {
    case password = "Username and password"
    case token = "Access token"
}

struct ServerLoginInput {
    var method: ServerLoginMethod = .password
    var username = ""
    var secret = ""

    var credential: ServerCredential {
        method == .token ? .accessToken(secret) : .basic(username: username, password: secret)
    }

    var isValid: Bool {
        guard !secret.isEmpty else { return false }
        if method == .password { return !username.isEmpty }
        // Bearer values cannot contain whitespace or controls. The server validates the token's
        // existence, expiry and access; don't impose a fixed token length on future servers.
        return secret.hasPrefix("tk_") && secret.count > 3 && secret.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
        }
    }

    func canSave(isEditing: Bool, originalMethod: ServerLoginMethod) -> Bool {
        if isEditing && method == originalMethod && secret.isEmpty {
            return method == .token || !username.isEmpty
        }
        return isValid
    }
}

/// Shared by the add-topic login, re-authentication and Settings. Tokens stay masked and never
/// enter Password AutoFill's username/password fields.
struct ServerLoginFields: View {
    @Binding var input: ServerLoginInput

    var body: some View {
        ForEach(ServerLoginMethod.allCases, id: \.self) { method in
            Button {
                if input.method != method {
                    input.secret = ""
                    input.method = method
                }
            } label: {
                HStack {
                    Text(method.rawValue).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if input.method == method {
                        Image(systemName: "checkmark").accessibilityHidden(true)
                    }
                }
                .foregroundColor(.primary)
            }
            .accessibilityAddTraits(input.method == method ? [.isSelected] : [])
        }
        if input.method == .password {
            TextField("Username", text: $input.username)
                .textContentType(.username)
                .disableAutocapitalization()
                .disableAutocorrection(true)
                .accessibilityLabel("Username")
                .accessibilityIdentifier("server-username")
            SecureField("Password", text: $input.secret)
                .textContentType(.password)
                .accessibilityLabel("Password")
                .accessibilityIdentifier("server-password")
        } else {
            SecureField("Access token, tk_…", text: $input.secret)
                .disableAutocapitalization()
                .disableAutocorrection(true)
                .accessibilityLabel("Access token")
                .accessibilityIdentifier("server-access-token")
            Text("Paste an access token created in your server's account settings. It is stored securely in the Keychain.")
                .font(.footnote).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
