#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-rename-app-mail.sh - DESTRUCTIVE end-to-end test of "rename" for a site
#  with a Node.js application and for sites with mail.
#
#  A PM2 application with a build step, a scheduled job and a variable is renamed and,
#  after an injected failure, put back. A site with two mailboxes and an alias is renamed:
#  same passwords under the new addresses, mail to the old ones delivered into the new
#  mailboxes, and what is still handed to Dovecot under an old address too; once more while
#  mail keeps arriving - marked spam among it, a message Postfix was holding from before, one
#  it holds although Dovecot had written it into the mailbox, one on hold, a sender that is
#  slow across the rename, the first mail of a mailbox that never had any - and back to the
#  name it had, past what was left under it: an empty directory, mail of the mailbox's own,
#  mail nobody can say whose; and once more with --keep-mail.
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
# Dovecot's user configuration, as it is when this begins. A server that was set up before
# lomp told Dovecot the addresses mailboxes had before a rename is told by the first rename
# with mail below (its configuration then names that list); at the end it is put back as it
# was, so that the next run finds such a server again.
DAUTH=/etc/dovecot/lomp/auth-passwdfile.conf; DFORMER=/etc/dovecot/lomp/former
cp -p "$DAUTH" "$T/auth.before" 2>/dev/null
[[ -e "$DFORMER" ]] && : >"$T/former.was-there"
dovecot_back() {
  [[ -s "$T/auth.before" ]] || return 0
  cmp -s "$T/auth.before" "$DAUTH" && return 0
  cp -p "$T/auth.before" "$DAUTH"
  [[ -e "$T/former.was-there" ]] || rm -f "$DFORMER"
  doveconf -n >/dev/null 2>&1 && doveadm reload >/dev/null 2>&1
  return 0
}
trap 'exec 7>&- 2>/dev/null; dovecot_back; rm -rf "$T"' EXIT
mkdir -p "$T/src" "$T/shim"
cp -r "$SRC/setup.sh" "$SRC/lib" "$SRC/tests" "$T/src/"
L="bash $T/src/setup.sh"
APP=rnapp.lomp-e2e.invalid; APPN=rnappnew.lomp-e2e.invalid; AI=rnapp_lomp_e2e_invalid; ANI=rnappnew_lomp_e2e_invalid
ML=rnmail.lomp-e2e.invalid; MLN=rnmailnew.lomp-e2e.invalid; MK=rnkeep.lomp-e2e.invalid; MKN=rnkeepnew.lomp-e2e.invalid
MB=rnbusy.lomp-e2e.invalid; MBN=rnbusynew.lomp-e2e.invalid
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
  # what Postfix still holds for an address of the test (a delivery the move of a mailbox
  # interrupted waits there for its next attempt)
  for d in $(postqueue -j 2>/dev/null | jq -r 'select((.recipients | length) > 0 and all(.recipients[]; .address | test("@rn[a-z]*\\.lomp-e2e\\.invalid$"))) | .queue_id' 2>/dev/null); do
    postsuper -d "$d" >/dev/null 2>&1
  done
  for d in "$APP" "$APPN" "$ML" "$MLN" "$MK" "$MKN" "$MB" "$MBN"; do
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
# (the directory of the old domain, closed in a way of its own: the new domain's is made like it)
chmod 0750 "/var/vmail/$ML"
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
# What a rename makes and moves in the mail store, the mail user makes and moves (root does
# not: a name there can be swapped for a link by anything that runs as that user). The
# directory of the new domain is that user's from the first moment, with no chown behind it.
eq "the directory of the new domain is the mail user's, closed as the old domain's is" "vmail vmail 750" "$(stat -c '%U %G %a' "/var/vmail/$MLN" 2>/dev/null)"
eq "and nothing in it is anybody else's" "" "$(find "/var/vmail/$MLN" \( ! -user vmail -o ! -group vmail \) -print -quit 2>/dev/null)"
if deliver "info@$ML" e2e-to-old "/var/vmail/$MLN/info/Maildir"; then ok "mail to the old address arrives in the new mailbox"; else bad "mail to the old address arrives in the new mailbox" "$(postqueue -p 2>&1 | tail -n 4)"; fi
if deliver "info@$MLN" e2e-to-new "/var/vmail/$MLN/info/Maildir"; then ok "mail to the new address arrives"; else bad "mail to the new address arrives" "$(postqueue -p 2>&1 | tail -n 4)"; fi
if deliver "team@$ML" e2e-team-old "/var/vmail/$MLN/sales/Maildir"; then ok "mail to an old alias reaches the mailboxes behind it"; else bad "mail to an old alias reaches the mailboxes behind it" "$(postqueue -p 2>&1 | tail -n 4)"; fi
if deliver "team@$MLN" e2e-team-new "/var/vmail/$MLN/info/Maildir"; then ok "the alias exists at the new domain"; else bad "the alias exists at the new domain" "$(postqueue -p 2>&1 | tail -n 4)"; fi
# Postfix applies an alias when a message comes in, not when it hands it over. What it took in
# under an old address before it had the alias - from a sender that was in the middle of it, or
# kept on hold since - still names that address when it reaches Dovecot, and was answered "550
# User doesn't exist" there and sent back. So Dovecot is told the addresses the mailboxes had:
# each is another name of its mailbox, and no login.
under() {   # address subject -> a message handed to Dovecot under that address, as Postfix hands one over
  swaks --protocol LMTP --socket /var/spool/postfix/private/dovecot-lmtp --from '<>' --to "$1" --header "Subject: $2" --body hello >/dev/null 2>&1
}
has "Dovecot's user configuration names the list of the addresses mailboxes had before" "$DFORMER" "$(cat "$DAUTH" 2>/dev/null)"
fl="$(cat "$DFORMER" 2>/dev/null)"
has "an old address is in it as another name of its mailbox" "info@$ML:::::/var/vmail/$MLN/info::userdb_user=info@$MLN " "$fl"
has "with the quota the mailbox has" "sales@$ML:::::/var/vmail/$MLN/sales::userdb_user=sales@$MLN userdb_quota_rule=*:storage=2G" "$fl"
lacks "an alias with two mailboxes behind it is the name of neither" "team@$ML:" "$fl"
check "Dovecot takes a message that is handed over under an old address" under "info@$ML" e2e-under-old
check "and puts it into the mailbox that had the address" bash -c "grep -rl '^Subject: e2e-under-old' /var/vmail/$MLN/info/Maildir | grep -E '/(new|cur)/'"
eq "under its old address a mailbox has its own quota" "2097152" "$(doveadm -f tab quota get -u "sales@$ML" 2>/dev/null | awk -F'\t' '$2 == "STORAGE" { print $4 }' | sed -n 1p)"
nope "a message handed over under the old alias is refused as it was" under "team@$ML" e2e-under-team
nope "and so is one for an address the old domain never had" under "nobody@$ML" e2e-under-nobody
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

sec "a site with mail, renamed while mail keeps arriving"
# Dovecot looks at its user file at most once a second, and Postfix asks it about the mailbox
# at every RCPT TO. A rename that did not wait for that second, with senders at work all
# through it, left a directory under the old name in six runs of seven and had "550 User
# doesn't exist" for the new address, a message bounced each time, in one of two.
out="$($L add "$MB" --static --no-ssl --mail --email e2e@example.org --yes --no-color 2>&1)"
check "the site is added" test -s "$ST/$MB/domain.json"
printf '%s' "$PW1" | $L mail box add "info@$MB" --yes --no-color >/dev/null 2>&1
# ... a mailbox that never had mail, and one more for the way back
printf '%s' "$PW2" | $L mail box add "fresh@$MB" --yes --no-color >/dev/null 2>&1
printf '%s' "$PW2" | $L mail box add "side@$MB" --yes --no-color >/dev/null 2>&1
if deliver "info@$MB" e2e-first "/var/vmail/$MB/info/Maildir"; then ok "a message is in the mailbox before the rename"; else bad "a message is in the mailbox before the rename" "$(postqueue -p 2>&1 | tail -n 4)"; fi
# that message as this server's Postfix and Dovecot write one into a mailbox (see below)
cp "$(grep -rl '^Subject: e2e-first' "/var/vmail/$MB/info/Maildir" 2>/dev/null | grep -E '/(new|cur)/' | sed -n 1p)" "$T/first.msg" 2>/dev/null
tb="$(date +%s)"; ln0="$(wc -l </var/log/server_setup.log 2>/dev/null || echo 0)"
# A message Postfix holds for the mailbox when the rename begins: Dovecot is refused the
# mailbox's tmp/ for a moment and answers 451, and Postfix puts the message off - under the
# address it came for, which it keeps: an alias is applied when a message comes in, not when
# it is handed over. Its next attempt after a rename was answered "550 User doesn't exist".
held_for() {   # address -> the ids of the messages the deferred queue holds for it
  postqueue -j 2>/dev/null | jq -r --arg a "$1" 'select(.queue_name == "deferred" and any(.recipients[]; .address == $a)) | .queue_id' 2>/dev/null
}
queue_of() {   # queue id -> the queue it is in and whom it is for
  postqueue -j 2>/dev/null | jq -r --arg id "$1" 'select(.queue_id == $id) | "\(.queue_name) \(.recipients[0].address)"' 2>/dev/null
}
chmod 000 "/var/vmail/$MB/info/Maildir/tmp"
# ... one that somebody then put on hold: it is nobody's to send on, and is released days later
swaks --server 127.0.0.1 --port 25 --helo client.example.org --from '<>' --to "info@$MB" --header "Subject: e2e-onhold" --body hello >/dev/null 2>&1
for i in $(seq 1 15); do [ -n "$(held_for "info@$MB")" ] && break; sleep 1; done
hid="$(held_for "info@$MB" | sed -n 1p)"
[ -z "$hid" ] || postsuper -h "$hid" >/dev/null 2>&1
swaks --server 127.0.0.1 --port 25 --helo client.example.org --from '<>' --to "info@$MB" --header "Subject: e2e-held" --body hello >/dev/null 2>&1
for i in $(seq 1 15); do [ -n "$(held_for "info@$MB")" ] && break; sleep 1; done
h="$(held_for "info@$MB" | sed -n 1p)"
# ... and one that will turn out to be in the mailbox already (see below)
swaks --server 127.0.0.1 --port 25 --helo client.example.org --from '<>' --to "info@$MB" --header "Subject: e2e-arrived" --body hello >/dev/null 2>&1
for i in $(seq 1 15); do [ "$(held_for "info@$MB" | grep -c .)" -ge 2 ] && break; sleep 1; done
chmod 700 "/var/vmail/$MB/info/Maildir/tmp"
ha="$(held_for "info@$MB" | grep -vxF -- "${h:-none}" | sed -n 1p)"
hmid="$(postcat -hq "${ha:-none}" 2>/dev/null | grep -i -m1 '^Message-Id:')"
if [ -n "$h" ] && [ -n "$ha" ]; then ok "Postfix holds two messages for the mailbox when the rename begins"; else bad "Postfix holds two messages for the mailbox when the rename begins" "$(postqueue -p 2>&1 | tail -n 6)"; fi
eq "and one more that was put on hold" "hold info@$MB" "$(queue_of "${hid:-none}")"
: >"$T/busy"
for i in 1 2 3 4; do
  ( while [ -e "$T/busy" ]; do
      swaks --server 127.0.0.1 --port 25 --helo client.example.org --from '<>' --to "info@$MB" --header "Subject: e2e-busy" --body hello >/dev/null 2>&1
    done ) &
done
# ... and mail that Rspamd marked, which the spam rule files into the folder Junk - handed to
# Dovecot under the old address, as Postfix does with what it took in before it had the alias
( while [ -e "$T/busy" ]; do
    swaks --protocol LMTP --socket /var/spool/postfix/private/dovecot-lmtp --from '<>' --to "info@$MB" --header "Subject: e2e-junk" --header "X-Spam: Yes" --body hello >/dev/null 2>&1
  done ) &
moved() {   # address -> waits until the rename has given the mailbox that address (its mail has moved by then)
  while [ -e "$T/busy" ]; do grep -q "^$1:" /etc/dovecot/lomp/passwd 2>/dev/null && return 0; sleep 0.05; done
  return 1
}
# ... the first mail a mailbox ever gets, handed over under its old address in the moments
# after the mailbox was given its new one: Dovecot still answers for the old one then, and
# makes a mailbox for it - which the mailbox that never had mail had no place to take it from
( moved "fresh@$MBN" || exit 0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    under "fresh@$MB" e2e-fresh && echo took >>"$T/fresh.took"
  done ) &
# ... a delivery the move of the mailbox interrupts. Dovecot has written the message when it
# finds the mailbox gone from under it, cannot take the file back - its path has moved - and
# answers 451: Postfix puts the message off, and offered again it arrived a second time (11 of
# the 18 the move put off in three renames on the test server). What Dovecot wrote is put
# there by hand at the moment the mailbox has moved, as this server's Postfix and Dovecot
# write a message: the one Postfix holds as "e2e-arrived", handed over out of that very queue
# file, with the Message-ID it has there.
( moved "info@$MBN" || exit 0
  fid="$(grep -m1 -oE '\(Postfix\) with [A-Z]+ id [0-9A-Za-z]+' "$T/first.msg" 2>/dev/null | awk '{ print $NF }')"
  [ -n "$fid" ] && [ -n "$ha" ] && [ -n "$hmid" ] && [ -d "/var/vmail/$MBN/info/Maildir/new" ] || exit 0
  sed -e "s/$fid/$ha/g" -e 's/^Subject: e2e-first/Subject: e2e-arrived/' -e "s|^Message-I[dD]:.*|$hmid|" "$T/first.msg" >"$T/copy.msg"
  install -o vmail -g vmail -m 0600 "$T/copy.msg" "/var/vmail/$MBN/info/Maildir/new/$(date +%s).M1P1.e2e-arrived" && : >"$T/copy.planted" ) &
# ... and a sender that is in the middle of a message when the aliases take effect: Postfix
# takes it in with the tables it had when the message began, under the old address
smtp() {   # [a line to say] -> the line Postfix answers
  local l=""
  [ -z "${1:-}" ] || printf '%s\r\n' "$1" >&7
  IFS= read -r -t 60 -u 7 l
  printf '%s' "${l%$'\r'}"
}
exec 7<>/dev/tcp/127.0.0.1/25
smtp >/dev/null; smtp "HELO client.example.org" >/dev/null; smtp "MAIL FROM:<>" >/dev/null
slow="$(smtp "RCPT TO:<info@$MB>")"
has "(a sender has begun a message for the old address)" "250 " "$slow"
sleep 2
out="$($L rename "$MB" "$MBN" --yes --no-color 2>&1 7<&-)"; rc=$?
# the sender that was slow ends its message now: the mailbox has no line under the old name
slow="$(smtp DATA)"; printf 'Subject: e2e-slow\r\n\r\nhello\r\n.\r\n' >&7; slow="$slow / $(smtp)"; smtp QUIT >/dev/null
exec 7>&-
rm -f "$T/busy"; wait
eq "the rename succeeds" "0" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 50
lacks "with no failure shown on the way" "FAILED" "$out"
has "Postfix takes the message of the sender that was slow across the rename" "250 2.0.0 Ok: queued" "$slow"
# the message that is on hold stayed there, under the address it came for; released, it is
# handed to Dovecot under that address
eq "a message on hold is left on hold" "hold info@$MB" "$(queue_of "${hid:-none}")"
postsuper -H "${hid:-none}" >/dev/null 2>&1; postqueue -i "${hid:-none}" >/dev/null 2>&1
for i in $(seq 1 30); do
  grep -rlq '^Subject: e2e-onhold' "/var/vmail/$MBN/info/Maildir" 2>/dev/null && grep -rlq '^Subject: e2e-slow' "/var/vmail/$MBN/info/Maildir" 2>/dev/null && break
  sleep 1
done
for i in $(seq 1 20); do postqueue -p 2>/dev/null | grep -q 'Mail queue is empty' && break; sleep 1; done
boxes="$($L mail box list --no-color 2>&1)"
has "the mailbox is one of the new domain" "info@$MBN" "$boxes"
has "and so is the one that never had mail" "fresh@$MBN" "$boxes"
check "released, the message that was on hold is in the mailbox that had the address" bash -c "grep -rl '^Subject: e2e-onhold' /var/vmail/$MBN/info/Maildir | grep -E '/(new|cur)/'"
check "and so is the message of the sender that was slow" bash -c "grep -rl '^Subject: e2e-slow' /var/vmail/$MBN/info/Maildir | grep -E '/(new|cur)/'"
nf="$(grep -rl '^Subject: e2e-fresh' "/var/vmail/$MBN/fresh/Maildir" 2>/dev/null | grep -cE '/(new|cur)/')"; nt="$(grep -c took "$T/fresh.took" 2>/dev/null)"
if [ "${nt:-0}" -ge 1 ] && [ "${nf:-0}" = "${nt:-0}" ]; then ok "every first message of the mailbox that never had mail is in it ($nf messages)"
else bad "every first message of the mailbox that never had mail is in it" "${nt:-0} taken by Dovecot under the old address, ${nf:-0} in the mailbox; under the old name: $(find "/var/vmail/$MB" -type f 2>/dev/null | grep -cE '/(new|cur)/')"; fi
n="$(grep -rl '^Subject: e2e-busy' "/var/vmail/$MBN/info/Maildir" 2>/dev/null | grep -cE '/(new|cur)/')"
if [ "${n:-0}" -ge 20 ]; then ok "the mail that kept arriving is in it ($n messages)"; else bad "the mail that kept arriving is in it" "${n:-0} messages"; fi
nj="$(grep -rl '^Subject: e2e-junk' "/var/vmail/$MBN/info/Maildir" 2>/dev/null | grep -cE '/\.Junk/(new|cur)/')"
if [ "${nj:-0}" -ge 2 ]; then ok "and what the spam rule filed is in Junk there ($nj messages)"; else bad "and what the spam rule filed is in Junk there" "${nj:-0} messages"; fi
nope "none of it is left in a Junk under the old name" bash -c "grep -rlq '^Subject: e2e-junk' /var/vmail/$MB"
nope "nothing is left under the old name, not a directory either" bash -c "ls -d /var/vmail/$MB/*"
eq "no message was refused at the new address" "0" "$(journalctl -t postfix/lmtp --since "@$tb" --no-pager -o cat 2>/dev/null | grep -c "to=<info@$MBN>.*status=bounced")"
for i in $(seq 1 30); do grep -rlq '^Subject: e2e-held' "/var/vmail/$MBN/info/Maildir" 2>/dev/null && break; sleep 1; done
check "the message Postfix was holding went on to the mailbox, under its new address" bash -c "grep -rl '^Subject: e2e-held' /var/vmail/$MBN/info/Maildir | grep -E '/(new|cur)/'"
eq "and is there once" "1" "$(grep -rl '^Subject: e2e-held' "/var/vmail/$MBN/info/Maildir" 2>/dev/null | grep -cE '/(new|cur)/')"
check "(what Dovecot had written of the other one was put into the mailbox as it moved)" test -e "$T/copy.planted"
eq "a message that was in the mailbox already is there once: it is taken out of the queue, not sent again" "1" "$(grep -rl '^Subject: e2e-arrived' "/var/vmail/$MBN/info/Maildir" 2>/dev/null | grep -cE '/(new|cur)/')"
eq "Postfix holds it no longer" "" "$(queue_of "${ha:-none}")"
# (how many the log names depends on the mail that kept arriving: a delivery the move itself
# interrupted after Dovecot had written the message is one more of them)
has "which the log says" "message(s) Postfix was holding for them were in the mailbox already" "$(sed -n "$((ln0 + 1)),\$p" /var/log/server_setup.log 2>/dev/null | grep -F 'in the mailbox already')"
eq "Postfix holds nothing for the old address any more" "" "$(held_for "info@$MB")"
eq "and nothing was bounced there" "0" "$(journalctl -t postfix/lmtp --since "@$tb" --no-pager -o cat 2>/dev/null | grep -c "to=<[a-z]*@$MB>.*status=bounced")"

sec "... and renamed back to the name it had"
# Every address of the first name became an alias of the same address at the second. A mailbox
# that comes back takes its address over from that alias: left in place, the two aliases sent
# each other its mail, and Postfix answered "451 4.6.0 Alias expansion error".
$L redirect del "$MB" --yes --no-color >/dev/null 2>&1
# What a release that did not wait for Dovecot, or carried over the inbox alone, left under the
# first name - put there by hand. Each was "in the way", and the mailbox stayed at the address
# of the meantime:
#  - fresh: the Maildir Dovecot makes of an address it is asked about, with no message in it
#  - info:  mail that arrived for the mailbox under its first address while it moved, in the
#           folder the spam rule files into
#  - side:  a message from another time - nobody can say whose that is
maildir() {   # directory... -> each made as Dovecot makes one
  install -d -o vmail -g vmail -m 0700 "$@"
}
maildir "/var/vmail/$MB" "/var/vmail/$MB/fresh" "/var/vmail/$MB/fresh/Maildir"
install -o vmail -g vmail -m 0600 /dev/null "/var/vmail/$MB/fresh/Maildir/dovecot.list.index.log"
maildir "/var/vmail/$MB/info" "/var/vmail/$MB/info/Maildir" "/var/vmail/$MB/info/Maildir/.Junk" "/var/vmail/$MB/info/Maildir/.Junk/new"
printf 'Subject: e2e-left-behind\n\nhello\n' >"$T/left.msg"
install -o vmail -g vmail -m 0600 "$T/left.msg" "/var/vmail/$MB/info/Maildir/.Junk/new/$(date +%s).M2P2.e2e-left"
maildir "/var/vmail/$MB/side" "/var/vmail/$MB/side/Maildir" "/var/vmail/$MB/side/Maildir/new" "/var/vmail/$MB/side/Maildir/cur" "/var/vmail/$MB/side/Maildir/tmp"
printf 'Subject: e2e-whose\n\nhello\n' >"$T/whose.msg"
install -o vmail -g vmail -m 0600 "$T/whose.msg" "/var/vmail/$MB/side/Maildir/new/1.M3P3.e2e-whose"
touch -d '3 days ago' "/var/vmail/$MB/side/Maildir/new/1.M3P3.e2e-whose"
out="$($L rename "$MBN" "$MB" --yes --no-color 2>&1)"; rc=$?
eq "the rename back succeeds" "0" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 50
has "an empty directory under that name is taken out of the mailbox's way, and said" "/var/vmail/$MB/fresh held no message and was in the way of fresh@$MB: removed" "$out"
has "mail of the mailbox's own that had been left there is carried into it, and said" "1 message(s) that had been left under info@$MB when the site was renamed are in the mailbox now" "$out"
check "into the folder it lay in" bash -c "grep -rl '^Subject: e2e-left-behind' /var/vmail/$MB/info/Maildir/.Junk | grep -E '/(new|cur)/'"
has "a directory with mail nobody can say whose is put aside, and named" "/var/vmail/$MB/side was in the way of side@$MB: it is /var/vmail/$MB/side~" "$out"
check "with the message that was in it" bash -c "grep -rlq '^Subject: e2e-whose' /var/vmail/$MB/side~*/Maildir/new"
# whose that mail is, lomp cannot say: it gives the command that copies it into the mailbox to
# whoever can - and that command, as it is printed, does
imp="$(printf '%s\n' "$out" | grep -o "doveadm import -u side@$MB maildir:/var/vmail/$MB/side~[0-9-]*/Maildir \"\" all" | sed -n 1p)"
if [ -n "$imp" ]; then ok "the command that copies its messages into the mailbox is printed"; else bad "the command that copies its messages into the mailbox is printed" "$(printf '%s\n' "$out" | grep -i 'side' | head -n 6)"; fi
has "and what becomes of the directory otherwise" "No backup of the mail holds that directory, and it is deleted with the mail of $MB" "$out"
nope "(the message is not in the mailbox yet)" bash -c "grep -rlq '^Subject: e2e-whose' /var/vmail/$MB/side/Maildir"
[ -z "$imp" ] || bash -c "$imp" >/dev/null 2>&1
check "run as printed, it puts the message into the mailbox" bash -c "grep -rl '^Subject: e2e-whose' /var/vmail/$MB/side/Maildir | grep -E '/(new|cur)/'"
check "and the message is still in what was put aside: it is copied" bash -c "grep -rl '^Subject: e2e-whose' /var/vmail/$MB/side~*/Maildir | grep -E '/(new|cur)/'"
boxes="$($L mail box list --no-color 2>&1)"
has "the mailbox has its first address again" "info@$MB" "$boxes"
has "the one whose place was empty too" "fresh@$MB" "$boxes"
has "and the one whose place was taken" "side@$MB" "$boxes"
lacks "and is none of the other domain" "@$MBN " "$boxes"
check "the same password signs in under it" doveadm auth test "info@$MB" "$PW1"
check "its mail came back with it" bash -c "grep -rlq '^Subject: e2e-busy' /var/vmail/$MB/info/Maildir"
lacks "its address is no alias of the other one any more" "info@$MBN" "$($L mail alias list --no-color 2>&1 | grep "^ *info@$MB ")"
if deliver "info@$MB" e2e-back "/var/vmail/$MB/info/Maildir"; then ok "mail to it arrives"; else bad "mail to it arrives" "$(postqueue -p 2>&1 | tail -n 4)"; fi
if deliver "info@$MBN" e2e-back-other "/var/vmail/$MB/info/Maildir"; then ok "and so does mail to the address of the meantime"; else bad "and so does mail to the address of the meantime" "$(postqueue -p 2>&1 | tail -n 4)"; fi
has "for Dovecot the address of the meantime is another name of the mailbox now" "info@$MBN:::::/var/vmail/$MB/info::userdb_user=info@$MB " "$(cat "$DFORMER" 2>/dev/null)"
eq "and its first address, a mailbox again, is nobody's other name" "0" "$(grep -c "^info@$MB:" "$DFORMER" 2>/dev/null)"
check "a message handed to Dovecot under the address of the meantime is taken" under "info@$MBN" e2e-under-meantime
check "into the mailbox" bash -c "grep -rl '^Subject: e2e-under-meantime' /var/vmail/$MB/info/Maildir | grep -E '/(new|cur)/'"
nope "nothing is left under the name of the meantime" bash -c "ls -d /var/vmail/$MBN/*"

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
n="$(grep -c '@rn[a-z]*\.lomp-e2e\.invalid' "$DFORMER" 2>/dev/null)"
eq "Dovecot's list names no address of the test any more" "0" "${n:-0}"
dovecot_back
check "Dovecot's user configuration is as it was" cmp -s "$T/auth.before" "$DAUTH"
check "and valid" doveconf -n
check "OpenLiteSpeed's configuration is valid" /usr/local/lsws/bin/openlitespeed -t
sed 's/^/   | /' "$T/rename-app.out" | sed -n '1,14p;/Node.js application/,/Certificate/p'
sed 's/^/   | /' "$T/rename-mail.out" | grep -i 'mail' | head -n 8
printf '\nRESULT: %s passed, %s failed (%s s)\n' "$PASS" "$FAIL" "$(( $(date +%s) - T0 ))"
[ "$FAIL" = 0 ]
