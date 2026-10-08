#!/usr/bin/env python3
"""Independent implementation of the upstream ntfy E2E format (Python `cryptography`), used to check the
app's Swift code in both directions. Not part of the app.

  interop.py derive <password> <topicUrl>
  interop.py encrypt <password> <topicUrl> <plaintext> [iv-hex]
  interop.py decrypt <password> <topicUrl> <jwe>
"""
import base64, hashlib, json, os, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

HEADER = '{"alg":"dir","enc":"A256GCM"}'


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64url(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def derive(password, topic_url):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), hashlib.sha256(topic_url.encode()).digest(), 50000, 32)


def encrypt(key, plaintext, iv=None):
    header = b64url(HEADER.encode())
    iv = iv or os.urandom(12)
    sealed = AESGCM(key).encrypt(iv, plaintext, header.encode())
    return ".".join([header, "", b64url(iv), b64url(sealed[:-16]), b64url(sealed[-16:])])


def decrypt(key, jwe):
    h, ek, iv, ct, tag = jwe.strip().split(".")
    assert ek == "", "encrypted-key segment must be empty"
    assert json.loads(unb64url(h)) == {"alg": "dir", "enc": "A256GCM"}, "unexpected header"
    return AESGCM(key).decrypt(unb64url(iv), unb64url(ct) + unb64url(tag), h.encode())


if __name__ == "__main__":
    cmd, *a = sys.argv[1:]
    if cmd == "derive":
        print(derive(a[0], a[1]).hex())
    elif cmd == "encrypt":
        iv = bytes.fromhex(a[3]) if len(a) > 3 else None
        print(encrypt(derive(a[0], a[1]), a[2].encode(), iv))
    elif cmd == "decrypt":
        sys.stdout.write(decrypt(derive(a[0], a[1]), a[2]).decode() + "\n")
    else:
        sys.exit("unknown command")
