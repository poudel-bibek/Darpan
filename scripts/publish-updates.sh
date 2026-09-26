#!/usr/bin/env bash
# Puts a release's update files on the repository's GitHub Pages site, https://<owner>.github.io/<repo>/.
#   apt/  darpan_<version>_amd64.deb, Packages and InRelease (from linux/packaging/apt-index.sh):
#         installed hosts update from here through APT, which needs the .deb next to its index.
#   mac/  darpan-mac.json and darpan-mac.json.sig (from scripts/mac-manifest.sh): the Mac app's updater.
# The `pages` branch is one commit holding just these, replaced each time: its history isn't needed,
# and each .deb would otherwise stay in it for good. The signatures make the files safe; Pages only
# carries them.
# Usage: scripts/publish-updates.sh <apt-index dir> <mac-manifest dir>
set -euo pipefail
apt=$1 mac=$2
debs=("$apt"/darpan_*_amd64.deb)
[[ ${#debs[@]} == 1 && -s ${debs[0]} ]] || { echo "want exactly one darpan_<version>_amd64.deb in $apt"; exit 1; }
deb=${debs[0]}
for f in "$apt"/{Packages,InRelease} "$mac"/darpan-mac.json{,.sig}; do
    [[ -s $f ]] || { echo "missing $f"; exit 1; }
done
# The commit is public: a neutral name and the GitHub no-reply address, never a personal identity.
email=$(git config user.email || true)
[[ $email == *@users.noreply.github.com ]] || { echo "set git's user.email to your GitHub no-reply address first"; exit 1; }
export GIT_AUTHOR_NAME=Darpan GIT_COMMITTER_NAME=Darpan GIT_AUTHOR_EMAIL=$email GIT_COMMITTER_EMAIL=$email
blob() { git hash-object -w "$1"; }
apt_tree=$(printf '100644 blob %s\t%s\n' "$(blob "$deb")" "$(basename "$deb")" \
    "$(blob "$apt/Packages")" Packages "$(blob "$apt/InRelease")" InRelease | git mktree)
mac_tree=$(printf '100644 blob %s\t%s\n' "$(blob "$mac/darpan-mac.json")" darpan-mac.json \
    "$(blob "$mac/darpan-mac.json.sig")" darpan-mac.json.sig | git mktree)
root=$(printf '100644 blob %s\t.nojekyll\n040000 tree %s\tapt\n040000 tree %s\tmac\n' \
    "$(git hash-object -w --stdin </dev/null)" "$apt_tree" "$mac_tree" | git mktree)   # .nojekyll: files as they are
version=$(sed -n 's/^Version: //p' "$apt/Packages")
commit=$(git commit-tree "$root" -m "Update files for Darpan $version")
git push --force origin "$commit:refs/heads/pages"
echo "published $version: $(git ls-tree -r --name-only "$commit" | tr '\n' ' ')"
