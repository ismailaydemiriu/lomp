#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-apcu.sh - DESTRUCTIVE end-to-end test of "lomp apcu": a site's APCu switched
#  off and on, on a real OpenLiteSpeed with a real LSPHP.
#
#  What a site's PHP itself says is what is checked: a page in each test site asks
#  apcu_enabled(), stores a value and reads back the one the request before it stored.
#  One site is switched while its neighbour keeps its cache; hardening and the switch
#  share one ini file and each leaves the other's lines; "--all" reaches every site and
#  the one added afterwards; a rename and a restore from a backup carry the setting;
#  doctor names an ini that went missing; and the menu's item does the same as the command.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It adds and removes real sites (names under
#  .invalid, which no DNS answers for) and reloads OpenLiteSpeed several times. "--all"
#  switches every site of the server and starts its PHP again; what each site and the
#  server had recorded is put back at the end.
#
#  Needs: an installed lomp server, and the "script" command for the menu part.
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-apcu.sh [tree to test, default: this checkout]
# =============================================================================
set -u
# the checks read what the commands print, and the menu: in English, whatever this server speaks
export LOMP_LANG=en LOMP_MENU_LANG=en
if [[ "${LOMPSTACK_INTEGRATION:-}" != "yes" ]]; then
  printf '%s\n' "This test adds and removes real sites on this machine, and switches APCu for every" \
    "site of it. Run it only on a throwaway server:  LOMPSTACK_INTEGRATION=yes bash $0" >&2
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
# from a copy: the tree under test cannot change under the run, and the path has no spaces
T="$(mktemp -d /tmp/lomp-e2e.XXXXXX)"
mkdir -p "$T/src"
cp -r "$SRC/setup.sh" "$SRC/lib" "$SRC/tests" "$T/src/"
L="bash $T/src/setup.sh"
# A: the site that is switched, hardened like every new site. B: its neighbour. C: added while
# APCu is off for every site. N: what A is renamed to.
A=apcua.lomp-e2e.invalid; B=apcub.lomp-e2e.invalid; C=apcuc.lomp-e2e.invalid; N=apcun.lomp-e2e.invalid
ST=/root/.server-setup/domains
MAN=/root/.server-setup/manifest.json
INI=/etc/lompstack/php
VH=/usr/local/lsws/conf/vhosts
T0=$(date +%s)
ident() { printf '%s' "${1//[.-]/_}"; }
rec()   { jq -r '.php.apcu // "-"' "$ST/$1/domain.json" 2>/dev/null; }
user()  { jq -r '.user' "$ST/$1/domain.json" 2>/dev/null; }
ini()   { printf '%s/%s/99-lompstack-site.ini' "$INI" "$1"; }
row()   { $L apcu status --no-color 2>/dev/null | awk -v d="$1" '$1 == d { $1 = ""; sub(/^ /, ""); print }'; }
# the oldest lsphp of a site: the one its workers come from, and the one a restart replaces
php_pid() { pgrep -o -u "$(user "$1")" lsphp 2>/dev/null || true; }

for s in mariadb lsws; do systemctl is-active --quiet "$s" || systemctl start "$s" >/dev/null 2>&1; done
for i in $(seq 1 60); do ss -ltn | grep -q ':80 ' && break; sleep 1; done

# The page that answers for the site's PHP. "was" is what the request before this one stored:
# 'kept' only where APCu holds values between requests.
probe_put() {   # domain
  runuser -u "$(user "$1")" -- tee "/home/$1/public_html/apcu-probe.php" >/dev/null <<'EOF'
<?php
header('Content-Type: text/plain'); header('Cache-Control: no-store');
$on  = function_exists('apcu_enabled') ? (apcu_enabled() ? 'yes' : 'no') : 'missing';
$was = function_exists('apcu_fetch') ? var_export(@apcu_fetch('lomp_e2e'), true) : 'missing';
$put = function_exists('apcu_store') ? var_export(@apcu_store('lomp_e2e', 'kept'), true) : 'missing';
printf("enabled=%s was=%s store=%s ini=%s exec=%s\n", $on, $was, $put, ini_get('apc.enabled'), function_exists('exec') ? 'yes' : 'no');
EOF
}
probe()  { curl -s --max-time 15 -H "Host: $1" "http://127.0.0.1/apcu-probe.php?r=$RANDOM"; }
probe2() { probe "$1" >/dev/null; probe "$1"; }   # the second request: what the first stored is there, or not

# What every site that was here before the test had recorded, and the server: "--all" writes
# into each of them, and all of it is put back.
declare -A APCU_WAS=()
PARAM_WAS="$(jq -r '.params.apcu // "-"' "$MAN")"
mine() { case "$1" in "$A"|"$B"|"$C"|"$N") return 0 ;; esac; return 1; }
remember() {
  local f="" d=""
  for f in "$ST"/*/domain.json; do
    [ -s "$f" ] || continue
    d="${f%/domain.json}"; d="${d##*/}"
    mine "$d" || APCU_WAS["$d"]="$(rec "$d")"
  done
}
put_back() {
  local d="" f="" tmp="$T/put-back.json"
  for d in "${!APCU_WAS[@]}"; do
    f="$ST/$d/domain.json"; [ -s "$f" ] || continue
    [ "$(rec "$d")" = "${APCU_WAS[$d]}" ] && continue
    case "${APCU_WAS[$d]}" in
      off) $L apcu off "$d" >/dev/null 2>&1 ;;
      on)  $L apcu on "$d" >/dev/null 2>&1 ;;
      *)   $L apcu on "$d" >/dev/null 2>&1
           jq 'del(.php.apcu)' "$f" >"$tmp" 2>/dev/null && cat "$tmp" >"$f" ;;
    esac
  done
  if [ "$(jq -r '.params.apcu // "-"' "$MAN")" != "$PARAM_WAS" ]; then
    if [ "$PARAM_WAS" = "-" ]; then jq 'del(.params.apcu)' "$MAN" >"$tmp" && cat "$tmp" >"$MAN"
    else jq --arg v "$PARAM_WAS" '.params.apcu = $v' "$MAN" >"$tmp" && cat "$tmp" >"$MAN"; fi
  fi
}
cleanup() {
  local d="" u=""
  for d in "$A" "$B" "$C" "$N"; do
    u="$(ident "$d")"
    [ -s "$ST/$d/redirect.json" ] && $L redirect del "$d" --yes >/dev/null 2>&1
    [ -s "$ST/$d/domain.json" ] && $L remove "$d" --yes >/dev/null 2>&1
    if getent passwd "$u" >/dev/null 2>&1; then
      pkill -KILL -u "$u" >/dev/null 2>&1; sleep 1
      userdel "$u" >/dev/null 2>&1; groupdel "$u" >/dev/null 2>&1
    fi
    rm -rf "/var/backups/server-setup/$d" "$ST/$d" "/home/$d" "${INI:?}/$d"
  done
  rm -rf /root/.server-setup/archive/domains/apcu?.lomp-e2e.invalid.* /root/.server-setup/archive/vhosts/apcu?.lomp-e2e.invalid.*
}
trap 'cleanup; put_back; rm -rf "$T"' EXIT

sec "two PHP sites, as they are added"
cleanup
remember
sites_before="$($L list --json 2>/dev/null | jq -r '[.[].domain] | sort | join(" ")')"
for d in "$A" "$B"; do
  out="$($L add "$d" --no-ssl --no-db --email e2e@example.org --yes --no-color 2>&1)"; rc=$?
  eq "$d is added" 0 "$rc"
  [ "$rc" = 0 ] || { printf '%s\n' "$out" | tail -n 14 | sed 's/^/   | /'; printf '\nRESULT: the sites could not be added; nothing else was tried\n'; exit 1; }
  probe_put "$d"
done
ver="$(jq -r '.php.version' "$ST/$A/domain.json")"; cli="/usr/local/lsws/lsphp${ver//./}/bin/php"
printf '   | PHP %s; a new site answers: %s\n' "$ver" "$(probe2 "$A")"
has   "APCu is on in a new site, and keeps a value between requests" "enabled=yes was='kept' store=true ini=1" "$(probe2 "$A")"
has   "the site is hardened, as every new one"    "exec=no" "$(probe "$A")"
eq    "nothing is recorded for it"                "-" "$(rec "$A")"
eq    "status calls it on"                        "php $ver on" "$(row "$A")"
eq    "its ini has what hardening wrote, no more" "disable_functions open_basedir" "$(grep -v '^;' "$(ini "$A")" | sed 's/ = .*//' | paste -sd' ' -)"
has   "its neighbour has APCu too"                "enabled=yes was='kept'" "$(probe2 "$B")"

sec "off for one site"
pid_a="$(php_pid "$A")"; pid_b="$(php_pid "$B")"
out="$($L apcu off "$A" --no-color 2>&1)"; rc=$?
eq    "apcu off exits 0"                          0 "$rc"
has   "it says so, with what the site answers"    "$A: APCu switched off (HTTP 200)" "$out"
p="$(probe2 "$A")"; printf '   | switched off, it answers: %s\n' "$p"
has   "the site's PHP says APCu is off"           "enabled=no" "$p"
has   "by the setting it started with"            "ini=0" "$p"
lacks "nothing is kept between requests"          "was='kept'" "$p"
has   "the functions are still there"             "store=false" "$p"
has   "and the site is hardened as before"        "exec=no" "$p"
eq    "off is in its record"                      "off" "$(rec "$A")"
eq    "and in its ini, under what hardening wrote" "disable_functions open_basedir apc.enabled" "$(grep -v '^;' "$(ini "$A")" | sed 's/ = .*//' | paste -sd' ' -)"
eq    "root's file, readable by the site's group" "640 root $(ident "$A")" "$(stat -c '%a %U %G' "$(ini "$A")")"
eq    "status calls it off"                       "php $ver off" "$(row "$A")"
new_pid="$(php_pid "$A")"
check "its PHP was started again"                 test -n "$pid_a" -a -n "$new_pid" -a "$new_pid" != "$pid_a"
eq    "PHP starts cleanly with that ini"          "0" "$(runuser -u "$(user "$A")" -- env PHP_INI_SCAN_DIR=":$INI/$A" "$cli" -d display_startup_errors=1 -d display_errors=1 -r 'echo ini_get("apc.enabled");' 2>&1)"
p="$(probe "$B")"
has   "the neighbour still has APCu"              "enabled=yes" "$p"
has   "and the value it kept: its PHP was not started again" "was='kept'" "$p"
eq    "the same process as before"                "$pid_b" "$(php_pid "$B")"
check "which was running all along"               test -n "$pid_b"
eq    "nothing is recorded for the neighbour"     "-" "$(rec "$B")"
eq    "nor for the sites added later"             "$PARAM_WAS" "$(jq -r '.params.apcu // "-"' "$MAN")"
pid_a="$(php_pid "$A")"
out="$($L apcu off "$A" --no-color 2>&1)"
has   "off twice: it is off already"              "$A: APCu is off already" "$out"
eq    "and its PHP is left running"               "$pid_a" "$(php_pid "$A")"
out="$($L apcu off "$A" --dry-run --no-color 2>&1)"
has   "a dry run of it says the same"             "$A: APCu is off already" "$out"

sec "hardening and the switch share the file"
# "harden" switches the site firewall on unless told otherwise: it is left as it was found
FW=(); [ "$(jq -r '.params.site_firewall' "$MAN")" = "true" ] || FW=(--firewall off)
out="$($L harden "$A" --allow-exec "${FW[@]}" --no-color 2>&1)"; rc=$?
eq    "harden --allow-exec exits 0"               0 "$rc"
eq    "the ini keeps the APCu line alone"         "apc.enabled" "$(grep -v '^;' "$(ini "$A")" | sed 's/ = .*//' | paste -sd' ' -)"
p="$(probe2 "$A")"
has   "PHP may start processes again, APCu stays off" "enabled=no was=false store=false ini=0 exec=yes" "$p"
out="$($L apcu on "$A" --no-color 2>&1)"; rc=$?
eq    "apcu on exits 0"                           0 "$rc"
has   "it says so"                                "$A: APCu switched on (HTTP 200)" "$out"
nope  "nothing is left for an ini: the directory goes" test -e "$INI/$A"
lacks "and the vhost points PHP at none"          "PHP_INI_SCAN_DIR" "$(cat "$VH/$A/vhconf.conf")"
has   "APCu is back, process execution stays"     "enabled=yes was='kept' store=true ini=1 exec=yes" "$(probe2 "$A")"
eq    "on is in its record"                       "on" "$(rec "$A")"
out="$($L harden "$A" "${FW[@]}" --no-color 2>&1)"
has   "hardened again, APCu stays on"             "enabled=yes was='kept' store=true ini=1 exec=no" "$(probe2 "$A")"
eq    "and the ini is hardening's alone"          "disable_functions open_basedir" "$(grep -v '^;' "$(ini "$A")" | sed 's/ = .*//' | paste -sd' ' -)"
out="$($L apcu off "$A" --no-color 2>&1)"
has   "off once more, for what follows"           "enabled=no" "$(probe2 "$A")"

sec "doctor"
doc() { $L doctor --json 2>/dev/null | jq -r --arg c "site $A: APCu" '[.checks[] | select(.check == $c) | .status] | join(" ")' 2>/dev/null; }
eq    "doctor has nothing to say while the ini says off" "" "$(doc)"
rm -rf "${INI:?}/$A"
eq    "an ini that went missing is a failure"     "FAIL" "$(doc)"
out="$($L apcu off "$A" --no-color 2>&1)"
has   "the command it names writes it again"      "$A: APCu switched off" "$out"
eq    "and doctor is quiet"                       "" "$(doc)"
has   "the site's PHP is off again"               "enabled=no" "$(probe2 "$A")"

sec "every site, and the one added afterwards"
out="$($L apcu off --all --dry-run --no-color 2>&1)"
has   "a dry run of --all names the neighbour"    "[dry-run] $B: APCu would be switched off" "$out"
has   "and what later sites would start with"     "[dry-run] sites added from now on would start with APCu off" "$out"
has   "it switched nothing"                       "enabled=yes" "$(probe "$B")"
eq    "and recorded nothing"                      "$PARAM_WAS" "$(jq -r '.params.apcu // "-"' "$MAN")"
params_before="$(jq -c '.params | del(.apcu)' "$MAN")"
out="$($L apcu off --all --no-color 2>&1)"; rc=$?
eq    "apcu off --all exits 0"                    0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 14 | sed 's/^/   | /'
has   "the neighbour is switched"                 "$B: APCu switched off (HTTP 200)" "$out"
has   "the one that was off is said to be"        "$A: APCu is off already" "$out"
has   "later sites are spoken for"                "Sites added from now on start with APCu off" "$out"
has   "the neighbour's PHP says off"              "enabled=no" "$(probe2 "$B")"
left=""
for f in "$ST"/*/domain.json; do
  case "$(jq -r '.mode // "php"' "$f")" in php|wordpress) ;; *) continue ;; esac
  [ "$(jq -r '.php.apcu // "-"' "$f")" = "off" ] || left+="${f%/domain.json} "
done
eq    "every site PHP runs in is recorded off"    "" "$left"
eq    "it is in the server's settings"            "off" "$(jq -r '.params.apcu // "-"' "$MAN")"
eq    "beside the others, which are as they were" "$params_before" "$(jq -c '.params | del(.apcu)' "$MAN")"
has   "status says what a new site gets"          "Sites added from now on start with APCu off" "$($L apcu status --no-color 2>&1 | sed -n 1p)"
out="$($L add "$C" --no-ssl --no-db --email e2e@example.org --yes --no-color 2>&1)"; rc=$?
eq    "a site is added afterwards"                0 "$rc"
probe_put "$C"
p="$(probe2 "$C")"; printf '   | added while APCu is off for every site, it answers: %s\n' "$p"
has   "its PHP never had APCu"                    "enabled=no was=false store=false ini=0 exec=no" "$p"
eq    "off is in its record from the start"       "off" "$(rec "$C")"
out="$($L apcu on --all --no-color 2>&1)"; rc=$?
eq    "apcu on --all exits 0"                     0 "$rc"
has   "later sites are spoken for again"          "Sites added from now on start with APCu on" "$out"
for d in "$A" "$B" "$C"; do
  has "$d has APCu again"                         "enabled=yes was='kept' store=true ini=1" "$(probe2 "$d")"
done
eq    "the server's setting says on"              "on" "$(jq -r '.params.apcu // "-"' "$MAN")"

sec "a rename and a backup carry it"
out="$($L apcu off "$A" "$B" --no-color 2>&1)"; rc=$?
eq    "two sites in one command"                  "0 off off" "$rc $(rec "$A") $(rec "$B")"
out="$($L rename "$A" "$N" --no-ssl --yes --no-color 2>&1)"; rc=$?
eq    "the site is renamed"                       0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 14 | sed 's/^/   | /'
eq    "off is in the record under the new name"   "off" "$(rec "$N")"
eq    "its ini moved with it"                     "disable_functions open_basedir apc.enabled" "$(grep -v '^;' "$(ini "$N")" 2>/dev/null | sed 's/ = .*//' | paste -sd' ' -)"
nope  "none is left under the old name"           test -e "$INI/$A"
has   "under the new name its PHP has no APCu"    "enabled=no was=false store=false ini=0 exec=no" "$(probe2 "$N")"
out="$($L backup "$B" --no-color 2>&1)"; rc=$?
eq    "the neighbour is backed up"                0 "$rc"
arc="$(sed -n 's/.*Backup created: \([^ ]*\) .*/\1/p' <<<"$out" | tail -n 1)"
check "the archive is there"                      test -s "$arc"
cp -f "$arc" "$T/neighbour.tar.gz" 2>/dev/null
out="$($L remove "$B" --yes --no-color 2>&1)"; rc=$?
eq    "and removed"                               0 "$rc"
nope  "its ini went with it"                      test -e "$INI/$B"
out="$($L restore "$B" --file "$T/neighbour.tar.gz" --yes --no-color 2>&1)"; rc=$?
eq    "it is restored from the archive"           0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 14 | sed 's/^/   | /'
eq    "with off in its record"                    "off" "$(rec "$B")"
has   "and a PHP that has no APCu"                "enabled=no was=false store=false ini=0" "$(probe2 "$B")"

sec "from the menu"
printf '31\n1\n\n0\n' | script -qec "$L" "$T/menu1.out" >/dev/null 2>&1
mo="$(sed 's/\x1b\[[0-9;]*m//g' "$T/menu1.out" | tr -d '\r')"
has   "the menu has the entry"                    "31) APCu, PHP's in-memory cache: on or off" "$mo"
has   "its first choice shows what is set"        "apcu status" "$mo"
has   "with the site that is off"                 "$N" "$(grep -E "^$N +php +$ver +off" <<<"$mo")"
# which number is the site? a first pass that picks none lists them
printf '31\n3\n0\n\n0\n' | script -qec "$L" "$T/menu2.out" >/dev/null 2>&1
idx="$(sed 's/\x1b\[[0-9;]*m//g' "$T/menu2.out" | tr -d '\r' | awk -v d="$N" '$2 == d && $1 ~ /^[0-9]+\)$/ { sub(/\)/, "", $1); print $1; exit }')"
check "the site is offered by number"             test -n "$idx"
eq    "picking none changes nothing"              "off" "$(rec "$N")"
printf '31\n3\n%s\n\n0\n' "$idx" | script -qec "$L" "$T/menu3.out" >/dev/null 2>&1
mo="$(sed 's/\x1b\[[0-9;]*m//g' "$T/menu3.out" | tr -d '\r')"
has   "the menu runs the command for the site picked" "apcu on $N" "$mo"
has   "which says what it did"                    "$N: APCu switched on (HTTP 200)" "$mo"
has   "and the site's PHP has APCu again"         "enabled=yes was='kept'" "$(probe2 "$N")"
printf '31\n2\n%s\n\n0\n' "$idx" | script -qec "$L" "$T/menu4.out" >/dev/null 2>&1
has   "the second choice switches it off"         "enabled=no" "$(probe2 "$N")"
LOMP_LANG=tr LOMP_MENU_LANG=tr script -qec "$L apcu status" "$T/tr.out" >/dev/null 2>&1
mo="$(sed 's/\x1b\[[0-9;]*m//g' "$T/tr.out" | tr -d '\r')"
has   "on a terminal, in Turkish: the heading"    "SİTE" "$mo"
has   "and the word"                              "$N" "$(grep -E "^$N +php +$ver +kapalı" <<<"$mo")"

sec "afterwards"
trap 'rm -rf "$T"' EXIT
cleanup
put_back
eq    "the server has the sites it had" "$sites_before" "$($L list --json 2>/dev/null | jq -r '[.[].domain] | sort | join(" ")')"
wrong=""
for d in "${!APCU_WAS[@]}"; do [ "$(rec "$d")" = "${APCU_WAS[$d]}" ] || wrong+="$d "; done
eq    "each of them has recorded what it had"     "" "$wrong"
eq    "and so has the server"                     "$PARAM_WAS" "$(jq -r '.params.apcu // "-"' "$MAN")"
nope  "no test user is left" bash -c "getent passwd | grep -q '^apcu._lomp_e2e_invalid:'"
nope  "no test home" bash -c "ls -d /home/apcu?.lomp-e2e.invalid"
nope  "no test ini" bash -c "ls -d $INI/apcu?.lomp-e2e.invalid"
check "OpenLiteSpeed's configuration is valid" /usr/local/lsws/bin/openlitespeed -t

printf '\nRESULT: %s passed, %s failed (%s s)\n' "$PASS" "$FAIL" "$(( $(date +%s) - T0 ))"
[ "$FAIL" = 0 ]
