#!/bin/sh
# Builds the interop tool from the app's shipped encryption sources and checks it against interop.py
# (Python `cryptography`) in both directions. Needs python3 + cryptography and Xcode's swiftc.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${TMPDIR:-/tmp}/ntfy-e2e-tool
swiftc -O "$root/ntfy/Utils/TopicEncryption.swift" "$root/ntfy/Utils/TopicEncryptionSnippets.swift" "$here/main.swift" -o "$out"

pw='correct horse ✓ "quoted"'
url='https://ntfy-me.com/e2e-interop'
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: [$2] != [$3]"; fail=1; fi; }

check "derive matches (swift vs python)" "$("$out" derive "$pw" "$url")" "$(python3 "$here/interop.py" derive "$pw" "$url")"
check "derive matches upstream Go vector" "$("$out" derive 'secr3t password' 'https://ntfy.sh/mysecret')" \
  30b7e72f6273da6e59d2dec535466e548da3eafc98650c9664c06edab707fa25

msg='{"message":"Swift → Python ✓","title":"interop","tags":["lock"],"priority":4}'
jwe=$("$out" encrypt "$pw" "$url" "$msg")
check "swift encrypt -> python decrypt" "$(python3 "$here/interop.py" decrypt "$pw" "$url" "$jwe")" "$msg"

payload_jwe=$("$out" encrypt-payload "$pw" "$url" '{"message":"payload ✓","title":"t","priority":5,"tags":["a","b"]}')
check "swift payload encoder -> python decrypt" "$(python3 "$here/interop.py" decrypt "$pw" "$url" "$payload_jwe")" \
  '{"message":"payload ✓","priority":5,"tags":["a","b"],"title":"t"}'

pjwe=$(python3 "$here/interop.py" encrypt "$pw" "$url" "$msg")
check "python encrypt -> swift decrypt" "$("$out" decrypt "$pw" "$url" "$pjwe")" "$msg"

if "$out" decrypt "wrong password" "$url" "$pjwe" >/dev/null 2>&1; then echo "FAIL wrong password decrypted"; fail=1; else echo "ok   wrong password rejected"; fi
if "$out" decrypt "$pw" "https://ntfy-me.com/other-topic" "$pjwe" >/dev/null 2>&1; then echo "FAIL wrong topic decrypted"; fail=1; else echo "ok   wrong topic URL (salt) rejected"; fi
# The sender snippets the app shows, run as generated: a local capture server stands in for the
# topic, so the check is offline. Each must send X-Encoding: jwe and a body the app decrypts.
snippet_check() { # $1 = node|python, $2 = runner
  cap=$(mktemp); portfile=$(mktemp); script=$(mktemp)
  python3 "$here/capture.py" "$cap" > "$portfile" & pid=$!
  i=0; while [ ! -s "$portfile" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  surl="http://127.0.0.1:$(cat "$portfile")/e2e-interop"
  "$out" snippet "$1" "$surl" > "$script"
  if NTFY_TOPIC_PASSWORD="$pw" $2 "$script" "snippet $1 ✓" "t" >/dev/null 2>&1; then :; else echo "FAIL $1 snippet did not run"; fail=1; fi
  wait $pid 2>/dev/null || true
  check "$1 snippet sends X-Encoding: jwe" "$(head -1 "$cap")" "jwe"
  sent=$("$out" decrypt "$pw" "$surl" "$(tail -n +2 "$cap")" 2>&1 || true)
  got=$(printf %s "$sent" | python3 -c 'import json,sys; p=json.load(sys.stdin); print(p["message"] + "|" + p["title"])' 2>/dev/null || true)
  check "$1 snippet -> swift decrypt" "$got" "snippet $1 ✓|t"
  rm -f "$cap" "$portfile" "$script"
}
if command -v node >/dev/null; then snippet_check node node; else echo "skip node snippet (no node)"; fi
snippet_check python python3

exit $fail
