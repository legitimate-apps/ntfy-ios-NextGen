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
    let onSave: (String, String, String?) -> Bool
    let onDelete: (User) -> Void
    let onCancel: () -> Void
    
    @State private var baseUrl: String
    @State private var username: String
    @State private var password: String
    @State private var editor = LoginEditorState()
    
    init(
        selectedUser: User?,
        onSave: @escaping (String, String, String?) -> Bool,
        onDelete: @escaping (User) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.selectedUser = selectedUser
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _baseUrl = State(initialValue: selectedUser?.baseUrl ?? "")
        _username = State(initialValue: selectedUser?.username ?? "")
        _password = State(initialValue: "")
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(
                    footer: isNewUser
                    ? Text("You can add a user here. All topics for the given server will use this user.")
                    : Text("Edit the username or password for \(shortUrl(url: baseUrl)) here. This user is used for all topics of this server. Leave the password blank to leave it unchanged.")
                ) {
                    if isNewUser {
                        TextField("Service URL, e.g. https://ntfy.home.io", text: $baseUrl)
                            .disableAutocapitalization()
                            .disableAutocorrection(true)
                    }
                    // See SubscriptionAddView: without textContentType iOS never offers the
                    // Passwords AutoFill bar, so every server password has to be typed by hand.
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .disableAutocapitalization()
                        .disableAutocorrection(true)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                if (!username.isEmpty || !password.isEmpty || !isNewUser),
                   let notice = UrlSecurityNotice.message(for: baseUrl) {
                    Text(notice).font(.footnote).foregroundColor(.secondary)
                }
                if editor.saveFailed {
                    Text(HardeningCopy.saveLoginFailed).foregroundColor(.secondary)
                        .accessibilityIdentifier("login-save-error")
                }
                if !isNewUser {
                    Button(HardeningCopy.deleteLogin, role: .destructive) { editor.requestDelete() }
                }
            }
            .alert(HardeningCopy.deleteTitle, isPresented: $editor.confirmingDelete) {
                Button(HardeningCopy.cancel, role: .cancel) { editor.finishDelete(confirmed: false) {} }
                Button(HardeningCopy.deleteLogin, role: .destructive) {
                    editor.finishDelete(confirmed: true, delete: deleteAction)
                }
            } message: { Text(HardeningCopy.deleteMessage) }
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
        let finalPassword = passwordForUserEdit(
            enteredPassword: password,
            storedPassword: selectedUser?.password,
            isNewUser: isNewUser
        )
        _ = editor.save { onSave(baseUrl, username, finalPassword) }
    }
    
    private func deleteAction() {
        guard let selectedUser = selectedUser else { return }
        onDelete(selectedUser)
    }
    
    private func isValid() -> Bool {
        if isNewUser {
            if baseUrl.range(of: "^https?://.+", options: .regularExpression, range: nil, locale: nil) == nil {
                return false
            } else if username.isEmpty || password.isEmpty {
                return false
            } else if store.getUser(baseUrl: baseUrl) != nil {
                return false
            }
        } else if username.isEmpty {
            return false
        }
        return true
    }
}


/// New hardening copy stays together for the later localization pass.
enum HardeningCopy {
    static let saveLoginFailed = "Couldn't save this login securely. Try again."
    static let deleteLogin = "Delete login"
    static let deleteTitle = "Delete this login?"
    static let deleteMessage = "Topics on this server may need you to sign in again."
    static let cancel = "Cancel"
    static let close = "Close"
    static let httpPassword = "This server uses HTTP. Your password is sent without encryption."
}

enum UrlSecurityNotice {
    static func message(for baseUrl: String) -> String? {
        URL(string: baseUrl)?.scheme?.lowercased() == "http" ? HardeningCopy.httpPassword : nil
    }
}

struct LoginEditorState {
    var saveFailed = false
    var confirmingDelete = false
    private var deletePending = false
    mutating func save(_ action: () -> Bool) -> Bool {
        let saved = action()
        saveFailed = !saved
        return saved
    }
    mutating func requestDelete() { confirmingDelete = true; deletePending = true }
    mutating func finishDelete(confirmed: Bool, delete: () -> Void) {
        guard deletePending else { return }
        deletePending = false
        confirmingDelete = false
        if confirmed { delete() }
    }
}
