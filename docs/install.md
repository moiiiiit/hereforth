# Install Hereforth

The disk image requires an Apple Silicon Mac running macOS 14 or later. It contains a signed, notarized app that runs without Xcode or Command Line Tools.

1. [Download Hereforth.dmg](https://github.com/moiiiiit/hereforth/releases/latest/download/Hereforth.dmg) and open the disk image.
2. Drag Hereforth to **Applications**. You can put it in the **Applications** folder in your home folder if you prefer a per-user installation.
3. Eject the disk image and open Hereforth from the folder where you installed it.
4. In the **Hereforth** menu, select **Connect Assistants…**, choose your client, and click **Connect**. If Claude Desktop has never opened on this Mac, open it once before connecting. Claude Code and Codex use their existing CLI. If Hereforth asks for the executable, choose it in the file picker.

Fully quit and reopen Claude Desktop after connecting it, or start a fresh Claude Code or Codex session. If your client already has a conflicting server called `hereforth`, Hereforth preserves its settings so you can review that entry in the client. Managed Macs follow their organization's installation and connector rules.

Choose **Hereforth → Check for Updates…** for an immediate check. Automatic checks and installation can be managed in **Hereforth → Settings**. Your library and connector settings stay separate from the app bundle during an update.

## Build from signed source

The signed-source installer builds natively on Apple Silicon or Intel using Apple's Command Line Tools. If those tools are missing, run `xcode-select --install` and complete the Mac's installation prompt.

```sh
curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
  https://github.com/moiiiiit/hereforth/releases/latest/download/install.sh \
  -o hereforth-bootstrap.sh
bash hereforth-bootstrap.sh
```

Pass one or more of `--claude-code`, `--claude-desktop`, and `--codex` to connect those clients during installation. The source installer builds into `~/Applications`, verifies the highest stable annotated Git tag against the pinned Hereforth release key, and stops if that tag fails verification. The local source build uses ad hoc code signing.

### Inspect the verified source first

Open the downloaded bootstrap in a text editor before running it, or clone the release source for inspection.

```sh
git clone --no-checkout https://github.com/moiiiiit/hereforth.git hereforth-source
cd hereforth-source
curl --fail --show-error --proto '=https' \
  https://raw.githubusercontent.com/moiiiiit/hereforth/main/scripts/release-signers \
  -o ../hereforth-release-signers
awk '{print $3, $4}' ../hereforth-release-signers | ssh-keygen -lf /dev/stdin
```

Check the Ed25519 fingerprint against the release key you trust. The current fingerprint is `SHA256:FxzNc1UgF8y6U2RT8Ccm9DhNWCVYB+w931RJHvxskmw`. Replace `vX.Y.Z` below with a stable tag from [Hereforth releases](https://github.com/moiiiiit/hereforth/releases).

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

### Updates for a source build

Stable source installations check daily at 10 a.m. local time and install a newer verified source release when available. Use the bundled helper for manual checks and to change the schedule.

```sh
helper="$HOME/Applications/Hereforth.app/Contents/MacOS/hereforth"
"$helper" update status
"$helper" update check
"$helper" update install
```

Use `"$helper" update disable` to turn off scheduled updates or `"$helper" update enable` to restore them. Manual checks and installation remain available when the schedule is off.
