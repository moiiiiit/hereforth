#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s [--claude-code] [--claude-desktop] [--codex]\n' "${0##*/}"
}

for option in "$@"; do
    case "$option" in
        --claude-code|--claude-desktop|--codex) ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [[ "$(/usr/bin/uname -s)" != Darwin ]] || ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    printf 'Hereforth needs macOS and the Apple Command Line Tools. Run xcode-select --install, then retry.\n' >&2
    exit 1
fi
macos_version="$(/usr/bin/sw_vers -productVersion)"
if (( ${macos_version%%.*} < 14 )); then
    printf 'Hereforth requires macOS 14 or later.\n' >&2
    exit 1
fi

origin='https://github.com/moiiiiit/hereforth.git'
allowed_signer='hereforth-release namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG0Hk2hgAJAUfAkv/DjUy911+oeMlHYvd12veD2jtSSt hereforth-release'
stage="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hereforth-install.XXXXXX")"
trap '/bin/rm -rf -- "$stage"' EXIT
source="$stage/source"
signers="$stage/allowed-signers"
printf '%s\n' "$allowed_signer" > "$signers"

# The verification step must not inherit URL rewrites, trust settings, or Git hooks.
trusted_git() {
    /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        GIT_TERMINAL_PROMPT=0 /usr/bin/git -c http.followRedirects=false \
        -c protocol.allow=never -c protocol.https.allow=always "$@"
}

abort() {
    printf '%s\n' "$1" >&2
    exit 1
}

candidate="$(trusted_git ls-remote --tags --refs "$origin" \
    | /usr/bin/awk '$2 ~ /^refs\/tags\/v(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$/ { print substr($2, 12), $1 }' \
    | LC_ALL=C /usr/bin/sort -t . -k1,1n -k2,2n -k3,3n \
    | /usr/bin/tail -n 1)"
[[ -n "$candidate" ]] || abort 'No stable Hereforth release tag was found.'
IFS=' ' read -r version oid <<< "$candidate"
[[ "$oid" =~ ^[0-9a-f]{40}$ ]] || abort 'The advertised release object ID was invalid.'
tag="v$version"
ref="refs/tags/$tag"

trusted_git init --quiet --template= "$source"
trusted_git -C "$source" remote add origin "$origin"
trusted_git -C "$source" fetch --quiet --depth=1 --no-tags origin "$ref:$ref"
[[ "$(trusted_git -C "$source" rev-parse --verify "$ref")" == "$oid" ]] \
    || abort 'The stable release tag changed during download.'
[[ "$(trusted_git -C "$source" cat-file -t "$oid")" == tag ]] \
    || abort "Hereforth $tag is not an annotated release tag."

tag_text="$(trusted_git -C "$source" cat-file tag "$oid")"
[[ "$(/usr/bin/sed -n '2p' <<< "$tag_text")" == 'type commit' &&
   "$(/usr/bin/sed -n '3p' <<< "$tag_text")" == "tag $tag" ]] \
    || abort 'The signed tag does not match the advertised release name and type.'
/usr/bin/grep -q '^-----BEGIN SSH SIGNATURE-----$' <<< "$tag_text" \
    || abort "Hereforth $tag has no SSH release signature."
trusted_git -C "$source" -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$signers" \
    -c gpg.ssh.program=/usr/bin/ssh-keygen verify-tag "$oid" \
    || abort "Hereforth $tag did not verify against the pinned release signer."

commit="$(trusted_git -C "$source" rev-parse --verify "$oid^{commit}")"
trusted_git -C "$source" show "$commit:scripts/release-signers" > "$stage/tagged-signers"
if ! /usr/bin/cmp -s "$signers" "$stage/tagged-signers"; then
    abort 'The release signer in the signed source does not match the bootstrap signer.'
fi

trusted_git -C "$source" checkout --quiet --detach "$commit"
printf 'Verified Hereforth %s. Building it for this Mac.\n' "$tag"
cd "$source"
./scripts/install.sh "$@"
