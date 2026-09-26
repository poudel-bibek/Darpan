#!/usr/bin/env bash
# Fails if tracked or new (untracked, not ignored) files, or with --history commit metadata, contain
# personal data. New files count so a board message or source file is caught before it is committed.
# Generic patterns: e-mail addresses, IPv4 addresses, home-directory paths, tailnet host names.
# Personal terms (names, accounts, machine names…) go in .private-denylist (untracked, one
# case-insensitive fixed string per line, # comments) so the list itself is never committed.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
deny=.private-denylist
found=0
report() { echo "$1"; found=1; }

# NUL-separated, so a file name with spaces stays one argument (never silently skipped)
mapfile -d '' files < <({ git ls-files -z; git ls-files -z --others --exclude-standard; } \
  | grep -zvE '^linux/native/third_party/|\.(png|jpg|ico|icns|a|so)$')
[ ${#files[@]} -gt 0 ] || { echo "clean: nothing to check"; exit 0; }
# e-mail addresses, except placeholders and GitHub no-reply addresses
while IFS= read -r m; do report "email      $m"; done < <(grep -nIoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -- "${files[@]}" \
  | grep -vE '@(darpan\.invalid|example\.(com|org)|users\.noreply\.github\.com)$')
# IPv4 addresses, except loopback/any, CGNAT range constant and documentation ranges
while IFS= read -r m; do report "ip         $m"; done < <(grep -nIoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' -- "${files[@]}" \
  | grep -vE ':(127\.0\.0\.1|0\.0\.0\.0|100\.64\.0\.0|192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|203\.0\.113\.[0-9]+)$')
# home directories and real tailnet names
while IFS= read -r m; do report "path       $m"; done < <(grep -nIoE '/(home|Users)/[A-Za-z][A-Za-z0-9._-]+' -- "${files[@]}")
while IFS= read -r m; do report "tailnet    $m"; done < <(grep -nIoE '[A-Za-z0-9-]+\.tail[0-9a-f]{4,}\.ts\.net' -- "${files[@]}")
# personal terms from the local denylist
if [ -f "$deny" ]; then
  while IFS= read -r m; do report "denylist   $m"; done < <(grep -v '^\s*#' "$deny" | grep -v '^\s*$' | grep -nIiFf - -- "${files[@]}")
else
  echo "note: no $deny — only generic patterns were checked" >&2
fi
if [ "${1:-}" = --history ]; then
  while IFS= read -r m; do report "commit     $m"; done < <(git log --all --format='%h %an <%ae> %s' \
    | grep -vE '<[^>]*@users\.noreply\.github\.com>')
  [ -f "$deny" ] && while IFS= read -r m; do report "commit     $m"; done < <(git log --all --format='%h %B' \
    | grep -v '^\s*#' | grep -iFf <(grep -v '^\s*#' "$deny" | grep -v '^\s*$'))
fi
[ $found = 0 ] && echo "clean: no personal data found"
exit $found
