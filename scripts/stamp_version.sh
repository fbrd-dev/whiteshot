#!/bin/bash
# The version of WhiteShot is the newest version tag in git (v1.2.0 -> 1.2.0), so the tag is the only place the number is kept.
#
#   stamp_version.sh <path to a built Info.plist>   writes the version into the plist (Xcode runs this after every build)
#   stamp_version.sh --print                        prints the version, or nothing if there is no version tag
#
# With no version tag (a fresh clone, an archive without git) the plist keeps its placeholder version, 0.0.0.
set -eu
cd "$(dirname "$0")/.."
tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [ "${1:-}" = "--print" ]; then
  if [ -n "$tag" ]; then echo "${tag#v}"; fi
  exit 0
fi
plist="$1"
if [ -z "$tag" ]; then
  echo "stamp_version: no version tag found; keeping the placeholder version"
  exit 0
fi
version="${tag#v}"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$version" "$plist"
echo "stamp_version: $version (from tag $tag)"
