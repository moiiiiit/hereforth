"""Verify the first-install trust boundary with a temporary local Git remote and test keys."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
script = (repo / "scripts/bootstrap.sh").read_text()
signer_pattern = r"^allowed_signer='([^'\n]+)'$"
assert re.search(signer_pattern, script, re.M)[1] == (repo / "scripts/release-signers").read_text().rstrip("\n")


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=30, **kwargs).stdout.strip()


with tempfile.TemporaryDirectory(prefix="hereforth-bootstrap-test-") as temporary:
    root = Path(temporary).resolve()
    checkout = root / "checkout"
    marker = root / "ran"
    good_key = root / "release-key"
    wrong_key = root / "wrong-key"
    for key in (good_key, wrong_key):
        run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key)
    signer = 'hereforth-release namespaces="git" ' + good_key.with_suffix(".pub").read_text().strip()
    wrong_signer = 'hereforth-release namespaces="git" ' + wrong_key.with_suffix(".pub").read_text().strip()
    run("/usr/bin/git", "init", "-q", "--template=", checkout)

    def git(*args):
        return run("/usr/bin/git", "-C", checkout, "-c", "user.name=Synthetic Hereforth",
                   "-c", "user.email=synthetic@example.test", "-c", "commit.gpgsign=false", *args)

    def tag(name, key):
        git("-c", "gpg.format=ssh", "-c", f"user.signingkey={key}", "tag", "-s", "-m", name, name)

    (checkout / "scripts").mkdir()
    signers = checkout / "scripts/release-signers"
    signers.write_text(signer + "\n")
    install = checkout / "scripts/install.sh"
    install.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\" > \"$HEREFORTH_BOOTSTRAP_TEST_MARKER\"\n")
    install.chmod(0o755)
    git("add", "scripts")
    git("commit", "-qm", "Synthetic signed release")
    tag("v2.9.9", good_key)
    tag("v2.10.0", good_key)
    git("-c", "tag.gpgsign=false", "tag", "v999.0.0-preview")
    git("-c", "tag.gpgsign=false", "tag", "v0999.0.0")

    # The distributed script has no runtime origin or signer overrides.
    test_script = root / "bootstrap.sh"
    synthetic = script.replace("https://github.com/moiiiiit/hereforth.git", checkout.as_uri())
    synthetic = synthetic.replace("protocol.https.allow=always", "protocol.file.allow=always")
    synthetic = re.sub(signer_pattern, lambda _: f"allowed_signer='{signer}'", synthetic, flags=re.M)
    test_script.write_text(synthetic)
    env = dict(os.environ, HEREFORTH_BOOTSTRAP_TEST_MARKER=str(marker), GIT_DIR=str(root / "unrelated-git-dir"))
    result = run("/bin/bash", test_script, "--codex", "--claude-code", env=env)
    assert "Verified Hereforth v2.10.0" in result, result
    assert marker.read_text().splitlines() == ["--codex", "--claude-code"]
    marker.unlink()

    def rejected(message):
        result = subprocess.run(["/bin/bash", test_script], env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode != 0 and message in result.stderr, result
        assert not marker.exists()

    git("-c", "tag.gpgsign=false", "tag", "-a", "-m", "unsigned", "v3.0.0")
    rejected("has no SSH release signature")
    git("tag", "-d", "v3.0.0")
    tag("v3.0.0", wrong_key)
    rejected("did not verify against the pinned release signer")
    git("tag", "-d", "v3.0.0")
    git("update-ref", "refs/tags/v3.0.0", git("rev-parse", "refs/tags/v2.10.0"))
    rejected("does not match the advertised release name")
    git("tag", "-d", "v3.0.0")
    signers.write_text(wrong_signer + "\n")
    git("add", "scripts/release-signers")
    git("commit", "-qm", "Changed synthetic trust pin")
    tag("v3.0.0", good_key)
    rejected("does not match the bootstrap signer")

print("Bootstrap smoke passed: stable ordering, argument forwarding, and refusal of untrusted candidates.")
