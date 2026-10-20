#!/usr/bin/env python3
"""Replay navigation integration tests on a dedicated, booted simulator.

Uses an already-built app. Seeding modifies ONLY that simulator's app-group store.
No app source changes, provisioning changes, or third-party Python packages.
"""
import argparse
import plistlib
from pathlib import Path
import sqlite3
import subprocess
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("udid", help="dedicated leased simulator, already booted")
parser.add_argument("app", type=Path, help="signed simulator ntfy.app")
parser.add_argument("derived_data", type=Path, help="UI runner DerivedData, preferably external disk")
parser.add_argument("output", type=Path)
parser.add_argument("--seed", action="store_true", help="replace subscriptions with 61 isolated fixture topics")
parser.add_argument("--seed-only", action="store_true", help="prepare fixture without running the UI suite")
parser.add_argument("--sort", choices=["name", "recentActivity"], default="name")
parser.add_argument("--only", action="append", default=[], help="test method name (repeatable)")
args = parser.parse_args()
if args.seed_only and not args.seed:
    parser.error("--seed-only requires --seed")
root = Path(__file__).resolve().parent
args.output.mkdir(parents=True, exist_ok=True)
app = args.app.resolve()
info = plistlib.loads((app / "Info.plist").read_bytes())
bundle_id = info["CFBundleIdentifier"]
group_id = info["AppGroupId"]
harness = args.output.resolve() / "NotificationHarness.dylib"
run("xcrun", "--sdk", "iphonesimulator", "clang", "-arch", "arm64", "-mios-simulator-version-min=16.4",
    "-fobjc-arc", "-dynamiclib", "-framework", "Foundation", "-framework", "UIKit", "-framework",
    "UserNotifications", str(root / "NotificationHarness.m"), "-o", str(harness))
run("codesign", "-s", "-", str(harness))
# A not-running app is normal before installation.
subprocess.run(["xcrun", "simctl", "terminate", args.udid, bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
run("xcrun", "simctl", "install", args.udid, str(app))
if args.seed:
    run("xcrun", "simctl", "launch", args.udid, bundle_id, "-ntfyDebugLastSeenVersion", "1.18.0",
        "-notificationPermissionPrimerOffered", "YES")
    data = Path.home() / "Library/Developer/CoreSimulator/Devices" / args.udid / "data"
    groups = data / "Containers/Shared/AppGroup"
    store = None
    for _ in range(50):
        for directory in groups.iterdir():
            metadata = directory / ".com.apple.mobile_container_manager.metadata.plist"
            if metadata.exists() and plistlib.loads(metadata.read_bytes()).get("MCMMetadataIdentifier") == group_id:
                candidate = directory / "ntfy.sqlite"
                if candidate.exists():
                    store = candidate
        if store:
            break
        time.sleep(0.2)
    if store is None:
        raise RuntimeError("App-group store not created; check simulator signing and app launch")
    run("xcrun", "simctl", "terminate", args.udid, bundle_id)
    with sqlite3.connect(store) as db:
        # This command is explicitly for a dedicated simulator, never a user's installation.
        db.execute("DELETE FROM ZNOTIFICATION")
        db.execute("DELETE FROM ZSUBSCRIPTION")
        for index in range(61):
            topic = f"aaa-nav-{index:03}" if index < 60 else "zz-nav-118-regression"
            server = "http://127.0.0.1:1" if index < 60 else "https://ntfy-me.com"
            db.execute("INSERT INTO ZSUBSCRIPTION (Z_PK,Z_ENT,Z_OPT,ZENCRYPTED,ZFCMSUBSCRIBED,ZLASTEVENTTIME,"
                       "ZPINNED,ZSEQUENCERECONCILE,ZBASEURL,ZTOPIC) VALUES (?,5,1,0,1,0,?,0,?,?)",
                       (index + 1, int(index == 0), server, topic))
            if index < 60:
                # Recent activity genuinely reverses the unpinned rows; the target stays last.
                db.execute("INSERT INTO ZNOTIFICATION (Z_PK,Z_ENT,Z_OPT,ZPRESENTED,ZREAD,ZPRIORITY,"
                           "ZTIME,ZSTOREDAT,ZSUBSCRIPTION,ZID,ZMESSAGE) VALUES (?,1,1,0,1,3,?,?,?,?,?)",
                           (index + 1, int(time.time()) + index, time.time() - 978307200,
                            index + 1, f"nav-fixture-{index}", "Navigation fixture"))
        db.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=60 WHERE Z_NAME='Notification'")
        db.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=61 WHERE Z_NAME='Subscription'")
        pk = db.execute("SELECT COALESCE(MAX(Z_PK),0) FROM ZPREFERENCE").fetchone()[0]
        for key, value in [("defaultBaseUrl", "http://127.0.0.1:1"), ("topicSortOrder", args.sort)]:
            pk += 1
            db.execute("DELETE FROM ZPREFERENCE WHERE ZKEY=?", (key,))
            db.execute("INSERT INTO ZPREFERENCE VALUES (?,3,1,?,?)", (pk, key, value))
        db.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=? WHERE Z_NAME='Preference'", (pk,))
    print("Seeded 61 subscriptions; target last; default server differs from link server; sort=" + args.sort, flush=True)
if args.seed_only:
    raise SystemExit(0)
command = ["xcodebuild", "-project", str(root / "NavigationPilot.xcodeproj"), "-scheme", "NavigationPilot",
           "-destination", "platform=iOS Simulator,id=" + args.udid, "-derivedDataPath", str(args.derived_data),
           "-parallel-testing-enabled", "NO", "NTFY_TEST_APP_ID=" + bundle_id,
           "NTFY_TEST_HARNESS=" + str(harness), "test"]
command += ["-only-testing:NavigationPilotUITests/NavigationPilotUITests/" + name for name in args.only]
run(*command)
