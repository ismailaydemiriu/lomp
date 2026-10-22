#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-lsphp-updates.sh - DESTRUCTIVE end-to-end test of LSPHP's security updates:
#  unattended-upgrades installs them from the LiteSpeed repository, the lsphp workers an update
#  leaves on the old files are ended, and PHP reads the request-parsing guards of php.net's
#  21 Oct 2026 advisory (CVE-2026-109618/109619). And "php" typed in a shell is LSPHP's CLI,
#  with the distribution's PHP installed beside it.
#
#  What is checked is what the server does: a page of a test site says which PHP answered it
#  and what it read; the workers are counted by their process ids; the versions are dpkg's.
#  A server set up before this release is made by taking this release's files away again, and
#  migrate brings it along. Then LSPHP is put one release back and updated twice: by hand
#  (apt-get) and by unattended-upgrades itself - with OpenLiteSpeed one release back as well,
#  which unattended-upgrades must leave alone.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It installs older packages from the LiteSpeed
#  repository and runs unattended-upgrades for real, which also installs whatever security
#  update of the distribution is waiting. Everything ends at the repository's current versions.
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-lsphp-updates.sh [tree to test, default: this checkout]
# =============================================================================
set -u
export LOMP_LANG=en LOMP_MENU_LANG=en
if [[ "${LOMPSTACK_INTEGRATION:-}" != "yes" ]]; then
  printf '%s\n' "This test installs older LiteSpeed packages and runs unattended-upgrades for real." \
    "Run it only on a throwaway server:  LOMPSTACK_INTEGRATION=yes bash $0" >&2
  exit 2
fi
if [[ "$(id -u)" != 0 ]]; then printf 'Run it as root.\n' >&2; exit 2; fi
need() { printf 'Cannot run here: %s\n' "$1" >&2; exit 2; }
[[ -s /root/.server-setup/manifest.json ]] || need "lomp is not installed on this server (setup.sh install)"
command -v unattended-upgrade >/dev/null 2>&1 || need "unattended-upgrades is not installed"
PASS=0; FAIL=0
ok()    { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; if [ -n "${2:-}" ]; then printf '        %s\n' "${2:0:900}"; fi; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n" "command failed: $*"; fi; }
nope()  { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n" "command succeeded: $*"; else ok "$n"; fi; }
has()   { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "missing [$2] in: $3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "unexpected [$2] in: $3"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
sec()   { printf '\n-- %s\n' "$*"; }

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SRC="${1:-$(dirname "$HERE")}"
T="$(mktemp -d /tmp/lomp-e2e.XXXXXX)"
mkdir -p "$T/src" "$T/deb"
cp -r "$SRC/setup.sh" "$SRC/lib" "$SRC/tests" "$T/src/"
L="bash $T/src/setup.sh"
D=lsphpup.lomp-e2e.invalid
ST=/root/.server-setup/domains
PHPV="$(jq -r '.components.php.default // "8.3"' /root/.server-setup/manifest.json)"
TAG="lsphp${PHPV//./}"
CLI="/usr/local/lsws/${TAG}/bin/php"
SCRIPT=/usr/local/sbin/lomp-lsphp-restart
HOOK=/etc/apt/apt.conf.d/53lompstack-lsphp-restart
UU=/etc/apt/apt.conf.d/52server-setup-unattended
POOL="https://rpms.litespeedtech.com/debian/pool/main/$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")"
T0=$(date +%s)
user() { jq -r '.user' "$ST/$1/domain.json" 2>/dev/null; }
ver()  { dpkg-query -W -f '${Version}' "$1" 2>/dev/null; }
workers() { pgrep -x lsphp 2>/dev/null | sort -n | paste -sd' ' -; }
# a worker of these that is still there
alive() { local p=""; for p in $1; do [ -d "/proc/$p" ] && [ "$(cat "/proc/$p/comm" 2>/dev/null)" = lsphp ] && printf '%s ' "$p"; done; return 0; }
page() { curl -s --max-time 20 -H "Host: $D" "http://127.0.0.1/lsphpup.php?r=$RANDOM"; }
# The release before the current one, from the repository's pool: "<package> <version>"
older() {   # package
  local cur="" list="" v=""
  cur="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}')"
  list="$(curl -fsS "$POOL/" | grep -o "${1}_[^\"<%]*_amd64\.deb" | sort -uV | sed "s/^${1}_//; s/_amd64\.deb\$//")"
  v="$(awk -v c="$cur" '$0 == c { print prev; exit } { prev = $0 }' <<<"$list")"
  printf '%s' "$v"
}
put_older() {   # package version
  curl -fsS -o "$T/deb/${1}_${2}_amd64.deb" "$POOL/${1}_${2}_amd64.deb" || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --allow-downgrades -o Dpkg::Options::=--force-confold "$T/deb/${1}_${2}_amd64.deb" 2>&1
}

for s in mariadb lsws; do systemctl is-active --quiet "$s" || systemctl start "$s" >/dev/null 2>&1; done
for i in $(seq 1 60); do ss -ltn | grep -q ':80 ' && break; sleep 1; done

cleanup() {
  local u=""
  u="$(user "$D")"
  [ -s "$ST/$D/domain.json" ] && $L remove "$D" --yes >/dev/null 2>&1
  if [ -n "$u" ] && getent passwd "$u" >/dev/null 2>&1; then
    pkill -KILL -u "$u" >/dev/null 2>&1; sleep 1; userdel "$u" >/dev/null 2>&1; groupdel "$u" >/dev/null 2>&1
  fi
  rm -rf "/var/backups/server-setup/$D" "${ST:?}/$D" "/home/$D" "/etc/lompstack/php/$D"
}
# whatever happened, the server ends at the repository's packages
restore() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q -o Dpkg::Options::=--force-confold "$TAG" openlitespeed >/dev/null 2>&1
  if [ "${DISTRO_PHP:-0}" = 1 ]; then DEBIAN_FRONTEND=noninteractive apt-get purge -y -q --autoremove php-cli >/dev/null 2>&1; fi
  systemctl restart lsws >/dev/null 2>&1
}
trap 'cleanup; restore; rm -rf "$T"' EXIT

sec "a PHP site whose page says which PHP answered it"
cleanup
out="$($L add "$D" --no-ssl --no-db --email e2e@example.org --yes --no-color 2>&1)"; rc=$?
eq "$D is added" 0 "$rc"
[ "$rc" = 0 ] || { printf '%s\n' "$out" | tail -n 14 | sed 's/^/   | /'; printf '\nRESULT: the site could not be added\n'; exit 1; }
runuser -u "$(user "$D")" -- tee "/home/$D/public_html/lsphpup.php" >/dev/null <<'EOF'
<?php
header('Content-Type: text/plain'); header('Cache-Control: no-store');
printf("php=%s progress=%s backtraces=%s pid=%d\n", PHP_VERSION, var_export(ini_get('session.upload_progress.enabled'), true),
  var_export(ini_get('fatal_error_backtraces'), true), getmypid());
EOF
has "the page answers" "php=" "$(page)"

sec "a server set up before this release"
# what an older release left: no hook, no script, unattended-upgrades without LiteSpeed, and
# an ini without the guards
rm -f "$SCRIPT" "$HOOK"
sed -i '/LiteSpeedTech/d; /^Unattended-Upgrade::Package-Blacklist {/,/^};/d' "$UU"
INIF="$("$CLI" --ini 2>/dev/null | sed -n 's/^Scan for additional \.ini files in: *//p')/99-server-setup.ini"
check "PHP ${PHPV} has lomp's drop-in"                 test -f "$INIF"
sed -i '/^session.upload_progress.enabled/d; /^fatal_error_backtraces/d' "$INIF"
systemctl restart lsws >/dev/null 2>&1; pkill -x lsphp; sleep 2
has   "its PHP takes the session upload progress hook" "progress='1'" "$(page)"
# and "php" in a shell is the distribution's, which some package brought along
DISTRO_PHP=0
if [ ! -e /usr/bin/php ]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends php-cli >/dev/null 2>&1 && DISTRO_PHP=1
fi
check "the distribution's PHP is there"                test -x /usr/bin/php
rm -f /usr/local/bin/php
# the PATH a login gets on Ubuntu (pam_env reads it), and sudo's
UPATH="$(sed -n 's/^PATH="\(.*\)"$/\1/p' /etc/environment)"
shphp() { env -i HOME=/tmp PATH="$UPATH" bash -c 'php -r "echo PHP_BINARY, \" \", PHP_VERSION;"' 2>&1; }
has   "\"php\" in a shell is the distribution's"       "/usr/bin/php" "$(shphp)"
has   "doctor says so"                                 '"php" in a shell is not LSPHP' "$($L doctor --no-color 2>&1)"
doc="$($L doctor --no-color 2>&1)"
has   "doctor says LSPHP waits for lomp update"        "unattended-upgrades does not install them" "$doc"
has   "and that nothing restarts the workers"          "${SCRIPT} is missing" "$doc"

out="$($L migrate --no-color 2>&1)"; rc=$?
eq    "migrate runs"                                   0 "$rc"
has   "it says unattended-upgrades takes LSPHP now"    "now installs LSPHP updates from the LiteSpeed repository" "$out"
has   "and that PHP reads the guards"                  "session upload progress is off now (CVE-2026-109619)" "$out"
has   "the drop-in has both guards again"              "$(printf 'session.upload_progress.enabled = 0')" "$(cat "$INIF")"
has   "the second one too"                             "fatal_error_backtraces = 0" "$(cat "$INIF")"
check "the script is there"                            test -x "$SCRIPT"
check "and apt runs it"                                grep -qF "$SCRIPT" "$HOOK"
dump="$(apt-config dump 2>/dev/null)"
has   "unattended-upgrades reads the LiteSpeed origin" 'Unattended-Upgrade::Allowed-Origins:: "LiteSpeedTech:${distro_codename}";' "$dump"
has   "and keeps OpenLiteSpeed back"                   'Unattended-Upgrade::Package-Blacklist:: "^openlitespeed$";' "$dump"
has   "and its modules"                                'Unattended-Upgrade::Package-Blacklist:: "^ols-";' "$dump"
has   "the security updates are still in"              '"${distro_id}:${distro_codename}-security";' "$dump"
pg="$(page)"
has   "the site's PHP reads upload progress off"       "progress='0'" "$pg"
eq    "nothing else for PHP ${PHPV} at its start"      "ok" "$("$CLI" -d display_startup_errors=1 -d display_errors=1 -d log_errors=0 -r 'echo "ok";' 2>&1)"
has   "the CLI reads it too"                           "session.upload_progress.enabled => Off" "$("$CLI" -i 2>/dev/null | grep '^session.upload_progress.enabled')"
has   "migrate makes \"php\" LSPHP's"                  "\"php\" in a shell is now LSPHP ${PHPV}'s CLI" "$out"
has   "a shell's php is LSPHP now"                     "/usr/local/lsws/${TAG}/bin/" "$(shphp)"
has   "and sudo's"                                     "/usr/local/lsws/${TAG}/bin/" "$(sudo php -r 'echo PHP_BINARY;' 2>&1)"
check "the distribution's PHP is still installed"      test -x /usr/bin/php
has   "php -m has the sites' extensions"               "redis" "$(env -i PATH="$UPATH" php -m 2>&1)"
doc="$($L doctor --no-color 2>&1)"
has   "doctor: php is LSPHP's"                         "LSPHP ${PHPV}'s CLI, the PHP the sites run" "$doc"
has   "doctor: unattended-upgrades installs them"      "unattended-upgrades installs them from the LiteSpeed repository" "$doc"
lacks "and no worker on old files"                     "still run PHP files an update replaced" "$doc"
out="$($L migrate --no-color 2>&1)"
has   "migrate again: the state said"                  "unattended-upgrades installs LSPHP updates from the LiteSpeed repository" "$out"
lacks "and nothing restarted"                          "session upload progress is off now" "$out"

sec "an update by hand: apt-get puts ${TAG} one release back"
# OpenLiteSpeed one release back first: its package depends on lsphp83, and apt brings that to
# the current release while it installs it. unattended-upgrades must leave it there.
OLS_OLD="$(older openlitespeed)"
if [ -n "$OLS_OLD" ]; then
  out="$(put_older openlitespeed "$OLS_OLD")"
  eq "OpenLiteSpeed ${OLS_OLD} is installed" "$OLS_OLD" "$(ver openlitespeed)"
  systemctl restart lsws >/dev/null 2>&1; sleep 2
else bad "an older OpenLiteSpeed in the repository's pool" "none in ${POOL}"; fi
OLD="$(older "$TAG")"; NEW="$(ver "$TAG")"
if [ -z "$OLD" ]; then bad "an older ${TAG} in the repository's pool" "none before ${NEW} in ${POOL}"
else
  page >/dev/null; page >/dev/null
  before="$(workers)"
  check "workers run"                                  test -n "$before"
  out="$(put_older "$TAG" "$OLD")"; rc=$?
  eq    "${TAG} ${OLD} is installed"                   "0 ${OLD}" "$rc $(ver "$TAG")"
  has   "apt's hook ends the workers on the old files" "ended the lsphp processes still running replaced PHP files" "$out"
  eq    "none of them is left"                         "" "$(alive "$before")"
  has   "the next request is answered by ${OLD%%-*}"   "php=${OLD%%-*} " "$(page)"
  check "the system log says it"                       bash -c "journalctl -t lompstack --since '-5min' --no-pager | grep -q 'ended the lsphp'"
fi

sec "unattended-upgrades: ${TAG} back to the current release, OpenLiteSpeed left alone"
apt-get update -q >/dev/null 2>&1
page >/dev/null; page >/dev/null
before="$(workers)"
check "workers run on ${OLD%%-*}"                      bash -c "curl -s -H 'Host: $D' http://127.0.0.1/lsphpup.php | grep -q 'php=${OLD%%-*} '"
dry="$(unattended-upgrade --dry-run -v 2>&1)"
has   "it would upgrade ${TAG}"                        "$TAG" "$(grep -i 'Packages that will be upgraded' <<<"$dry")"
lacks "and not OpenLiteSpeed"                          "openlitespeed" "$(grep -i 'Packages that will be upgraded' <<<"$dry")"
uu_start="$(date '+%Y-%m-%d %H:%M:%S')"
out="$(unattended-upgrade -v 2>&1)"; rc=$?
eq    "unattended-upgrades runs"                       0 "$rc"
eq    "${TAG} is the current release again"            "$NEW" "$(ver "$TAG")"
[ -n "$OLS_OLD" ] && eq "OpenLiteSpeed is where it was" "$OLS_OLD" "$(ver openlitespeed)"
eq    "no worker of ${OLD%%-*} is left"                "" "$(alive "$before")"
has   "the next request is answered by ${NEW%%-*}"     "php=${NEW%%-*} " "$(page)"
has   "with upload progress still off"                 "progress='0'" "$(page)"
check "the system log says the hook ended them"        bash -c "journalctl -t lompstack --since '$uu_start' --no-pager | grep -q 'ended the lsphp'"
eq    "the script finds nothing left"                  "" "$("$SCRIPT" --list)"
lacks "doctor finds no worker on old files"            "still run PHP files an update replaced" "$($L doctor --no-color 2>&1)"

sec "php-update, and the menu's item for it"
if [ -n "$OLD" ]; then
  put_older "$TAG" "$OLD" >/dev/null 2>&1
  eq    "${TAG} is one release back again"            "$OLD" "$(ver "$TAG")"
  out="$($L php-update --no-color 2>&1)"; rc=$?
  eq    "php-update runs"                              0 "$rc"
  has   "it says what changed"                         "PHP ${PHPV}: ${OLD%%-*} -> ${NEW%%-*}" "$out"
  has   "and that the sites still answer"              "Every PHP site answers as it did before" "$out"
  eq    "${TAG} is current"                            "$NEW" "$(ver "$TAG")"
  [ -n "$OLS_OLD" ] && eq "OpenLiteSpeed is not touched" "$OLS_OLD" "$(ver openlitespeed)"
  has   "the next request is answered by ${NEW%%-*}"   "php=${NEW%%-*} " "$(page)"
  out="$($L php-update --no-color 2>&1)"
  has   "run again: nothing to do, said"               "PHP ${PHPV}: ${NEW%%-*}, the latest release in the repository" "$out"
  lacks "and nothing restarted"                        "PHP workers restarted" "$out"
  put_older "$TAG" "$OLD" >/dev/null 2>&1
  if command -v script >/dev/null 2>&1; then
    # apt-get reads the terminal the menu hands it: what is typed while it runs is gone. The
    # Enter after the command and the 0 go only once the menu asks for them.
    { printf '32\n'
      for i in $(seq 1 300); do grep -qs 'Press Enter' "$T/menu.out" && break; sleep 1; done
      printf '\n0\n'; } | timeout 600 script -qfec "$L" "$T/menu.out" >/dev/null 2>&1
    mo="$(sed 's/\x1b\[[0-9;]*m//g' "$T/menu.out" | tr -d '\r')"
    has "the menu offers it as 32"                     "32) Update PHP" "$mo"
    has "and item 32 updates PHP"                      "PHP ${PHPV}: ${OLD%%-*} -> ${NEW%%-*}" "$mo"
    eq  "${TAG} is current after the menu"             "$NEW" "$(ver "$TAG")"
    printf '0\n' | LOMP_LANG=tr LOMP_MENU_LANG=tr script -qec "$L" "$T/menu-tr.out" >/dev/null 2>&1
    has "in Turkish too"                               "PHP'yi güncelle" "$(sed 's/\x1b\[[0-9;]*m//g' "$T/menu-tr.out" | tr -d '\r')"
  else bad "the menu" "the script command is missing"; fi
fi

sec "afterwards"
trap 'rm -rf "$T"' EXIT
cleanup
restore
eq    "${TAG} is the repository's"                     "$NEW" "$(ver "$TAG")"
eq    "and OpenLiteSpeed"                              "$(apt-cache policy openlitespeed | awk '/Candidate:/{print $2}')" "$(ver openlitespeed)"
check "OpenLiteSpeed runs"                             systemctl is-active --quiet lsws
nope  "no test home" test -e "/home/$D"

printf '\nRESULT: %s passed, %s failed (%s s)\n' "$PASS" "$FAIL" "$(( $(date +%s) - T0 ))"
[ "$FAIL" = 0 ]
