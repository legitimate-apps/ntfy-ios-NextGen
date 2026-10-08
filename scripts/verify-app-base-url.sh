#!/bin/sh
# Release gate: fail unless the app AND its notification service extension carry the expected
# built-in server (Info.plist `AppBaseURL`, from the APP_BASE_URL build setting) and the same
# build identity (AppBundleIdBase, AppGroupId, AppKeychainGroup).
#
# Why: the app subscribes subscriptions on its built-in server to RAW FCM topic names and every other
# server to HASHED ones, and the NSE falls back to AppBaseURL for pushes that carry no base_url. A build
# with the wrong value looks perfect and silently receives no push for its default server.
#
# Usage: scripts/verify-app-base-url.sh <path.xcarchive | path.ipa | path.app> [expected-url]
#        expected-url defaults to $EXPECTED_APP_BASE_URL, then https://ntfy-me.com
# Exit:  0 = both match, 1 = mismatch or missing, 2 = usage error.
set -eu

usage() { echo "usage: $0 <path.xcarchive|path.ipa|path.app> [expected-url]" >&2; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage
input=$1
expected=${2:-${EXPECTED_APP_BASE_URL:-https://ntfy-me.com}}
[ -e "$input" ] || { echo "FAIL: $input does not exist" >&2; exit 1; }

tmp=
cleanup() { if [ -n "$tmp" ]; then rm -rf "$tmp"; fi; }
trap cleanup EXIT INT TERM

case "$input" in
  *.xcarchive|*.xcarchive/) app=$(find "$input/Products/Applications" -maxdepth 1 -name '*.app' -type d | head -1) ;;
  *.ipa)
    tmp=$(mktemp -d)
    unzip -q "$input" 'Payload/*' -d "$tmp" || { echo "FAIL: cannot unzip $input" >&2; exit 1; }
    app=$(find "$tmp/Payload" -maxdepth 1 -name '*.app' -type d | head -1) ;;
  *.app|*.app/) app=${input%/} ;;
  *) usage ;;
esac
[ -n "${app:-}" ] && [ -d "$app" ] || { echo "FAIL: no .app bundle found in $input" >&2; exit 1; }

# Read one key from a plist (binary or XML); empty if absent.
read_key() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

# Trailing slashes are not significant to the app (normalizeBaseUrl); compare without them.
strip() { printf '%s' "$1" | sed 's:/*$::'; }

status=0
check() { # label plist
  value=$(read_key "$2" AppBaseURL)
  if [ "$(strip "$value")" = "$(strip "$expected")" ]; then
    echo "OK:   $1 AppBaseURL = $value"
  else
    echo "FAIL: $1 AppBaseURL = '${value:-<missing>}', expected '$expected' ($2)" >&2
    status=1
  fi
}

check "app" "$app/Info.plist"

nse=
for ext in "$app"/PlugIns/*.appex; do
  [ -d "$ext" ] || continue
  if [ "$(read_key "$ext/Info.plist" NSExtension.NSExtensionPointIdentifier)" = "com.apple.usernotifications.service" ]; then
    nse=$ext
    check "NSE ($(basename "$ext"))" "$ext/Info.plist"
  fi
done
if [ -z "$nse" ]; then
  echo "FAIL: no notification service extension found in $app/PlugIns" >&2
  status=1
fi

# Build identity (Configuration/*.xcconfig): the app and the extension find each other's Keychain
# items and shared container by these values, so both must carry the app's own bundle id and the
# same groups. An archive built without the maintainer's Local.xcconfig fails here.
bundle_id=$(read_key "$app/Info.plist" CFBundleIdentifier)
for key in AppBundleIdBase AppGroupId AppKeychainGroup; do
  app_value=$(read_key "$app/Info.plist" $key)
  [ -n "$app_value" ] || { echo "FAIL: app $key is missing" >&2; status=1; continue; }
  if [ -n "$nse" ] && [ "$(read_key "$nse/Info.plist" $key)" != "$app_value" ]; then
    echo "FAIL: NSE $key differs from the app's ($app_value)" >&2
    status=1
  fi
done
if [ "$(read_key "$app/Info.plist" AppBundleIdBase)" = "$bundle_id" ]; then
  echo "OK:   build identity $bundle_id (app and NSE agree)"
else
  echo "FAIL: AppBundleIdBase is not the app's bundle id $bundle_id" >&2
  status=1
fi

exit $status
