#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-redirect-cert.sh - DESTRUCTIVE end-to-end test of a redirect that is left
#  holding a certificate nothing renews.
#
#  "import" can bring the certificate a site answers with: a copy in the deploy directory,
#  with no lineage at certbot, and a mark in the site's record (.ssl.imported) so that
#  "renew-ssl --missing" replaces it. Rename such a site and the record is the new name's,
#  while the copy stays with the old name - the redirect - which answered under it until the
#  day it ran out. Here a real site on a real OpenLiteSpeed is renamed in that state, and its
#  old name is watched: the certificate it presents over HTTPS, where it sends a visitor,
#  what rename, doctor, "renew-ssl --missing" and "redirect add" say and do about it - while
#  its DNS still points elsewhere, and once it points here.
#
#  The site is not imported. It gets a certificate through "renew-ssl" and is then made what
#  an import leaves: the lineage taken away, the record marked. The run of a real import over
#  such a rename belongs to the import test.
#
#  certbot and the DNS answers for the test's names are stand-ins, first in PATH for this
#  test's own commands only: a self-signed certificate for the test's names, and a Cloudflare
#  address as their DNS answer (or another address while "DNS points elsewhere"). Both refuse
#  every other name.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It adds, renames and removes real sites
#  (rdcert-e2e.lomptest.net, rdcert2-e2e.lomptest.net), reloads OpenLiteSpeed many times,
#  runs "renew-ssl --missing" - which asks for a certificate for every site of the server
#  that has none (the stand-ins refuse them) - and leaves the server as it found it.
#
#  Needs: an installed lomp server.
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-redirect-cert.sh [tree to test, default: this checkout]
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
[[ -s /root/.server-setup/manifest.json ]] || { printf 'Cannot run here: lomp is not installed on this server (setup.sh install)\n' >&2; exit 2; }
WT="${1:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
OLD="rdcert-e2e.lomptest.net"; NEW="rdcert2-e2e.lomptest.net"
SRC="/tmp/lomp-rdcert-e2e"; STATE="/root/.server-setup/domains"
DEPLOY="/etc/server-setup/ssl"; LIVE="/etc/letsencrypt/live"
PASS=0; FAIL=0
ok()    { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()   { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected: $2, got: $3)"; fi; }
has()   { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
lacks() { if grep -qF -- "$2" <<<"$3"; then bad "$1 (found: $2)"; else ok "$1"; fi; }
lomp()  { PATH="$SRC/bin:$PATH" bash "$SRC/tree/setup.sh" "$@" --non-interactive --no-color; }
show()  { grep -E "$2" "$1" | cut -c1-230 | sed 's/^/   | /'; }
# the certificate file the servers read for a name, and the one OpenLiteSpeed presents for it
fp()     { openssl x509 -noout -fingerprint -sha256 -in "$DEPLOY/$1/fullchain.pem" 2>/dev/null | cut -d= -f2; }
served() {   # retried: the server is reloaded while this runs, by this test and by others
  local o="" n=0
  while (( n < 8 )); do
    o="$(openssl s_client -connect 127.0.0.1:443 -servername "$1" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
    [[ -n "$o" ]] && break
    n=$((n + 1)); sleep 2
  done
  printf '%s' "$o"
}
# what a visitor of https://<name>/some/path?x=1 gets: the status and where it sends them
goes()  {
  local o="" n=0
  while (( n < 8 )); do
    o="$(curl -s -o /dev/null -m 15 -k --resolve "$1:443:127.0.0.1" -w '%{http_code} %{redirect_url}' "https://$1/some/path?x=1")"
    [[ "$o" == 3* || "$o" == 2* ]] && break
    n=$((n + 1)); sleep 2
  done
  printf '%s' "$o"
}
rec()    { jq -r "$2" "$STATE/$1/domain.json" 2>/dev/null; }
asked()  { grep -c -- "^certonly .*--cert-name $1 " "$SRC/certbot.log" 2>/dev/null || true; }
others() { ls "$STATE" | grep -v -e "^$OLD\$" -e "^$NEW\$" | while read -r d; do cat "$STATE/$d/domain.json" "$STATE/$d/redirect.json" 2>/dev/null; done | cksum; }
drop() {
  local d=""
  for d in "$OLD" "$NEW"; do
    [ -s "$STATE/$d/redirect.json" ] && lomp redirect del "$d" --yes >/dev/null 2>&1
    [ -d "/home/$d" ] && lomp remove "$d" --yes >/dev/null 2>&1
    rm -rf "/var/backups/server-setup/$d"
    [ -e "$LIVE/$d/.stand-in" ] && rm -rf "${LIVE:?}/$d"
  done
  return 0
}
# A site under the old name with a certificate that certbot issued: a lineage, and the copy
# the servers read.
site() {
  drop
  lomp add "$OLD" --www --no-ssl --static >"$SRC/add.out" 2>&1 || { tail -n 15 "$SRC/add.out"; return 1; }
  lomp renew-ssl "$OLD" >"$SRC/renew.out" 2>&1 || { tail -n 15 "$SRC/renew.out"; return 1; }
  [ -e "$LIVE/$OLD/.stand-in" ] && [ -s "$DEPLOY/$OLD/fullchain.pem" ]
}
# ... made what "import" leaves of a certificate it brought: the copy alone, and the mark
copy_of_it() {
  rm -rf "${LIVE:?}/$1"
  if [ -s "$STATE/$1/domain.json" ]; then
    jq '.ssl.imported = true' "$STATE/$1/domain.json" >"$SRC/t.json" && cat "$SRC/t.json" >"$STATE/$1/domain.json"
  fi
}

for s in mariadb lsws; do systemctl is-active --quiet "$s" || systemctl start "$s"; done; sleep 3
rm -rf "$SRC"; mkdir -p "$SRC/tree" "$SRC/bin"; cp -r "$WT/setup.sh" "$WT/lib" "$SRC/tree/"
echo "tree: $WT ($(grep -c SSL_UNRENEWED "$SRC/tree/lib/rename.sh") mention(s) of SSL_UNRENEWED in lib/rename.sh)"
cat >"$SRC/bin/certbot" <<'CERTBOT_STAND_IN'
#!/usr/bin/env bash
# Stand-in for certbot, first in PATH for this test's own commands only. A name that does not
# resolve from outside cannot get a Let's Encrypt certificate, so this does what certbot would:
# a certificate under the lineage name it is given, for the names it is given. Self-signed,
# five days. It refuses every lineage and name that is not this test's and logs each request.
set -u
MINE=" rdcert-e2e.lomptest.net www.rdcert-e2e.lomptest.net rdcert2-e2e.lomptest.net www.rdcert2-e2e.lomptest.net "
LOG="/tmp/lomp-rdcert-e2e/certbot.log"; LIVE="/etc/letsencrypt/live"
printf '%s\n' "$*" >>"$LOG"
sub="${1:-}"; shift || true
name=""; names=()
while (($# > 0)); do
  a="$1"; shift
  case "$a" in
    --cert-name) name="${1:-}"; shift || true ;;
    -d) names+=("${1:-}"); shift || true ;;
    -w|--email|--key-type|--dns-cloudflare-credentials|--dns-cloudflare-propagation-seconds) shift || true ;;
  esac
done
[[ -n "$name" && "$name" != www.* && "$MINE" == *" $name "* ]] || { echo "stand-in: '${name:-none}' is not this test's lineage" >&2; exit 1; }
for n in ${names[@]+"${names[@]}"}; do
  [[ "$MINE" == *" $n "* ]] || { echo "stand-in: '${n}' is not a name of this test" >&2; exit 1; }
done
if [[ -d "${LIVE}/${name}" && ! -e "${LIVE}/${name}/.stand-in" ]]; then
  echo "stand-in: ${LIVE}/${name} exists and is not this test's" >&2; exit 1
fi
case "$sub" in
  delete) rm -rf "${LIVE:?}/${name}"; exit 0 ;;
  renew)  [[ -e "${LIVE}/${name}/.stand-in" ]] || exit 1; exit 0 ;;   # not due: nothing to do
  certonly)
    ((${#names[@]} > 0)) || exit 1
    mkdir -p "${LIVE}/${name}"; : >"${LIVE}/${name}/.stand-in"
    san=""; for n in "${names[@]}"; do san="${san:+${san},}DNS:${n}"; done
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 5 \
      -keyout "${LIVE}/${name}/privkey.pem" -out "${LIVE}/${name}/cert.pem" \
      -subj "/CN=${names[0]}" -addext "subjectAltName=${san}" >/dev/null 2>&1 || exit 1
    cp "${LIVE}/${name}/cert.pem" "${LIVE}/${name}/fullchain.pem"
    chmod 0600 "${LIVE}/${name}/privkey.pem"
    exit 0 ;;
esac
exit 1
CERTBOT_STAND_IN
cat >"$SRC/bin/dig" <<'DIG_STAND_IN'
#!/usr/bin/env bash
# Stand-in for dig, first in PATH for this test's own commands only: the test's names, which
# exist in no DNS, answer with a Cloudflare address (so a certificate may be asked for them);
# every other question goes to the real dig.
MINE=" rdcert-e2e.lomptest.net www.rdcert-e2e.lomptest.net rdcert2-e2e.lomptest.net www.rdcert2-e2e.lomptest.net "
for a in "$@"; do
  if [[ "$MINE" == *" $a "* ]]; then
    for b in "$@"; do [[ "$b" == "AAAA" ]] && exit 0; done
    # while this file is there the names point somewhere else: "DNS does not point here yet"
    if [[ -e /tmp/lomp-rdcert-e2e/dns-elsewhere ]]; then echo "203.0.113.9"; exit 0; fi
    echo "104.16.0.1"; exit 0
  fi
done
exec /usr/bin/dig "$@"
DIG_STAND_IN
chmod 0755 "$SRC/bin/certbot" "$SRC/bin/dig"
OTHERS_BEFORE="$(others)"
cleanup() {
  echo; echo "===== cleanup"
  drop
  check "homes removed" "[ ! -d /home/$OLD ] && [ ! -d /home/$NEW ]"
  check "deployed certificates and lineages removed" "[ ! -e $DEPLOY/$OLD ] && [ ! -e $LIVE/$OLD ] && [ ! -e $DEPLOY/$NEW ] && [ ! -e $LIVE/$NEW ]"
  check "no record of the test's names is left" "[ ! -e $STATE/$OLD ] && [ ! -e $STATE/$NEW ]"
  eq    "every other site's and redirect's record is byte for byte what it was" "$OTHERS_BEFORE" "$(others)"
  check "OpenLiteSpeed runs" "systemctl is-active --quiet lsws"
  rm -rf "$SRC"
  echo; echo "RESULT: $PASS passed, $FAIL failed"
  (( FAIL == 0 )) || exit 1
}
trap cleanup EXIT
drop

echo "===== A: a site whose certificate is a copy is renamed while its DNS points elsewhere"
site || { bad "A: the site could not be set up"; exit 1; }
copy_of_it "$OLD"
FP0="$(fp "$OLD")"; echo "   the copy: ${FP0:0:29}..."
check "A: the site answers over HTTPS with that certificate" "[ -n '$FP0' ] && [ \"\$(served $OLD)\" = '$FP0' ]"
check "A: which has no lineage at certbot, and the record says it was brought" "[ ! -e $LIVE/$OLD ] && [ \"\$(rec $OLD .ssl.imported)\" = true ]"
: >"$SRC/dns-elsewhere"; : >"$SRC/certbot.log"
lomp rename "$OLD" "$NEW" --yes >"$SRC/renameA.out" 2>&1; RC=$?; echo "rename rc=$RC"
show "$SRC/renameA.out" 'copy|of its own|Renamed|\[warn\]|FAILED'
O="$(cat "$SRC/renameA.out")"
eq    "A: the rename succeeds" 0 "$RC"
has   "A: it is said before anything moves that the certificate is a copy" "that certificate is a copy from another server, which nothing renews here" "$O"
has   "A: the old name is asked for a certificate of its own" "The certificate of $OLD is a copy from another server, which nothing renews here: asking for one of its own" "$O"
has   "A: none can be had, and it is said what the redirect answers under" "$OLD redirects under a certificate that was copied from another server: nothing renews it here, and it runs out in " "$O"
check "A: with the days it has left" "grep -qE 'it runs out in [0-9]+ day\\(s\\)' '$SRC/renameA.out'"
has   "A: why" "One of its own could not be had now: its DNS does not point to this server" "$O"
has   "A: and what to run once its DNS is here, www with it" "Once the DNS of $OLD points here: setup.sh redirect add $OLD $NEW --www " "$O"
eq    "A: certbot was not asked for the old name: its DNS is not here" 0 "$(asked "$OLD")"
eq    "A: the copy is where it was" "$FP0" "$(fp "$OLD")"
eq    "A: and is what the old name presents over HTTPS" "$FP0" "$(served "$OLD")"
eq    "A: a visitor of the old name is sent on, path and query kept" "301 http://$NEW/some/path?x=1" "$(goes "$OLD")"
eq    "A: and of its www name" "301 http://$NEW/some/path?x=1" "$(goes "www.$OLD")"
check "A: it still has no lineage" "[ ! -e $LIVE/$OLD ]"
eq    "A: the new name's record claims no certificate, brought or other" "false null" "$(rec "$NEW" '"\(.ssl.enabled) \(.ssl.imported)"')"
lomp doctor >"$SRC/doctorA.out" 2>&1
show "$SRC/doctorA.out" "redirect $OLD"
has   "A: doctor names the certificate that nothing renews" "its certificate is a copy from another server that nothing renews here; it runs out in " "$(cat "$SRC/doctorA.out")"
has   "A: with the command that fetches one, www with it" "(setup.sh redirect add $OLD $NEW --www)" "$(cat "$SRC/doctorA.out")"

echo; echo "===== B: renew-ssl --missing, DNS still elsewhere: the redirect is taken, and keeps its copy"
: >"$SRC/certbot.log"
lomp renew-ssl --missing >"$SRC/missingB.out" 2>&1; RC=$?; echo "renew-ssl --missing rc=$RC"
show "$SRC/missingB.out" "^== |$OLD|SSL renewal failed"
O="$(cat "$SRC/missingB.out")"
has   "B: the redirect is one of those it asks for" "== redirect add $OLD $NEW ==" "$O"
has   "B: and so is the site under its new name" "== renew-ssl $NEW ==" "$O"
eq    "B: certbot is not asked: the DNS is not here" 0 "$(asked "$OLD")"
F="$(grep -E 'SSL renewal failed for:' "$SRC/missingB.out" | head -n 1)"; echo "   failed list: ${F:-none}"
has   "B: the redirect is among those that got none" " $OLD" "$F "
eq    "B: the run fails" 1 "$RC"
eq    "B: the copy still serves" "$FP0" "$(served "$OLD")"
eq    "B: the other sites are what they were" "$OTHERS_BEFORE" "$(others)"

echo; echo "===== C: the DNS points here: renew-ssl --missing gives the redirect a certificate of its own"
rm -f "$SRC/dns-elsewhere"; : >"$SRC/certbot.log"
lomp renew-ssl --missing >"$SRC/missingC.out" 2>&1; RC=$?; echo "renew-ssl --missing rc=$RC"
show "$SRC/missingC.out" "^== |$OLD|SSL renewal"
O="$(cat "$SRC/missingC.out")"
has   "C: the redirect is asked for" "== redirect add $OLD $NEW ==" "$O"
eq    "C: once, with both its names" 1 "$(grep -c -- "^certonly .*--cert-name $OLD .*-d $OLD -d www.$OLD" "$SRC/certbot.log")"
check "C: it has a lineage now" "[ -e $LIVE/$OLD/.stand-in ]"
FP1="$(fp "$OLD")"; echo "   its own: ${FP1:0:29}..."
check "C: the certificate the servers read is another than the copy" "[ -n '$FP1' ] && [ '$FP1' != '$FP0' ]"
eq    "C: and it is the one presented: OpenLiteSpeed was reloaded for it" "$FP1" "$(served "$OLD")"
eq    "C: the site got its certificate in the same run" "true" "$(rec "$NEW" .ssl.enabled)"
eq    "C: so the old name sends its visitors to https" "301 https://$NEW/some/path?x=1" "$(goes "$OLD")"
F="$(grep -E 'SSL renewal failed for:' "$SRC/missingC.out" | head -n 1)"; echo "   failed list: ${F:-none}"
lacks "C: neither name of the test is among the failed" "rdcert" "$F"
eq    "C: the other sites are what they were" "$OTHERS_BEFORE" "$(others)"
: >"$SRC/certbot.log"
lomp renew-ssl --missing >"$SRC/missingC2.out" 2>&1
lacks "C: asked again, --missing passes it over" "== redirect add $OLD" "$(cat "$SRC/missingC2.out")"
eq    "C: and certbot hears nothing of it" 0 "$(asked "$OLD")"
lomp doctor >"$SRC/doctorC.out" 2>&1
lacks "C: doctor has nothing to say about a copy any more" "is a copy from another server" "$(cat "$SRC/doctorC.out")"

echo; echo "===== D: the same site renamed while its DNS points here: the old name gets its own at once"
site || { bad "D: the site could not be set up"; exit 1; }
copy_of_it "$OLD"
FP0="$(fp "$OLD")"; : >"$SRC/certbot.log"
lomp rename "$OLD" "$NEW" --yes >"$SRC/renameD.out" 2>&1; RC=$?; echo "rename rc=$RC"
show "$SRC/renameD.out" 'copy|of its own|Renamed|\[warn\]|FAILED'
O="$(cat "$SRC/renameD.out")"
eq    "D: the rename succeeds" 0 "$RC"
has   "D: the old name is asked for a certificate of its own" "asking for one of its own" "$O"
has   "D: and gets it" "$OLD has a certificate of its own now" "$O"
lacks "D: nothing is said about a copy that runs out" "it runs out in" "$O"
eq    "D: certbot was asked once for the old name" 1 "$(asked "$OLD")"
check "D: it has a lineage" "[ -e $LIVE/$OLD/.stand-in ]"
FP1="$(fp "$OLD")"
check "D: the certificate the servers read is another than the copy" "[ -n '$FP1' ] && [ '$FP1' != '$FP0' ]"
eq    "D: and it is the one presented" "$FP1" "$(served "$OLD")"
eq    "D: the old name sends its visitors to the new one, which has its certificate too" "301 https://$NEW/some/path?x=1" "$(goes "$OLD")"
eq    "D: the new name's record: its own certificate, no mark" "true null" "$(rec "$NEW" '"\(.ssl.enabled) \(.ssl.imported)"')"

echo; echo "===== E: redirect add over a copy"
copy_of_it "$OLD"
FP0="$(fp "$OLD")"
: >"$SRC/dns-elsewhere"; : >"$SRC/certbot.log"
lomp redirect add "$OLD" "$NEW" --www >"$SRC/addE1.out" 2>&1; RC=$?; echo "redirect add rc=$RC"
show "$SRC/addE1.out" 'copied|of its own|Once the DNS|now go to|No certificate'
O="$(cat "$SRC/addE1.out")"
eq    "E: DNS elsewhere: the command succeeds" 0 "$RC"
has   "E: it says what the redirect answers under" "$OLD redirects under a certificate that was copied from another server" "$O"
lacks "E: and not that it has no certificate" "No certificate for" "$O"
has   "E: it answers HTTPS" "(HTTPS too)" "$O"
eq    "E: under the copy" "$FP0" "$(served "$OLD")"
rm -f "$SRC/dns-elsewhere"; : >"$SRC/certbot.log"
lomp redirect add "$OLD" "$NEW" --www >"$SRC/addE2.out" 2>&1; RC=$?; echo "redirect add rc=$RC"
O="$(cat "$SRC/addE2.out")"
eq    "E: DNS here: certbot is asked once" 1 "$(asked "$OLD")"
lacks "E: nothing is said about a copy" "copied from another server" "$O"
check "E: it has a lineage again" "[ -e $LIVE/$OLD/.stand-in ]"
FP1="$(fp "$OLD")"
check "E: and another certificate than the copy" "[ -n '$FP1' ] && [ '$FP1' != '$FP0' ]"
eq    "E: which is the one presented" "$FP1" "$(served "$OLD")"
lomp redirect add "$OLD" "$NEW" --www >"$SRC/addE3.out" 2>&1
eq    "E: run again, certbot is not asked again" 1 "$(asked "$OLD")"
eq    "E: and the certificate stays" "$FP1" "$(fp "$OLD")"

echo; echo "===== F: the control - a site whose certificate certbot issued here"
site || { bad "F: the site could not be set up"; exit 1; }
FP0="$(fp "$OLD")"
: >"$SRC/dns-elsewhere"; : >"$SRC/certbot.log"
lomp rename "$OLD" "$NEW" --yes --no-ssl >"$SRC/renameF.out" 2>&1; RC=$?; echo "rename rc=$RC"
rm -f "$SRC/dns-elsewhere"
O="$(cat "$SRC/renameF.out")"
eq    "F: the rename succeeds" 0 "$RC"
lacks "F: nothing is said about a copy" "copy from another server" "$O"
lacks "F: nor about one copied" "copied from another server" "$O"
eq    "F: certbot is not asked for the old name" 0 "$(asked "$OLD")"
check "F: its lineage is where it was" "[ -e $LIVE/$OLD/.stand-in ]"
eq    "F: and so is its certificate" "$FP0" "$(fp "$OLD")"
eq    "F: under which it sends its visitors on" "301 http://$NEW/some/path?x=1" "$(goes "$OLD")"
lomp doctor >"$SRC/doctorF.out" 2>&1
lacks "F: doctor calls it no copy" "is a copy from another server" "$(cat "$SRC/doctorF.out")"
exit 0
