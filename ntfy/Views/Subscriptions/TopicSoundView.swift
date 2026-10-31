import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import UserNotifications

final class TopicSoundPreview: ObservableObject {
    private var player: AVAudioPlayer?

    func stop() { player?.stop(); player = nil }

    func play(_ filename: String?, library: TopicSoundLibrary) throws {
        stop()
        if let filename {
            guard let url = library.file(filename) else { throw TopicSoundImportError() }
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            let next = try AVAudioPlayer(contentsOf: url)
            guard next.prepareToPlay(), next.play() else { throw TopicSoundImportError() }
            player = next
        } else {
            let content = UNMutableNotificationContent()
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil))
        }
    }

    static let requestID = "topic-sound-preview"
}

struct TopicSoundButton: View {
    @Binding var showingOptions: Bool
    var body: some View {
        Button { showingOptions = true } label: {
            Label(String(localized: "Notification sound"), systemImage: "speaker.wave.2")
        }
    }
}

struct TopicSoundView: View {
    @ObservedObject var subscription: Subscription
    @Environment(\.presentationMode) private var presentationMode
    @StateObject private var preview = TopicSoundPreview()
    @State private var selected: String?
    @State private var imports: [TopicSound] = []
    @State private var importing = false
    @State private var busy = false
    @State private var failed = false
    @State private var importTask: Task<Void, Never>?
    private let library = TopicSoundLibrary.shared
    private var identity: String { subscription.objectID.uriRepresentation().absoluteString }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text(subscription.shortDisplayName()), footer: Text(String(localized: "Tap a sound to select and preview it. Muted topics stay quiet. Critical alerts use the system critical sound."))) {
                    soundRow(nil, title: String(localized: "Default"))
                    ForEach(TopicSound.builtins) { sound in soundRow(sound.id, title: sound.title) }
                }
                Section(header: Text(String(localized: "Imported sounds")), footer: Text(String(localized: "Import audio from Files, up to 50 MB. The first 29 seconds are used. iOS system ringtones are not available to apps."))) {
                    ForEach(imports) { sound in soundRow(sound.id, title: sound.title) }
                    Button { importing = true } label: {
                        Label(String(localized: "Import sound from Files"), systemImage: "square.and.arrow.down")
                            .foregroundColor(.primary)
                    }
                    .accessibilityIdentifier("sound-import")
                    .disabled(busy)
                    if busy { ProgressView() }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(String(localized: "Notification sound"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { presentationMode.wrappedValue.dismiss() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let source):
                    busy = true
                    importTask = Task {
                        do {
                            let sound = try await Task.detached { try TopicSoundImporter.importFile(source, library: library) }.value
                            guard !Task.isCancelled else { busy = false; return }
                            imports = library.imports
                            select(sound.id)
                        } catch { failed = true }
                        busy = false
                    }
                case .failure: failed = true
                }
            }
            .alert(isPresented: $failed) {
                Alert(title: Text(String(localized: "Couldn't use this sound")),
                      message: Text(String(localized: "Choose a readable audio file up to 50 MB. Protected or unsupported audio cannot be imported.")),
                      dismissButton: .default(Text("OK")))
            }
            .task {
                selected = library.resolvedChoice(for: identity)
                busy = true
                do { try await Task.detached { try TopicSoundImporter.installBuiltins(library: library) }.value }
                catch { failed = true }
                imports = library.imports
                busy = false
            }
            .onDisappear { importTask?.cancel(); preview.stop() }
        }
    }

    private func soundRow(_ filename: String?, title: String) -> some View {
        Button { select(filename) } label: {
            HStack {
                Text(title).foregroundColor(.primary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if selected == filename { Image(systemName: "checkmark").foregroundColor(.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .disabled(busy)
        .accessibilityAddTraits(selected == filename ? .isSelected : [])
    }

    private func select(_ filename: String?) {
        do {
            try preview.play(filename, library: library)
            library.setChoice(filename, for: identity)
            selected = filename
        } catch { failed = true }
    }
}
