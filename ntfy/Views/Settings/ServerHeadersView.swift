import SwiftUI

struct ServerHeadersView: View {
    private struct HeaderDraft: Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    private let credentialStore: CredentialStoring
    @State private var baseUrl: String
    @State private var headers: [HeaderDraft] = []
    @State private var alertMessage: String?
    @State private var saveBlockedBaseUrls: Set<String> = []

    init(
        defaultBaseUrl: String = Config.appBaseUrl,
        credentialStore: CredentialStoring = KeychainCredentialStore.shared
    ) {
        self.credentialStore = credentialStore
        _baseUrl = State(initialValue: normalizeBaseUrl(defaultBaseUrl))
    }

    var body: some View {
        Form {
            Section(
                header: Text("Server"),
                footer: Text("Headers are scoped to this normalized server URL. They are never sent to another origin.")
            ) {
                TextField("https://ntfy.example.com", text: $baseUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Load saved headers", action: load)
            }

            Section(
                header: Text("Headers"),
                footer: Text("Values are credentials stored in the shared Keychain and are masked here. An explicitly configured Authorization or User-Agent overrides the app default.")
            ) {
                ForEach($headers) { $header in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Header name", text: $header.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Header value", text: $header.value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .onDelete { headers.remove(atOffsets: $0) }

                Button {
                    headers.append(HeaderDraft(name: "", value: ""))
                } label: {
                    Label("Add header", systemImage: "plus")
                }
            }

            Section {
                Button("Save", action: save)
                Button("Delete saved headers", role: .destructive, action: delete)
            }
        }
        .navigationTitle("Server headers")
        .onAppear(perform: load)
        .alert("Server headers", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func validatedBaseUrl() -> String? {
        let normalized = normalizeBaseUrl(baseUrl)
        guard let components = URLComponents(string: normalized),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false else {
            alertMessage = "Enter a valid HTTP or HTTPS server URL."
            return nil
        }
        return normalized
    }

    private func load() {
        guard let normalized = validatedBaseUrl() else { return }
        guard let storedHeaders = Self.loadedHeaders(
            from: credentialStore.readHTTPHeaders(baseUrl: normalized)
        ) else {
            saveBlockedBaseUrls.insert(normalized)
            alertMessage = "The saved headers could not be read from the Keychain. The current form was left unchanged."
            return
        }
        saveBlockedBaseUrls.remove(normalized)
        baseUrl = normalized
        headers = storedHeaders
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { HeaderDraft(name: $0.key, value: $0.value) }
        if headers.isEmpty {
            headers = [HeaderDraft(name: "", value: "")]
        }
    }

    /// `nil` tells `load()` to preserve the visible draft. A successful empty read is an
    /// authoritative "no saved headers" result; a failed read is not.
    static func loadedHeaders(from result: HTTPHeadersReadResult) -> [String: String]? {
        guard case .success(let headers) = result else { return nil }
        return headers
    }

    enum SavePlan: Equatable {
        case persist([String: String])
        case nothingToSave
        case duplicateName
        case blockedByReadFailure
    }

    static func savePlan(
        for rows: [(name: String, value: String)],
        hasUnresolvedReadFailure: Bool
    ) -> SavePlan {
        guard !hasUnresolvedReadFailure else { return .blockedByReadFailure }
        var values: [String: String] = [:]
        var lowercasedNames = Set<String>()
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty && row.value.isEmpty { continue }
            guard lowercasedNames.insert(name.lowercased()).inserted else {
                return .duplicateName
            }
            values[name] = row.value
        }
        return values.isEmpty ? .nothingToSave : .persist(values)
    }

    private func save() {
        guard let normalized = validatedBaseUrl() else { return }
        let values: [String: String]
        switch Self.savePlan(
            for: headers.map { (name: $0.name, value: $0.value) },
            hasUnresolvedReadFailure: saveBlockedBaseUrls.contains(normalized)
        ) {
        case .blockedByReadFailure:
            alertMessage = "The saved headers must be loaded successfully before changes can be saved."
            return
        case .nothingToSave:
            alertMessage = "There are no headers to save. To remove the headers stored for this server, use \"Delete saved headers\"."
            return
        case .duplicateName:
            alertMessage = "Header names must be unique, ignoring capitalization."
            return
        case .persist(let parsed):
            values = parsed
        }
        if let error = ServerCredentials.validationError(headers: values) {
            alertMessage = error
            return
        }
        guard credentialStore.setHTTPHeaders(values, baseUrl: normalized) else {
            alertMessage = "The headers could not be saved to the Keychain."
            return
        }
        baseUrl = normalized
        saveBlockedBaseUrls.remove(normalized)
        alertMessage = "Headers saved."
    }

    private func delete() {
        guard let normalized = validatedBaseUrl() else { return }
        guard credentialStore.deleteHTTPHeaders(baseUrl: normalized) else {
            alertMessage = "The saved headers could not be deleted from the Keychain."
            return
        }
        saveBlockedBaseUrls.remove(normalized)
        headers = [HeaderDraft(name: "", value: "")]
        alertMessage = "Saved headers were deleted."
    }
}
