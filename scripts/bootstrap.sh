#!/usr/bin/env bash
# Make a fresh clone buildable.
#
# Xcode lists ntfy/Assets/GoogleService-Info.plist as a build input, and that file is
# gitignored because it carries a real Firebase API key. So a clean clone fails to build
# with "Build input file cannot be found" long before any code is compiled — which is what
# a new contributor hits first, and what CI hit on its first run.
#
# This copies the tracked placeholder into place when no real config exists. It never
# overwrites a real one.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PLIST="ntfy/Assets/GoogleService-Info.plist"
EXAMPLE="$PLIST.example"

if [ -f "$PLIST" ]; then
	echo "✓ $PLIST already present — leaving it alone."
else
	[ -f "$EXAMPLE" ] || { echo "✗ $EXAMPLE is missing; cannot bootstrap." >&2; exit 1; }
	cp "$EXAMPLE" "$PLIST"
	echo "✓ installed placeholder $PLIST"
	echo "  The app will build and the tests will run. PUSH NOTIFICATIONS WILL NOT WORK —"
	echo "  replace it with your own Firebase config to test push."
fi

# Verify it is a well-formed plist. A truncated or hand-edited file produces a far more
# confusing build error than this one line does.
plutil -lint "$PLIST" >/dev/null || { echo "✗ $PLIST is not a valid plist." >&2; exit 1; }
echo "✓ bootstrap complete."
