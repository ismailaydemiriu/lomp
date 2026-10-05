#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-rename-app-mail.sh - DESTRUCTIVE end-to-end test of "rename" for a site
#  with a Node.js application and for sites with mail.
#
#  A PM2 application with a build step, a scheduled job and a variable is renamed and,
#  after an injected failure, put back. A site with two mailboxes and an alias is renamed:
#  same passwords under the new addresses, mail to the old ones delivered into the new
#  mailboxes; and once more with --keep-mail.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It adds, renames and removes real sites
#  (names under .invalid, which no DNS answers for), reloads OpenLiteSpeed many times
#  and leaves the server as it found it.
#
#  Needs: an installed lomp server with mail (install --with-mail), Node.js and PM2
#  (add --node installs them), and swaks (apt-get install swaks libnet-ssleay-perl).
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-rename-app-mail.sh [tree to test, default: this checkout]
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
command -v swaks >/dev/null 2>&1 || need "swaks is missing (apt-get install swaks libnet-ssleay-perl)"
command -v doveadm >/dev/null 2>&1 || need "doveadm is missing"
PASS=0; FAIL=0
ok()    { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; if [ -n "${2:-}" ]; then printf '        %s\n' "${2:0:700}"; fi; }
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
APP=rnapp.lomp-e2e.invalid; APPN=rnappnew.lomp-e2e.invalid; AI=rnapp_lomp_e2e_invalid; ANI=rnappnew_lomp_e2e_invalid
ML=rnmail.lomp-e2e.invalid; MLN=rnmailnew.lomp-e2e.invalid; MK=rnkeep.lomp-e2e.invalid; MKN=rnkeepnew.lomp-e2e.invalid
ST=/root/.server-setup/domains
MD=/root/.server-setup/mail/domains
T0=$(date +%s)

for s in mariadb lomp-redis-rspamd unbound rspamd dovecot postfix lsws; do systemctl is-active --quiet "$s" || systemctl start "$s" >/dev/null 2>&1; done
for i in $(seq 1 60); do ss -ltn | grep -q ':80 ' && ss -ltn | grep -q ':443 ' && break; sleep 1; done

code()  { curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: $1" "http://127.0.0.1${2:-/}"; }
body()  { curl -s --max-time 15 -H "Host: $1" "http://127.0.0.1${2:-/}"; }
loc()   { curl -s -o /dev/null -w '%{redirect_url}' --max-time 15 -H "Host: $1" "http://127.0.0.1${2:-/}"; }
wait_body() {   # host needle seconds
  local i=0 b=""
  for i in $(seq 1 "$3"); do b="$(body "$1")"; [[ "$b" == *"$2"* ]] && { printf '%s' "$b"; return 0; }; sleep 1; done
  printf '%s' "$b"; return 1
}
cleanup() {
  local d="" u=""
  for d in "$APP" "$APPN" "$ML" "$MLN" "$MK" "$MKN"; do
    [ -s "$ST/$d/redirect.json" ] && $L redirect del "$d" --yes >/dev/null 2>&1
    [ -s "$MD/$d/domain.json" ] && $L mail domain del "$d" --yes --no-backup >/dev/null 2>&1
    [ -s "$ST/$d/domain.json" ] && $L remove "$d" --yes >/dev/null 2>&1
    rm -rf "/var/backups/server-setup/$d" "/etc/server-setup/ssl/$d" "$ST/$d"
  done
  rm -rf /root/.server-setup/archive/domains/rn*.lomp-e2e.invalid.* /root/.server-setup/archive/vhosts/rn*.lomp-e2e.invalid.* /root/.server-setup/archive/mail-domains/rn*.lomp-e2e.invalid.*
}

cleanup
sites_before="$($L list --json 2>/dev/null | jq -r '[.[].domain | select(startswith("rn") | not)] | sort | join(" ")')"

sec "a Node.js site: an application, a scheduled job, a variable"
out="$($L add "$APP" --node --no-ssl --email e2e@example.org --yes --no-color 2>&1)"
check "the site is added" test -s "$ST/$APP/domain.json"
[ -s "$ST/$APP/domain.json" ] || { printf '%s\n' "$out" | tail -n 30; echo "RESULT: cannot go on"; exit 1; }
port="$(jq -r .app.port "$ST/$APP/domain.json")"
runuser -u "$AI" -- sh -c "cd /home/$APP/app && cat >package.json" <<'EOF'
{ "name": "e2e", "version": "1.0.0", "scripts": { "start": "node server.js", "build": "node -e \"require('fs').writeFileSync('built.txt', process.cwd())\"" } }
EOF
runuser -u "$AI" -- sh -c "cd /home/$APP/app && cat >server.js" <<'EOF'
const http = require('http'), os = require('os'), fs = require('fs');
http.createServer((q, r) => r.end('cwd=' + process.cwd() + ' user=' + os.userInfo().username + ' built=' + fs.readFileSync('built.txt', 'utf8') + ' url=' + (process.env.APP_URL || ''))).listen(process.env.PORT, '127.0.0.1');
EOF
runuser -u "$AI" -- sh -c "cd /home/$APP/app && printf 'console.log(process.cwd())\n' >tick.js"
printf 'https://%s' "$APP" | $L app env "$APP" set APP_URL --yes --no-color >/dev/null 2>&1
$L app worker "$APP" add tick --cron "*/5 * * * *" --start "node tick.js" --yes --no-color >/dev/null 2>&1
out="$($L app deploy "$APP" --yes --no-color 2>&1)"
b="$(wait_body "$APP" "cwd=/home/$APP/app" 40)"
has "the application answers through the site" "cwd=/home/$APP/app user=$AI built=/home/$APP/app url=https://$APP" "$b"
[[ "$b" == *"cwd="* ]] || printf '%s\n' "$out" | tail -n 20
check "under its PM2 unit" systemctl is-active --quiet "pm2-$AI"
has "its job is in cron" "$AI /bin/bash /home/$APP/.pm2/jobs/tick.sh" "$(grep "job:$APP:tick" /etc/cron.d/server-setup)"

sec "a rename that fails after the move puts the application back"
printf '#!/bin/sh\ncase "$*" in *"Host: %s"*) printf 000; exit 7 ;; esac\nexec /usr/bin/curl "$@"\n' "$APPN" >"$T/shim/curl"; chmod +x "$T/shim/curl"
out="$(PATH="$T/shim:$PATH" $L rename "$APP" "$APPN" --yes --no-color 2>&1)"; rc=$?
rm -f "$T/shim/curl"
eq "it fails" "1" "$rc"
has "at the smoke test" "$APPN does not answer" "$out"
check "the old user is back" id -u "$AI"
nope "nothing is left of the new name" bash -c "test -e /home/$APPN || test -e $ST/$APPN || test -e /etc/systemd/system/pm2-$ANI.service || id -u $ANI"
check "its PM2 unit runs again" systemctl is-active --quiet "pm2-$AI"
b="$(wait_body "$APP" "cwd=/home/$APP/app" 40)"
has "and the application answers as before" "cwd=/home/$APP/app user=$AI" "$b"
has "its job is back in cron" "$AI /bin/bash /home/$APP/.pm2/jobs/tick.sh" "$(grep "job:$APP:tick" /etc/cron.d/server-setup)"
[ "$FAIL" = 0 ] || printf '%s\n' "$out" | tail -n 40

sec "the rename of a Node.js site"
runuser -u "$AI" -- sh -c ": >/home/$APP/.pm2/dump.pm2"
out="$($L rename "$APP" "$APPN" --yes --no-color 2>&1)"; rc=$?
printf '%s\n' "$out" >"$T/rename-app.out"
eq "it succeeds" "0" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 40
check "the PM2 unit of the new user runs" systemctl is-active --quiet "pm2-$ANI"
nope "the unit of the old user is gone" test -e "/etc/systemd/system/pm2-$AI.service"
nope "and not known to systemd as running" systemctl is-active --quiet "pm2-$AI"
b="$(wait_body "$APPN" "cwd=/home/$APPN/app" 40)"
has "the application runs in the new home as the new user, built there" "cwd=/home/$APPN/app user=$ANI built=/home/$APPN/app" "$b"
eco="$(cat "/home/$APPN/.pm2/lomp.ecosystem.json" 2>/dev/null)"
has "its ecosystem names the new home" "/home/$APPN/app" "$eco"
lacks "and not the old one" "/home/$APP/" "$eco"
nope "PM2's saved list is gone" test -e "/home/$APPN/.pm2/dump.pm2"
cron="$(grep 'job:rnapp' /etc/cron.d/server-setup)"
has "the job runs as the new user from the new home" "$ANI /bin/bash /home/$APPN/.pm2/jobs/tick.sh # server-setup:job:$APPN:tick" "$cron"
lacks "no job line of the old name" "job:$APP:" "$cron"
has "the job script names the new home" "cd \"/home/$APPN/app\"" "$(cat "/home/$APPN/.pm2/jobs/tick.sh" 2>/dev/null)"
eq "the port is the one it had" "$port" "$(jq -r .app.port "$ST/$APPN/domain.json")"
has "app status knows it under the new name" "$APPN" "$($L app status "$APPN" --no-color 2>&1)"
has "the variable that still names the old domain is pointed out" "A variable of the application still names $APP" "$out"
eq "the old name redirects" "http://$APPN/x?y=1" "$(loc "$APP" '/x?y=1')"
out2="$($L app worker "$APPN" run tick --yes --no-color 2>&1)"; rc=$?
eq "the job can be run by hand under the new name" "0" "$rc"
has "and ran in the new home" "/home/$APPN/app" "$(tail -n 5 "/home/$APPN/.pm2/logs/tick-job.log" 2>/dev/null)"
doc="$($L doctor --no-color 2>&1 | grep -E "$APP|$APPN")"
lacks "doctor has no failure for either name" "FAIL" "$doc"

deliver() {   # to subject maildir -> 0 when a message with that subject is in the maildir
  local f="" i=0
  swaks --server 127.0.0.1 --port 25 --helo client.example.org --from someone@example.org --to "$1" --header "Subject: $2" --body hello >/dev/null 2>&1
  for i in $(seq 1 40); do
    f="$(grep -rl "^Subject: $2" "$3" 2>/dev/null | grep -E '/(new|cur)/' | head -n 1)"
    [ -n "$f" ] && return 0
    postqueue -f >/dev/null 2>&1; sleep 1
  done
  return 1
}
PW1='Passw0rd-e2e-Rn1'; PW2='Passw0rd-e2e-Rn2'

sec "a site with mail: the mailboxes follow it"
out="$($L add "$ML" --static --no-ssl --mail --email e2e@example.org --yes --no-color 2>&1)"
check "the site is added" test -s "$ST/$ML/domain.json"
printf '%s' "$PW1" | $L mail box add "info@$ML" --yes --no-color >/dev/null 2>&1
printf '%s' "$PW2" | $L mail box add "sales@$ML" --quota 2G --yes --no-color >/dev/null 2>&1
$L mail alias add "team@$ML" "info@$ML,sales@$ML" --yes --no-color >/dev/null 2>&1
has "it has two mailboxes" "sales@$ML" "$($L mail box list --no-color 2>&1 | grep -c "@$ML" | sed "s/^2\$/sales@$ML/")"
if deliver "info@$ML" e2e-before "/var/vmail/$ML/info/Maildir"; then ok "a message is in the mailbox before the rename"; else bad "a message is in the mailbox before the rename" "$(postqueue -p 2>&1 | tail -n 4)"; fi
sel="$(jq -r '.mail.selector' "$ST/$ML/domain.json")"
out="$($L rename "$ML" "$MLN" --yes --no-color 2>&1)"; rc=$?
printf '%s\n' "$out" >"$T/rename-mail.out"
eq "the rename succeeds" "0" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 50
boxes="$($L mail box list --no-color 2>&1)"
has "the mailbox is one of the new domain" "info@$MLN" "$boxes"
has "both are" "sales@$MLN" "$boxes"
lacks "none is left at the old domain" "@$ML " "$boxes"
has "the quota came along" "2G" "$(printf '%s\n' "$boxes" | grep "sales@$MLN")"
check "the same password signs in under the new address" doveadm auth test "info@$MLN" "$PW1"
check "for the second mailbox too" doveadm auth test "sales@$MLN" "$PW2"
nope "the old address is no login any more" doveadm auth test "info@$ML" "$PW1"
check "the mail that was there moved with the mailbox" bash -c "grep -rlq '^Subject: e2e-before' /var/vmail/$MLN/info/Maildir"
nope "nothing is left of the old mailbox directory" test -e "/var/vmail/$ML/info"
if deliver "info@$ML" e2e-to-old "/var/vmail/$MLN/info/Maildir"; then ok "mail to the old address arrives in the new mailbox"; else bad "mail to the old address arrives in the new mailbox" "$(postqueue -p 2>&1 | tail -n 4)"; fi
if deliver "info@$MLN" e2e-to-new "/var/vmail/$MLN/info/Maildir"; then ok "mail to the new address arrives"; else bad "mail to the new address arrives" "$(postqueue -p 2>&1 | tail -n 4)"; fi
if deliver "team@$ML" e2e-team-old "/var/vmail/$MLN/sales/Maildir"; then ok "mail to an old alias reaches the mailboxes behind it"; else bad "mail to an old alias reaches the mailboxes behind it" "$(postqueue -p 2>&1 | tail -n 4)"; fi
if deliver "team@$MLN" e2e-team-new "/var/vmail/$MLN/info/Maildir"; then ok "the alias exists at the new domain"; else bad "the alias exists at the new domain" "$(postqueue -p 2>&1 | tail -n 4)"; fi
nope "nothing was delivered into a mailbox made afresh under the old name" bash -c "ls -d /var/vmail/$ML/*/Maildir"
al="$($L mail alias list --no-color 2>&1)"
has "the old address is listed as an alias of the new one" "info@$MLN" "$(printf '%s\n' "$al" | grep "^ *info@$ML")"
eq "the old domain is still a mail domain, with the key its mail was signed with" "true $sel" "$(jq -r '"\(.mail.enabled) \(.mail.selector)"' "$MD/$ML/domain.json" 2>/dev/null)"
eq "the new one has mail, in the site's state" "true" "$(jq -r '.mail.enabled' "$ST/$MLN/domain.json")"
check "and a DKIM key of its own" bash -c "ls /var/lib/lompstack/dkim/$MLN.*.key"
has "it is said where the mail is now" "Mail: now at @$MLN" "$out"
if swaks --server 127.0.0.1 --port 587 --tls --auth PLAIN --auth-user "info@$MLN" --auth-password "$PW1" --helo client.example.org \
     --from "info@$ML" --to "sales@$MLN" --header "Subject: e2e-send-as-old" --body x >/dev/null 2>&1; then ok "the mailbox may still send as its old address"
else bad "the mailbox may still send as its old address" "swaks refused"; fi
# (a test domain has no DNS: that finding is there before the rename as well)
doc="$($L doctor --no-color 2>&1 | grep -E "$ML|$MLN" | grep -v 'mail: DNS')"
lacks "doctor has no failure for either name" "FAIL" "$doc"

sec "a site with mail, renamed with --keep-mail"
out="$($L add "$MK" --static --no-ssl --mail --email e2e@example.org --yes --no-color 2>&1)"
printf '%s' "$PW1" | $L mail box add "info@$MK" --yes --no-color >/dev/null 2>&1
out="$($L rename "$MK" "$MKN" --keep-mail --yes --no-color 2>&1)"; rc=$?
eq "the rename succeeds" "0" "$rc"
has "the mailbox stays at the old domain" "info@$MK" "$($L mail box list --no-color 2>&1)"
lacks "the new name has none" "@$MKN" "$($L mail box list --no-color 2>&1)"
check "the old name is a mail domain of its own" test -s "$MD/$MK/domain.json"
eq "the site under its new name has no mail" "false" "$(jq -r 'has("mail")' "$ST/$MKN/domain.json")"
if deliver "info@$MK" e2e-kept "/var/vmail/$MK/info/Maildir"; then ok "and mail to it is delivered as before"; else bad "and mail to it is delivered as before" "$(postqueue -p 2>&1 | tail -n 4)"; fi

sec "afterwards"
cleanup
eq "the server has the sites it had" "$sites_before" "$($L list --json 2>/dev/null | jq -r '[.[].domain | select(startswith("rn") | not)] | sort | join(" ")')"
nope "no test user is left" bash -c "getent passwd | grep -q '^rn.*_lomp_e2e_invalid:'"
nope "no test unit is left" bash -c "ls /etc/systemd/system/pm2-rn*"
nope "no test mailbox is left" bash -c "$L mail box list --no-color 2>&1 | grep -q '@rn'"
nope "no test mail is left" bash -c "ls -d /var/vmail/rn*"
check "OpenLiteSpeed's configuration is valid" /usr/local/lsws/bin/openlitespeed -t
sed 's/^/   | /' "$T/rename-app.out" | sed -n '1,14p;/Node.js application/,/Certificate/p'
sed 's/^/   | /' "$T/rename-mail.out" | grep -i 'mail' | head -n 8
printf '\nRESULT: %s passed, %s failed (%s s)\n' "$PASS" "$FAIL" "$(( $(date +%s) - T0 ))"
[ "$FAIL" = 0 ]
