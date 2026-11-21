#!/usr/bin/env python3
"""Prepare a staged Hereforth app for Xcode's Developer ID upload workflow."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("staged_app", type=Path)
    parser.add_argument("archive", type=Path)
    parser.add_argument("team_id")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        parser.error("Provide the 10-character Apple Developer Team ID.")
    if args.archive.suffix != ".xcarchive":
        parser.error("Provide an output path ending in .xcarchive.")

    app = args.staged_app.resolve()
    archive = args.archive.absolute()
    upload_options = Path(str(archive) + ".upload.plist")
    for output in (archive, upload_options):
        if output.exists() or output.is_symlink():
            parser.error(f"Output already exists: {output}")
    bundle = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if bundle.get("CFBundleIdentifier") != "com.hereforth.app" or bundle.get("HereforthUpdateChannel") != "binary":
        parser.error("Use the binary app from package-macos.sh stage.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True)
    architectures = subprocess.check_output([
        "/usr/bin/lipo", "-archs", app / "Contents/MacOS/HereforthApp",
    ], text=True).split()
    if architectures != ["arm64"]:
        parser.error("The main executable must be Apple silicon.")

    app_path = Path("Applications/Hereforth.app")
    archived_app = archive / "Products" / app_path
    archived_app.parent.mkdir(parents=True)
    subprocess.run(["/usr/bin/ditto", app, archived_app], check=True)

    properties = {
        key: bundle[key]
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")
    }
    properties.update(ApplicationPath=str(app_path), Architectures=architectures, Team=args.team_id)
    (archive / "Info.plist").write_bytes(plistlib.dumps({
        "ArchiveVersion": 2,
        "ApplicationProperties": properties,
        "CreationDate": datetime.now(timezone.utc).replace(tzinfo=None),
        "Name": "Hereforth",
        "SchemeName": "Hereforth",
    }))
    with upload_options.open("xb") as file:
        plistlib.dump({
            "method": "developer-id",
            "destination": "upload",
            "signingStyle": "automatic",
            "teamID": args.team_id,
            "manageAppVersionAndBuildNumber": False,
        }, file)
    print(f"Created {archive} and {upload_options}")


if __name__ == "__main__":
    main()
