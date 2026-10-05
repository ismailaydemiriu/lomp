#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-rename.sh - DESTRUCTIVE end-to-end test of "rename" and "redirect".
#
#  A real WordPress site is renamed on a real OpenLiteSpeed: the move, two injected
#  failures and the rollback, the 301s over HTTP and HTTPS, the redirect following a
#  certificate, a second rename, "redirect add/del", and the rename driven from the menu.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It adds, renames and removes real sites
#  (names under .invalid, which no DNS answers for), reloads OpenLiteSpeed many times
#  and leaves the server as it found it.
#
#  Needs: an installed lomp server with MariaDB; network (it downloads WordPress);
#  the "script" command for the menu part.
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-rename.sh [tree to test, default: this checkout]
# =============================================================================
set -u
# the checks read what the commands print, and the menu: in English, whatever this server speaks
export LOMP_LANG=en LOMP_MENU_LANG=en
if [[ "${LOMPSTACK_INTEGRATION:-}" != "yes" ]]; then
  printf '%s\n' "This test adds, renames and removes real sites on this machine. Run it only on a" \
    "throwaway server:  LOMPSTACK_INTEGRATION=yes bash $0" >&2
  exit 2
fi
if [[ "$(id -u)" != 0 ]]; then printf 'Run it as root.\n' >&2; exit 2; fi
need() {   # what is missing -> exit 2 with the reason
  printf 'Cannot run here: %s\n' "$1" >&2; exit 2
}
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
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src" "$T/shim"
cp -r "$SRC/setup.sh" "$SRC/lib" "$SRC/tests" "$T/src/"
L="bash $T/src/setup.sh"
OLD=rnold.lomp-e2e.invalid; NEW=rnnew.lomp-e2e.invalid; THIRD=rnthird.lomp-e2e.invalid; BACK=rnback.lomp-e2e.invalid; MENU=rnmenu.lomp-e2e.invalid
OI=rnold_lomp_e2e_invalid; NI=rnnew_lomp_e2e_invalid
ST=/root/.server-setup/domains
SSLD=/etc/server-setup/ssl
T0=$(date +%s)

for s in mariadb lsws; do systemctl is-active --quiet "$s" || systemctl start "$s" >/dev/null 2>&1; done
for i in $(seq 1 60); do ss -ltn | grep -q ':80 ' && ss -ltn | grep -q ':443 ' && break; sleep 1; done

code()  { curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: $1" "http://127.0.0.1${2:-/}"; }
loc()   { curl -s -o /dev/null -w '%{redirect_url}' --max-time 15 -H "Host: $1" "http://127.0.0.1${2:-/}"; }
scode() { curl -sk -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$1:443:127.0.0.1" "https://$1${2:-/}"; }
sloc()  { curl -sk -o /dev/null -w '%{redirect_url}' --max-time 15 --resolve "$1:443:127.0.0.1" "https://$1${2:-/}"; }
wp_as() { local d="$1" u=""; shift; u="$(jq -r .user "$ST/$d/domain.json")"; runuser -u "$u" -- env HOME="/home/$d" /usr/local/bin/wp --path="/home/$d/public_html" --skip-plugins --skip-themes "$@" 2>/dev/null; }
selfsigned() {   # name [san...]
  local n="$1" sans="" s=""
  for s in "$@"; do sans+="${sans:+,}DNS:${s}"; done
  mkdir -p "$SSLD/$n"; chmod 700 "$SSLD/$n"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=$n" -addext "subjectAltName=$sans" \
    -keyout "$SSLD/$n/privkey.pem" -out "$SSLD/$n/fullchain.pem" >/dev/null 2>&1
  chmod 600 "$SSLD/$n"/*.pem
}
rerender() { $L proxy add "$1" /zz-e2e/ 127.0.0.1:9 --yes >/dev/null 2>&1; $L proxy remove "$1" /zz-e2e/ --yes >/dev/null 2>&1; }
cleanup() {
  local d=""
  for d in "$THIRD" "$OLD" "$NEW" "$BACK" "$MENU"; do
    [ -s "$ST/$d/redirect.json" ] && $L redirect del "$d" --yes >/dev/null 2>&1
  done
  for d in "$OLD" "$NEW" "$BACK" "$MENU"; do
    [ -s "$ST/$d/domain.json" ] && $L remove "$d" --yes >/dev/null 2>&1
    rm -rf "/var/backups/server-setup/$d" "$SSLD/$d" "$ST/$d"
  done
  rm -rf "$SSLD/$THIRD" /root/.server-setup/archive/domains/rn*.lomp-e2e.invalid.* /root/.server-setup/archive/vhosts/rn*.lomp-e2e.invalid.*
}

sec "a WordPress site with HTTPS, as it would be before the rename"
cleanup
sites_before="$($L list --json 2>/dev/null | jq -r '[.[].domain] | sort | join(" ")')"
out="$($L add "$OLD" --wordpress --www --no-ssl --email e2e@example.org --yes --no-color 2>&1)"
check "the site is added" test -s "$ST/$OLD/domain.json"
[ -s "$ST/$OLD/domain.json" ] || { printf '%s\n' "$out" | tail -n 30; echo "RESULT: cannot go on"; exit 1; }
uid_before="$(id -u "$OI")"
selfsigned "$OLD" "$OLD" "www.$OLD"
jq '.ssl.enabled = true | .ssl.wanted = true' "$ST/$OLD/domain.json" >"$T/dj" && cat "$T/dj" >"$ST/$OLD/domain.json"
rerender "$OLD"
wp_as "$OLD" search-replace "http://$OLD" "https://$OLD" --all-tables-with-prefix >/dev/null
wp_as "$OLD" post create --post_status=publish --post_title=e2e-links \
  --post_content="see https://www.$OLD/page and https://$OLD/other, write to info@$OLD" >/dev/null
wp_as "$OLD" option update e2e_paths "{\"dir\":\"/home/$OLD/public_html/wp-content/uploads\",\"url\":\"https:\\/\\/$OLD\\/x\"}" --format=json >/dev/null
runuser -u "$OI" -- sh -c "printf '%s\n' \"define('E2E_DIR', '/home/$OLD/public_html/x');\" >>/home/$OLD/public_html/wp-config.php"
runuser -u "$OI" -- sh -c "printf '<?php echo get_current_user(), \" \", __DIR__;' >/home/$OLD/public_html/who.php"
eq "WordPress answers under the old name" "https://$OLD" "$(wp_as "$OLD" option get home)"
eq "over HTTPS" "200" "$(scode "$OLD" /wp-login.php)"
has "the scheduled events run as its user" " $OI cd /home/$OLD/public_html" "$(grep "wpcron:$OLD" /etc/cron.d/server-setup)"
dbname="$(jq -r .db.name "$ST/$OLD/domain.json")"

sec "what is refused, and a dry run"
out="$($L rename "$OLD" "$OLD" --yes --no-color 2>&1)"; has "to itself" "called that already" "$out"
out="$($L rename "$OLD" "www.$NEW" --yes --no-color 2>&1)"; has "to a www name" "bare name" "$out"
out="$($L rename "$OLD" "../x" --yes --no-color 2>&1)"; has "to something that is no name" "Invalid domain name" "$out"
first="$(printf '%s\n' $sites_before | grep -v '^rn' | head -n 1)"
if [ -n "$first" ]; then out="$($L rename "$OLD" "$first" --yes --no-color 2>&1)"; has "to a site that exists" "is a site of this server already" "$out"; fi
out="$($L rename nosuch.lomp-e2e.invalid "$NEW" --yes --no-color 2>&1)"; has "a site that is not there" "not registered" "$out"
out="$($L rename "$OLD" "$NEW" --dry-run --no-color 2>&1)"
has "the dry run says what it would do" "becomes /home/$NEW" "$out"
has "and that it did not" "nothing was changed" "$out"
check "the site is where it was" test -d "/home/$OLD/public_html"
nope "nothing of the new name exists" test -e "$ST/$NEW"
eq "and still answers" "200" "$(scode "$OLD" /wp-login.php)"

sec "a rename that fails half way puts the site back"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "-d" ] && exit 1; done\nexec /usr/sbin/usermod "$@"\n' >"$T/shim/usermod"; chmod +x "$T/shim/usermod"
out="$(PATH="$T/shim:$PATH" $L rename "$OLD" "$NEW" --yes --no-color 2>&1)"; rc=$?
eq "it fails" "1" "$rc"
has "and says it rolls back" "Rolling back" "$out"
check "the old user is back" id -u "$OI"
nope "the new one is gone" id -u "$NI"
check "the home is back" test -d "/home/$OLD/public_html"
nope "no home under the new name" test -e "/home/$NEW"
nope "no state under the new name" test -e "$ST/$NEW"
nope "no virtual host directory under the new name" test -e "/usr/local/lsws/conf/vhosts/$NEW"
eq "the passwd entry points at the old home" "/home/$OLD" "$(getent passwd "$OI" | cut -d: -f6)"
eq "the site answers again, over HTTPS" "200" "$(scode "$OLD" /wp-login.php)"
has "PHP runs as the old user" "$OI /home/$OLD/public_html" "$(curl -sk --resolve "$OLD:443:127.0.0.1" "https://$OLD/who.php")"
has "the scheduled events are back" " $OI cd /home/$OLD/public_html" "$(grep "wpcron:$OLD" /etc/cron.d/server-setup)"
check "the log directory is back" test -d "/var/log/lomp-sites/$OLD"
[ "$FAIL" = 0 ] || { printf '%s\n' "$out" | tail -n 40; }
# later: the site has moved and its new virtual host is loaded, but it does not answer
rm -f "$T/shim/usermod"
printf '#!/bin/sh\ncase "$*" in *"Host: %s"*) printf 000; exit 7 ;; esac\nexec /usr/bin/curl "$@"\n' "$NEW" >"$T/shim/curl"; chmod +x "$T/shim/curl"
out="$(PATH="$T/shim:$PATH" $L rename "$OLD" "$NEW" --yes --no-color 2>&1)"; rc=$?
rm -f "$T/shim/curl"
eq "a site that does not answer under its new name: the rename fails" "1" "$rc"
has "at the smoke test" "$NEW does not answer" "$out"
check "the old user is back again" id -u "$OI"
nope "the new one is gone again" id -u "$NI"
nope "no home under the new name" test -e "/home/$NEW"
nope "no state under the new name" test -e "$ST/$NEW"
nope "no virtual host directory under the new name" test -e "/usr/local/lsws/conf/vhosts/$NEW"
lacks "and none in the configuration" "$NEW" "$(cat /usr/local/lsws/conf/httpd_config.conf)"
has "the old one is" "virtualhost $OLD {" "$(cat /usr/local/lsws/conf/httpd_config.conf)"
check "which OpenLiteSpeed accepts" /usr/local/lsws/bin/openlitespeed -t
eq "the site answers again, over HTTPS" "200" "$(scode "$OLD" /wp-login.php)"
has "PHP runs as the old user" "$OI /home/$OLD/public_html" "$(curl -sk --resolve "$OLD:443:127.0.0.1" "https://$OLD/who.php")"
eq "WordPress was not touched" "https://$OLD" "$(wp_as "$OLD" option get home)"
nope "the old name was not made a redirect" test -e "$ST/$OLD/redirect.json"
check "its certificate note is still there" test -e "$ST/$OLD/domain.json"

sec "the rename"
mkdir -p /var/www/acme/.well-known/acme-challenge; echo e2e-token >/var/www/acme/.well-known/acme-challenge/e2e-rn
out="$($L rename "$OLD" "$NEW" --yes --no-color 2>&1)"; rc=$?
printf '%s\n' "$out" >"$T/rename.out"
eq "it succeeds" "0" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 40
has "it says so" "Renamed $OLD to $NEW" "$out"
check "the home has the new name" test -d "/home/$NEW/public_html"
nope "and the old one is gone" test -e "/home/$OLD"
eq "the user has the new name and the same uid" "$uid_before" "$(id -u "$NI" 2>/dev/null)"
nope "the old user name is gone" id -u "$OI"
eq "its files are still its" "$NI:$NI" "$(stat -c %U:%G "/home/$NEW/public_html/wp-config.php")"
eq "its passwd entry names the new home" "/home/$NEW" "$(getent passwd "$NI" | cut -d: -f6)"
eq "the state says who it is" "$NEW $NI /home/$NEW $OLD" "$(jq -r '"\(.domain) \(.user) \(.home) \(.renamed_from)"' "$ST/$NEW/domain.json")"
eq "the database kept its name" "$dbname" "$(jq -r .db.name "$ST/$NEW/domain.json")"
eq "the old name's state is a redirect and nothing else" "redirect.json" "$(ls "$ST/$OLD" | tr '\n' ' ' | sed 's/ $//')"
eq "the site answers under the new name" "200" "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $NEW" -H 'X-Forwarded-Proto: https' http://127.0.0.1/wp-login.php)"
has "PHP runs as the renamed user, in the new home" "$NI /home/$NEW/public_html" "$(curl -s -H "Host: $NEW" -H 'X-Forwarded-Proto: https' http://127.0.0.1/who.php)"
eq "WordPress knows its new address" "https://$NEW" "$(wp_as "$NEW" option get home)"
eq "and its site address" "https://$NEW" "$(wp_as "$NEW" option get siteurl)"
post="$(wp_as "$NEW" post list --post_type=post --name=e2e-links --field=post_content)"
has "links in a post follow" "https://www.$NEW/page and https://$NEW/other" "$post"
has "a mail address does not" "info@$OLD" "$post"
opt="$(wp_as "$NEW" option get e2e_paths --format=json)"
has "a path inside an option follows" "/home\\/$NEW\\/public_html" "$opt"
has "and an escaped address" "$NEW\\/x" "$opt"
lacks "nothing of the old name is left in it" "$OLD" "$opt"
cron="$(grep wpcron /etc/cron.d/server-setup | grep rn)"
has "the scheduled events run as the new user in the new home" " $NI cd /home/$NEW/public_html" "$cron"
lacks "and no line for the old name" "$OLD" "$cron"
check "the logs moved" test -f "/var/log/lomp-sites/$NEW/access.log"
nope "and left nothing behind" test -e "/var/log/lomp-sites/$OLD"
eq "logs/ in the home leads to them" "/var/log/lomp-sites/$NEW" "$(readlink "/home/$NEW/logs")"
lr="$(cat /etc/logrotate.d/ols-sites)"; has "logrotate knows the new name" "/var/log/lomp-sites/$NEW/" "$lr"; lacks "not the old one" "/$OLD/" "$lr"
check "PHP's own ini directory has the new name" test -d "/etc/lompstack/php/$NEW"
nope "the old one is gone" test -e "/etc/lompstack/php/$OLD"
has "open_basedir names the new home" "/home/$NEW/" "$(cat /etc/lompstack/php/$NEW/*.ini 2>/dev/null)"
check "the backups followed, the safety one among them" bash -c "ls /var/backups/server-setup/$NEW/$OLD-pre-rename-*.tar.gz"
has "the file that still names the old home is pointed out" "/home/$NEW/public_html/wp-config.php" "$out"
has "the missing certificate is said" "renew-ssl $NEW" "$out"

sec "the old name"
eq "answers with a 301" "301" "$(code "$OLD" /)"
eq "to the same path and query on the new name (http: it has no certificate yet)" "http://$NEW/some/page?x=1&y=2" "$(loc "$OLD" '/some/page?x=1&y=2')"
eq "www too" "http://$NEW/a" "$(loc "www.$OLD" /a)"
eq "and over HTTPS" "301" "$(scode "$OLD" /a)"
eq "to the same place" "http://$NEW/a" "$(sloc "$OLD" /a)"
has "under its own certificate" "CN = $OLD" "$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$OLD" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed 's/CN=/CN = /; s/CN  =/CN =/')"
eq "the ACME challenge is still served, not redirected" "e2e-token" "$(curl -s -H "Host: $OLD" http://127.0.0.1/.well-known/acme-challenge/e2e-rn)"
lst="$($L list --no-color 2>&1)"
has "list shows the site" "$NEW" "$lst"
has "and the redirect" "-> $NEW" "$lst"
eq "list --json has only sites" "0" "$($L list --json | jq "[.[] | select(.domain == \"$OLD\")] | length")"
has "redirect list shows it" "$OLD (+www)" "$($L redirect list --no-color 2>&1)"
out="$($L add "$OLD" --no-ssl --yes --no-color 2>&1)"; has "a site of that name is refused" "only redirects to $NEW" "$out"
nope "and nothing was made of it" test -e "/home/$OLD"
out="$($L redirect add "$NEW" "$OLD" --yes --no-color 2>&1)"; has "a site cannot become a redirect" "is a site of this server" "$out"
sslst="$($L ssl status --no-color 2>&1)"
has "ssl status lists the redirect's certificate" "Redirects" "$sslst"
has "under its name" "  $OLD " "$(printf '%s\n' "$sslst" | sed -n '/Redirects/,/AUTOMATIC/p')"
doc="$($L doctor --no-color 2>&1 | grep -E "$OLD|$NEW")"
lacks "doctor has no failure for either" "FAIL" "$doc"
has "doctor checks the redirect" "redirect $OLD" "$doc"
lacks "and does not call it unmanaged" "unmanaged vhost $OLD" "$doc"

sec "the new name gets its certificate: the redirect follows"
selfsigned "$NEW" "$NEW" "www.$NEW"
jq '.ssl.enabled = true' "$ST/$NEW/domain.json" >"$T/dj" && cat "$T/dj" >"$ST/$NEW/domain.json"
rerender "$NEW"
eq "the site answers over HTTPS" "200" "$(scode "$NEW" /wp-login.php)"
eq "the old name now sends to https" "https://$NEW/a?b=c" "$(loc "$OLD" '/a?b=c')"
eq "over HTTPS as well" "https://$NEW/a" "$(sloc "www.$OLD" /a)"

sec "a redirect of its own, and a second rename"
out="$($L redirect add "$THIRD" "$OLD" --yes --no-color 2>&1)"; has "a redirect to a redirect is refused" "itself only a redirect" "$out"
out="$($L redirect add "www.$THIRD" "$NEW" --yes --no-color 2>&1)"; has "a www name is refused" "--www" "$out"
out="$($L redirect add "$THIRD" "$NEW" --www --yes --no-color 2>&1)"; rc=$?
eq "redirect add succeeds without a certificate" "0" "$rc"
has "and says why there is none" "No certificate for $THIRD" "$out"
eq "it redirects" "https://$NEW/p" "$(loc "$THIRD" /p)"
eq "www too" "https://$NEW/p" "$(loc "www.$THIRD" /p)"
out="$($L rename "$NEW" "$BACK" --yes --no-redirect --no-color 2>&1)"; rc=$?
eq "the second rename succeeds" "0" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 30
nope "without a redirect: the name before has no state left" test -e "$ST/$NEW"
nope "nor a certificate" test -e "$SSLD/$NEW"
eq "and is answered like any unknown name" "403" "$(code "$NEW" /)"
eq "the name that led to it leads to the new one" "$BACK" "$(jq -r .target "$ST/$THIRD/redirect.json")"
eq "in the answer too" "http://$BACK/p" "$(loc "$THIRD" /p)"
eq "the first redirect as well" "http://$BACK/p" "$(loc "$OLD" /p)"
eq "WordPress followed again" "https://$BACK" "$(wp_as "$BACK" option get home)"
has "PHP still runs, as the third user name" "rnback_lomp_e2e_invalid /home/$BACK/public_html" "$(curl -s -H "Host: $BACK" -H 'X-Forwarded-Proto: https' http://127.0.0.1/who.php)"

sec "redirect del"
out="$($L redirect del "$THIRD" --yes --no-color 2>&1)"; rc=$?
eq "it succeeds" "0" "$rc"
nope "its state is gone" test -e "$ST/$THIRD"
nope "its virtual host directory too" test -e "/usr/local/lsws/conf/vhosts/$THIRD"
eq "the name is answered like any unknown one" "403" "$(code "$THIRD" /)"
out="$($L redirect del "$THIRD" --yes --no-color 2>&1)"; has "a second time there is nothing" "No redirect called" "$out"
out="$($L redirect del "../$BACK" --yes --no-color 2>&1)"; has "a path is no name" "Invalid domain name" "$out"
check "and the site it pointed at is untouched" test -s "$ST/$BACK/domain.json"

sec "from the menu"
idx="$(ls -d $ST/*/domain.json | xargs -n1 dirname | xargs -n1 basename | grep -n "^$BACK\$" | cut -d: -f1)"
printf '26\n%s\n%s\ny\ny\n\n0\n' "$idx" "$MENU" | script -qec "bash $T/src/setup.sh" "$T/menu.out" >/dev/null 2>&1
mo="$(sed 's/\x1b\[[0-9;]*m//g' "$T/menu.out" | tr -d '\r')"
has "the menu has the entry" "26) Rename a site" "$mo"
has "it ran the command" "rename $BACK $MENU" "$mo"
has "which renamed the site" "Renamed $BACK to $MENU" "$mo"
check "the site has the name typed in the menu" test -s "$ST/$MENU/domain.json"
eq "and the name before redirects to it" "http://$MENU/x" "$(loc "$BACK" /x)"
printf '27\n1\n\n0\n' | script -qec "bash $T/src/setup.sh" "$T/menu2.out" >/dev/null 2>&1
mo="$(sed 's/\x1b\[[0-9;]*m//g' "$T/menu2.out" | tr -d '\r')"
has "the redirects are listed from the menu" "$BACK" "$mo"

sec "afterwards"
cleanup
eq "the server has the sites it had" "$sites_before" "$($L list --json 2>/dev/null | jq -r '[.[].domain] | sort | join(" ")')"
nope "no test user is left" bash -c "getent passwd | grep -q '^rn.*_lomp_e2e_invalid:'"
nope "no test home" bash -c "ls -d /home/rn*.lomp-e2e.invalid"
check "OpenLiteSpeed's configuration is valid" /usr/local/lsws/bin/openlitespeed -t
rm -f /var/www/acme/.well-known/acme-challenge/e2e-rn

sed 's/^/   | /' "$T/rename.out"
printf '\nRESULT: %s passed, %s failed (%s s)\n' "$PASS" "$FAIL" "$(( $(date +%s) - T0 ))"
[ "$FAIL" = 0 ]
