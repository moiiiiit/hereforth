#!/bin/bash -p
set -euo pipefail

usage() {
    cat <<'TEXT'
Usage:
  package-macos.sh stage --version VERSION --build NUMBER --track beta|production --output /path/Hereforth.app
  package-macos.sh dmg --version VERSION --build NUMBER --track beta|production --output /path/dist
    --asset-base-url HTTPS_URL
    [--adhoc-preview | --identity "Developer ID Application: …" --notary-profile NAME
                     | --notarized-app /path/Hereforth.app [--notary-profile NAME]]
  Both modes accept --sparkle-account NAME (default: com.hereforth.release).
  Stage also accepts --public-key BASE64 for builds without a local signing key.
TEXT
}

fail() { printf 'Hereforth packaging: %s\n' "$*" >&2; exit 1; }

action="${1:-}"
if [[ "$action" == -h || "$action" == --help ]]; then usage; exit 0; fi
if [[ "$action" != stage && "$action" != dmg ]]; then usage >&2; exit 2; fi
shift
version="" build="" track="" output="" asset_base="" identity="" notary="" notarized_app="" public_key=""
account="com.hereforth.release"
adhoc=false
while [[ $# -gt 0 ]]; do
    argument="$1"
    shift
    if [[ "$argument" == --adhoc-preview ]]; then adhoc=true; continue; fi
    [[ $# -gt 0 && -n "$1" && "$1" != --* ]] || fail "$argument needs a value."
    case "$argument" in
        --version) version="$1" ;;
        --build) build="$1" ;;
        --track) track="$1" ;;
        --output) output="$1" ;;
        --asset-base-url) asset_base="$1" ;;
        --identity) identity="$1" ;;
        --notary-profile) notary="$1" ;;
        --notarized-app) notarized_app="$1" ;;
        --sparkle-account) account="$1" ;;
        --public-key) public_key="$1" ;;
        *) fail "Unknown option: $argument." ;;
    esac
    shift
done

numeric_version='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
case "$track" in
    beta)
        [[ "$version" =~ ^${numeric_version}-beta\.[1-9][0-9]*$ ]] || fail "Use a release version such as 0.2.0-beta.1 for beta."
        feed_name="appcast-beta.xml"
        ;;
    production)
        [[ "$version" =~ ^${numeric_version}$ ]] || fail "Use a stable X.Y.Z release version for production."
        feed_name="appcast.xml"
        ;;
    *) fail "Choose beta or production." ;;
esac
[[ "$build" =~ ^[1-9][0-9]{0,8}$ ]] || fail "Use a positive build number of up to nine digits."
[[ -n "$output" ]] || fail "Specify an output path."
feed="https://raw.githubusercontent.com/moiiiiit/hereforth/main/updates/$feed_name"
marketing_version="${version%%-*}"

if [[ "$action" == stage ]]; then
    [[ "$output" == *.app ]] || fail "The stage output must end in .app."
    [[ -z "$identity$notary$notarized_app$asset_base" ]] && ! $adhoc || fail "Stage only builds an app for local testing or later Developer ID signing."
    [[ ! -e "$output" && ! -L "$output" ]] || fail "The staged app output already exists."
else
    [[ "$asset_base" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]+)?$ ]] || fail "Use an HTTPS asset base URL without query parameters."
    [[ -z "$public_key" ]] || fail "Disk images use the public key of the selected Sparkle Keychain account."
    if $adhoc; then
        [[ "$track" == beta && -z "$identity$notary$notarized_app" ]] ||
            fail "Ad-hoc previews are beta-only and must be explicitly requested."
    elif [[ -n "$notarized_app" ]]; then
        [[ -z "$identity" || "$identity" == 'Developer ID Application: '* ]] ||
            fail "Use a Developer ID Application identity for the disk image."
    else
        [[ "$identity" == 'Developer ID Application: '* && -n "$notary" ]] ||
            fail "A release needs a Developer ID Application identity and notary profile, or an already-notarized app."
    fi
fi

case "$output" in /*) ;; *) output="$PWD/$output" ;; esac
case "$notarized_app" in ''|/*) ;; *) notarized_app="$PWD/$notarized_app" ;; esac
cd "$(dirname "$0")/.."
stage=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf -- "$stage"' EXIT
trap 'exit 1' HUP INT TERM
scratch="$PWD/.build/macos-package"
sparkle="$scratch/artifacts/hereforth/Sparkle"
swiftpm() { HEREFORTH_BINARY_UPDATER=1 /usr/bin/swift "$@"; }
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }
plist_set() { /usr/libexec/PlistBuddy -c "Add :$2 $3 $4" "$1"; }

if [[ -z "$notarized_app" ]]; then
    swiftpm build --scratch-path "$scratch" --configuration release --arch arm64
    products="$(swiftpm build --scratch-path "$scratch" --configuration release --arch arm64 --show-bin-path)"
else
    swiftpm package --scratch-path "$scratch" resolve
fi
framework="$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
tools="$sparkle/bin"
[[ -x "$tools/generate_keys" && -x "$tools/sign_update" ]] || fail "The pinned Sparkle distribution is missing."
if [[ -z "$public_key" ]]; then
    public_key=$("$tools/generate_keys" --account "$account" -p) ||
        fail "The Sparkle Keychain account is unavailable. Generate the dedicated release key first."
fi
[[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "The Sparkle public key must be a 32-byte base64 value."

verify_architecture() {
    local arches
    arches=$(/usr/bin/lipo -archs "$1") || fail "Not a Mach-O binary: $1."
    if [[ "${2:-}" == framework ]]; then
        [[ " $arches " == *' arm64 '* ]] || fail "Missing arm64: $1."
    else
        [[ "$arches" == arm64 ]] || fail "Expected only arm64: $1."
    fi
}

sign() {
    local path="$1"
    shift
    if [[ -n "$identity" ]]; then
        /usr/bin/codesign --force --sign "$identity" --timestamp --options runtime "$@" "$path"
    elif [[ "$action" == stage ]]; then
        /usr/bin/codesign --force --sign - --options runtime "$@" "$path"
    else
        /usr/bin/codesign --force --sign - "$@" "$path"
    fi
}

remove_build_rpaths() {
    local binary="$1" rpath
    while IFS= read -r rpath; do
        case "$rpath" in
            /usr/lib/swift|/System/Library/*) ;;
            /*) /usr/bin/install_name_tool -delete_rpath "$rpath" "$binary" ;;
        esac
    done < <(/usr/bin/otool -l "$binary" | /usr/bin/sed -n 's/^[[:space:]]*path \(.*\) (offset [0-9]*)$/\1/p' | /usr/bin/sort -u)
}

build_app() {
    local app="$1" contents="$1/Contents" size plist fw
    verify_architecture "$products/HereforthApp"
    verify_architecture "$products/hereforth"
    [[ -L "$framework/Versions/Current" ]] || fail "The Sparkle framework is missing its version symlink."
    [[ "$(plist_get "$framework/Resources/Info.plist" CFBundleShortVersionString)" == 2.10.1 ]] ||
        fail "Expected the pinned Sparkle 2.10.1 runtime."
    mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Frameworks"
    install -m 644 scripts/Info.plist "$contents/Info.plist"
    install -m 755 "$products/HereforthApp" "$products/hereforth" "$contents/MacOS/"
    remove_build_rpaths "$contents/MacOS/HereforthApp"
    remove_build_rpaths "$contents/MacOS/hereforth"
    /usr/bin/ditto "$products/Hereforth_HereforthCore.bundle" "$contents/Resources/Hereforth_HereforthCore.bundle"
    /usr/bin/ditto "$framework" "$contents/Frameworks/Sparkle.framework"
    if [[ -f "$sparkle/LICENSE" ]]; then install -m 644 "$sparkle/LICENSE" "$contents/Resources/Sparkle-LICENSE"; fi
    touch "$contents/Resources/hereforth-install"
    mkdir "$stage/Hereforth.iconset"
    for size in 16 32 128 256 512; do
        /usr/bin/sips -z "$size" "$size" Assets/Hereforth.png --out "$stage/Hereforth.iconset/icon_${size}x${size}.png" >/dev/null
        /usr/bin/sips -z "$((size * 2))" "$((size * 2))" Assets/Hereforth.png --out "$stage/Hereforth.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    /usr/bin/iconutil -c icns "$stage/Hereforth.iconset" -o "$contents/Resources/Hereforth.icns"

    plist="$contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing_version" -c "Set :CFBundleVersion $build" \
        -c "Set :HereforthUpdateChannel binary" "$plist"
    plist_set "$plist" HereforthReleaseVersion string "$version"
    plist_set "$plist" HereforthBinaryUpdateTrack string "$track"
    plist_set "$plist" SUPublicEDKey string "$public_key"
    plist_set "$plist" SUFeedURL string "$feed"
    plist_set "$plist" SUEnableAutomaticChecks bool true
    plist_set "$plist" SUAutomaticallyUpdate bool true
    plist_set "$plist" SUAllowsAutomaticUpdates bool true
    plist_set "$plist" SUVerifyUpdateBeforeExtraction bool true
    plist_set "$plist" SUEnableSystemProfiling bool false

    if [[ -n "$identity" || "$action" == stage ]]; then
        fw="$contents/Frameworks/Sparkle.framework"
        sign "$fw/Versions/Current/Autoupdate" --preserve-metadata=identifier,entitlements
        sign "$fw/Versions/Current/Updater.app" --preserve-metadata=identifier,entitlements
        sign "$fw/Versions/Current/XPCServices/Downloader.xpc" --preserve-metadata=identifier,entitlements
        sign "$fw/Versions/Current/XPCServices/Installer.xpc" --preserve-metadata=identifier,entitlements
        sign "$fw" --preserve-metadata=identifier,entitlements
    fi
    sign "$contents/MacOS/hereforth"
    sign "$app"
}

verify_app() {
    local app="$1" plist="$1/Contents/Info.plist" fw libs rpath
    [[ "$(plist_get "$plist" CFBundleIdentifier)" == com.hereforth.app &&
        "$(plist_get "$plist" CFBundleShortVersionString)" == "$marketing_version" &&
        "$(plist_get "$plist" CFBundleVersion)" == "$build" &&
        "$(plist_get "$plist" HereforthReleaseVersion)" == "$version" &&
        "$(plist_get "$plist" HereforthUpdateChannel)" == binary &&
        "$(plist_get "$plist" HereforthBinaryUpdateTrack)" == "$track" &&
        "$(plist_get "$plist" SUPublicEDKey)" == "$public_key" &&
        "$(plist_get "$plist" SUFeedURL)" == "$feed" ]] || fail "The app version, build, update track, or signing key does not match."
    [[ -f "$app/Contents/Resources/Hereforth_HereforthCore.bundle/Contents/Resources/Humanizer/SKILL.md" ]] ||
        fail "The SwiftPM resources are missing."
    fw="$app/Contents/Frameworks/Sparkle.framework"
    verify_architecture "$app/Contents/MacOS/HereforthApp"
    verify_architecture "$app/Contents/MacOS/hereforth"
    verify_architecture "$fw/Sparkle" framework
    verify_architecture "$fw/Versions/Current/Autoupdate" framework
    verify_architecture "$fw/Versions/Current/Updater.app/Contents/MacOS/Updater" framework
    verify_architecture "$fw/Versions/Current/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" framework
    verify_architecture "$fw/Versions/Current/XPCServices/Installer.xpc/Contents/MacOS/Installer" framework
    libs=$(/usr/bin/otool -arch arm64 -L "$app/Contents/MacOS/HereforthApp")
    rpath=$(/usr/bin/otool -arch arm64 -l "$app/Contents/MacOS/HereforthApp")
    [[ "$libs" == *'@rpath/Sparkle.framework/'* &&
        "$rpath" == *'path @executable_path/../Frameworks '* ]] || fail "Invalid Sparkle runtime search path for arm64."
    /usr/bin/codesign --verify --deep --strict --all-architectures "$app"
}

verify_notarized_app() {
    local app="$1" description leaf
    local fw="$app/Contents/Frameworks/Sparkle.framework"
    local hardened='flags=0x[[:xdigit:]]+\([^)]*runtime[^)]*\)'
    for leaf in "$app" "$app/Contents/MacOS/hereforth" "$fw" "$fw/Versions/Current/Autoupdate" \
        "$fw/Versions/Current/Updater.app" "$fw/Versions/Current/XPCServices/Downloader.xpc" \
        "$fw/Versions/Current/XPCServices/Installer.xpc"; do
        description=$(/usr/bin/codesign -dv --verbose=4 "$leaf" 2>&1)
        [[ "$description" == *'Authority=Developer ID Application: '* &&
            "$description" == *'Timestamp='* && "$description" =~ $hardened ]] ||
            fail "Developer ID + Hardened Runtime verification failed for $leaf."
    done
    /usr/bin/xcrun stapler validate "$app"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
}

notarize() {
    local archive="$1" target="$2"
    /usr/bin/xcrun notarytool submit "$archive" --keychain-profile "$notary" --wait --output-format json > "$stage/notary.json"
    [[ "$(/usr/bin/plutil -extract status raw "$stage/notary.json")" == Accepted ]] || fail "Apple did not accept the notarization submission."
    /usr/bin/xcrun stapler staple "$target"
    /usr/bin/xcrun stapler validate "$target"
}

if [[ "$action" == stage ]]; then
    built="$stage/Hereforth.app"
    build_app "$built"
    verify_app "$built"
    mkdir -p "$(dirname "$output")"
    [[ ! -e "$output" && ! -L "$output" ]] || fail "The staged app output appeared during the build."
    /usr/bin/ditto "$built" "$output"
    verify_app "$output"
    printf 'Staged Apple silicon app at %s\n' "$output"
    exit 0
fi

volume_name="Hereforth"
dmg_name="Hereforth-$version.dmg"
if [[ "$track" == production ]]; then dmg_name="Hereforth.dmg"; fi
if $adhoc; then
    volume_name="Hereforth Preview"
    dmg_name="Hereforth-$version-preview.dmg"
fi
dmg="$stage/$dmg_name"
if [[ -e "$output/$dmg_name" || -L "$output/$dmg_name" || -e "$output/$feed_name" || -L "$output/$feed_name" ]]; then
    fail "A release output file already exists."
fi
volume="$stage/volume"
mkdir "$volume"
built="$volume/Hereforth.app"
/bin/ln -s /Applications "$volume/Applications"
if [[ -n "$notarized_app" ]]; then
    verify_app "$notarized_app"
    verify_notarized_app "$notarized_app"
    /usr/bin/ditto "$notarized_app" "$built"
else
    build_app "$built"
    if ! $adhoc; then
        /usr/bin/ditto -c -k --keepParent "$built" "$stage/Hereforth.zip"
        notarize "$stage/Hereforth.zip" "$built"
    fi
fi
verify_app "$built"
if ! $adhoc; then verify_notarized_app "$built"; fi
/usr/bin/hdiutil create -volname "$volume_name" -fs HFS+ -format UDRW -srcfolder "$volume" "$stage/volume.dmg"
/usr/bin/hdiutil convert "$stage/volume.dmg" -format UDZO -o "$dmg"
if [[ -n "$identity" ]]; then
    /usr/bin/codesign --sign "$identity" --timestamp "$dmg"
fi
if [[ -n "$notary" ]]; then
    notarize "$dmg" "$dmg"
elif ! $adhoc; then
    printf 'The app has a stapled Apple ticket. The disk image has no separate notarization ticket.\n'
fi
/usr/bin/hdiutil verify "$dmg"
mount_path="$stage/mounted"
mkdir "$mount_path"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_path" "$dmg" >/dev/null
trap '/usr/bin/hdiutil detach "$mount_path" >/dev/null 2>&1 || true; /bin/rm -rf -- "$stage"' EXIT
[[ "$(/usr/bin/readlink "$mount_path/Applications")" == /Applications ]] || fail "The disk image is missing the Applications shortcut."
verify_app "$mount_path/Hereforth.app"
if ! $adhoc; then verify_notarized_app "$mount_path/Hereforth.app"; fi
/usr/bin/hdiutil detach "$mount_path" >/dev/null
trap '/bin/rm -rf -- "$stage"' EXIT

signature=$("$tools/sign_update" --account "$account" -p "$dmg")
[[ "$signature" =~ ^[A-Za-z0-9+/]{86}==$ ]] || fail "Sparkle returned an invalid enclosure signature."
"$tools/sign_update" --account "$account" --verify "$dmg" "$signature" >/dev/null
size=$(/usr/bin/stat -f '%z' "$dmg")
asset_url="${asset_base%/}/$dmg_name"
cat > "$stage/$feed_name" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Hereforth Updates</title>
    <item>
      <title>Hereforth $version</title>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$asset_url" sparkle:edSignature="$signature" length="$size" type="application/x-apple-diskimage" />
    </item>
  </channel>
</rss>
XML
mkdir -p "$output"
/bin/mv -n "$dmg" "$output/$dmg_name"
/bin/mv -n "$stage/$feed_name" "$output/$feed_name"
[[ ! -e "$dmg" && ! -e "$stage/$feed_name" ]] || fail "A release output file appeared while packaging."
printf 'Packaged %s and %s\n' "$output/$dmg_name" "$output/$feed_name"
