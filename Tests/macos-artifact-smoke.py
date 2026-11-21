"""Mount and verify a packaged Hereforth DMG without installing its app."""
import argparse
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("image", type=Path)
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True)
parser.add_argument("--track", choices=("production", "beta"), default="production")
parser.add_argument("--notarized-app", action="store_true")
parser.add_argument("--notarized-dmg", action="store_true")
args = parser.parse_args()
image = args.image.resolve(strict=True)


def command(*args, success=True, env=None):
    result = subprocess.run(args, text=True, capture_output=True, env=env, timeout=180)
    assert (result.returncode == 0) == success, (args, result.stdout, result.stderr)
    return result


command("/usr/bin/hdiutil", "verify", image)
if args.notarized_dmg:
    command("/usr/bin/xcrun", "stapler", "validate", image)

with tempfile.TemporaryDirectory(prefix="hereforth-dmg-qa-") as directory:
    mount = Path(directory)
    command("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, image)
    try:
        link = mount / "Applications"
        assert link.is_symlink() and os.readlink(link) == "/Applications"
        app = mount / "Hereforth.app"
        contents = app / "Contents"
        plist = plistlib.loads((contents / "Info.plist").read_bytes())
        assert plist["CFBundleIdentifier"] == "com.hereforth.app"
        assert plist["CFBundleShortVersionString"] == args.version.split("-", 1)[0]
        assert plist["CFBundleVersion"] == args.build
        assert plist["LSMinimumSystemVersion"] == "14.0"
        assert plist["HereforthReleaseVersion"] == args.version
        assert plist["HereforthUpdateChannel"] == "binary"
        assert plist["HereforthBinaryUpdateTrack"] == args.track
        filename = "appcast.xml" if args.track == "production" else "appcast-beta.xml"
        assert plist["SUFeedURL"] == f"https://raw.githubusercontent.com/moiiiiit/hereforth/main/updates/{filename}"
        assert len(base64.b64decode(plist["SUPublicEDKey"], validate=True)) == 32
        assert plist["SUVerifyUpdateBeforeExtraction"] is True

        resources = contents / "Resources"
        assert (resources / "Hereforth.icns").stat().st_size > 0
        guide = resources / "Hereforth_HereforthCore.bundle/Contents/Resources/Humanizer"
        for required in ("SKILL.md", "LICENSE", "NOTICE.md"):
            assert (guide / required).is_file(), required
        assert not (resources / "update.sh").exists()
        assert not (resources / "release-signers").exists()

        helper = contents / "MacOS/hereforth"
        gui = contents / "MacOS/HereforthApp"
        fw = contents / "Frameworks/Sparkle.framework"
        for executable in (gui, helper):
            assert command("/usr/bin/lipo", "-archs", executable).stdout.strip() == "arm64", executable
        for executable in [
            fw / "Sparkle", fw / "Versions/Current/Autoupdate",
            fw / "Versions/Current/Updater.app/Contents/MacOS/Updater",
            fw / "Versions/Current/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
            fw / "Versions/Current/XPCServices/Installer.xpc/Contents/MacOS/Installer",
        ]:
            assert "arm64" in command("/usr/bin/lipo", "-archs", executable).stdout.split(), executable
        linked = command("/usr/bin/otool", "-arch", "arm64", "-L", gui).stdout
        paths = command("/usr/bin/otool", "-arch", "arm64", "-l", gui).stdout
        assert "@rpath/Sparkle.framework/" in linked
        assert "path @executable_path/../Frameworks " in paths
        assert "/.build/" not in paths
        command("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", app)
        if args.notarized_app:
            command("/usr/bin/xcrun", "stapler", "validate", app)
            command("/usr/sbin/spctl", "--assess", "--type", "execute", app)

        env = dict(os.environ, PATH="/usr/bin:/bin")
        runtime = command(helper, "update", "status", env=env).stdout
        assert args.version in runtime and args.track in runtime
        error = command(helper, "update", "check", success=False, env=env).stderr
        assert "Check for Updates" in error
    finally:
        command("/usr/bin/hdiutil", "detach", mount)

print("DMG smoke passed: verified image, Applications link, Apple Silicon code, Sparkle, resources, signatures, and binary CLI.")
