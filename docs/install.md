# Install Hereforth

Hereforth requires macOS 14 or later and Apple's Command Line Tools. If the tools are missing, run `xcode-select --install` and complete the Mac's installation prompt.

In Terminal, download the bootstrap script and run it.

```sh
curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
  https://github.com/moiiiiit/hereforth/releases/latest/download/install.sh \
  -o hereforth-bootstrap.sh
bash hereforth-bootstrap.sh
```

To register a local assistant during installation, run `bash hereforth-bootstrap.sh` with one or more of `--claude-code`, `--claude-desktop`, and `--codex`. The flags are optional. Hereforth installs in `~/Applications` and builds for the Mac running the installer.

The bootstrap script comes from the canonical GitHub repository over HTTPS. It pins the Hereforth release signing key, selects the highest stable version, and verifies its signed Git tag before checking out and running the installer. Preview tags are skipped. If the latest stable candidate fails verification, installation stops. The app uses local ad hoc code signing. Apple Developer ID signing and notarization are outside this distribution. On managed Macs, your organization's installation and connector rules apply.

## Inspect the source before running the installer

You can open the downloaded bootstrap in a text editor before running it. To verify and inspect the release source yourself, first clone without checking out files and retrieve the public signer from the canonical project.

```sh
git clone --no-checkout https://github.com/moiiiiit/hereforth.git hereforth-source
cd hereforth-source
curl --fail --show-error --proto '=https' \
  https://raw.githubusercontent.com/moiiiiit/hereforth/main/scripts/release-signers \
  -o ../hereforth-release-signers
awk '{print $3, $4}' ../hereforth-release-signers | ssh-keygen -lf /dev/stdin
```

Check the Ed25519 fingerprint against the release key you trust. The current fingerprint is `SHA256:FxzNc1UgF8y6U2RT8Ccm9DhNWCVYB+w931RJHvxskmw`. Choose a stable tag from the project's releases. Replace `vX.Y.Z` below with that tag.

```sh
tag=vX.Y.Z
git -c gpg.format=ssh \
  -c gpg.ssh.allowedSignersFile="$(cd .. && pwd)/hereforth-release-signers" \
  verify-tag "$tag"
git cat-file -p "$tag" | sed -n '1,3p'
```

Continue after verification succeeds and the tag header reports `type commit` and the exact `tag` you chose.

```sh
git switch --detach "$tag"
less scripts/install.sh
./scripts/install.sh
```

The installer accepts the same assistant flags. See the [Hereforth releases](https://github.com/moiiiiit/hereforth/releases) for version notes.

## Updates

Stable installations check daily at 10 a.m. local time and install a newer verified release when available. To inspect the setting, check for a release now, or install an available release, use the bundled helper.

```sh
helper="$HOME/Applications/Hereforth.app/Contents/MacOS/hereforth"
"$helper" update status
"$helper" update check
"$helper" update install
```

Run `"$helper" update disable` to turn off the daily check or `"$helper" update enable` to restore it. Manual checks and installation remain available when the daily check is off.
