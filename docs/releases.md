# Make a stable Hereforth release

The standard download is an Apple Silicon DMG containing a Developer ID-signed and notarized Hereforth app. The same GitHub release also carries the first-install script for a native build from signed source. The source installer and binary updater verify releases through separate signing keys.

## Keep release keys separate

- **Source verification.** Use the dedicated SSH Ed25519 release key `hereforth-release`. Keep the encrypted private key outside the repository and CI. If you need to create a key, an example is `ssh-keygen -t ed25519 -a 100 -C hereforth-release -f ~/.ssh/hereforth_release`. Keep the public entry in `scripts/release-signers` identical to the embedded `allowed_signer` line in `scripts/bootstrap.sh`. A change to this pin requires a renewed bootstrap obtained from a trusted source.
- **macOS signing and notarization.** Use an authorized Developer ID Application identity. Store notary credentials in a Keychain profile or sign and notarize through Xcode. Keep these credentials out of the repository and CI logs.
- **Binary update verification.** Use the dedicated Sparkle Ed25519 Keychain account `com.hereforth.release`. The app includes its public key. Keep the matching private key protected and keep it stable across releases so already-installed copies can verify the next update.

## Prepare the source tag

Pick a new `vMAJOR.MINOR.PATCH` version with decimal fields and no leading zeros. A suffix makes a preview tag. Pass macOS CI on the exact commit, test with a separate Hereforth library, and prepare release notes. Keep the Sparkle build number higher than every previous production build number.

Create and verify an annotated SSH-signed tag on the tested commit. Substitute the actual version and your release key path.

```sh
tag=vX.Y.Z
git -c gpg.format=ssh -c user.signingKey="$HOME/.ssh/hereforth_release" \
  tag -s "$tag" -m "Hereforth $tag" HEAD
git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$PWD/scripts/release-signers" \
  verify-tag "$tag"
```

Use a clean, detached checkout of this tag for release builds. The source installer builds for the architecture of that Mac. The [installation guide](install.md) covers source verification and installation.

## Build and verify the DMG

On an Apple Silicon build Mac, use `scripts/package-macos.sh stage` to build the production app for signing and notarization. Use the same release version, build number and Sparkle key for staging and packaging.

```sh
build=20002  # Replace with this release's build number
workspace="$(mktemp -d)"
archive="$workspace/Hereforth.xcarchive"
./scripts/package-macos.sh stage --version "${tag#v}" --build "$build" --track production \
  --output "$workspace/Hereforth.app"
python3 scripts/archive-macos.py "$workspace/Hereforth.app" "$archive" TEAM_ID
xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist "$archive.upload.plist" -allowProvisioningUpdates
xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$workspace/export"
```

Substitute your Apple development team ID for `TEAM_ID`. The cloud export uses your signed-in Xcode account. If Apple is still processing the upload, wait and retry `xcodebuild -exportNotarizedApp` against the same archive. Verify the exported app before passing it to the packaging command.

```sh
out="$workspace/dist"
./scripts/package-macos.sh dmg --version "${tag#v}" --build "$build" --track production \
  --output "$out" --asset-base-url "https://github.com/moiiiiit/hereforth/releases/download/$tag" \
  --notarized-app "$workspace/export/Hereforth.app"
python3 Tests/macos-artifact-smoke.py "$out/Hereforth.dmg" \
  --version "${tag#v}" --build "$build" --notarized-app
```

The packaging script also supports building and notarizing directly with `--identity` and `--notary-profile`. Check the available options with `./scripts/package-macos.sh --help`. Describe the notarized app inside the DMG in the release notes. Claim outer disk-image notarization only after verifying a separate stapled ticket with `xcrun stapler validate` and rerunning the smoke test with `--notarized-dmg`.

The smoke test mounts the image without installing the app and verifies the Applications link, arm64 code, Sparkle linkage, signature and resources. On a test Mac, drag the same verified app into Applications and exercise one test connector between **Hereforth → Connect Assistants…** and a synthetic assistant profile. Confirm an existing conflicting connector remains intact.

## Publish

Push the exact signed tag once all assets are ready. Stable source installers can discover it as soon as the Git tag is visible. Upload the DMG and an exact copy of the tagged bootstrap under the `install.sh` asset name.

```sh
git push origin "refs/tags/$tag"
asset_dir="$(mktemp -d)"
git show "$tag:scripts/bootstrap.sh" > "$asset_dir/install.sh"
gh release create "$tag" --verify-tag --title "Hereforth $tag" \
  --notes-file release-notes.md "$out/Hereforth.dmg" "$asset_dir/install.sh"
rm "$asset_dir/install.sh"
rmdir "$asset_dir"
```

Confirm the enclosure URL in the generated `appcast.xml` downloads the exact disk image you just signed with Sparkle. Publish that feed as `updates/appcast.xml` on the canonical default branch only after the asset is available. Preview releases use a separate feed. Publish corrections under a new version and keep released tags and assets fixed.
