#!/usr/bin/env bash
# =============================================================================
#  tests/dovecot-facts.sh - what lomp takes for granted about Dovecot, asked of the
#  Dovecot of this machine.
#
#  Two things lomp does rest on how Dovecot behaves, and both were measured on one Dovecot
#  (2.3.21, Ubuntu 24.04):
#   - it tells that a message Postfix still holds has arrived by the file Dovecot wrote into
#     the mailbox (lib_mail_arrived): Dovecot's own lines on top, the recipient among them
#     unless the message was handed over for two in one go, and below them the message byte
#     for byte as it was handed over;
#   - it has Dovecot take mail for the address a mailbox had before a rename, out of a second
#     user database nobody signs in from (lib_mail_render_former).
#  This asks the same of whatever Dovecot is installed here - Ubuntu 22.04 has 2.3.16 - with
#  lomp's own configuration of the user databases and lomp's own functions, on a Dovecot of
#  its own beside the machine's: its directories are under a temporary one, it listens on no
#  port, and nothing of /etc/dovecot or of a Dovecot that runs here is touched.
#
#  As root, on a machine with dovecot-core, dovecot-lmtpd, dovecot-sieve and python3:
#      bash tests/dovecot-facts.sh [tree to test, default: this checkout]
# =============================================================================
set -u
if [[ "$(id -u)" != 0 ]]; then printf 'Run it as root: it starts a Dovecot of its own.\n' >&2; exit 2; fi
for t in dovecot doveadm python3; do
  command -v "$t" >/dev/null 2>&1 || { printf 'Cannot run here: %s is missing\n' "$t" >&2; exit 2; }
done
[[ -x /usr/lib/dovecot/lmtp ]] || { printf 'Cannot run here: dovecot-lmtpd is missing\n' >&2; exit 2; }
PASS=0; FAIL=0
ok()    { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; if [ -n "${2:-}" ]; then printf '        %s\n' "${2:0:900}"; fi; }
has()   { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "missing [$2] in: $3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "unexpected [$2] in: $3"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
sec()   { printf '\n-- %s\n' "$*"; }

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SRC="${1:-$(dirname "$HERE")}"
D="$(mktemp -d /tmp/lomp-dfacts.XXXXXX)"; chmod 0755 "$D"
MADE_USER=""
if id vmail >/dev/null 2>&1; then VM=vmail
else VM=lompfacts; useradd --system --user-group --no-create-home --shell /usr/sbin/nologin "$VM" >/dev/null 2>&1 && MADE_USER=1; fi
DC=(-c "$D/dovecot.conf")
finish() {
  [[ -s "$D/run/master.pid" ]] && doveadm "${DC[@]}" stop >/dev/null 2>&1
  [[ -z "$MADE_USER" ]] || userdel "$VM" >/dev/null 2>&1
  rm -rf "$D"
}
trap finish EXIT

# ---- lomp's own functions, over directories of this test ---------------------------------
# what setup.sh sets before it loads its modules: its configuration block and its fixed paths
eval "$(sed -n '/^#  USER CONFIGURATION/,/^#  END OF USER CONFIGURATION/p' "$SRC/setup.sh" | grep -E '^[A-Z_]+=')"
eval "$(sed -n '/^# ---- Fixed paths/,/^# ---- Global runtime flags/p' "$SRC/setup.sh" | grep -E '^readonly [A-Z_]+=' | sed 's/^readonly //')"
# shellcheck disable=SC2034   # (read by the modules that are loaded below)
{
  OPT_YES=1; OPT_DRY_RUN=0; OPT_QUIET=1; OPT_VERBOSE=0; OPT_NO_COLOR=1; OPT_JSON=0; OPT_NON_INTERACTIVE=1
  SCRIPT_VERSION_LINE="1.0"; SCRIPT_PATH="$SRC/setup.sh"; SCRIPT_DIR="$SRC"
  STATE_DIR="$D/state-lomp"; LOG_FILE="$D/lomp.log"; LIB_TMP_ROOT="$D/tmp"; mkdir -p "$D/tmp" "$D/state-lomp"
  MAIL_VMAIL_USER="$VM"; MAIL_VMAIL_HOME="$D/vmail"; MAIL_DOVECOT_DIR="$D/etc"; MAIL_PASSWD_FILE="$D/etc/passwd"; MAIL_SIEVE_DIR="$D/sieve"
}
for m in $(sed -n 's/^for _m in \(.*\); do$/\1/p' "$SRC/setup.sh"); do
  # shellcheck source=/dev/null
  source "$SRC/lib/$m.sh"
done
trap - ERR
trap finish EXIT
set +e +E; set +o pipefail

# ---- a Dovecot of its own -------------------------------------------------------------------
mkdir -p "$D/etc" "$D/state" "$D/sieve" "$D/vmail"
chown "$VM:$VM" "$D/vmail"; chmod 0750 "$D/vmail"
PW='Facts-Passw0rd'
HASH="$(doveadm pw -s BLF-CRYPT -p "$PW" 2>/dev/null)"
printf '%s\n' "info@new.facts.test:${HASH}::::::userdb_quota_rule=*:storage=2G" "sales@new.facts.test:${HASH}::::::userdb_quota_rule=*:storage=1G" >"$MAIL_PASSWD_FILE"
# the address a mailbox had before a rename, as lomp writes one into its list
printf 'info@old.facts.test:::::%s/new.facts.test/info::userdb_user=info@new.facts.test userdb_quota_rule=*:storage=2G\n' "$MAIL_VMAIL_HOME" >"$(lib_mail_former_file)"
chown root:dovecot "$MAIL_PASSWD_FILE" "$(lib_mail_former_file)"; chmod 0640 "$MAIL_PASSWD_FILE" "$(lib_mail_former_file)"
lib_mail_render_dovecot_auth >"$D/etc/auth-passwdfile.conf"
lib_mail_render_sieve_spam >"$D/sieve/spam-to-junk.sieve"
SIEVE=""
if [[ -n "$(find /usr/lib/dovecot/modules -name 'lib90_sieve_plugin.so' 2>/dev/null)" ]]; then
  SIEVE=1; sievec "$D/sieve/spam-to-junk.sieve" >/dev/null 2>&1; chmod 0644 "$D/sieve"/*
fi
{
  printf 'base_dir = %s/run\nstate_dir = %s/state\ninstance_name = lomp-facts\nlog_path = %s/dovecot.log\n' "$D" "$D" "$D"
  printf 'protocols = lmtp\nssl = no\nfirst_valid_uid = 1\nauth_username_format = %%Lu\n'
  # as lomp configures them: where a mailbox lies, the quota, the spam rule
  printf 'mail_location = maildir:%s/%%Ld/%%Ln/Maildir\n' "$MAIL_VMAIL_HOME"
  printf 'mail_plugins = $mail_plugins quota\n'
  printf '!include %s/auth-passwdfile.conf\n' "$D/etc"
  printf 'service lmtp {\n  unix_listener %s/lmtp {\n    mode = 0600\n  }\n}\n' "$D"
  printf 'service quota-status {\n  executable = quota-status -p postfix\n  unix_listener %s/quota-status {\n    mode = 0600\n  }\n  client_limit = 1\n}\n' "$D"
  printf 'service auth {\n  unix_listener auth-userdb {\n    mode = 0660\n    user = %s\n    group = %s\n  }\n}\n' "$VM" "$VM"
  printf 'protocol lmtp {\n%s  postmaster_address = postmaster@facts.test\n}\n' "${SIEVE:+  mail_plugins = \$mail_plugins sieve
}"
  printf 'plugin {\n  quota = count:User quota\n  quota_vsizes = yes\n  quota_rule = *:storage=1G\n  quota_status_success = DUNNO\n  quota_status_nouser = DUNNO\n  quota_status_overquota = "552 5.2.2 Mailbox is over quota"\n%s}\n' "${SIEVE:+  sieve_before = $D/sieve/spam-to-junk.sieve
}"
} >"$D/dovecot.conf"
VERSION="$(dovecot --version 2>/dev/null | cut -d' ' -f1)"
printf 'Dovecot %s, with the user databases as lomp configures them; the spam rule: %s\n' "$VERSION" "$(if [[ -n "$SIEVE" ]]; then echo "as lomp writes it"; else echo "left out (dovecot-sieve is not installed)"; fi)"
if ! doveconf "${DC[@]}" -n >/dev/null 2>"$D/doveconf.err"; then
  bad "Dovecot takes the configuration" "$(cat "$D/doveconf.err")"; printf '\nRESULT: %s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi
dovecot "${DC[@]}" 2>"$D/start.err"
for i in $(seq 1 30); do [[ -S "$D/lmtp" ]] && break; sleep 0.3; done
if [[ ! -S "$D/lmtp" ]]; then
  bad "a Dovecot of its own starts" "$(cat "$D/start.err" "$D/dovecot.log" 2>/dev/null | tail -n 12)"; printf '\nRESULT: %s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi
ok "a Dovecot of its own runs beside the machine's (${VERSION})"

# ---- a message, handed over as Postfix hands one over ---------------------------------------
cat >"$D/lmtp.py" <<'PY'
import socket
import sys
import threading
import time


class Lmtp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(30)
        self.s.connect(path)
        self.f = self.s.makefile("rb")
        self.answer()
        self.say(b"LHLO mail.facts.test")

    def answer(self):
        while True:
            line = self.f.readline()
            if not line:
                return "LOST the connection was closed"
            if len(line) < 4 or line[3:4] != b"-":
                return line.decode("utf-8", "replace").strip()

    def say(self, cmd):
        self.s.sendall(cmd + b"\r\n")
        return self.answer()

    def hand_over(self, data, rcpts):
        """-> one answer per recipient (the one to RCPT TO when that was refused)"""
        out, taken = {}, []
        self.say(b"MAIL FROM:<>")
        for r in rcpts:
            a = self.say(b"RCPT TO:<" + r.encode() + b">")
            if a.startswith("250"):
                taken.append(r)
            else:
                out[r] = "RCPT " + a
        if taken:
            self.say(b"DATA")
            wire = b"".join((b"." + l if l.startswith(b".") else l) + b"\r\n" for l in data.split(b"\n")[:-1])
            self.s.sendall(wire + b".\r\n")
            for r in taken:
                out[r] = self.answer()
        else:
            self.say(b"RSET")
        return [out[r] for r in rcpts]


def message(qid, subject, extra=b""):
    return (b"Received: from client.example.org (unknown [203.0.113.5])\n"
            b"\tby mail.facts.test (Postfix) with ESMTPS id " + qid.encode() + b"\n"
            b"\tfor <info@new.facts.test>; Tue, 13 Oct 2026 12:00:00 +0300 (+03)\n"
            b"Message-ID: <" + qid.encode() + b"@example.org>\n"
            b"Delivered-To: somebody@an-earlier-hop.example\n"
            b"From: A Sender <a@example.org>\n"
            b"Subject: " + subject.encode() + b"\n" + extra +
            b"\n"
            b"a line of the body\n"
            b".a line that begins with a dot\n"
            b"T\xc3\xbcrk\xc3\xa7e \xc3\xa7\xc4\x9f\xc4\xb1\xc3\xb6\xc5\x9f\xc3\xbc, eight bits\n"
            b"the last line\n")


if sys.argv[1] == "message":     # the message of a queue id, as it is handed over: to standard output
    sys.stdout.buffer.write(message(sys.argv[2], sys.argv[3]))
    sys.exit(0)
if sys.argv[1] == "policy":      # what Dovecot's quota service answers when Postfix asks about a recipient
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    s.connect(sys.argv[2])
    s.sendall(("request=smtpd_access_policy\nprotocol_state=RCPT\nprotocol_name=ESMTP\nrecipient=%s\nsize=1000\n\n" % sys.argv[3]).encode())
    got = b""
    while b"\n\n" not in got:
        chunk = s.recv(4096)
        if not chunk:
            break
        got += chunk
    print(" ".join(got.decode("utf-8", "replace").split()) or "NO ANSWER")
    sys.exit(0)
mode, sock, out = sys.argv[1], sys.argv[2], sys.argv[3]
if mode == "one":
    qid, subject = sys.argv[4], sys.argv[5]
    extra = b"X-Spam: Yes\n" if subject.startswith("spam") else b""
    data = message(qid, subject, extra)
    with open(out, "wb") as fh:
        fh.write(data)
    for a in Lmtp(sock).hand_over(data, sys.argv[6:]):
        print(a)
else:
    # "busy": several connections hand messages over all the time until the stop file is there;
    # one line per message: its queue id, the answer
    stop, conns = sys.argv[4], int(sys.argv[5])
    lock = threading.Lock()
    report = open(out, "w", buffering=1)

    def work(k):
        n = 0
        conn = None
        import os
        while not os.path.exists(stop):
            n += 1
            qid = "B%dQ%05d" % (k, n)
            try:
                if conn is None:
                    conn = Lmtp(sock)
                a = conn.hand_over(message(qid, "busy"), ["info@new.facts.test"])[0]
            except Exception as e:
                a = "LOST %s" % e
            if not a.startswith("250"):
                try:
                    conn.s.close()
                except Exception:
                    pass
                conn = None
                time.sleep(0.05)
            with lock:
                report.write("%s\t%s\n" % (qid, " ".join(a.split())))

    threads = [threading.Thread(target=work, args=(k,)) for k in range(conns)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
PY
hand() {   # queue id, subject, recipient... -> the answers, one per recipient; the message as handed over is $D/handed.<queue id>
  python3 "$D/lmtp.py" one "$D/lmtp" "$D/handed.$1" "$@" 2>&1
}
files() {   # mailbox (domain/local), subject -> its message files of that subject, in any folder
  grep -rl "^Subject: $2\$" "$MAIL_VMAIL_HOME/$1/Maildir" 2>/dev/null | grep -E '/(new|cur)/[^/]*$' | sort
}
same() {   # a mailbox file, the message as handed over -> "the same" when the file is that message below what Dovecot put on top
  if lib_mail_msg_as_queued "$1" | cmp -s - "$2"; then echo "the same"; else echo "DIFFERENT: $(lib_mail_msg_as_queued "$1" | cmp - "$2" 2>&1 | cut -c1-120)"; fi
}

sec "a message handed over for one recipient"
a="$(hand 4FACTS1ONE one-recipient info@new.facts.test)"
has "Dovecot takes it" "250 " "$a"
f="$(files new.facts.test/info one-recipient | sed -n 1p)"
eq "it is in the mailbox once" "1" "$(files new.facts.test/info one-recipient | grep -c .)"
printf '   what Dovecot %s put on top of it:\n' "$VERSION"; sed -n '1,/^Received: from client/p' "${f:-/dev/null}" | sed '$d' | sed 's/\t/^I/g; s/^/   | /'
eq "the first line is the Return-Path" "Return-Path: <>" "$(sed -n 1p "${f:-/dev/null}")"
eq "Dovecot names the recipient it was handed over for, and lomp reads it" "info@new.facts.test" "$(lib_mail_msg_delivered_to "${f:-/dev/null}")"
has "its own Received line says LMTP" "with LMTP" "$(sed -n '1,/^Received: from client/p' "${f:-/dev/null}" | tr '\n' ' ')"
eq "below what Dovecot put on top, the file is the message as it was handed over, byte for byte" "the same" "$(same "${f:-/dev/null}" "$D/handed.4FACTS1ONE")"
eq "the file names the queue file it was handed over from" "4FACTS1ONE" "$(lib_mail_msg_queue_file "${f:-/dev/null}" $'OTHER1\n4FACTS1ONE\n4FACTS1')"
eq "and the line of that hop is the one the message came with" "$(lib_mail_msg_hop "$D/handed.4FACTS1ONE")" "$(lib_mail_msg_hop "${f:-/dev/null}")"
eq "the message's own Message-ID is read, not anything of Dovecot's" "<4facts1one@example.org>" "$(lib_mail_msg_id <"${f:-/dev/null}")"

sec "a message handed over for two recipients in one go"
a="$(hand 4FACTS2TWO two-recipients info@new.facts.test sales@new.facts.test)"
eq "Dovecot takes it for both" "2" "$(grep -c '^250 ' <<<"$a")"
f1="$(files new.facts.test/info two-recipients | sed -n 1p)"; f2="$(files new.facts.test/sales two-recipients | sed -n 1p)"
eq "each mailbox has it once" "1 1" "$(files new.facts.test/info two-recipients | grep -c .) $(files new.facts.test/sales two-recipients | grep -c .)"
printf '   on top of it:\n'; sed -n '1,/^Received: from client/p' "${f1:-/dev/null}" | sed '$d' | sed 's/\t/^I/g; s/^/   | /'
eq "Dovecot names no recipient on such a message: the Delivered-To further down is an earlier hop's, and lomp does not take it" "|" "$(lib_mail_msg_delivered_to "${f1:-/dev/null}")|$(lib_mail_msg_delivered_to "${f2:-/dev/null}")"
eq "both files are the message as it was handed over" "the same the same" "$(same "${f1:-/dev/null}" "$D/handed.4FACTS2TWO") $(same "${f2:-/dev/null}" "$D/handed.4FACTS2TWO")"

sec "the address a mailbox had before a rename"
has "Dovecot knows the old address as another name of the mailbox" "info@new.facts.test" "$(doveadm "${DC[@]}" user info@old.facts.test 2>&1 | tr '\n' ' ')"
has "with the directory of the mailbox" "$MAIL_VMAIL_HOME/new.facts.test/info" "$(doveadm "${DC[@]}" user -f home info@old.facts.test 2>&1)"
has "and its quota" "*:storage=2G" "$(doveadm "${DC[@]}" user info@old.facts.test 2>&1 | tr '\n' ' ')"
a="$(hand 4FACTS3OLD under-the-old-address info@old.facts.test)"
has "a message handed over under the old address is taken" "250 " "$a"
f="$(files new.facts.test/info under-the-old-address | sed -n 1p)"
eq "into the mailbox that had the address" "1" "$(files new.facts.test/info under-the-old-address | grep -c .)"
eq "nothing is made under the old name" "" "$(ls -A "$MAIL_VMAIL_HOME/old.facts.test" 2>/dev/null)"
eq "Dovecot names the address it was handed over for - the old one" "info@old.facts.test" "$(lib_mail_msg_delivered_to "${f:-/dev/null}")"
eq "and the file is the message as it was handed over" "the same" "$(same "${f:-/dev/null}" "$D/handed.4FACTS3OLD")"
eq "where lomp looks for mail of the old address is that mailbox" "$MAIL_VMAIL_HOME/new.facts.test/info" "$(lib_mail_address_home info@old.facts.test)"
if doveadm "${DC[@]}" auth test info@new.facts.test "$PW" >/dev/null 2>&1; then ok "(the password of the mailbox signs in under its address)"; else bad "(the password of the mailbox signs in under its address)" "$(doveadm "${DC[@]}" auth test info@new.facts.test "$PW" 2>&1 | tail -n 3)"; fi
if doveadm "${DC[@]}" auth test info@old.facts.test "$PW" >/dev/null 2>&1; then bad "nobody signs in under the old address" "the password of the mailbox was taken"; else ok "nobody signs in under the old address"; fi
a="$(hand 4FACTS3NONE for-nobody nobody@new.facts.test)"
has "an address that is in neither list is nobody" "RCPT 550" "$a"
# ... and what Postfix is told when it asks about a recipient before it takes a message
# (Dovecot's quota service, which lomp has it ask at every RCPT TO)
policy() { python3 "$D/lmtp.py" policy "$D/quota-status" "$1" 2>&1; }
eq "asked about a mailbox with room, Dovecot leaves the decision to Postfix" "action=DUNNO" "$(policy info@new.facts.test)"
eq "about its old address too" "action=DUNNO" "$(policy info@old.facts.test)"
eq "and about an address that is nobody's" "action=DUNNO" "$(policy nobody@new.facts.test)"
# a server no site of which was ever renamed has a list with nothing in it - lomp writes the
# file all the same, because of what Dovecot says without it:
cp -p "$(lib_mail_former_file)" "$D/former.kept"; : >"$(lib_mail_former_file)"; sleep 1.2
eq "with a list that has no line, Dovecot answers for a mailbox as before" "action=DUNNO" "$(policy info@new.facts.test)"
eq "and for an address that is nobody's" "action=DUNNO" "$(policy nobody@new.facts.test)"
has "an address that left the list is nobody again" "RCPT 550" "$(hand 4FACTS3LEFT left-the-list info@old.facts.test)"
rm -f "$(lib_mail_former_file)"; sleep 1.2
printf '   without the file of the list, asked about an address that is nobody'"'"'s, Dovecot %s says: %s\n' "$VERSION" "$(policy nobody@new.facts.test | cut -c1-110)"
eq "(a mailbox is still answered for)" "action=DUNNO" "$(policy info@new.facts.test)"
cp -p "$D/former.kept" "$(lib_mail_former_file)"; sleep 1.2
has "(the list is back: the old address is taken again)" "250 " "$(hand 4FACTS3BACK back-in-the-list info@old.facts.test)"

if [[ -n "$SIEVE" ]]; then
  sec "a message Rspamd marked as spam"
  a="$(hand 4FACTS4SPAM spam-marked info@new.facts.test)"
  has "Dovecot takes it" "250 " "$a"
  f="$(files new.facts.test/info spam-marked | sed -n 1p)"
  has "the spam rule files it into Junk" "/Maildir/.Junk/" "$f"
  has "lomp finds it there among the messages of the mailbox" "$f" "$(lib_mail_box_messages "$MAIL_VMAIL_HOME/new.facts.test/info")"
  eq "and the file is the message as it was handed over" "the same" "$(same "${f:-/dev/null}" "$D/handed.4FACTS4SPAM")"
fi

sec "Dovecot told to read its configuration again while messages are handed over"
# What lomp's look after a reload is for: Dovecot ends the deliveries it is in the middle of,
# and answers "Shutting down" for a message it has saved.
python3 "$D/lmtp.py" busy "$D/lmtp" "$D/busy.report" "$D/busy.stop" 4 &
sleep 1
for i in 1 2 3 4 5 6 7 8; do doveadm "${DC[@]}" reload >/dev/null 2>&1; sleep 0.7; done
sleep 0.5; : >"$D/busy.stop"; wait
taken="$(grep -c $'\t250 ' "$D/busy.report")"; cut="$(grep -vc $'\t250 ' "$D/busy.report")"
shut="$(grep -c 'Shutting down' "$D/busy.report")"
printf '   %s messages taken, %s answered otherwise: %s\n' "$taken" "$cut" "$(grep -v $'\t250 ' "$D/busy.report" | cut -f2 | sed -E 's/[0-9A-Za-z+/]{16,}/ID/g' | cut -c1-70 | sort | uniq -c | sort -rn | sed -n '1,4p' | tr '\n' ';' | tr -s ' ')"
if [ "$taken" -ge 50 ]; then ok "mail went on being taken through eight reloads ($taken messages)"; else bad "mail went on being taken through eight reloads" "$taken taken; $(tail -n 3 "$D/busy.report" | tr '\n' ' ')"; fi
# which queue ids the mailbox has a message of, and every message Dovecot did not answer 250
# for: is it in the mailbox all the same?
box="$MAIL_VMAIL_HOME/new.facts.test/info"
lib_mail_box_messages "$box" -print0 | xargs -0 -r grep -hoE 'with ESMTPS id B[0-9]+Q[0-9]+' 2>/dev/null | awk '{ print $NF }' | sort >"$D/busy.inbox"
saved=0; saved_same=0; not_saved=0
while IFS=$'\t' read -r q why; do
  if [[ "$why" == 250\ * ]]; then continue; fi
  f="$(lib_mail_box_messages "$box" -print0 | xargs -0 -r grep -lF "ESMTPS id $q" 2>/dev/null | sed -n 1p)"
  if [[ -n "$f" ]]; then
    saved=$((saved + 1))
    python3 "$D/lmtp.py" message "$q" busy >"$D/busy.msg"
    if [[ "$(lib_mail_msg_queue_file "$f" "$q")" == "$q" && "$(same "$f" "$D/busy.msg")" == "the same" && "$(lib_mail_msg_delivered_to "$f")" == "info@new.facts.test" ]]; then saved_same=$((saved_same + 1)); fi
  else not_saved=$((not_saved + 1)); fi
done <"$D/busy.report"
printf '   of the %s that were not answered 250: %s lie in the mailbox all the same (answered "Shutting down": %s), %s do not\n' "$cut" "$saved" "$shut" "$not_saved"
eq "every message that lies in the mailbox although Dovecot gave it back is told by lomp's proof: that queue file, the same bytes, for that recipient" "$saved" "$saved_same"
eq "no message is in the mailbox twice by Dovecot's own doing" "0" "$(uniq -d "$D/busy.inbox" | grep -c .)"
eq "every message Dovecot answered 250 for is in the mailbox" "0" "$(awk -F'\t' '$2 ~ /^250 / { print $1 }' "$D/busy.report" | sort | comm -23 - "$D/busy.inbox" | grep -c .)"

printf '\nRESULT: %s passed, %s failed (Dovecot %s)\n' "$PASS" "$FAIL" "$VERSION"
[ "$FAIL" = 0 ]
