import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import UserNotifications

final class TopicSoundPreview: ObservableObject {
    private var player: AVAudioPlayer?

    func stop() { player?.stop(); player = nil }

    func select(_ filename: String?, for identity: String, library: TopicSoundLibrary) throws {
        library.setChoice(filename, for: identity)
        try play(filename, library: library)
    }

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

private enum TopicSoundFailure: String, Identifiable {
    case importing, preview, removal, preparation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .preview: return String(localized: "Couldn't preview this sound")
        case .removal: return String(localized: "Couldn't remove this sound")
        default: return String(localized: "Couldn't use this sound")
        }
    }
    var message: String {
        switch self {
        case .importing: return String(localized: "Choose a readable audio file up to 50 MB. Protected or unsupported audio cannot be imported.")
        case .preview: return String(localized: "Your sound was selected, but the preview couldn't play.")
        case .removal: return String(localized: "Try removing the sound again.")
        case .preparation: return String(localized: "Couldn't prepare the built-in sounds. Try opening this screen again.")
        }
    }
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
    @State private var editMode = EditMode.inactive
    @State private var failure: TopicSoundFailure?
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
                        .onDelete(perform: remove)
                        .deleteDisabled(busy)
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
                ToolbarItem(placement: .navigationBarLeading) {
                    if !imports.isEmpty { EditButton().disabled(busy).accessibilityIdentifier("sound-edit") }
                }
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
                        } catch { failure = .importing }
                        busy = false
                    }
                case .failure: failure = .importing
                }
            }
            .alert(item: $failure) { error in
                Alert(title: Text(error.title), message: Text(error.message),
                      dismissButton: .default(Text("OK")))
            }
            .task {
                selected = library.resolvedChoice(for: identity)
                busy = true
                do { try await Task.detached { try TopicSoundImporter.installBuiltins(library: library) }.value }
                catch { failure = .preparation }
                imports = library.imports
                busy = false
            }
            .onDisappear { importTask?.cancel(); preview.stop() }
        }
        .environment(\.editMode, $editMode)
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
        selected = filename
        do { try preview.select(filename, for: identity, library: library) }
        catch { failure = .preview }
    }

    private func remove(_ offsets: IndexSet) {
        preview.stop()
        for sound in offsets.map({ imports[$0] }) {
            do { try library.removeImport(sound.id) }
            catch { failure = .removal }
        }
        imports = library.imports
        selected = library.resolvedChoice(for: identity)
        if imports.isEmpty { editMode = .inactive }
    }
}
