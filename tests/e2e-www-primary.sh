#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-www-primary.sh - DESTRUCTIVE end-to-end test of "add --www-primary" and of
#  what a failed "add" leaves behind.
#
#  A real WordPress site is added with --www --www-primary on a real OpenLiteSpeed: the
#  PHP probe has to ask www.<domain> (the bare name only redirects), WordPress has to
#  store that address, and an "add" that fails after PHP has run for the site has to
#  take the Linux user back although the site's lsphp is still running. Such a site is
#  renamed too: "rename" asks the same probe.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It adds and removes real sites (names under
#  .invalid, which no DNS answers for), reloads OpenLiteSpeed several times and leaves
#  the server as it found it.
#
#  Needs: an installed lomp server with MariaDB; network (it downloads WordPress).
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-www-primary.sh [tree to test, default: this checkout]
# =============================================================================
set -u
# the checks read what the commands print: in English, whatever this server speaks
export LOMP_LANG=en LOMP_MENU_LANG=en
if [[ "${LOMPSTACK_INTEGRATION:-}" != "yes" ]]; then
  printf '%s\n' "This test adds and removes real sites on this machine. Run it only on a" \
    "throwaway server:  LOMPSTACK_INTEGRATION=yes bash $0" >&2
  exit 2
fi
if [[ "$(id -u)" != 0 ]]; then printf 'Run it as root.\n' >&2; exit 2; fi
[[ -s /root/.server-setup/manifest.json ]] || { printf 'Cannot run here: lomp is not installed on this server (setup.sh install)\n' >&2; exit 2; }
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
mkdir -p "$T/src" "$T/shim"
cp -r "$SRC/setup.sh" "$SRC/lib" "$SRC/tests" "$T/src/"
L="bash $T/src/setup.sh"
# WWW: the site that is added. FAILW: the same options, and the WordPress download fails.
# FAILB: no www at all, and the download fails. NEW: what FAILW, added after all, is renamed to.
WWW=wwwp.lomp-e2e.invalid; FAILW=wwwpf.lomp-e2e.invalid; FAILB=wwwpb.lomp-e2e.invalid; NEW=wwwpn.lomp-e2e.invalid
ST=/root/.server-setup/domains
T0=$(date +%s)
ident() { printf '%s' "${1//[.-]/_}"; }

for s in mariadb lsws; do systemctl is-active --quiet "$s" || systemctl start "$s" >/dev/null 2>&1; done
for i in $(seq 1 60); do ss -ltn | grep -q ':80 ' && break; sleep 1; done

code()  { curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: $1" "http://127.0.0.1${2:-/}"; }
loc()   { curl -s -o /dev/null -w '%{redirect_url}' --max-time 15 -H "Host: $1" "http://127.0.0.1${2:-/}"; }
wp_as() { local d="$1" u=""; shift; u="$(jq -r .user "$ST/$d/domain.json")"; runuser -u "$u" -- env HOME="/home/$d" /usr/local/bin/wp --path="/home/$d/public_html" --skip-plugins --skip-themes "$@" 2>/dev/null; }
cleanup() {
  local d="" u=""
  for d in "$WWW" "$FAILW" "$FAILB" "$NEW"; do
    u="$(ident "$d")"
    [ -s "$ST/$d/redirect.json" ] && $L redirect del "$d" --yes >/dev/null 2>&1
    [ -s "$ST/$d/domain.json" ] && $L remove "$d" --yes >/dev/null 2>&1
    # what a release with the bug leaves behind, so that this test can be run against one
    if getent passwd "$u" >/dev/null 2>&1; then
      pkill -KILL -u "$u" >/dev/null 2>&1; sleep 1
      userdel "$u" >/dev/null 2>&1; groupdel "$u" >/dev/null 2>&1
    fi
    rm -rf "/var/backups/server-setup/$d" "$ST/$d" "/home/$d"
  done
  rm -rf /root/.server-setup/archive/domains/wwwp*.lomp-e2e.invalid.* /root/.server-setup/archive/vhosts/wwwp*.lomp-e2e.invalid.*
}
trap 'cleanup; rm -rf "$T"' EXIT

# In front of the real commands, for the test's own runs of lomp only:
#   curl     notes what each PHP probe was answered
#   runuser  fails the download of WordPress (wp core download, run as the site user) while
#            $T/no-wordpress exists
#   pkill, userdel   note what ran as the user at that moment, and what userdel said
cat >"$T/shim/curl" <<EOF
#!/bin/sh
case "\$*" in
  *ss-probe-*) printf '%s -> %s\n' "\$(printf '%s' "\$*" | grep -o 'Host: [^ ]*')" "\$(/usr/bin/curl -o /dev/null -w '%{http_code} %{redirect_url}' "\$@")" >>"$T/probe.log" ;;
esac
exec /usr/bin/curl "\$@"
EOF
cat >"$T/shim/runuser" <<EOF
#!/bin/sh
case "\$*" in *"core download"*) if [ -e "$T/no-wordpress" ]; then echo "e2e: no download today" >&2; exit 1; fi ;; esac
exec $(command -v runuser) "\$@"
EOF
for c in pkill userdel; do
  real="$(command -v "$c")"
  cat >"$T/shim/$c" <<EOF
#!/bin/sh
u=""; for a in "\$@"; do u="\$a"; done
{ echo "== $c \$*"; ps -u "\$u" -o pid=,etimes=,args= 2>/dev/null | sed 's/^/   runs: /'; } >>"$T/users.log"
$real "\$@" 2>>"$T/users.log"; rc=\$?
echo "   $c rc=\$rc" >>"$T/users.log"
exit \$rc
EOF
done
chmod +x "$T/shim"/*
: >"$T/probe.log"; : >"$T/users.log"
lomp() { PATH="$T/shim:$PATH" $L "$@"; }
gone() {   # label domain: nothing of a site that was rolled back is left
  local n="$1" d="$2" u=""; u="$(ident "$2")"
  nope "$n: no Linux user"            getent passwd "$u"
  nope "$n: no group"                 getent group "$u"
  nope "$n: nothing runs as it"       pgrep -u "$u"
  nope "$n: no home"                  test -e "/home/$d"
  nope "$n: no record"                test -e "$ST/$d"
  nope "$n: no virtual host"          test -e "/usr/local/lsws/conf/vhosts/$d"
  nope "$n: not in the configuration" grep -qF "$d" /usr/local/lsws/conf/httpd_config.conf
  eq   "$n: no database"              "" "$(mysql -N -e 'SHOW DATABASES' 2>/dev/null | grep -F "${u:0:5}" || true)"
}

sec "add --wordpress --no-ssl --www --www-primary"
cleanup
sites_before="$($L list --json 2>/dev/null | jq -r '[.[].domain] | sort | join(" ")')"
out="$(lomp add "$WWW" --wordpress --no-ssl --www --www-primary --email e2e@example.org --yes --no-color 2>&1)"; rc=$?
eq    "the site is added"                         0 "$rc"
[ "$rc" = 0 ] || { printf '%s\n' "$out" | tail -n 14; cat "$T/probe.log" "$T/users.log"; } | sed 's/^/   | /'
lacks "nothing failed on the way"                 "FAILED" "$out"
lacks "and nothing was rolled back"               "Rolling back" "$out"
has   "the PHP probe asked www, and PHP answered" "Host: www.$WWW -> 200" "$(cat "$T/probe.log")"
lacks "it did not ask the name that redirects"    "Host: $WWW ->" "$(cat "$T/probe.log")"
eq    "it is on record as www-primary"            "true true" "$(jq -r '"\(.www) \(.www_primary)"' "$ST/$WWW/domain.json" 2>/dev/null)"
eq    "the bare name redirects"                   "301" "$(code "$WWW" /x)"
eq    "to www"                                    "http://www.$WWW/x" "$(loc "$WWW" /x)"
eq    "www answers"                               "200" "$(code "www.$WWW" /wp-login.php)"
eq    "WordPress stores the www address as home"  "http://www.$WWW" "$(wp_as "$WWW" option get home)"
eq    "and as its own"                            "http://www.$WWW" "$(wp_as "$WWW" option get siteurl)"
page="$(curl -s --max-time 15 -H "Host: www.$WWW" http://127.0.0.1/)"
has   "the page a visitor gets links to www"      "http://www.$WWW/" "$page"
lacks "and nowhere to the bare name"              "//$WWW" "$page"
check "the site has its Linux user"               getent passwd "$(ident "$WWW")"

sec "the same add, and WordPress cannot be downloaded: it is rolled back"
: >"$T/no-wordpress"; : >"$T/probe.log"; : >"$T/users.log"
out="$(lomp add "$FAILW" --wordpress --no-ssl --www --www-primary --email e2e@example.org --yes --no-color 2>&1)"; rc=$?
eq    "the add fails"                             1 "$rc"
has   "at the download"                           "FAILED: WordPress download failed" "$out"
has   "PHP had run for the site by then"          "Host: www.$FAILW -> 200" "$(cat "$T/probe.log")"
has   "and its lsphp was still there when the rollback came" "lsphp" "$(cat "$T/users.log")"
has   "the rollback ran"                          "Rollback finished" "$out"
lacks "and every step of it worked"               "rollback step failed" "$out"
gone  "afterwards" "$FAILW"
sed 's/^/   | /' "$T/users.log"

sec "a site without www that fails the same way"
: >"$T/probe.log"; : >"$T/users.log"
out="$(lomp add "$FAILB" --wordpress --no-ssl --email e2e@example.org --yes --no-color 2>&1)"; rc=$?
eq    "the add fails"                             1 "$rc"
has   "PHP had run for the site by then"          "Host: $FAILB -> 200" "$(cat "$T/probe.log")"
has   "and its lsphp was still there when the rollback came" "lsphp" "$(cat "$T/users.log")"
lacks "every step of the rollback worked"         "rollback step failed" "$out"
gone  "afterwards" "$FAILB"
sed 's/^/   | /' "$T/users.log"
rm -f "$T/no-wordpress"

sec "the name of a failed add is free: the same command, and the download works"
out="$(lomp add "$FAILW" --wordpress --no-ssl --www --www-primary --email e2e@example.org --yes --no-color 2>&1)"; rc=$?
eq    "the site is added"                         0 "$rc"
eq    "WordPress under www"                       "http://www.$FAILW" "$(wp_as "$FAILW" option get home)"

sec "rename of a www-primary site"
: >"$T/probe.log"
out="$(lomp rename "$FAILW" "$NEW" --no-ssl --yes --no-color 2>&1)"; rc=$?
eq    "the site is renamed"                       0 "$rc"
[ "$rc" = 0 ] || { printf '%s\n' "$out" | tail -n 14; cat "$T/probe.log"; } | sed 's/^/   | /'
has   "the PHP probe asked www of the new name"   "Host: www.$NEW -> 200" "$(cat "$T/probe.log")"
lacks "and not the name that redirects"           "Host: $NEW ->" "$(cat "$T/probe.log")"
eq    "the bare new name redirects to its www"    "http://www.$NEW/x" "$(loc "$NEW" /x)"
eq    "WordPress has the new www address"         "http://www.$NEW" "$(wp_as "$NEW" option get home)"
eq    "the old name goes on to the new www"       "http://www.$NEW/x" "$(loc "$FAILW" /x)"
eq    "and so does its www"                       "http://www.$NEW/x" "$(loc "www.$FAILW" /x)"
page="$(curl -s --max-time 15 -H "Host: www.$NEW" http://127.0.0.1/)"
has   "the page a visitor gets links to the new www" "http://www.$NEW/" "$page"
lacks "and nowhere to the old name"               "//$FAILW" "$page"
lacks "nor to its www"                            "//www.$FAILW" "$page"
has   "the title was the old name, and that is said" "its title was the old name, $FAILW; it is $NEW now" "$out"
eq    "WordPress is called by the new name"       "$NEW" "$(wp_as "$NEW" option get blogname)"
lacks "the old name is nowhere in the page"       "$FAILW" "$page"
nope  "the old Linux user is gone"                getent passwd "$(ident "$FAILW")"

sec "remove"
: >"$T/users.log"
out="$(lomp remove "$WWW" --yes --no-color 2>&1)"; rc=$?
eq    "the www-primary site is removed"           0 "$rc"
nope  "its user with it"                          getent passwd "$(ident "$WWW")"

sec "afterwards"
cleanup
eq    "the server has the sites it had" "$sites_before" "$($L list --json 2>/dev/null | jq -r '[.[].domain] | sort | join(" ")')"
nope  "no test user is left" bash -c "getent passwd | grep -q '^wwwp.*_lomp_e2e_invalid:'"
nope  "no test home" bash -c "ls -d /home/wwwp*.lomp-e2e.invalid"
check "OpenLiteSpeed's configuration is valid" /usr/local/lsws/bin/openlitespeed -t

printf '\nRESULT: %s passed, %s failed (%s s)\n' "$PASS" "$FAIL" "$(( $(date +%s) - T0 ))"
[ "$FAIL" = 0 ]
