// Command-line front end over the app's own encryption sources, so an independent implementation can
// check what the shipped code produces. Built by run.sh; never part of the app.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: e2e-tool derive|encrypt|decrypt|snippet ...") }

switch (command, args.count) {
case ("derive", 3):
    guard let key = TopicEncryption.deriveKey(password: args[1], topicUrl: args[2]) else { fail("derive failed") }
    print(key.map { String(format: "%02x", $0) }.joined())
case ("encrypt", 4):
    // encrypt <password> <topicUrl> <plaintext>
    guard let key = TopicEncryption.deriveKey(password: args[1], topicUrl: args[2]) else { fail("derive failed") }
    do { print(try TopicEncryption.encrypt(Data(args[3].utf8), key: key)) } catch { fail("encrypt failed: \(error)") }
case ("encrypt-payload", 4):
    // encrypt-payload <password> <topicUrl> <json EncryptedPayload> — exercises the app's payload encoder
    guard let key = TopicEncryption.deriveKey(password: args[1], topicUrl: args[2]) else { fail("derive failed") }
    do {
        let payload = try JSONDecoder().decode(EncryptedPayload.self, from: Data(args[3].utf8))
        print(try TopicEncryption.encrypt(payload, key: key))
    } catch { fail("encrypt failed: \(error)") }
case ("decrypt", 4):
    guard let key = TopicEncryption.deriveKey(password: args[1], topicUrl: args[2]) else { fail("derive failed") }
    do { print(String(decoding: try TopicEncryption.decrypt(args[3], key: key), as: UTF8.self)) } catch { fail("decrypt failed: \(error)") }
case ("snippet", 3) where args[1] == "node":
    print(TopicEncryptionSnippets.node(topicUrl: args[2]))
case ("snippet", 3) where args[1] == "python":
    print(TopicEncryptionSnippets.python(topicUrl: args[2]))
default:
    fail("bad arguments: \(args)")
}
