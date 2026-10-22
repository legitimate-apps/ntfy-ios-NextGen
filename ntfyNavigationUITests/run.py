#!/usr/bin/env python3
"""Replay navigation integration tests on a dedicated, booted simulator.

Uses an already-built app. Seeding modifies ONLY that simulator's app-group store.
No app source changes, provisioning changes, or third-party Python packages.
"""
import argparse
import base64
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
parser.add_argument("--result-bundle", type=Path, help="explicit xcresult path to preserve evidence outside automatic log pruning")
parser.add_argument("--empty-fixture", action="store_true", help="seed no subscriptions for the empty-state capture")
parser.add_argument("--seed", action="store_true", help="replace subscriptions with 61 isolated fixture topics")
parser.add_argument("--seed-only", action="store_true", help="prepare fixture without running the UI suite")
parser.add_argument("--german", action="store_true", help="run the German localization suite instead of English navigation")
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
        for index in range(0 if args.empty_fixture else 61):
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
    if not args.empty_fixture:
        with sqlite3.connect(store) as db:
            db.execute("DELETE FROM ZUSER")
            # A synthetic legacy password lets the current app migrate a real named login.
            db.execute("INSERT INTO ZUSER VALUES (1,6,1,'http://127.0.0.1:1','accessibility-fixture-password','accessibility-user')")
            db.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=1 WHERE Z_NAME='User'")
        image = store.parent / "accessibility-fixture.png"
        image.write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII="))
        with sqlite3.connect(store) as db:
            db.execute("UPDATE ZNOTIFICATION SET ZPRIORITY=4,ZTAGS='warning,heart',ZMESSAGE='Accessibility fixture',"
                       "ZATTACHMENTNAME='Fixture image.png',ZATTACHMENTTYPE='image/png',ZATTACHMENTURL='http://127.0.0.1:1/image.png',"
                       "ZATTACHMENTLOCALPATH=? WHERE Z_PK=1", (str(image),))
    print("Seeded 61 subscriptions; target last; default server differs from link server; sort=" + args.sort, flush=True)
if args.seed_only:
    raise SystemExit(0)
command = ["xcodebuild", "-project", str(root / "NavigationPilot.xcodeproj"), "-scheme", "NavigationPilot",
           "-destination", "platform=iOS Simulator,id=" + args.udid, "-derivedDataPath", str(args.derived_data),
           "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "NTFY_TEST_APP_ID=" + bundle_id,
           "NTFY_TEST_HARNESS=" + str(harness), "test"]
if args.result_bundle:
    command += ["-resultBundlePath", str(args.result_bundle.resolve())]
suite = "GermanLocalizationUITests" if args.german else "NavigationPilotUITests"
command += ["-only-testing:NavigationPilotUITests/" + suite + "/" + name for name in args.only]
if not args.only:
    if args.german:
        names = ["testGermanEmptyList"] if args.empty_fixture else ["testGermanMainScreens", "testGermanLicenseScreens"]
        command += ["-only-testing:NavigationPilotUITests/" + suite + "/" + name for name in names]
    else:
        command += ["-only-testing:NavigationPilotUITests/" + suite]
run(*command)
