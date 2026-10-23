#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-fail2ban.sh - DESTRUCTIVE end-to-end test of "lomp fail2ban on|off [--ufw]|status|
#  refresh", "lomp ufw", and of the rule that fail2ban never bans Cloudflare or Google's crawlers.
#
#  What is checked is what the server does: whether systemd runs fail2ban and starts it at boot,
#  whether a package upgrade or a lomp command starts it again behind the operator's back, and
#  which addresses a real fail2ban bans from a log it reads - Google's crawler by the published
#  ranges and, with those taken away, by the reverse DNS check. A server set up before the allow
#  list is made by taking its files away again (and ignoreip back into the base jails), and
#  migrate brings it along.
#
#  UFW is stood in for: WSL distros share one network namespace, and a real "ufw enable" here
#  would filter every distro of the machine. The stand-in keeps the state lomp switches.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It stops and starts fail2ban, reinstalls its package
#  and bans test addresses (with fail2ban's dummy action: no firewall rule is written for them).
#  It needs the internet: Google's ranges, and Google's address resolving to its googlebot.com name.
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-fail2ban.sh [tree to test, default: this checkout]
# =============================================================================
set -u
export LOMP_LANG=en LOMP_MENU_LANG=en
if [[ "${LOMPSTACK_INTEGRATION:-}" != "yes" ]]; then
  printf '%s\n' "This test stops fail2ban, reinstalls its package and bans test addresses." \
    "Run it only on a throwaway server:  LOMPSTACK_INTEGRATION=yes bash $0" >&2
  exit 2
fi
if [[ "$(id -u)" != 0 ]]; then printf 'Run it as root.\n' >&2; exit 2; fi
need() { printf 'Cannot run here: %s\n' "$1" >&2; exit 2; }
[[ -s /root/.server-setup/manifest.json ]] || need "lomp is not installed on this server (setup.sh install)"
dpkg -s fail2ban >/dev/null 2>&1 || need "fail2ban is not installed"
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
mkdir -p "$T/src"
cp -r "$SRC/setup.sh" "$SRC/lib" "$SRC/tests" "$T/src/"
L="bash $T/src/setup.sh"
GB=/usr/local/sbin/lomp-f2b-goodbot
GBJ=/etc/fail2ban/jail.d/server-setup-allow.conf
BASEJ=/etc/fail2ban/jail.d/server-setup.conf
GLIST=/root/.server-setup/google-crawler-ips.conf
EJ=/etc/fail2ban/jail.d/zz-lomp-e2e.conf
# the UFW stand-in (see the top)
UFWS=/root/ufw-state
printf 'active\n' >"$UFWS"
cat >/usr/local/sbin/ufw <<'EOF'
#!/bin/sh
echo "ufw $*" >>/root/ufw-calls.log
case "$*" in
  status*) echo "Status: $(cat /root/ufw-state)" ;;
  "show added") echo "ufw allow 22/tcp" ;;
  "--force enable") echo active >/root/ufw-state ;;
  "--force disable") echo inactive >/root/ufw-state ;;
esac
exit 0
EOF
chmod +x /usr/local/sbin/ufw; : >/root/ufw-calls.log
ELOG="$T/e2e-access.log"
GOOGLE=66.249.66.1
OTHER=203.0.113.77
f2b_wait() {   # wait until fail2ban answers (a start or reload takes a moment)
  local i=0
  while (( i < 30 )); do fail2ban-client ping >/dev/null 2>&1 && return 0; sleep 1; i=$((i + 1)); done
  return 1
}
manifest() { jq -r "$1 // empty" /root/.server-setup/manifest.json; }
cleanup() { rm -f "$EJ" /usr/local/sbin/ufw; fail2ban-client reload >/dev/null 2>&1 || true; }
trap cleanup EXIT

sec "the starting point: fail2ban on"
$L fail2ban on >"$T/on0.out" 2>&1 || true
check "fail2ban runs"                            systemctl is-active --quiet fail2ban
f2b_wait || true

sec "a server set up before the allow list: migrate brings it"
rm -f "$GB" "$GBJ" "$GLIST"
grep -q '^ignoreip' "$BASEJ" || sed -i 's/^backend = systemd$/&\nignoreip = 127.0.0.1\/8 ::1/' "$BASEJ"
fail2ban-client reload >/dev/null 2>&1; f2b_wait || true
out="$($L migrate 2>&1)"; rc=$?
eq  "migrate succeeds"                           0 "$rc"
has "and says so"                                "fail2ban never bans Cloudflare's edge and Google's crawlers now" "$out"
check "the script is there, executable"          test -x "$GB"
check "and the allow file"                       test -s "$GBJ"
nope "the old ignoreip left the base jails"      grep -q '^ignoreip' "$BASEJ"
n="$(grep -vc '^#' "$GLIST" 2>/dev/null)"
if (( ${n:-0} >= 100 )); then ok "Google's ranges were fetched (${n})"; else bad "Google's ranges were fetched" "${n:-none}"; fi
check "fail2ban accepts its configuration"       fail2ban-client --test
f2b_wait || true
ign="$(fail2ban-client get sshd ignoreip 2>&1)"
has "sshd ignores a Google range"                "66.249.66.0/27" "$ign"
has "and a Cloudflare one"                       "173.245.48.0/20" "$ign"
has "and this machine"                           "127.0.0.0/8" "$ign"
has "the sshd jail asks the script before a ban" "$GB" "$(fail2ban-client get sshd ignorecommand 2>&1)"
out="$($L migrate 2>&1)"
lacks "a second migrate has nothing to add"      "never bans Cloudflare's edge" "$out"
printf '[DEFAULT]\nignoreip = 127.0.0.1/8\n' >/etc/fail2ban/jail.d/zz-own.local
out="$($L fail2ban refresh 2>&1)"; rc=$?
eq  "refresh succeeds"                           0 "$rc"
has "an operator's own ignoreip is named"        "zz-own.local sets ignoreip, which replaces lomp's list" "$out"
rm -f /etc/fail2ban/jail.d/zz-own.local

sec "the script against the real DNS"
if getent hosts "$GOOGLE" | grep -q 'googlebot\.com'; then
  dns=1
  check "Google's crawler address: never banned"  "$GB" "$GOOGLE"
  nope  "8.8.8.8 (dns.google) is no crawler"       "$GB" 8.8.8.8
  nope  "a documentation address is no crawler"    "$GB" "$OTHER"
  nope  "not an address"                            "$GB" 'x;id'
else
  dns=0
  printf 'skip  no reverse DNS for %s here: the crawler checks are left out\n' "$GOOGLE"
fi

sec "a real fail2ban bans the prober and leaves Cloudflare and Google's crawler alone"
CFIP=172.68.195.206
probe_round() {   # jail-name prober -> the jail's banned list once the prober is banned (or 30 s)
  local jail="$1" prober="$2" ip="" now="" i="" banned=""
  : >"$ELOG"
  printf '[%s]\nenabled = true\nfilter = server-setup-web-probe\nbackend = polling\nlogpath = %s\nport = http,https\nmaxretry = 3\nfindtime = 10m\nbantime = 10m\nbanaction = dummy\n' "$jail" "$ELOG" >"$EJ"
  fail2ban-client reload >/dev/null 2>&1; f2b_wait || true
  sleep 2
  now="$(LC_ALL=C date '+%d/%b/%Y:%H:%M:%S %z')"
  for i in 1 2 3 4 5 6; do
    for ip in "$GOOGLE" "$CFIP" "$prober"; do
      printf '%s - - [%s] "GET /.env HTTP/1.1" 404 153 "-" "Mozilla/5.0"\n' "$ip" "$now" >>"$ELOG"
    done
  done
  for i in $(seq 1 30); do
    banned="$(fail2ban-client get "$jail" banned 2>/dev/null)"
    [[ "$banned" == *"$prober"* ]] && break
    sleep 1
  done
  sleep 3
  fail2ban-client get "$jail" banned 2>/dev/null
}
banned="$(probe_round "lomp-e2e-r1-$$" "$OTHER")"
has   "the prober is banned"                     "$OTHER" "$banned"
lacks "Google's crawler is not"                  "$GOOGLE" "$banned"
lacks "nor a Cloudflare edge address"            "$CFIP" "$banned"
f2blog="$(tail -n 400 /var/log/fail2ban.log)"
has   "Google: by its published range"           "Ignore ${GOOGLE} by ip" "$f2blog"
has   "Cloudflare: by its range"                 "Ignore ${CFIP} by ip" "$f2blog"
if (( dns )); then
  # a crawler address newer than the list: the ranges taken away, the reverse DNS check decides
  grep -vxF -f <(sed 's/^/           /' "$GLIST") "$GBJ" >"$T/allow-nogoogle" && cp "$T/allow-nogoogle" "$GBJ"
  lacks "(the Google ranges are gone)"           "66.249.66.0/27" "$(cat "$GBJ")"
  banned="$(probe_round "lomp-e2e-r2-$$" 203.0.113.78)"
  has   "the prober is banned"                   "203.0.113.78" "$banned"
  lacks "Google's crawler is not"                "$GOOGLE" "$banned"
  has   "by the reverse DNS check"               "Ignore ${GOOGLE} by command" "$(tail -n 400 /var/log/fail2ban.log)"
  $L fail2ban refresh >/dev/null 2>&1
  f2b_wait || true
  has   "refresh puts the ranges back"           "66.249.66.0/27" "$(fail2ban-client get sshd ignoreip 2>&1)"
fi
rm -f "$EJ"; fail2ban-client reload >/dev/null 2>&1; f2b_wait || true

sec "off: stopped, not started at boot, and nothing starts it again"
out="$($L fail2ban off 2>&1)"; rc=$?
eq  "off succeeds"                               0 "$rc"
has "it says it stays off"                       "stays off after a reboot and after updates" "$out"
has "and what that leaves open"                  "Nothing bans an address that keeps guessing passwords" "$out"
nope "fail2ban does not run"                     systemctl is-active --quiet fail2ban
nope "nor start at boot"                         systemctl is-enabled --quiet fail2ban
eq  "the manifest remembers"                     off "$(manifest .fail2ban)"
eq  "UFW is left alone without --ufw"            active "$(cat "$UFWS")"
out="$($L fail2ban status 2>&1)"
has "status: off"                                "off" "$(grep -E '^ *switched' <<<"$out")"
has "status: inactive"                           "inactive" "$(grep -E '^ *service' <<<"$out")"
has "status: what is never banned"               "Google crawlers" "$out"
out="$($L doctor 2>&1)"
has  "doctor: switched off, not a failure"       "switched off (lomp fail2ban on switches it on)" "$out"
lacks "doctor: no fail2ban failure"              "fail2ban at boot" "$out"
out="$($L migrate 2>&1)"
has  "migrate says it is off"                    "fail2ban is switched off" "$out"
nope "migrate does not start it"                 systemctl is-active --quiet fail2ban
if apt-get install --reinstall -y -q fail2ban >"$T/reinstall.out" 2>&1; then
  nope "a package upgrade does not start it"     systemctl is-active --quiet fail2ban
  nope "nor enable it"                           systemctl is-enabled --quiet fail2ban
else
  printf 'skip  apt-get could not reinstall fail2ban here (no network?)\n'
fi
out="$($L fail2ban refresh 2>&1)"
nope "nor does the weekly refresh"               systemctl is-active --quiet fail2ban

sec "off --ufw: UFW goes with it, its rules kept"
: >/root/ufw-calls.log
out="$($L fail2ban off --ufw 2>&1)"; rc=$?
eq  "off --ufw succeeds"                         0 "$rc"
eq  "UFW is off"                                 inactive "$(cat "$UFWS")"
eq  "the manifest remembers"                     off "$(manifest .ufw)"
has "it says the rules are kept"                 "its rules are kept" "$out"
has "and lists what answers from outside"        "Reachable from the internet now" "$out"
has "the web server among them"                  "80/tcp" "$out"
lacks "no rule was deleted"                      "delete" "$(cat /root/ufw-calls.log)"
out="$($L doctor 2>&1)"
has  "doctor: UFW switched off, not a failure"   "switched off (lomp ufw on switches it on)" "$out"
lacks "doctor: no firewall failure"              "firewall inactive" "$out"
$L migrate >/dev/null 2>&1
eq  "migrate does not switch UFW on"             inactive "$(cat "$UFWS")"
has "firewall status says so"                    "switched off: no rule of it applies" "$($L firewall status 2>&1)"
has "ufw status"                                 "off" "$($L ufw status 2>&1 | grep 'UFW switched')"

sec "on --ufw: both running and started at boot again, every jail back"
out="$($L fail2ban on --ufw 2>&1)"; rc=$?
eq  "on succeeds"                                0 "$rc"
check "fail2ban runs"                            systemctl is-active --quiet fail2ban
check "and starts at boot"                       systemctl is-enabled --quiet fail2ban
eq  "the manifest remembers"                     on "$(manifest .fail2ban)"
eq  "UFW is on"                                  active "$(cat "$UFWS")"
eq  "(remembered)"                               on "$(manifest .ufw)"
f2b_wait || true
has "the sshd jail is loaded"                    "sshd" "$(fail2ban-client status 2>&1)"
has "still asking about crawlers"                "$GB" "$(fail2ban-client get sshd ignorecommand 2>&1)"
has "and ignoring Google's ranges"               "66.249.66.0/27" "$(fail2ban-client get sshd ignoreip 2>&1)"
out="$($L doctor 2>&1)"
has "doctor: active"                             "active, sshd jail loaded" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
