#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-fix-owner-modes.sh - DESTRUCTIVE end-to-end test of what fix-owner does to the
#  modes of an upload: root puts a tree into a site the way WinSCP with "set permissions
#  777" does (777 directories, 666 files), and fix-owner - the command, menu item 21 and the
#  minute check alike - hands it to the site's user AND takes write away from group and
#  others (777 -> 755, 666 -> 644), as the site's user, through the real runuser.
#
#  Checked: the modes and owners afterwards, the page OpenLiteSpeed serves from the upload,
#  that a file a link leads to outside the site and the site's log directory keep their
#  modes, a dry run that changes nothing, the Turkish line, menu item 21 for one site, and
#  one pass of the minute check (htaccess-check) on a fresh upload.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It adds and removes a real site (a name under
#  .invalid) and switches the automatic hand-over off and on again (put back at the end).
#
#  Needs: an installed lomp server, and the "script" command for the menu part.
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-fix-owner-modes.sh [tree to test, default: this checkout]
# =============================================================================
set -u
export LOMP_LANG=en LOMP_MENU_LANG=en
if [[ "${LOMPSTACK_INTEGRATION:-}" != "yes" ]]; then
  printf '%s\n' "This test adds and removes a real site on this machine. Run it only on a throwaway" \
    "server:  LOMPSTACK_INTEGRATION=yes bash $0" >&2
  exit 2
fi
if [[ "$(id -u)" != 0 ]]; then printf 'Run it as root.\n' >&2; exit 2; fi
need() { printf 'Cannot run here: %s\n' "$1" >&2; exit 2; }
[[ -s /root/.server-setup/manifest.json ]] || need "lomp is not installed on this server (setup.sh install)"
command -v script >/dev/null 2>&1 || need "the script command is missing (apt-get install bsdutils)"
PASS=0; FAIL=0
ok()    { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; if [ -n "${2:-}" ]; then printf '        %s\n' "${2:0:600}"; fi; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n" "command failed: $*"; fi; }
nope()  { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n" "command succeeded: $*"; else ok "$n"; fi; }
has()   { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "missing [$2] in: $3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "unexpected [$2] in: $3"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
sec()   { printf '\n-- %s\n' "$*"; }

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SRC="${1:-$(dirname "$HERE")}"
T="$(mktemp -d /tmp/lomp-e2e.XXXXXX)"
mkdir -p "$T/src"
cp -r "$SRC/setup.sh" "$SRC/lib" "$SRC/tests" "$T/src/"
L="bash $T/src/setup.sh"
F=fomodes.lomp-e2e.invalid
H="/home/$F"
ST=/root/.server-setup/domains
MAN=/root/.server-setup/manifest.json
OUT="$T/outside"
T0=$(date +%s)
ident() { printf '%s' "${1//[.-]/_}"; }
U="$(ident "$F")"
modes() { stat -c '%a %U' "$@" | paste -sd' ' -; }
plain() { sed 's/\x1b\[[0-9;]*m//g' "$1" | tr -d '\r'; }
# what WinSCP as root with "set permissions: rwxrwxrwx" leaves: root's, 777 and 666
upload() {   # dir under public_html
  local d="$H/public_html/$1"
  mkdir -p "$d/img"
  printf 'jpg-%s' "$1" >"$d/img/a.jpg"; printf '<?php echo "%s";\n' "$1" >"$d/index.php"; printf '#!/bin/sh\n' >"$d/run.sh"
  chmod 0777 "$d" "$d/img" "$d/run.sh"; chmod 0666 "$d/img/a.jpg" "$d/index.php"
}
AUTO_WAS="$(jq -r '.fix_owner_auto // "-"' "$MAN")"

for s in mariadb lsws; do systemctl is-active --quiet "$s" || systemctl start "$s" >/dev/null 2>&1; done
for i in $(seq 1 60); do ss -ltn | grep -q ':80 ' && break; sleep 1; done

cleanup() {
  [ -s "$ST/$F/domain.json" ] && $L remove "$F" --yes >/dev/null 2>&1
  if getent passwd "$U" >/dev/null 2>&1; then
    pkill -KILL -u "$U" >/dev/null 2>&1; sleep 1
    userdel "$U" >/dev/null 2>&1; groupdel "$U" >/dev/null 2>&1
  fi
  rm -rf "/var/backups/server-setup/$F" "${ST:?}/$F" "$H"
  rm -rf /root/.server-setup/archive/domains/"$F".* /root/.server-setup/archive/vhosts/"$F".*
}
put_back() {
  local now=""; now="$(jq -r '.fix_owner_auto // "-"' "$MAN")"
  [ "$now" = "$AUTO_WAS" ] && return 0
  case "$AUTO_WAS" in
    off) $L fix-owner --auto off >/dev/null 2>&1 ;;
    *)   $L fix-owner --auto on >/dev/null 2>&1
         if [ "$AUTO_WAS" = "-" ]; then jq 'del(.fix_owner_auto)' "$MAN" >"$T/m.json" && cat "$T/m.json" >"$MAN"; fi ;;
  esac
}
trap 'cleanup; put_back; rm -rf "$T"' EXIT

sec "a site, and an upload as root with 777"
cleanup
out="$($L add "$F" --no-ssl --no-db --email e2e@example.org --yes --no-color 2>&1)"; rc=$?
eq "$F is added" 0 "$rc"
[ "$rc" = 0 ] || { printf '%s\n' "$out" | tail -n 14 | sed 's/^/   | /'; printf '\nRESULT: the site could not be added\n'; exit 1; }
# the minute check must not get there first while the command is tested
$L fix-owner --auto off >/dev/null 2>&1
eq "the automatic hand-over is off for the test" "off" "$(jq -r '.fix_owner_auto // "-"' "$MAN")"
upload up
mkdir -p "$OUT"; printf 's' >"$OUT/secret"; chmod 0777 "$OUT" "$OUT/secret"
ln -s "$OUT/secret" "$H/public_html/up/secret-link"
logdir="$(readlink -f "$H/logs")"
log_before="$(stat -c '%a %U %G' "$logdir")"
eq "the upload is root's and open" "777 root 777 root 666 root 777 root" \
  "$(modes "$H/public_html/up" "$H/public_html/up/img" "$H/public_html/up/img/a.jpg" "$H/public_html/up/run.sh")"

sec "a dry run"
out="$($L fix-owner "$F" --dry-run --no-color 2>&1)"; rc=$?
eq  "exits 0" 0 "$rc"
has "counts what it would hand over" "would hand" "$out"
has "and what it would close" "[dry-run] $F: would take write access for group and others away from 5 files and directories (777 -> 755, 666 -> 644)" "$out"
eq  "and changes nothing" "777 root 666 root" "$(modes "$H/public_html/up" "$H/public_html/up/index.php")"

sec "fix-owner"
out="$($L fix-owner "$F" --no-color 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/   | /'
eq  "exits 0" 0 "$rc"
has "hands the upload over" "handed to $U:$U" "$out"
has "and says what it closed" "$F: write access for group and others taken away from 5 files and directories (777 -> 755, 666 -> 644)" "$out"
eq  "777 directories are 755, the site user's" "755 $U 755 $U" "$(modes "$H/public_html/up" "$H/public_html/up/img")"
eq  "666 files are 644" "644 $U 644 $U" "$(modes "$H/public_html/up/img/a.jpg" "$H/public_html/up/index.php")"
eq  "a 777 file keeps its execute bits: 755" "755 $U" "$(modes "$H/public_html/up/run.sh")"
eq  "nothing in the home can be written by group or others" "" \
  "$(find -P "$H" -xdev \( -path "$H/logs" -prune \) -o \( -type d -o -type f \) -perm /022 -print)"
eq  "nothing in the home is root's but logs/" "" "$(find -P "$H" -xdev \( -path "$H/logs" -prune \) -o -uid 0 -print)"
eq  "a file a link led to outside the site keeps its mode and owner" "777 root 777 root" "$(modes "$OUT" "$OUT/secret")"
eq  "the site's log directory is as it was" "$log_before" "$(stat -c '%a %U %G' "$logdir")"
eq  "OpenLiteSpeed serves the uploaded image" "200 jpg-up" \
  "$(curl -s --max-time 15 -o "$T/a.jpg" -w '%{http_code}' -H "Host: $F" "http://127.0.0.1/up/img/a.jpg") $(cat "$T/a.jpg" 2>/dev/null)"
eq  "and the uploaded PHP runs" "up" "$(curl -s --max-time 15 -H "Host: $F" "http://127.0.0.1/up/index.php?r=$RANDOM")"
has "the log names the chmod, as the site user" "chmod go-w, as $U, what group or others may write to in $H (5)" "$(tail -n 200 /var/log/server_setup.log 2>/dev/null)"
out="$($L fix-owner "$F" --no-color 2>&1)"
has "a second run has nothing to do" "$F: everything already belongs to $U" "$out"
# open again, now the site user's own: closed without a chown
chmod 0777 "$H/public_html/up/img"; chown "$U:$U" "$H/public_html/up/img"
out="$($L fix-owner "$F" --no-color 2>&1)"
has "a directory of the site's own that is open is closed too" "taken away from 1 file or directory" "$out"
lacks "with no hand-over to speak of" "handed to" "$out"
eq  "755" "755 $U" "$(modes "$H/public_html/up/img")"

sec "in Turkish"
upload tr
LOMP_LANG=tr script -qec "$L fix-owner $F" "$T/tr.out" >/dev/null 2>&1
has "the line is Turkish, the count too" "$F: 5 dosya ve dizin için grubun ve herkesin yazma izni kaldırıldı (777 -> 755, 666 -> 644)" "$(plain "$T/tr.out")"
eq  "and it was done" "755 $U 644 $U" "$(modes "$H/public_html/tr" "$H/public_html/tr/index.php")"

sec "menu item 21, one site"
upload menu
printf '21\n2\n0\n\n0\n' | script -qec "$L" "$T/menu1.out" >/dev/null 2>&1
mo="$(plain "$T/menu1.out")"
has "the menu has the item" "21) Fix file ownership (after uploading as root)" "$mo"
has "and says what it does to modes" "What group or others may write to is closed: 777 becomes 755, 666 becomes 644." "$mo"
idx="$(awk -v d="$F" '$2 == d && $1 ~ /^[0-9]+\)$/ { sub(/\)/, "", $1); print $1; exit }' <<<"$mo")"
check "the site is in the menu's list" test -n "$idx"
printf '21\n2\n%s\n\n0\n' "$idx" | script -qec "$L" "$T/menu2.out" >/dev/null 2>&1
mo="$(plain "$T/menu2.out")"
has "the menu runs fix-owner for it" "$F: write access for group and others taken away from 5 files and directories" "$mo"
eq  "and the menu's upload is 755/644 and the site user's" "755 $U 755 $U 644 $U" \
  "$(modes "$H/public_html/menu" "$H/public_html/menu/img" "$H/public_html/menu/img/a.jpg")"

sec "by itself: one pass of the minute check"
$L fix-owner --auto on >/dev/null 2>&1
upload auto
$L htaccess-check --quiet >/dev/null 2>&1
eq  "the upload is the site user's and closed" "755 $U 755 $U 644 $U 644 $U 755 $U" \
  "$(modes "$H/public_html/auto" "$H/public_html/auto/img" "$H/public_html/auto/img/a.jpg" "$H/public_html/auto/index.php" "$H/public_html/auto/run.sh")"
eq  "nothing in the home can be written by group or others" "" \
  "$(find -P "$H" -xdev \( -path "$H/logs" -prune \) -o \( -type d -o -type f \) -perm /022 -print)"
eq  "the link's target outside is still as it was" "777 root" "$(modes "$OUT/secret")"
eq  "the auto upload is served" "200" "$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' -H "Host: $F" "http://127.0.0.1/auto/img/a.jpg")"

sec "afterwards"
trap 'rm -rf "$T"' EXIT
cleanup
put_back
eq    "the automatic hand-over is as it was" "$AUTO_WAS" "$(jq -r '.fix_owner_auto // "-"' "$MAN")"
nope  "no test user is left" getent passwd "$U"
nope  "no test home" test -e "$H"
check "OpenLiteSpeed's configuration is valid" /usr/local/lsws/bin/openlitespeed -t

printf '\nRESULT: %s passed, %s failed (%s s)\n' "$PASS" "$FAIL" "$(( $(date +%s) - T0 ))"
[ "$FAIL" = 0 ]
