#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-rename-mail-store.sh - DESTRUCTIVE end-to-end test of who takes the steps of
#  "rename" in the mail store.
#
#  The mail store is the mail user's, and whatever runs as that user can swap a name in it
#  for a link. So what a rename makes, moves and removes there is that user's to do, not
#  root's. This shows it on a real server without swapping anything: sites are renamed whose
#  mail store holds directories that ROOT owns - a mailbox, an empty directory where a
#  mailbox goes, the inbox that mail left under the old name is to be carried into. A step
#  of root's goes through each of them; the mail user's is refused, the mailbox or the
#  message stays where it is, and it is said. What is the mail user's own moves as ever.
#  The commands are started in a directory the mail user may not enter, as root's own is.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It adds, renames and removes real sites
#  (names under .invalid, which no DNS answers for), reloads OpenLiteSpeed many times
#  and leaves the server as it found it.
#
#  Needs: an installed lomp server with mail (install --with-mail) and swaks
#  (apt-get install swaks libnet-ssleay-perl).
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-rename-mail-store.sh [tree to test, default: this checkout]
# =============================================================================
set -u
# the checks read what the commands print: in English, whatever this server speaks
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
id -u vmail >/dev/null 2>&1 || need "there is no mail user (vmail)"
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
# Dovecot's user configuration, as it is when this begins: a rename with mail tells a server
# that was set up before of the addresses mailboxes had, and at the end it is put back
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
trap 'cd / 2>/dev/null; dovecot_back; rm -rf "$T"' EXIT
mkdir -p "$T/src"
cp -r "$SRC/setup.sh" "$SRC/lib" "$SRC/tests" "$T/src/"
L="bash $T/src/setup.sh"
MS=rnst.lomp-e2e.invalid; MSN=rnstnew.lomp-e2e.invalid; MO=rnsb.lomp-e2e.invalid; MON=rnsbnew.lomp-e2e.invalid
ST=/root/.server-setup/domains
MD=/root/.server-setup/mail/domains
PWF=/etc/dovecot/lomp/passwd
T0=$(date +%s)

for s in mariadb lomp-redis-rspamd unbound rspamd dovecot postfix lsws; do systemctl is-active --quiet "$s" || systemctl start "$s" >/dev/null 2>&1; done
for i in $(seq 1 60); do ss -ltn | grep -q ':25 ' && ss -ltn | grep -q ':80 ' && break; sleep 1; done

cleanup() {
  local d=""
  for d in $(postqueue -j 2>/dev/null | jq -r 'select((.recipients | length) > 0 and all(.recipients[]; .address | test("@rns[a-z]*\\.lomp-e2e\\.invalid$"))) | .queue_id' 2>/dev/null); do
    postsuper -d "$d" >/dev/null 2>&1
  done
  for d in "$MS" "$MSN" "$MO" "$MON"; do
    [ -s "$ST/$d/redirect.json" ] && $L redirect del "$d" --yes >/dev/null 2>&1
    [ -s "$MD/$d/domain.json" ] && $L mail domain del "$d" --yes --no-backup >/dev/null 2>&1
    [ -s "$ST/$d/domain.json" ] && $L remove "$d" --yes >/dev/null 2>&1
    # (and what this test made by hand in the mail store)
    rm -rf "/var/backups/server-setup/${d:?}" "/etc/server-setup/ssl/${d:?}" "${ST:?}/${d:?}" "/var/vmail/${d:?}"
  done
  rm -rf /root/.server-setup/archive/domains/rns*.lomp-e2e.invalid.* /root/.server-setup/archive/vhosts/rns*.lomp-e2e.invalid.* /root/.server-setup/archive/mail-domains/rns*.lomp-e2e.invalid.*
}
deliver() {   # to subject maildir -> 0 when a message with that subject is in the maildir
  local f="" i=0
  swaks --server 127.0.0.1 --port 25 --helo client.example.org --from someone@example.org --to "$1" --header "Subject: $2" --body hello >/dev/null 2>&1
  for i in $(seq 1 40); do
    f="$(grep -rl "^Subject: $2" "$3" 2>/dev/null | grep -E '/(new|cur)/' | sed -n 1p)"
    [ -n "$f" ] && return 0
    postqueue -f >/dev/null 2>&1; sleep 1
  done
  return 1
}
owner() { stat -c '%U %G' "$1" 2>/dev/null; }
PW1='Passw0rd-e2e-Ms1'

cleanup
sites_before="$($L list --json 2>/dev/null | jq -r '[.[].domain | select(startswith("rn") | not)] | sort | join(" ")')"
# Root is at home in a directory nobody else may enter, and that is where it starts lomp on a
# server. (As the mail user, find ended there with status 1, behind a list that was whole.)
cd "$T" || exit 1
nope "(the commands are started in a directory the mail user may not enter)" runuser -u vmail -- test -x .

sec "a mailbox of the mail user's, one whose directory is root's, one whose place is taken by a directory of root's"
out="$($L add "$MS" --static --no-ssl --mail --email e2e@example.org --yes --no-color 2>&1)"
check "the site is added" test -s "$ST/$MS/domain.json"
for b in moves rooted blocked; do printf '%s' "$PW1" | $L mail box add "$b@$MS" --yes --no-color >/dev/null 2>&1; done
for b in moves rooted blocked; do
  if deliver "$b@$MS" "e2e-$b" "/var/vmail/$MS/$b/Maildir"; then ok "a message is in $b@ before the rename"; else bad "a message is in $b@ before the rename" "$(postqueue -p 2>&1 | tail -n 4)"; fi
done
# ... a mailbox directory that root owns: moving a directory to another one asks for the
# right to write into it, which the mail user has not got
chown root:root "/var/vmail/$MS/rooted"; chmod 0755 "/var/vmail/$MS/rooted"
# ... and where "blocked" would go, what Dovecot makes of an address it is asked about - no
# message in it - made by root: the mail user may not take anything out of that Maildir
install -d -o vmail -g vmail -m 0700 "/var/vmail/$MSN"
install -d -o root -g root -m 0755 "/var/vmail/$MSN/blocked" "/var/vmail/$MSN/blocked/Maildir"
install -o root -g root -m 0600 /dev/null "/var/vmail/$MSN/blocked/Maildir/dovecot.list.index.log"
out="$($L rename "$MS" "$MSN" --yes --no-color 2>&1)"; rc=$?
printf '%s\n' "$out" >"$T/rename-away.out"
eq "the rename succeeds" "0" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 50
lacks "with no failure shown on the way" "FAILED" "$out"
check "the mailbox that is the mail user's is one of the new domain" grep -q "^moves@$MSN:" "$PWF"
check "with its mail" bash -c "grep -rl '^Subject: e2e-moves' /var/vmail/$MSN/moves/Maildir | grep -E '/(new|cur)/'"
eq "its directory is the mail user's still" "vmail vmail" "$(owner "/var/vmail/$MSN/moves")"
nope "nothing is left of it under the old name" test -e "/var/vmail/$MS/moves"
has "a mailbox directory of root's is not moved: the mail user is refused, and it is said" "rooted@$MS stays a mailbox at $MS: could not move /var/vmail/$MS/rooted" "$out"
check "that mailbox stays one of the old domain" grep -q "^rooted@$MS:" "$PWF"
nope "and is none of the new one" grep -q "^rooted@$MSN:" "$PWF"
eq "its directory lies where it lay, root's as it was" "root root" "$(owner "/var/vmail/$MS/rooted")"
check "with its mail" bash -c "grep -rl '^Subject: e2e-rooted' /var/vmail/$MS/rooted/Maildir | grep -E '/(new|cur)/'"
nope "nothing of that name is at the new domain" test -e "/var/vmail/$MSN/rooted"
has "an empty directory of root's in a mailbox's way is not removed: it is in the way, and said" "blocked@$MS stays a mailbox at $MS: /var/vmail/$MSN/blocked is in the way" "$out"
lacks "nothing is said to be removed" "held no message" "$out"
eq "what root had made there is there, root's as it was" "root root" "$(owner "/var/vmail/$MSN/blocked/Maildir/dovecot.list.index.log")"
check "that mailbox stays one of the old domain too" grep -q "^blocked@$MS:" "$PWF"
check "with its mail where it was" bash -c "grep -rl '^Subject: e2e-blocked' /var/vmail/$MS/blocked/Maildir | grep -E '/(new|cur)/'"
has "the rename says which mailbox moved" "Mail: now at @$MSN - moves@$MSN." "$out"

sec "mail of a mailbox's own that was left under the name it comes back to - and for one mailbox, the inbox it is to be carried into is root's"
out="$($L add "$MO" --static --no-ssl --mail --email e2e@example.org --yes --no-color 2>&1)"
check "the site is added" test -s "$ST/$MO/domain.json"
for b in kept shut; do printf '%s' "$PW1" | $L mail box add "$b@$MO" --yes --no-color >/dev/null 2>&1; done
for b in kept shut; do
  if deliver "$b@$MO" "e2e-$b" "/var/vmail/$MO/$b/Maildir"; then ok "a message is in $b@ before the rename"; else bad "a message is in $b@ before the rename" "$(postqueue -p 2>&1 | tail -n 4)"; fi
done
omode="$(stat -c %a "/var/vmail/$MO" 2>/dev/null)"
out="$($L rename "$MO" "$MON" --yes --no-color 2>&1)"; rc=$?
eq "the rename away succeeds" "0" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 50
check "both mailboxes are of the new domain" bash -c "grep -q '^kept@$MON:' $PWF && grep -q '^shut@$MON:' $PWF"
# (no directory was there for the new domain: the mail user made it, from where it may not go back to)
eq "the directory of the new domain is the mail user's, closed as the old domain's is" "vmail vmail ${omode:-700}" "$(stat -c '%U %G %a' "/var/vmail/$MON" 2>/dev/null)"
eq "and nothing in it is anybody else's" "" "$(find "/var/vmail/$MON" \( ! -user vmail -o ! -group vmail \) -print -quit 2>/dev/null)"
$L redirect del "$MO" --yes --no-color >/dev/null 2>&1
# what arrived for each mailbox under its first address while it moved away, and was not
# carried over then - put there by hand, as the mail user's
for b in kept shut; do
  install -d -o vmail -g vmail -m 0700 "/var/vmail/$MO" "/var/vmail/$MO/$b" "/var/vmail/$MO/$b/Maildir" "/var/vmail/$MO/$b/Maildir/new"
  printf 'Subject: e2e-left-%s\n\nhello\n' "$b" >"$T/left.msg"
  install -o vmail -g vmail -m 0600 "$T/left.msg" "/var/vmail/$MO/$b/Maildir/new/$(date +%s).M2P2.e2e-left-$b"
done
# ... and the inbox of one of the two is root's by the time it is to be carried into
chown root:root "/var/vmail/$MON/shut/Maildir/new"
out="$($L rename "$MON" "$MO" --yes --no-color 2>&1)"; rc=$?
printf '%s\n' "$out" >"$T/rename-back.out"
eq "the rename back succeeds" "0" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 50
lacks "with no failure shown on the way" "FAILED" "$out"
check "both mailboxes have their first addresses again" bash -c "grep -q '^kept@$MO:' $PWF && grep -q '^shut@$MO:' $PWF"
has "into a mailbox of the mail user's, what was left is carried, and said" "1 message(s) that had been left under kept@$MO when the site was renamed are in the mailbox now" "$out"
check "it is in the mailbox" bash -c "grep -rl '^Subject: e2e-left-kept' /var/vmail/$MO/kept/Maildir | grep -E '/(new|cur)/'"
check "beside the mail the mailbox had" bash -c "grep -rl '^Subject: e2e-kept' /var/vmail/$MO/kept/Maildir | grep -E '/(new|cur)/'"
nope "and nothing of the directory it lay in is left beside the mailbox" bash -c "ls -d /var/vmail/$MO/kept~*"
eq "nothing in that mailbox is anybody else's" "" "$(find "/var/vmail/$MO/kept" \( ! -user vmail -o ! -group vmail \) -print -quit 2>/dev/null)"
lacks "into an inbox of root's nothing is said to be carried" "left under shut@$MO" "$out"
has "what could not be carried is put aside whole, and said, with how much is in it" "/var/vmail/$MO/shut was in the way of shut@$MO: it is /var/vmail/$MO/shut~" "$out"
has "one message" "with what was in it (1 message(s))" "$(printf '%s\n' "$out" | grep -F "/var/vmail/$MO/shut was in the way")"
check "the message is in what was put aside" bash -c "grep -rlq '^Subject: e2e-left-shut' /var/vmail/$MO/shut~*/Maildir/new"
eq "the inbox is root's as it was" "root root" "$(owner "/var/vmail/$MO/shut/Maildir/new")"
nope "and nothing was put into it" bash -c "ls /var/vmail/$MO/shut/Maildir/new | grep -q e2e-left"

sec "afterwards"
cd / || exit 1
cleanup
eq "the server has the sites it had" "$sites_before" "$($L list --json 2>/dev/null | jq -r '[.[].domain | select(startswith("rn") | not)] | sort | join(" ")')"
nope "no test user is left" bash -c "getent passwd | grep -q '^rns.*_lomp_e2e_invalid:'"
nope "no test mailbox is left" grep -q '@rns[a-z]*\.lomp-e2e\.invalid:' "$PWF"
nope "no test mail is left" bash -c "ls -d /var/vmail/rns*"
n="$(grep -c '@rns[a-z]*\.lomp-e2e\.invalid' "$DFORMER" 2>/dev/null)"
eq "Dovecot's list names no address of the test any more" "0" "${n:-0}"
dovecot_back
check "Dovecot's user configuration is as it was" cmp -s "$T/auth.before" "$DAUTH"
check "and valid" doveconf -n
check "OpenLiteSpeed's configuration is valid" /usr/local/lsws/bin/openlitespeed -t
grep -E 'stays a mailbox|in the way|Permission denied|Mail: now' "$T/rename-away.out" | sed 's/^/   | /' | cut -c1-230
grep -E 'message\(s\)|in the way|Permission denied|Mail: now' "$T/rename-back.out" | sed 's/^/   | /' | cut -c1-230
printf '\nRESULT: %s passed, %s failed (%s s)\n' "$PASS" "$FAIL" "$(( $(date +%s) - T0 ))"
[ "$FAIL" = 0 ]
