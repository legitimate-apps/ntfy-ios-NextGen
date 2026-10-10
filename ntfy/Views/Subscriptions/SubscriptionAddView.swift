import SwiftUI

struct SubscriptionAddView: View {
    private let tag = "SubscriptionAddView"
    
    @Binding var isShowing: Bool
    
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var delegate: AppDelegate
    @State private var topic: String = ""
    @State private var useAnother: Bool = false
    @State private var baseUrl: String = ""
    
    @State private var showLogin: Bool = false
    @State private var username: String = ""
    @State private var password: String = ""
    
    @State private var loading = false
    @State private var addError: String?
    @State private var loginError: String?
    /// The topic URL just subscribed to, while the notification-permission explanation is showing.
    @State private var primingTopicUrl: String?

    private var subscriptionManager: SubscriptionManager {
        return SubscriptionManager(store: store)
    }
    
    var body: some View {
        NavigationView {
            // This is a little weird, but it works. The nagivation link for the login view
            // is rendered in the backgroun (it's hidden), abd we toggle it manually.
            // If anyone has a better way to do a two-page layout let me know.
            
            Group {
                if let primingTopicUrl {
                    permissionPrimingView(topicUrl: primingTopicUrl)
                } else {
                    addView
                }
            }
                .background(Group {
                    NavigationLink(
                        destination: loginView,
                        isActive: $showLogin
                    ) {
                        EmptyView()
                    }
                })
        }
    }
    
    private var addView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(
                    // Subscribe is disabled until the input is valid. Saying why beats a greyed
                    // out button the user can't explain — "already subscribed" in particular
                    // looked identical to the app simply not responding.
                    footer: Text(topicFooterText)
                ) {
                    HStack {
                        TextField("Topic name, e.g. alerts-k7m2-x9qp", text: $topic)
                            .disableAutocapitalization()
                            .disableAutocorrection(true)
                        // On a public server the topic name is the password, and a newcomer has
                        // no idea what makes a good one. One tap fills in an unguessable name.
                        Button {
                            topic = TopicNameGenerator.random()
                        } label: {
                            Label("Random", systemImage: "dice")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Random topic name")
                        .accessibilityHint("Fills in a hard-to-guess topic name")
                    }
                }
                Section(footer: ServerFooterText(text: serverFooterText)
                    .fixedSize(horizontal: false, vertical: true)) {
                    Toggle("Use another server", isOn: $useAnother)
                    if useAnother {
                        TextField("Service URL, e.g. https://ntfy.home.io", text: $baseUrl)
                            .disableAutocapitalization()
                            .disableAutocorrection(true)
                    }
                }
            }
            if let error = addError {
                ErrorView(error: error)
            }
        }
        .navigationTitle("Add subscription")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: cancelAction) {
                    Text("Cancel")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: subscribeOrShowLoginAction) {
                    VStack {
                        if loading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Text("Subscribe")
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)

                }
                .disabled(!isAddViewValid())
            }
        }
    }
    
    private var loginView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(
                    footer: Text("This topic requires that you log in with username and password. The user will be stored on your device, and will be re-used for other topics.")
                ) {
                    // textContentType is what lets iOS offer saved credentials (and store new
                    // ones) here. Without it the Passwords AutoFill bar never appears, so a
                    // read-protected topic means typing a server password by hand every time.
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .disableAutocapitalization()
                        .disableAutocorrection(true)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
            }
            if let error = loginError {
                ErrorView(error: error)
            }
        }
        .navigationTitle("Login required")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: subscribeWithUserAction) {
                    if loading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Text("Subscribe")
                    }
                }
                .disabled(!isLoginViewValid())
            }
        }
    }
    
    private var sanitizedTopic: String {
        return topic.trimmingCharacters(in: .whitespaces)
    }

    /// The default guidance, replaced by the reason Subscribe is unavailable once the user has
    /// typed something that can't be subscribed to. Stays quiet while the field is empty —
    /// scolding someone before they've typed anything is worse than saying nothing.
    private var topicFooterText: String {
        let defaultText = "Anyone who knows a topic name can read and send its messages, so pick one "
            + "that's hard to guess, or tap Random."
        guard !sanitizedTopic.isEmpty else { return defaultText }
        if !isValidTopicName(sanitizedTopic) {
            return "Topic names can only use letters, numbers, dashes and underscores, up to 64 characters."
        }
        if useAnother, selectedBaseUrl.range(of: "^https?://.+", options: .regularExpression) == nil {
            return "Enter the full server URL, including https://"
        }
        if store.getSubscription(baseUrl: selectedBaseUrl, topic: sanitizedTopic) != nil {
            return "You're already subscribed to \(topicShortUrl(baseUrl: selectedBaseUrl, topic: sanitizedTopic))."
        }
        // Show where messages go before they subscribe, so the URL isn't a surprise afterwards.
        return defaultText + "\n\nSend messages to:\n"
            + PublishCommand.publishUrl(baseUrl: selectedBaseUrl, topic: sanitizedTopic)
    }
    
    private func isAddViewValid() -> Bool {
        if sanitizedTopic.isEmpty {
            return false
        } else if !isValidTopicName(sanitizedTopic) {
            return false
        } else if selectedBaseUrl.range(of: "^https?://.+", options: .regularExpression, range: nil, locale: nil) == nil {
            return false
        } else if store.getSubscription(baseUrl: selectedBaseUrl, topic: sanitizedTopic) != nil {
            return false
        }
        return true
    }
    
    private func isLoginViewValid() -> Bool {
        if username.isEmpty || password.isEmpty {
            return false
        }
        return true
    }
    
    private func subscribeOrShowLoginAction() {
        loading = true
        addError = nil
        let user = store.getBasicUser(baseUrl: selectedBaseUrl)
        // checkAuth's handler runs on a URLSession delegate queue, so everything below — SwiftUI @State
        // writes and Core Data through subscriptionManager/store — has to be hopped onto main.
        ApiService.shared.checkAuth(baseUrl: selectedBaseUrl, topic: sanitizedTopic, user: user) { result in
            DispatchQueue.main.async {
                switch result {
                case .Success:
                    subscriptionManager.subscribe(baseUrl: selectedBaseUrl, topic: sanitizedTopic)
                    finishSubscribing()
                case .Unauthorized:
                    if let user = user {
                        addError = "User \(user.username) is not authorized to read this topic"
                    } else {
                        addError = nil // Reset
                        showLogin = true
                    }
                    loading = false
                case .Error(let err):
                    addError = err
                    loading = false
                }
            }
        }
    }
    
    private func subscribeWithUserAction() {
        loading = true
        loginError = nil
        let user = BasicUser(username: username, password: password)
        // See subscribeOrShowLoginAction: the handler is off-main, so hop before touching @State or Core Data.
        ApiService.shared.checkAuth(baseUrl: selectedBaseUrl, topic: sanitizedTopic, user: user) { result in
            DispatchQueue.main.async {
                switch result {
                case .Success:
                    store.saveUser(baseUrl: selectedBaseUrl, username: username, password: password)
                    subscriptionManager.subscribe(baseUrl: selectedBaseUrl, topic: sanitizedTopic)
                    finishSubscribing()
                case .Unauthorized:
                    loginError = "Invalid credentials, or user \(username) is not authorized to read this topic"
                    loading = false
                case .Error(let err):
                    loginError = err
                    loading = false
                }
            }
        }
    }
    
    private func cancelAction() {
        resetAndHide()
    }

    /// After a successful subscribe: explain notifications first if iOS is about to ask for the
    /// first time, then close the sheet and open the new topic, whose empty state shows the
    /// ready-to-copy publish commands. "loading" is reset by resetAndHide() once the sheet is gone.
    private func finishSubscribing() {
        let url = topicUrl(baseUrl: selectedBaseUrl, topic: sanitizedTopic)
        delegate.notificationAuthorizationStatus { status in
            if NotificationPermissionPolicy.shouldPrime(status: status) {
                NotificationPermissionPolicy.recordPrimerOffered()
                showLogin = false
                primingTopicUrl = url
            } else {
                resetAndHide(openingTopicUrl: url)
            }
        }
    }

    /// A short explanation before the system permission prompt (HIG: explain the benefit in your
    /// own UI, then let the system ask). "Not now" never blocks: the topic is already subscribed and
    /// messages still show in the app. The explanation shows again the next time a topic is added, and the
    /// launch-time request leaves this install alone (`NotificationPermissionPolicy.primerOffered`).
    private func permissionPrimingView(topicUrl url: String) -> some View {
        // The explanation scrolls and the two choices stay pinned below it, so at the largest
        // accessibility text sizes on a small phone (with a long server address) the buttons are
        // always on screen and the text is never cut off.
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)
                Text("Get notified")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(Config.ntfyShDeliveryHint(baseUrl: selectedBaseUrl)
                     ?? "Allow notifications so each message sent to \(shortUrl(url: url)) shows up on your "
                        + "lock screen, even when the app is closed. iOS will ask you next.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button {
                    delegate.requestStandardNotificationAuthorization {
                        resetAndHide(openingTopicUrl: url)
                    }
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Shows the system notification permission prompt")
                Button("Not now") {
                    resetAndHide(openingTopicUrl: url)
                }
                .accessibilityHint("Skips notifications for now. Messages still appear in the app.")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }
    
    private var serverFooterText: String {
        Config.subscriptionServerFooter(baseUrl: selectedBaseUrl, useAnother: useAnother)
    }

    private var selectedBaseUrl: String {
        return normalizeBaseUrl((useAnother) ? baseUrl : store.getDefaultBaseUrl())
    }
    
    private func resetAndHide(openingTopicUrl url: String? = nil) {
        isShowing = false
        if let url {
            // Land on the new topic: its empty state is where the copyable publish commands live.
            // Wait for the sheet to finish dismissing, or the navigation push is dropped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                delegate.selectedBaseUrl = url
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // Hide first and then reset, otherwise we'll see the text fields change
            addError = nil
            loginError = nil
            loading = false
            baseUrl = ""
            topic = ""
            useAnother = false
            primingTopicUrl = nil
        }
    }
}

/// UIKit links work on iOS 14 too; reuse the message renderer's wrapping and sizing.
struct ServerFooterText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> MessageTextView {
        makeTextView()
    }

    func updateUIView(_ textView: MessageTextView, context: Context) {
        updateText(textView)
    }

    func makeTextView() -> MessageTextView {
        let textView = MessageTextView(frame: .zero, textContainer: nil)
        configureMessageTextView(textView, isInteractionEnabled: true)
        updateText(textView)
        return textView
    }

    func updateText(_ textView: MessageTextView) {
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote),
            .foregroundColor: UIColor.secondaryLabel
        ])
        for url in [Config.migrateUrl, Config.selfHostingUrl] {
            let range = (text as NSString).range(of: url)
            if range.location != NSNotFound {
                attributed.addAttribute(.link, value: URL(string: url)!, range: range)
            }
        }
        textView.setMessageText(attributed)
    }
}

struct ErrorView: View {
    var error: String
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.title2)
            Text(error)
                .font(.subheadline)
        }
        .padding([.leading, .trailing], 20)
        .padding([.top, .bottom], 10)
    }
}

struct SubscriptionAddView_Previews: PreviewProvider {
    @State static var isShowing = true
    
    static var previews: some View {
        let store = Store.preview
        SubscriptionAddView(isShowing: $isShowing)
            .environmentObject(store)
            .environmentObject(AppDelegate())
    }
}
