#!/usr/bin/env sh
# Update the project's current-version declarations without rewriting release
# history in CHANGELOG.md or archived project prompts.
set -eu

usage() {
  printf '%s\n' "Usage: $0 OLD_VERSION NEW_VERSION" >&2
  exit 64
}

[ "$#" -eq 2 ] || usage
old_version=$1
new_version=$2

valid_version() {
  case $1 in
    *[!0-9.]* | .* | *.) return 1 ;;
  esac
  previous_ifs=$IFS
  IFS=.
  set -- $1
  IFS=$previous_ifs
  [ "$#" -eq 3 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ]
}

valid_version "$old_version" || usage
valid_version "$new_version" || usage

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repo_root"

# Keep this list explicit: a release number in changelog entries or historical
# design notes is not a current-version declaration and must not be rewritten.
version_files='
AGENTS.md
PKGBUILD
build.zig.zon
src/common.zig
packaging/keadb-leaselinkd-sync
packaging/provision-opnsense-leaselinkd.php
tests/integration.sh
'

changed=0
for file in $version_files; do
  [ -f "$file" ] || {
    printf 'missing version file: %s\n' "$file" >&2
    exit 1
  }
  if grep -F -q -- "$old_version" "$file"; then
    OLD_VERSION=$old_version NEW_VERSION=$new_version perl -pi -e 's/\Q$ENV{OLD_VERSION}\E/$ENV{NEW_VERSION}/g' "$file"
    printf 'updated %s\n' "$file"
    changed=$((changed + 1))
  fi
done

if rg -n -F -- "$old_version" $version_files; then
  printf 'old version remains in a current-version file\n' >&2
  exit 1
fi

if [ "$changed" -eq 0 ]; then
  printf 'no current-version declarations contained %s\n' "$old_version" >&2
  exit 1
fi

printf 'version changed: %s -> %s (%s files)\n' "$old_version" "$new_version" "$changed"
