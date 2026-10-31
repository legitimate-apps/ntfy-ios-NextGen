import Foundation
import CoreData
import CryptoKit

struct TopicSound: Equatable, Identifiable {
    let id: String
    let title: String

    static var builtins: [TopicSound] {
        [TopicSound(id: "ntfy-ping-v1.wav", title: String(localized: "Short ping")),
         TopicSound(id: "ntfy-chime-v1.wav", title: String(localized: "Chime")),
         TopicSound(id: "ntfy-alert-v1.wav", title: String(localized: "Insistent alert"))]
    }
}

/// Choices use individual versioned keys, so changing one topic cannot overwrite another's choice.
/// The permanent Core Data identity also prevents an interrupted unsubscribe from reviving a choice.
final class TopicSoundLibrary {
    static let shared = TopicSoundLibrary(
        defaults: UserDefaults(suiteName: Config.appGroupId)!,
        container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Config.appGroupId))
    let defaults: UserDefaults
    let directory: URL?

    init(defaults: UserDefaults, container: URL?) {
        self.defaults = defaults
        directory = container?.appendingPathComponent("Library/Sounds", isDirectory: true)
    }

    private func key(_ identity: String) -> String {
        "topicSound.v1." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func choice(for identity: String) -> String? { defaults.string(forKey: key(identity)) }

    func setChoice(_ filename: String?, for identity: String) {
        if let filename { defaults.set(filename, forKey: key(identity)) }
        else { defaults.removeObject(forKey: key(identity)) }
    }

    func file(_ name: String) -> URL? {
        guard name == (name as NSString).lastPathComponent, !name.isEmpty,
              let url = directory?.appendingPathComponent(name),
              FileManager.default.isReadableFile(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 44 else { return nil }
        return url
    }

    func resolvedChoice(for identity: String) -> String? {
        guard let name = choice(for: identity), file(name) != nil else { return nil }
        return name
    }

    var imports: [TopicSound] {
        (defaults.dictionary(forKey: "topicSoundImports.v1") as? [String: String] ?? [:])
            .compactMap { file($0.key) == nil ? nil : TopicSound(id: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func registerImport(filename: String, title: String) {
        var names = defaults.dictionary(forKey: "topicSoundImports.v1") as? [String: String] ?? [:]
        names[filename] = title
        defaults.set(names, forKey: "topicSoundImports.v1")
    }
}

extension Store {
    /// App and NSE resolve on a fresh context, never a stale view-context subscription snapshot.
    func topicSoundName(baseUrl: String, topic: String, library: TopicSoundLibrary = .shared) -> String? {
        let reader = container.newBackgroundContext()
        var name: String?
        reader.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Subscription")
            request.predicate = NSPredicate(format: "baseUrl == %@ AND topic == %@", normalizeBaseUrl(baseUrl), topic)
            request.fetchLimit = 1
            if let row = try? reader.fetch(request).first {
                name = library.resolvedChoice(for: row.objectID.uriRepresentation().absoluteString)
            }
        }
        return name
    }
}
