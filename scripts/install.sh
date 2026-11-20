#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s [--claude-code] [--claude-desktop]\n' "${0##*/}"
}

claude_code=false
claude_desktop=false
for option in "$@"; do
    case "$option" in
        --claude-code) claude_code=true ;;
        --claude-desktop) claude_desktop=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."
dest="$HOME/Applications/Hereforth.app"
marker="Contents/Resources/hereforth-install"
if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ -L "$dest" || ! -f "$dest/$marker" ]] ||
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null)" != "com.hereforth.app" ]]; then
        printf 'An existing app at %s is owned by another installer.\n' "$dest" >&2
        exit 1
    fi
fi

swift build --configuration release
bin="$(swift build --configuration release --show-bin-path)"
mkdir -p "$HOME/Applications"
stage="$(mktemp -d "$HOME/Applications/.hereforth.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Hereforth.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 644 scripts/Info.plist "$bundle/Contents/Info.plist"
install -m 755 "$bin/HereforthApp" "$bin/hereforth" "$bundle/Contents/MacOS/"
touch "$bundle/$marker"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$bundle/Contents/MacOS/hereforth"
    codesign --force --sign - "$bundle"
    codesign --verify --deep --strict "$bundle"
fi

# A same-volume swap keeps the previous app available until its replacement is ready.
swift scripts/install-support.swift bundle "$bundle" "$dest"
printf 'Installed %s\n' "$dest"

helper="$dest/Contents/MacOS/hereforth"
status=0
if $claude_code; then
    if command -v claude >/dev/null 2>&1; then
        code_dir="${CLAUDE_CONFIG_DIR:-$HOME}"
        if ! swift scripts/install-support.swift code "$code_dir/.claude.json" "$helper" "$(command -v claude)"; then
            status=1
        fi
    else
        printf 'Claude Code registration requires claude on PATH.\n' >&2
        status=1
    fi
fi

if $claude_desktop; then
    desktop="$HOME/Library/Application Support/Claude"
    if [[ -d "$desktop" ]]; then
        if ! swift scripts/install-support.swift desktop "$desktop/claude_desktop_config.json" "$helper"; then
            status=1
        fi
    else
        printf 'Open Claude Desktop once to initialize its settings, then rerun with --claude-desktop.\n' >&2
        status=1
    fi
fi
exit "$status"
