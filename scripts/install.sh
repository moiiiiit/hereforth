#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s [--claude-code] [--claude-desktop] [--codex]\n' "${0##*/}"
}

claude_code=false
claude_desktop=false
codex_client=false
stage_app=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --claude-code) claude_code=true ;;
        --claude-desktop) claude_desktop=true ;;
        --codex) codex_client=true ;;
        --stage-app)
            [[ $# -ge 2 && "$2" = /*.app && -z "$stage_app" ]] || { usage >&2; exit 2; }
            stage_app="$2"
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
if [[ -n "$stage_app" ]] && { $claude_code || $claude_desktop || $codex_client; }; then
    usage >&2
    exit 2
fi

cd "$(dirname "$0")/.."
dest="${stage_app:-$HOME/Applications/Hereforth.app}"
dest_dir="$(dirname "$dest")"
marker="Contents/Resources/hereforth-install"
if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ -L "$dest" || ! -f "$dest/$marker" ]] ||
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null)" != "com.hereforth.app" ]]; then
        printf 'An existing app at %s is owned by another installer.\n' "$dest" >&2
        exit 1
    fi
fi

release_signers="$PWD/scripts/release-signers"
release_version=""
tag="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ "$tag" =~ ^v((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$ ]]; then
    candidate_version="${BASH_REMATCH[1]}"
    if [[ -z "$(git status --porcelain --untracked-files=normal)" ]] &&
        git -c gpg.format=ssh -c gpg.ssh.program=/usr/bin/ssh-keygen -c gpg.ssh.allowedSignersFile="$release_signers" \
            -c gpg.minTrustLevel=fully verify-tag "$tag" >/dev/null 2>&1; then
        release_version="$candidate_version"
    fi
fi

HEREFORTH_BINARY_UPDATER=0 swift build --configuration release
bin="$(HEREFORTH_BINARY_UPDATER=0 swift build --configuration release --show-bin-path)"
mkdir -p "$dest_dir"
stage="$(mktemp -d "$dest_dir/.hereforth.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Hereforth.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 644 scripts/Info.plist "$bundle/Contents/Info.plist"
install -m 755 "$bin/HereforthApp" "$bin/hereforth" "$bundle/Contents/MacOS/"
install -m 755 scripts/update.sh "$bundle/Contents/Resources/update.sh"
install -m 644 "$release_signers" "$bundle/Contents/Resources/release-signers"
if [[ -n "$release_version" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $release_version" \
        -c "Set :CFBundleVersion $release_version" -c "Set :HereforthUpdateChannel stable" "$bundle/Contents/Info.plist"
fi
resource_bundle="Hereforth_HereforthCore.bundle"
/usr/bin/ditto "$bin/$resource_bundle" "$bundle/Contents/Resources/$resource_bundle"

iconset="$stage/Hereforth.iconset"
mkdir "$iconset"
for size in 16 32 64 128 256 512 1024; do
    /usr/bin/sips -z "$size" "$size" Assets/Hereforth.png --out "$stage/icon-$size.png" >/dev/null
done
for size in 16 32 128 256 512; do
    cp "$stage/icon-$size.png" "$iconset/icon_${size}x${size}.png"
    cp "$stage/icon-$((size * 2)).png" "$iconset/icon_${size}x${size}@2x.png"
done
/usr/bin/iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/Hereforth.icns"

touch "$bundle/$marker"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$bundle/Contents/MacOS/hereforth"
    codesign --force --sign - "$bundle"
    codesign --verify --deep --strict "$bundle"
fi

# A same-volume swap keeps the previous app available until its replacement is ready.
swift scripts/install-support.swift bundle "$bundle" "$dest"
printf 'Installed %s\n' "$dest"
[[ -z "$stage_app" ]] || exit 0

helper="$dest/Contents/MacOS/hereforth"
status=0
if ! "$helper" update configure; then
    status=1
fi
if $claude_code; then
    "$helper" connect claude-code || status=1
fi

if $claude_desktop; then
    "$helper" connect claude-desktop || status=1
fi

if $codex_client; then
    "$helper" connect codex || status=1
fi
exit "$status"
