# Make a stable Hereforth release

Hereforth releases use annotated Git tags signed with a dedicated SSH Ed25519 key. The first installer pins the public key. The installed updater uses the public signer shipped in the installed app. The GitHub release page holds notes and source downloads. The supported first-install path checks out verified Git source and builds natively with Xcode Command Line Tools.

## Release key custody

Use a dedicated release key named `hereforth-release` with a strong passphrase. Keep the private key in encrypted storage outside the repository and CI. If you need to create a key, an example is `ssh-keygen -t ed25519 -a 100 -C hereforth-release -f ~/.ssh/hereforth_release`.

Publish only the public key. The allowed-signers entry begins with `hereforth-release namespaces="git"` followed by the Ed25519 public key. Keep `scripts/release-signers` and the embedded `allowed_signer` line in `scripts/bootstrap.sh` identical. The local bootstrap smoke test checks this. Key changes require coordination with people who already pinned a release key. Use a renewed bootstrap obtained from a trusted source if the existing pin changes.

## Prepare and sign

1. Pick a new `vMAJOR.MINOR.PATCH` version with decimal fields and no leading zeros. A suffix makes a preview tag. The bootstrap and updater select stable tags by version.
2. Verify macOS CI on the exact commit. Exercise the app build and assistant integration on a test Mac, using a separate library and synthetic evidence. Prepare the GitHub release notes before pushing the tag.
3. Create the annotated SSH-signed tag on the tested commit. Substitute the actual version and your local release key path.

```sh
tag=vX.Y.Z
git -c gpg.format=ssh -c user.signingKey="$HOME/.ssh/hereforth_release" \
  tag -s "$tag" -m "Hereforth $tag" HEAD
git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$PWD/scripts/release-signers" \
  verify-tag "$tag"
```

From a clean detached checkout of the verified tag, `./scripts/install.sh` builds for the architecture of that Mac. Validate the bundle version and signature on the test Mac.

```sh
app="$HOME/Applications/Hereforth.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist"
codesign --verify --deep --strict "$app"
```

## Publish

Push the exact signed tag once the release is ready. Stable installers can discover it as soon as the tag is visible. Create the GitHub release against that existing tag and attach an exact copy of the tagged bootstrap as the `install.sh` asset.

```sh
git push origin "refs/tags/$tag"
asset_dir="$(mktemp -d)"
git show "$tag:scripts/bootstrap.sh" > "$asset_dir/install.sh"
gh release create "$tag" --verify-tag --title "Hereforth $tag" \
  --notes-file release-notes.md "$asset_dir/install.sh"
rm "$asset_dir/install.sh"
rmdir "$asset_dir"
```

Users install from the signed source with the [installation guide](install.md). The automatic source archives on GitHub lack the Git tag object and its signature. Use the verified Git checkout to build a stable installation. Publish corrections under a new version and keep released tags fixed.
