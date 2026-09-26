#!/usr/bin/env bash
# The flat APT index a release carries next to its .deb: Packages and a signed InRelease. With these
# three files in the latest release, installed hosts get new versions from the system's updater.
# Usage: apt-index.sh <darpan_amd64.deb> <out-dir>   (signs with the release key in $GNUPGHOME)
set -euo pipefail
deb=$(realpath "$1")
mkdir -p "$2"
cd "$2"
rm -f InRelease Packages ./*.deb          # only this release's .deb gets indexed
cp "$deb" darpan_amd64.deb
apt-ftparchive packages . > Packages
release=$(mktemp)                       # outside the directory, so the index doesn't list itself
trap 'rm -f "$release"' EXIT
apt-ftparchive -o APT::FTPArchive::Release::Origin=Darpan -o APT::FTPArchive::Release::Label=Darpan \
    -o APT::FTPArchive::Release::Architectures=amd64 release . > "$release"
gpg --batch --yes --clearsign --digest-algo SHA512 -o InRelease "$release"
echo "wrote $(pwd)/{darpan_amd64.deb,Packages,InRelease}"
