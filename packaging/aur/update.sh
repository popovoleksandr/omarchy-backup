#!/usr/bin/env bash
# Prepares the AUR files for a release that is already tagged on GitHub:
# sets pkgver, resets pkgrel, fills in the tarball checksum, regenerates
# .SRCINFO, and test-builds the package from the GitHub tarball.
#
# Usage: packaging/aur/update.sh <version>     (e.g. 1.0.0 for tag v1.0.0)

set -euo pipefail

version=${1:?usage: packaging/aur/update.sh <version>}
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$dir"

sed -i -e "s/^pkgver=.*/pkgver=$version/" -e "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
updpkgsums
makepkg --printsrcinfo >.SRCINFO

build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
cp PKGBUILD omarchy-backup.install "$build/"
(cd "$build" && makepkg -f --noconfirm >/dev/null && tar -tf ./*.pkg.tar.zst | grep -v '/$' | grep -v '^\.')

echo
echo "PKGBUILD and .SRCINFO are ready for $version. Publish them with:"
echo "  $dir/publish.sh"
