import Foundation

/// Copy-paste senders for an encrypted topic, shown on the topic's encryption help screen.
///
/// Foundation-only so `scripts/e2e-interop` can compile this file and run the exact text the app shows
/// (the end-to-end proof runs the generated Node snippet against a real server).
enum TopicEncryptionSnippets {
    static let passwordPlaceholder = "YOUR_TOPIC_PASSWORD"

    /// Node 18+, built-in modules only.
    static func node(topicUrl: String, password: String? = nil) -> String {
        """
        // Send an end-to-end encrypted message. Node 18+, no dependencies.
        // Usage: node send.js "Backup finished" "Optional title"
        const crypto = require("node:crypto");
        const topicUrl = \(jsString(topicUrl));
        const password = process.env.NTFY_TOPIC_PASSWORD || \(jsString(password ?? passwordPlaceholder));
        const payload = JSON.stringify({ message: process.argv[2] || "Hello", title: process.argv[3] });

        const b64url = (b) => Buffer.from(b).toString("base64url");
        const salt = crypto.createHash("sha256").update(topicUrl).digest();
        const key = crypto.pbkdf2Sync(password, salt, 50000, 32, "sha256");
        const header = b64url('{"alg":"dir","enc":"A256GCM"}');
        const iv = crypto.randomBytes(12);
        const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
        cipher.setAAD(Buffer.from(header, "ascii"));
        const ct = Buffer.concat([cipher.update(payload, "utf8"), cipher.final()]);
        const body = [header, "", b64url(iv), b64url(ct), b64url(cipher.getAuthTag())].join(".");
        if (body.length > 4096) throw new Error(`Encrypted message is ${body.length} bytes; the limit is 4096`);

        fetch(topicUrl, { method: "POST", body, headers: { "X-Encoding": "jwe" } })
          .then((r) => { if (!r.ok) throw new Error(`HTTP ${r.status}`); console.log("Sent"); })
          .catch((e) => { console.error(e.message); process.exit(1); });
        """
    }

    /// Python 3 with the `cryptography` package (pip install cryptography).
    static func python(topicUrl: String, password: String? = nil) -> String {
        """
        # Send an end-to-end encrypted message. Needs: pip install cryptography
        # Usage: python3 send.py "Backup finished" "Optional title"
        import base64, hashlib, json, os, sys, urllib.request
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM

        topic_url = \(pyString(topicUrl))
        password = os.environ.get("NTFY_TOPIC_PASSWORD", \(pyString(password ?? passwordPlaceholder)))
        args = sys.argv[1:]
        payload = {"message": args[0] if args else "Hello"}
        if len(args) > 1:
            payload["title"] = args[1]

        def b64url(b):
            return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

        salt = hashlib.sha256(topic_url.encode()).digest()
        key = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 50000, 32)
        header = b64url(b'{"alg":"dir","enc":"A256GCM"}')
        iv = os.urandom(12)
        sealed = AESGCM(key).encrypt(iv, json.dumps(payload).encode(), header.encode())
        body = ".".join([header, "", b64url(iv), b64url(sealed[:-16]), b64url(sealed[-16:])])
        if len(body) > 4096:
            sys.exit(f"Encrypted message is {len(body)} bytes; the limit is 4096")

        req = urllib.request.Request(topic_url, data=body.encode(), headers={"X-Encoding": "jwe"}, method="POST")
        urllib.request.urlopen(req).read()
        print("Sent")
        """
    }

    /// JSON string literals are valid JavaScript and Python string literals for any input, including
    /// quotes, backslashes and non-ASCII, so a password can never break out of the snippet.
    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }

    private static func pyString(_ value: String) -> String {
        jsString(value)
    }
}
