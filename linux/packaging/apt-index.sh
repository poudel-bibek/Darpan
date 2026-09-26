#!/usr/bin/env bash
# The flat APT index for a release's .deb: Packages and a signed InRelease. Published with the .deb on
# the Pages site (scripts/publish-updates.sh), they bring installed hosts new versions through the
# system's updater.
# Usage: apt-index.sh <darpan_amd64.deb> <out-dir>   (signs with the release key in $GNUPGHOME)
set -euo pipefail
deb=$(realpath "$1")
mkdir -p "$2"
cd "$2"
rm -f InRelease darpan_*_amd64.deb
# The version in the name: a cached copy of an older .deb can't meet a newer index (Pages caches).
name=$(dpkg-deb -f "$deb" Package)_$(dpkg-deb -f "$deb" Version)_amd64.deb
cp "$deb" "$name"
apt-ftparchive packages . > Packages
release=$(mktemp)                       # outside the directory, so the index doesn't list itself
trap 'rm -f "$release"' EXIT
apt-ftparchive -o APT::FTPArchive::Release::Origin=Darpan -o APT::FTPArchive::Release::Label=Darpan \
    -o APT::FTPArchive::Release::Architectures=amd64 release . > "$release"
gpg --batch --yes --clearsign --digest-algo SHA512 -o InRelease "$release"
echo "wrote $(pwd)/{$name,Packages,InRelease}"
