#!/usr/bin/env bash
# Increment the Arch package release number (pkgrel) without changing pkgver.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/buildnumber.sh [--add | --reset]

Show the current PKGBUILD pkgrel and offer to increment it. Use --add to
increment it without prompting. Use --reset to set it to 1 without prompting.
EOF
}

case "${1:-}" in
    "") action=increment; automatic=false ;;
    --add) action=increment; automatic=true ;;
    --reset) action=reset; automatic=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

if (($# > 1)); then
    usage >&2
    exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
pkgbuild="$script_dir/../PKGBUILD"
current=$(sed -n 's/^pkgrel=\([0-9][0-9]*\)$/\1/p' "$pkgbuild")

if [[ $(printf '%s\n' "$current" | wc -l) -ne 1 || ! $current =~ ^[0-9]+$ ]]; then
    printf 'ERROR: expected exactly one numeric pkgrel= line in %s\n' "$pkgbuild" >&2
    exit 1
fi

if [[ $action == reset ]]; then
    next=1
    action_text="Reset package release to"
else
    next=$((current + 1))
    action_text="Increase package release to"
fi
printf 'Current package release: %s\n' "$current"

if [[ $automatic != true ]]; then
    read -r -p "$action_text $next? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) printf 'Package release unchanged.\n'; exit 0 ;;
    esac
fi

sed -i "s/^pkgrel=$current$/pkgrel=$next/" "$pkgbuild"
printf 'Updated PKGBUILD pkgrel: %s -> %s\n' "$current" "$next"
