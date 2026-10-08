import Foundation

struct Emoji: Decodable {
    let emoji: String
    let aliases: [String]
    let tags: [String]

    func getUnicode() -> String {
        return emoji
    }
}

class EmojiManager {
    private static let tag = "EmojiManager"
    private static var emojis: Dictionary<String, Emoji> = [:]
    static let shared = EmojiManager()

    init() {
        // emojis.json pulled from https://github.com/github/gemoji/blob/master/db/emoji.json
        if let url = Bundle.main.url(forResource: "emojis", withExtension: "json") {
            do {
                let jsonData = try Data(contentsOf: url)
                if let jsonEmojis = try? JSONDecoder().decode([Emoji].self, from: jsonData) {
                    for emoji in jsonEmojis {
                        // gemoji entries may carry several aliases ("+1" and "thumbsup" are both 👍);
                        // index every one, or tags the other ntfy clients accept won't resolve here.
                        for alias in emoji.aliases {
                            EmojiManager.emojis[alias] = emoji
                        }
                    }
                }
            } catch {
                Log.e(EmojiManager.tag, "Unable to load emojis: \(error.localizedDescription)", error)
            }
        }
    }

    func getEmojiByAlias(alias: String) -> Emoji? {
        if alias.isEmpty {
            return nil
        }
        return EmojiManager.emojis[alias]
    }
}
