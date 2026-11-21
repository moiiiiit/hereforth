#!/bin/bash -p
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C

fail() {
    printf 'Hereforth: %s\n' "$1" >&2
    exit 1
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

stable_version() {
    [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

newer() {
    local lhs rhs i
    IFS=. read -r -a lhs <<< "$1"
    IFS=. read -r -a rhs <<< "$2"
    for i in 0 1 2; do
        (( ${#lhs[i]} > ${#rhs[i]} )) && return 0
        (( ${#lhs[i]} < ${#rhs[i]} )) && return 1
        [[ ${lhs[i]} > ${rhs[i]} ]] && return 0
        [[ ${lhs[i]} < ${rhs[i]} ]] && return 1
    done
    return 1
}

automatic_enabled() {
    local plist=$1 preference=$2
    [[ $(plist_value "$plist" HereforthUpdateChannel) == stable && -f $preference && ! -L $preference ]] &&
        /usr/bin/cmp -s "$preference" <(printf 'enabled\n')
}

git_release() {
    /usr/bin/env -i PATH=/usr/bin:/bin HOME="$profile_home" LC_ALL=C GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
        /usr/bin/git -c protocol.allow=never -c protocol.https.allow=always \
        -c http.followRedirects=false -c core.hooksPath=/dev/null "$@"
}

owned_bundle() {
    local app=$1
    [[ -d $app && ! -L $app && -f $app/Contents/Resources/hereforth-install && ! -L $app/Contents/Resources/hereforth-install &&
        $(plist_value "$app/Contents/Info.plist" CFBundleIdentifier) == com.hereforth.app ]]
}

update_locked() {
    local mode=$1 profile_home=$2 dest=$3 signers=$4
    local remote='https://github.com/moiiiiit/hereforth.git'
    local plist="$dest/Contents/Info.plist" preference="$profile_home/Library/Application Support/Hereforth/automatic-updates"
    owned_bundle "$dest" || fail 'Install Hereforth in your Applications folder before checking for updates.'
    local current
    current=$(plist_value "$plist" CFBundleShortVersionString) || fail 'The installed app has no version.'
    stable_version "$current" || fail 'The installed version is not a stable release version.'
    if [[ $mode == automatic ]] && ! automatic_enabled "$plist" "$preference"; then return 0; fi

    [[ -f $signers && ! -L $signers && -s $signers ]] || fail 'The installed bundle is missing its pinned release signer.'
    umask 077
    work=$(/usr/bin/mktemp -d "${dest%/*}/.hereforth-update.XXXXXX") || fail 'Could not create a temporary update folder.'
    trap '/bin/rm -rf -- "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    local checkout="$work/source" pins="$work/release-signers"
    /bin/mkdir "$checkout" "$work/stage"
    /bin/cp "$signers" "$pins"

    git_release ls-remote --tags --refs "$remote" > "$work/refs" || fail 'Could not check the canonical release repository.'
    local oid ref selected='' version='' candidate
    while IFS=$'\t' read -r oid ref; do
        [[ $oid =~ ^[0-9a-f]{40}$ && $ref == refs/tags/v* ]] || continue
        candidate=${ref#refs/tags/v}
        stable_version "$candidate" || continue
        if [[ -z $version ]] || newer "$candidate" "$version"; then
            version=$candidate
            selected=$oid
        fi
    done < "$work/refs"

    if [[ -z $version ]] || ! newer "$version" "$current"; then
        printf 'current %s\n' "$current"
        return 0
    fi

    local tag="v$version" fetched object_line type_line tag_line commit
    git_release -C "$checkout" init --quiet
    git_release -C "$checkout" fetch --quiet --no-tags --depth=1 "$remote" "refs/tags/$tag:refs/tags/$tag" ||
        fail 'Could not fetch the selected release tag.'
    fetched=$(git_release -C "$checkout" rev-parse --verify "refs/tags/$tag") || fail 'The selected release tag is missing.'
    [[ $fetched == "$selected" ]] || fail 'The release tag changed while it was being fetched.'
    [[ $(git_release -C "$checkout" cat-file -t "$fetched") == tag ]] || fail 'The release is missing an annotated tag.'
    git_release -C "$checkout" cat-file tag "$fetched" > "$work/tag"
    {
        IFS= read -r object_line
        IFS= read -r type_line
        IFS= read -r tag_line
    } < "$work/tag"
    [[ $object_line =~ ^object\ [0-9a-f]{40}$ && $type_line == 'type commit' && $tag_line == "tag $tag" ]] ||
        fail 'The signed tag does not name the selected release commit.'
    commit=${object_line#object }
    [[ $(git_release -C "$checkout" cat-file -t "$commit") == commit ]] || fail 'The selected release commit is missing.'
    /usr/bin/grep -qxF -- '-----BEGIN SSH SIGNATURE-----' "$work/tag" || fail 'The release tag has no SSH signature.'
    git_release -C "$checkout" -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$pins" \
        -c gpg.ssh.program=/usr/bin/ssh-keygen -c gpg.openpgp.program=/usr/bin/false -c gpg.x509.program=/usr/bin/false \
        verify-tag "$fetched" >/dev/null 2>&1 ||
        fail 'The release tag signature did not match the installed release signer.'

    if [[ $mode == check ]]; then
        printf 'available %s\n' "$version"
        return 0
    fi

    git_release -C "$checkout" checkout --quiet --detach "$commit"
    local installer="$checkout/scripts/install.sh" swap="$checkout/scripts/install-support.swift" staged="$work/stage/Hereforth.app"
    [[ -f $installer && ! -L $installer && -f $swap && ! -L $swap ]] ||
        fail 'The verified release is missing its installer.'
    /usr/bin/env -i PATH="$PATH" HOME="$profile_home" LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        /bin/bash -p "$installer" --stage-app "$staged" >&2 ||
        fail 'Building the update failed. The installed app was left unchanged.'

    owned_bundle "$staged" && [[ $(plist_value "$staged/Contents/Info.plist" CFBundleShortVersionString) == "$version" &&
        $(plist_value "$staged/Contents/Info.plist" HereforthUpdateChannel) == stable &&
        -x $staged/Contents/Resources/update.sh && ! -L $staged/Contents/Resources/update.sh &&
        -s $staged/Contents/Resources/release-signers && ! -L $staged/Contents/Resources/release-signers ]] ||
        fail 'The staged app did not match the verified release.'
    /usr/bin/codesign --verify --deep --strict "$staged" >/dev/null 2>&1 ||
        fail 'The staged app did not pass its code-signature check.'

    owned_bundle "$dest" && [[ $(plist_value "$plist" CFBundleShortVersionString) == "$current" ]] &&
        /usr/bin/cmp -s "$pins" "$signers" || fail 'The installed app changed during the check. Run the update again.'
    if [[ $mode == automatic ]] && ! automatic_enabled "$plist" "$preference"; then return 0; fi
    /usr/bin/env -i PATH="$PATH" HOME="$profile_home" LC_ALL=C /usr/bin/swift "$swap" bundle "$staged" "$dest" >&2 ||
        fail 'Could not replace the installed app.'
    printf 'installed %s\n' "$version"
}

[[ $# == 1 ]] || fail 'Usage: update.sh check | install | automatic'
case $1 in
    check|install|automatic) ;;
    *) fail 'Usage: update.sh check | install | automatic' ;;
esac
[[ $EUID != 0 ]] || fail 'Run updates as the user who installed Hereforth.'
profile_home=$(cd -P -- "${HOME:?}" && pwd -P)
apps="$profile_home/Applications"
dest="$apps/Hereforth.app"
resources=$(cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
[[ ! -L $apps && ! -L $dest && $resources == "$dest/Contents/Resources" ]] ||
    fail 'Open the updater bundled with Hereforth in your Applications folder.'
lock="$apps/.hereforth-update.lock"
[[ ! -L $lock && ( ! -e $lock || -f $lock ) ]] || fail 'The update lock is not a regular file.'
umask 077

# Run under the OS lock without importing shell functions or a startup script from the environment.
worker="$(declare -f fail plist_value stable_version newer automatic_enabled git_release owned_bundle update_locked)"
exec /usr/bin/lockf -k -t 0 "$lock" /bin/bash -p -c "$worker"$'\n''set -euo pipefail; update_locked "$@"' \
    hereforth-update "$1" "$profile_home" "$dest" "$resources/release-signers"
