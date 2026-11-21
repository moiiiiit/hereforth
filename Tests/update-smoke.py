"""Run with python3 Tests/update-smoke.py on macOS."""
import fcntl
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
GIT = "/usr/bin/git"


def command(arguments, **kwargs):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=60, **kwargs)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def git(repository, *arguments):
    env = {"PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
    return command([GIT, "-C", repository, *arguments], env=env)


def update(app, env, mode, *, expected="", error=None):
    result = subprocess.run([app / "Contents/Resources/update.sh", mode], env=env,
                            capture_output=True, text=True, timeout=60)
    if error:
        assert result.returncode != 0 and error in result.stderr, (result.returncode, result.stderr)
        assert result.stdout == ""
    else:
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == expected, result.stdout
    assert not any(path.is_dir() for path in app.parent.glob(".hereforth-update.*")), "Staging directories were left behind."
    return result.stderr


def metadata(app, version, channel="stable"):
    info = dict(CFBundleIdentifier="com.hereforth.app", CFBundleShortVersionString=version,
                CFBundleVersion="1", CFBundleName="Hereforth", CFBundlePackageType="APPL",
                CFBundleExecutable="HereforthApp", HereforthUpdateChannel=channel)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))


def exercise(root):
    repo = root / "releases"
    repo.mkdir()
    git(repo, "init", "--quiet")
    git(repo, "config", "user.name", "Synthetic Release Signer")
    git(repo, "config", "user.email", "release-fixture@example.invalid")
    trusted = root / "trusted"
    untrusted = root / "untrusted"
    for key in (trusted, untrusted):
        command(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key])

    scripts = repo / "scripts"
    scripts.mkdir()
    pins = "fixture namespaces=\"git\" " + trusted.with_suffix(".pub").read_text()
    (scripts / "release-signers").write_text(pins)
    production = (ROOT / "scripts/update.sh").read_text()
    canonical = "https://github.com/moiiiiit/hereforth.git"
    assert production.count(canonical) == 1 and "protocol.file.allow" not in production
    # Only this temporary installed copy accepts the local transport.
    updater = production.replace(canonical, repo.as_uri()).replace(
        "-c protocol.https.allow=always", "-c protocol.https.allow=always -c protocol.file.allow=always")
    (scripts / "update.sh").write_text(updater)
    (scripts / "update.sh").chmod(0o755)
    shutil.copyfile(ROOT / "scripts/install-support.swift", scripts / "install-support.swift")
    shutil.copyfile(ROOT / "scripts/Info.plist", scripts / "Info.plist")
    (scripts / "install.sh").write_text('''#!/bin/bash
set -euo pipefail
[[ $# == 2 && $1 == --stage-app ]]
cd "$(dirname "$0")/.."
version="$(/usr/bin/git describe --exact-match --tags HEAD)"
printf 'fixture installer ran\n' >&2
bundle="$2"
mkdir -p "$bundle/Contents/"{MacOS,Resources}
cp /usr/bin/true "$bundle/Contents/MacOS/HereforthApp"
cp scripts/Info.plist "$bundle/Contents/Info.plist"
cp scripts/{release-signers,update.sh} "$bundle/Contents/Resources/"
touch "$bundle/Contents/Resources/hereforth-install"
[[ ! -e fail-stage ]] || exit 7
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version#v}" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :HereforthUpdateChannel' "$bundle/Contents/Info.plist" 2>/dev/null || :
/usr/libexec/PlistBuddy -c 'Add :HereforthUpdateChannel string stable' "$bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$bundle"
''')
    git(repo, "add", "scripts")
    git(repo, "commit", "-qm", "Synthetic release source")

    def signed(tag, key=trusted):
        git(repo, "-c", "gpg.format=ssh", "-c", f"user.signingkey={key}", "tag", "-s", "-m", tag, tag)

    fixture_profile = root / "test user"
    app = fixture_profile / "Applications/Hereforth.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    metadata(app, "0.1.0")
    (resources / "hereforth-install").touch()
    (resources / "release-signers").write_text(pins)
    (resources / "update.sh").write_text(updater)
    (resources / "update.sh").chmod(0o755)
    (resources / "old-bundle").touch()
    profile = fixture_profile / "Library/Application Support/Hereforth"
    profile.mkdir(parents=True)
    settings = profile / "untouched-fixture.json"
    settings.write_bytes(b'{"keep":"exact"}\n')
    preference = profile / "automatic-updates"

    # The worker and release commands must ignore inherited shell and Git startup settings.
    startup_marker = root / "ambient-startup-ran"
    startup = root / "ambient-shell"
    startup.write_text(f"touch {shlex.quote(str(startup_marker))}\n")
    hostile_git = root / "ambient-git"
    hostile_git.write_text(f'[url "file:///nonexistent-release"]\n\tinsteadOf = {repo.as_uri()}\n')
    env = {**os.environ, "HOME": str(fixture_profile), "BASH_ENV": str(startup), "GIT_CONFIG_GLOBAL": str(hostile_git)}

    signed("v0.1.0")
    signed("v0.0.999")
    git(repo, "tag", "v999.01.0")
    git(repo, "tag", "v999.0.0-rc.1")
    git(repo, "tag", "999.0.0")
    update(app, env, "install", expected="current 0.1.0")

    git(repo, "tag", "v0.2.0")
    assert "fixture installer ran" not in update(app, env, "install", error="missing an annotated tag")
    git(repo, "tag", "-d", "v0.2.0")
    git(repo, "tag", "-a", "-m", "Unsigned tag", "v0.2.0")
    assert "fixture installer ran" not in update(app, env, "install", error="no SSH signature")
    git(repo, "tag", "-d", "v0.2.0")
    signed("v0.2.0", untrusted)
    assert "fixture installer ran" not in update(app, env, "check", error="did not match")
    git(repo, "tag", "-d", "v0.2.0")
    old_tag = git(repo, "rev-parse", "refs/tags/v0.1.0")
    git(repo, "update-ref", "refs/tags/v0.2.0", old_tag)
    assert "fixture installer ran" not in update(app, env, "install", error="does not name the selected release commit")
    git(repo, "tag", "-d", "v0.2.0")

    signed("v0.2.0")
    installed_updater = resources / "update.sh"
    before_fetch = 'git_release -C "$checkout" init --quiet'
    assert updater.count(before_fetch) == 1
    # Simulate the exact ref changing after ls-remote but before fetch in the temporary clone.
    replace_ref = f"git_release -C {shlex.quote(str(repo))} update-ref refs/tags/v0.2.0 {old_tag}"
    installed_updater.write_text(updater.replace(before_fetch, before_fetch + "\n    " + replace_ref))
    assert "fixture installer ran" not in update(app, env, "install", error="changed while it was being fetched")
    installed_updater.write_text(updater)
    git(repo, "tag", "-d", "v0.2.0")

    (repo / "fail-stage").touch()
    git(repo, "add", "fail-stage")
    git(repo, "commit", "-qm", "Signed fixture that fails during staging")
    signed("v0.2.0")
    assert "fixture installer ran" not in update(app, env, "check", expected="available 0.2.0")
    assert "fixture installer ran" in update(app, env, "install", error="Building the update failed")
    assert (resources / "old-bundle").exists()
    assert plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == "0.1.0"
    assert settings.read_bytes() == b'{"keep":"exact"}\n'
    git(repo, "tag", "-d", "v0.2.0")
    git(repo, "rm", "fail-stage")
    git(repo, "commit", "-qm", "Signed fixture that stages successfully")
    signed("v0.2.0")

    preference.write_text("disabled\n")
    assert "fixture installer ran" not in update(app, env, "automatic")
    assert (resources / "old-bundle").exists()
    preference.write_text("enabled\n")
    metadata(app, "0.1.0", channel="development")
    assert "fixture installer ran" not in update(app, env, "automatic")
    metadata(app, "0.1.0")

    lock = app.parent / ".hereforth-update.lock"
    with lock.open("rb") as locked:
        fcntl.flock(locked, fcntl.LOCK_EX)
        assert "fixture installer ran" not in update(app, env, "install", error="already locked")
    assert "fixture installer ran" in update(app, env, "automatic", expected="installed 0.2.0")
    assert not (resources / "old-bundle").exists()
    assert (resources / "release-signers").read_text() == pins
    assert preference.read_text() == "enabled\n" and settings.read_bytes() == b'{"keep":"exact"}\n'
    update(app, env, "install", expected="current 0.2.0")
    git(repo, "tag", "-d", "v0.2.0")
    update(app, env, "install", expected="current 0.2.0")
    assert not startup_marker.exists()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="hereforth-update-test-") as temp:
        exercise(Path(temp))
    print("Signed updater smoke test passed.")
