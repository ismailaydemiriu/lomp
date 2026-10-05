#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-rename-webmail.sh - DESTRUCTIVE end-to-end test of what the webmail keeps
#  for a mailbox when its site is renamed.
#
#  Two people sign in to a real Roundcube; one gets an address book entry, a setting and
#  a second identity. After the rename their users carry the new addresses and are the
#  same rows, the address book and the identities are there in the browser, and signing
#  in under the new address makes no new user.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It adds, renames and removes real sites
#  (names under .invalid, which no DNS answers for), reloads OpenLiteSpeed many times
#  and leaves the server as it found it.
#
#  Needs: an installed lomp server with mail and the webmail (mail webmail on <domain>
#  installs it), and MariaDB reachable as root over its socket.
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-rename-webmail.sh [tree to test, default: this checkout]
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
[[ -n "$(jq -r '.components.mail.postfix // empty' /root/.server-setup/manifest.json 2>/dev/null)" ]] || need "this server runs no mail (setup.sh install --with-mail --mail-hostname ...)"
[[ -s /var/www/lomp-webmail/current/public_html/index.php ]] || need "the webmail is not installed (setup.sh mail webmail on <a domain with mail>)"
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
# from a copy: the tree under test cannot change under the run, and the path has no spaces
T="$(mktemp -d /tmp/lomp-e2e.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src" "$T/shim"
cp -r "$SRC/setup.sh" "$SRC/lib" "$SRC/tests" "$T/src/"
L="bash $T/src/setup.sh"
W=rnwm.lomp-e2e.invalid; WN=rnwmnew.lomp-e2e.invalid
ST=/root/.server-setup/domains; MD=/root/.server-setup/mail/domains
DB=lomp_webmail
printf '%s' 'Passw0rd-e2e-Wm1' >"$T/pw1"; printf '%s' 'Passw0rd-e2e-Wm2' >"$T/pw2"; chmod 600 "$T"/pw*
T0=$(date +%s)

for s in mariadb lomp-redis-rspamd unbound rspamd dovecot postfix lsws; do systemctl is-active --quiet "$s" || systemctl start "$s" >/dev/null 2>&1; done
for i in $(seq 1 60); do ss -ltn | grep -q ':443 ' && ss -ltn | grep -q ':993 ' && break; sleep 1; done

sql() { mariadb -N -B -e "$1" 2>&1; }
# sign in to the webmail of a domain: prints "<http code> <where it sends the browser>"
wm_login() {   # domain user password-file
  local h="webmail.$1" jar="" tok=""
  jar="$T/jar.cur"; rm -f "$jar"
  tok="$(curl -sk -c "$jar" --max-time 30 --resolve "$h:443:127.0.0.1" "https://$h/?_task=login" | sed -n 's/.*name="_token" value="\([^"]*\)".*/\1/p' | head -n 1)"
  curl -sk -b "$jar" -c "$jar" --max-time 30 --resolve "$h:443:127.0.0.1" -o "$T/login.body" -w '%{http_code} %{redirect_url}' \
    --data "_task=login&_action=login&_timezone=Europe%2FIstanbul&_url=" --data-urlencode "_token=$tok" \
    --data-urlencode "_user=$2" --data-urlencode "_pass@$3" "https://$h/?_task=login"
}
# a page of the signed-in session
wm_get() {   # domain query
  curl -sk -b "$T/jar.cur" -c "$T/jar.cur" -L --max-time 30 --resolve "webmail.$1:443:127.0.0.1" "https://webmail.$1/?$2"
}
cleanup() {
  local d=""
  for d in "$W" "$WN"; do
    [ -s "$ST/$d/redirect.json" ] && $L redirect del "$d" --yes >/dev/null 2>&1
    [ -s "$MD/$d/domain.json" ] && $L mail domain del "$d" --yes --no-backup >/dev/null 2>&1
    [ -s "$ST/$d/domain.json" ] && $L remove "$d" --yes >/dev/null 2>&1
    rm -rf "/var/backups/server-setup/$d" "/etc/server-setup/ssl/$d" "$ST/$d"
    $L webmail forget "@$d" --yes >/dev/null 2>&1
  done
  rm -rf /root/.server-setup/archive/domains/rnwm*.lomp-e2e.invalid.* /root/.server-setup/archive/vhosts/rnwm*.lomp-e2e.invalid.* /root/.server-setup/archive/mail-domains/rnwm*.lomp-e2e.invalid.*
}
cleanup
users_before="$(sql "SELECT COUNT(*) FROM $DB.users WHERE username NOT LIKE '%@rnwm%'")"

sec "a site with mail and a webmail, and two people who use it"
out="$($L add "$W" --static --no-ssl --mail --email e2e@example.org --yes --no-color 2>&1)"
check "the site is added" test -s "$ST/$W/domain.json"
$L mail box add "info@$W" --yes --no-color <"$T/pw1" >/dev/null 2>&1
$L mail box add "sales@$W" --yes --no-color <"$T/pw2" >/dev/null 2>&1
$L mail box add "quiet@$W" --yes --no-color <"$T/pw2" >/dev/null 2>&1
out="$($L mail webmail on "$W" --yes --no-color 2>&1)"; rc=$?
eq "the webmail is switched on" "0" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 25
printf '      Roundcube release: %s\n' "$(basename "$(readlink -f /var/www/lomp-webmail/current)")"
r="$(wm_login "$W" "info@$W" "$T/pw1")"
has "info signs in to the webmail" "302" "$r"; has "and lands in the mail view" "_task=mail" "$r"
[[ "$r" == 302* ]] || { head -c 600 "$T/login.body"; echo; }
r="$(wm_login "$W" "sales@$W" "$T/pw2")"
has "sales signs in too" "_task=mail" "$r"
uid_info="$(sql "SELECT user_id FROM $DB.users WHERE username='info@$W'")"
uid_sales="$(sql "SELECT user_id FROM $DB.users WHERE username='sales@$W'")"
check "Roundcube made a user for each" test -n "$uid_info" -a -n "$uid_sales"
eq "the one who never signed in has none" "" "$(sql "SELECT user_id FROM $DB.users WHERE username='quiet@$W'")"
# what a person keeps there: an address book entry, a setting, a second identity
sql "INSERT INTO $DB.contacts (user_id, changed, del, name, email, firstname, surname, vcard, words) VALUES ($uid_info, NOW(), 0, 'Ayse Test', 'ayse@example.org', 'Ayse', 'Test', 'BEGIN:VCARD\nVERSION:3.0\nFN:Ayse Test\nEMAIL:ayse@example.org\nEND:VCARD', 'ayse test ayse@example.org')" >/dev/null
sql "UPDATE $DB.users SET preferences='a:1:{s:8:\"timezone\";s:15:\"Europe/Istanbul\";}' WHERE user_id=$uid_info" >/dev/null
sql "INSERT INTO $DB.identities (user_id, changed, del, standard, name, email) VALUES ($uid_info, NOW(), 0, 0, 'Info elsewhere', 'me@elsewhere.example')" >/dev/null
ident_before="$(sql "SELECT email FROM $DB.identities WHERE user_id=$uid_info AND del=0 ORDER BY email" | tr '\n' ' ')"
has "info has an identity under its address" "info@$W" "$ident_before"
printf '      identities of info before: %s\n' "$ident_before"

sec "the rename"
out="$($L rename "$W" "$WN" --yes --no-color 2>&1)"; rc=$?
eq "it succeeds" "0" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 50
has "the mailboxes moved" "info@$WN" "$($L mail box list --no-color 2>&1)"
printf '%s\n' "$out" | grep -i 'webmail' | sed 's/^/      | /' | head -n 6

sec "what the webmail kept follows the new address"
eq "the user row of info carries the new address, and is the same row" "$uid_info" "$(sql "SELECT user_id FROM $DB.users WHERE username='info@$WN'")"
eq "the one of sales too" "$uid_sales" "$(sql "SELECT user_id FROM $DB.users WHERE username='sales@$WN'")"
eq "no row is left under an old address" "0" "$(sql "SELECT COUNT(*) FROM $DB.users WHERE username LIKE '%@$W'")"
eq "and no second row was made" "2" "$(sql "SELECT COUNT(*) FROM $DB.users WHERE username LIKE '%@$WN'")"
eq "the address book entry is still that user's" "Ayse Test ayse@example.org" "$(sql "SELECT name, email FROM $DB.contacts WHERE user_id=$uid_info AND del=0" | tr '\t' ' ')"
has "the setting is still there" "Europe/Istanbul" "$(sql "SELECT preferences FROM $DB.users WHERE user_id=$uid_info")"
ident_after="$(sql "SELECT email FROM $DB.identities WHERE user_id=$uid_info AND del=0 ORDER BY email" | tr '\n' ' ')"
printf '      identities of info after: %s\n' "$ident_after"
has "the identity that was the old address is the new one" "info@$WN" "$ident_after"
has "an identity at another domain is left as it was" "me@elsewhere.example" "$ident_after"
check "the new domain has a webmail" bash -c "curl -sk --max-time 30 --resolve webmail.$WN:443:127.0.0.1 https://webmail.$WN/?_task=login | grep -q 'name=\"_token\"'"
r="$(wm_login "$WN" "info@$WN" "$T/pw1")"
has "info signs in at the new domain with the new address and the same password" "_task=mail" "$r"
[[ "$r" == 302* ]] || { head -c 600 "$T/login.body"; echo; }
eq "signing in made no new user: it is the row that was renamed" "$uid_info" "$(sql "SELECT user_id FROM $DB.users WHERE username='info@$WN'")"
eq "still exactly two users of the new domain" "2" "$(sql "SELECT COUNT(*) FROM $DB.users WHERE username LIKE '%@$WN'")"
rtok="$(wm_get "$WN" '_task=addressbook' | grep -o '"request_token":"[^"]*"' | head -n 1 | cut -d'"' -f4)"
printf '      request token found: %s\n' "$( [ -n "$rtok" ] && echo yes || echo no )"
page="$(curl -sk -b "$T/jar.cur" --max-time 30 --resolve "webmail.$WN:443:127.0.0.1" -H "X-Roundcube-Request: $rtok" -H 'X-Requested-With: XMLHttpRequest' "https://webmail.$WN/?_task=addressbook&_action=list&_source=0&_remote=1")"
has "the address book shown in the browser has the entry" "Ayse Test" "$page"
page="$(wm_get "$WN" '_task=settings&_action=identities')"
has "the identities shown in the browser name the new address" "info@$WN" "$page"
r="$(wm_login "$WN" "info@$W" "$T/pw1")"
lacks "the old address is no login any more" "_task=mail" "$r"
eq "and the failed attempt made no user" "0" "$(sql "SELECT COUNT(*) FROM $DB.users WHERE username LIKE '%@$W'")"
r="$(wm_login "$WN" "quiet@$WN" "$T/pw2")"
has "the mailbox that had never signed in does so now, as a new user" "_task=mail" "$r"
r="$(wm_login "$W" "sales@$WN" "$T/pw2")"
has "the old domain's webmail, still there for its mail domain, takes the new login too" "_task=mail" "$r"
eq "as the same user" "$uid_sales" "$(sql "SELECT user_id FROM $DB.users WHERE username='sales@$WN'")"

sec "afterwards"
cleanup
eq "no webmail user of the test domains is left" "0" "$(sql "SELECT COUNT(*) FROM $DB.users WHERE username LIKE '%@rnwm%'")"
eq "the other webmail users are the ones there were" "$users_before" "$(sql "SELECT COUNT(*) FROM $DB.users WHERE username NOT LIKE '%@rnwm%'")"
nope "no test mailbox is left" bash -c "$L mail box list --no-color 2>&1 | grep -q '@rnwm'"
nope "no test user account is left" bash -c "getent passwd | grep -q '^rnwm'"
check "OpenLiteSpeed's configuration is valid" /usr/local/lsws/bin/openlitespeed -t
printf '\nRESULT: %s passed, %s failed (%s s)\n' "$PASS" "$FAIL" "$(( $(date +%s) - T0 ))"
[ "$FAIL" = 0 ]
