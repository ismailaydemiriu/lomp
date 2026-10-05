#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-wp-https.sh - DESTRUCTIVE end-to-end test of a WordPress that gets its
#  certificate after it was installed.
#
#  A real WordPress is added without a certificate on a real OpenLiteSpeed, and the address
#  it has STORED (wp_options, read from the database) is compared before and after
#  "renew-ssl": http:// becomes https://, an address somebody set is left alone, an address
#  pinned in wp-config.php and a WordPress that wp-cli cannot run are warnings and never fail
#  the certificate. The same after "rename" to a name that is the first with a certificate.
#
#  certbot and the DNS answers for the test's names are stand-ins, first in PATH for this
#  test's own commands only: a self-signed certificate for the test's names, and a Cloudflare
#  address as their DNS answer. Both refuse every other name.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It adds, renames and removes real sites
#  (wphttps-e2e.lomptest.net, wphttps2-e2e.lomptest.net), reloads OpenLiteSpeed many times
#  and leaves the server as it found it.
#
#  Needs: an installed lomp server with MariaDB; network (it downloads WordPress).
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-wp-https.sh [tree to test, default: this checkout]
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
DM="wphttps-e2e.lomptest.net"; DM2="wphttps2-e2e.lomptest.net"
SRC="/tmp/lomp-wphttps-e2e"; STATE="/root/.server-setup/domains"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
has()  { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
lacks() { if grep -qF -- "$2" <<<"$3"; then bad "$1 (found: $2)"; else ok "$1"; fi; }
lomp() { PATH="$SRC/bin:$PATH" bash "$SRC/tree/setup.sh" "$@" --non-interactive --no-color; }
rs()   { printf -- '--resolve %s:443:127.0.0.1 --resolve %s:80:127.0.0.1 -k' "$1" "$1"; }
# retried: other sessions reload the server while this runs
get() { local o="" n=0; while (( n < 8 )); do o="$(curl -s -m 15 "$@")"; [[ -n "$o" ]] && break; n=$((n + 1)); sleep 2; done; printf '%s' "$o"; }
db()     { jq -r '.db.name' "$STATE/$1/domain.json"; }
stored() { mysql -N -e "SELECT CONCAT(option_name, '=', option_value) FROM \`$(db "$1")\`.wp_options WHERE option_name IN ('home','siteurl') ORDER BY option_name" 2>&1 | tr '\n' ' ' | sed 's/ $//'; }
setopt() { mysql -e "UPDATE \`$(db "$1")\`.wp_options SET option_value='$3' WHERE option_name='$2'"; }   # site option value - straight into the database
wpurl()  { awk -F= '$1 == "WP_URL" {print $2}' "$STATE/$1/wp.info" 2>/dev/null; }
wp()     { local d="$1" u=""; shift; u="$(stat -c %U "/home/$d/public_html")"; runuser -u "$u" -- env HOME="/home/$d" /usr/local/bin/wp --path="/home/$d/public_html" "$@" 2>&1 | tail -n 1; }
drop() {
  local d=""
  for d in "$DM" "$DM2"; do
    [ -s "$STATE/$d/redirect.json" ] && lomp redirect del "$d" --yes >/dev/null 2>&1
    [ -d "/home/$d" ] && lomp remove "$d" --yes >/dev/null 2>&1
    rm -rf "/var/backups/server-setup/$d"
    [ -e "/etc/letsencrypt/live/$d/.stand-in" ] && rm -rf "/etc/letsencrypt/live/$d"
  done
  return 0
}

for s in mariadb lsws; do systemctl is-active --quiet "$s" || systemctl start "$s"; done; sleep 3
rm -rf "$SRC"; mkdir -p "$SRC/tree" "$SRC/bin"; cp -r "$WT/setup.sh" "$WT/lib" "$SRC/tree/"
echo "tree: $WT ($(grep -c lib_domain_wp_https "$SRC/tree/lib/domain.sh") mention(s) of lib_domain_wp_https in lib/domain.sh)"
cat >"$SRC/bin/certbot" <<'CERTBOT_STAND_IN'
#!/usr/bin/env bash
# Stand-in for certbot, first in PATH for this test's own commands only. A name that does not
# resolve from outside cannot get a Let's Encrypt certificate, so this does what certbot would:
# a certificate under the lineage name it is given, for the names it is given. Self-signed,
# five days. It refuses every lineage and name that is not this test's and logs each request.
set -u
MINE=" wphttps-e2e.lomptest.net www.wphttps-e2e.lomptest.net wphttps2-e2e.lomptest.net "
LOG="/tmp/lomp-wphttps-e2e/certbot.log"; LIVE="/etc/letsencrypt/live"
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
# exist in no DNS, answer with a Cloudflare address (so lomp takes the DNS-01 road it takes
# for a proxied name); every other question goes to the real dig.
MINE=" wphttps-e2e.lomptest.net www.wphttps-e2e.lomptest.net wphttps2-e2e.lomptest.net "
for a in "$@"; do
  if [[ "$MINE" == *" $a "* ]]; then
    for b in "$@"; do [[ "$b" == "AAAA" ]] && exit 0; done
    # while this file is there the names point somewhere else: "DNS does not point here yet"
    if [[ -e /tmp/lomp-wphttps-e2e/dns-elsewhere ]]; then echo "203.0.113.9"; exit 0; fi
    echo "104.16.0.1"; exit 0
  fi
done
exec /usr/bin/dig "$@"
DIG_STAND_IN
chmod 0755 "$SRC/bin/certbot" "$SRC/bin/dig"
OTHERS_BEFORE="$(ls "$STATE" | grep -v -e "^$DM\$" -e "^$DM2\$" | while read -r d; do cat "$STATE/$d/domain.json" "$STATE/$d/wp.info" 2>/dev/null; done | cksum)"
cleanup() {
  echo; echo "===== cleanup"
  drop
  check "homes removed" "[ ! -d /home/$DM ] && [ ! -d /home/$DM2 ]"
  check "deployed certificates and lineages removed" "[ ! -e /etc/server-setup/ssl/$DM ] && [ ! -e /etc/letsencrypt/live/$DM ] && [ ! -e /etc/server-setup/ssl/$DM2 ] && [ ! -e /etc/letsencrypt/live/$DM2 ]"
  check "no record of the test's names is left" "[ ! -e $STATE/$DM ] && [ ! -e $STATE/$DM2 ]"
  check "every other site's record is byte for byte what it was" "[ \"\$(ls $STATE | grep -v -e '^$DM\$' -e '^$DM2\$' | while read -r d; do cat $STATE/\$d/domain.json $STATE/\$d/wp.info 2>/dev/null; done | cksum)\" = \"$OTHERS_BEFORE\" ]"
  check "OpenLiteSpeed runs" "systemctl is-active --quiet lsws"
  rm -rf "$SRC"
  echo; echo "RESULT: $PASS passed, $FAIL failed"
  (( FAIL == 0 )) || exit 1
}
trap cleanup EXIT
drop

echo "===== A: add --wordpress --no-ssl, the certificate comes later with renew-ssl"
lomp add "$DM" --wordpress --no-ssl >"$SRC/addA.out" 2>&1; RC=$?; echo "add rc=$RC"; (( RC == 0 )) || tail -n 15 "$SRC/addA.out"
# a post of the site's own, with a picture at its http:// address: the site is no longer "fresh"
PID="$(wp "$DM" post create --post_status=publish --post_title='wph e2e' --post_name=wph-e2e --post_content="<p>picture: <img src=\"http://$DM/wp-content/uploads/wph.png\"> and a <a href=\"http://$DM/sample-page/\">link</a></p>" --porcelain)"
echo "   post created: $PID"
B="$(stored "$DM")"; echo "   stored before: $B"; echo "   wp.info before: $(wpurl "$DM")"
check "A: before the certificate the database says http://" "[ '$B' = 'home=http://$DM siteurl=http://$DM' ]"
check "A: and so does lomp's record" "[ \"\$(wpurl $DM)\" = 'http://$DM' ]"
lomp renew-ssl "$DM" >"$SRC/renewA.out" 2>&1; RC=$?; echo "renew-ssl rc=$RC"; grep -E 'WordPress|page cache|runuser|SSL active|\[warn\]|\[error\]' "$SRC/renewA.out" | cut -c1-260 | sed 's/^/   | /'
O="$(cat "$SRC/renewA.out")"
check "A: renew-ssl succeeded" "[ $RC -eq 0 ]"
A="$(stored "$DM")"; echo "   stored after:  $A"; echo "   wp.info after:  $(wpurl "$DM")"
check "A: after it the database says https:// for home and siteurl" "[ '$A' = 'home=https://$DM siteurl=https://$DM' ]"
check "A: lomp's record says https://" "[ \"\$(wpurl $DM)\" = 'https://$DM' ]"
has   "A: it says what it did to home" "WordPress: its home is now https://$DM (was http://$DM)" "$O"
has   "A: and to siteurl" "WordPress: its siteurl is now https://$DM (was http://$DM)" "$O"
has   "A: the page cache was emptied" "page cache emptied" "$O"
has   "A: the content links are counted, not rewritten" "place(s) in its database still say http://$DM" "$O"
has   "A: with the command for the site user" "runuser -u $(stat -c %U "/home/$DM/public_html") -- wp --path=/home/$DM/public_html search-replace 'http://$DM' 'https://$DM' --all-tables-with-prefix --skip-columns=guid" "$O"
lacks "A: no warning about WordPress" "[warn]  WordPress" "$O"
check "A: wp-cli (cron, mails) says https" "[ \"\$(wp $DM option get home)\" = 'https://$DM' ]"
C="$(mysql -N -e "SELECT post_content FROM \`$(db "$DM")\`.wp_posts WHERE ID=$PID")"
check "A: the post in the database still has its http:// picture (nothing was rewritten)" "grep -qF 'src=\"http://$DM/wp-content/uploads/wph.png\"' <<<'$C'"
sleep 2
J="$(get $(rs "$DM") "https://$DM/wp-json/" | jq -c '{url, home}' 2>/dev/null)"; echo "   REST index: $J"
check "A: the REST index names the site with https" "[ '$J' = '{\"url\":\"https://$DM\",\"home\":\"https://$DM\"}' ]"
CR="$(lomp credentials "$DM" 2>&1 | grep -i 'wp-admin')"; echo "   credentials: $CR"
has   "A: credentials prints the https admin address" "https://$DM/wp-admin/" "$CR"
F="$(get $(rs "$DM") -o /dev/null -w '%{http_code}' "https://$DM/")"
check "A: the front page answers 200 over https" "[ '$F' = 200 ]"
R="$(get $(rs "$DM") -o /dev/null -w '%{http_code} %{redirect_url}' "http://$DM/")"; echo "   http://$DM/ -> $R"
check "A: plain http is one 301 to https" "[ '$R' = '301 https://$DM/' ]"
P="$(get $(rs "$DM") "https://$DM/wph-e2e/")"
echo "   the post as served: $(grep -o "src=\"[^\"]*wph.png\"" <<<"$P" | head -n 1), https_migration_required=$(wp "$DM" option get https_migration_required)"
check "A: WordPress serves the post's picture as https:// by itself" "grep -qF 'src=\"https://$DM/wp-content/uploads/wph.png\"' <<<'$P'"
U="$(get $(rs "$DM") -o /dev/null -w '%{http_code}' "https://$DM/wp-login.php")"
check "A: the login page answers 200" "[ '$U' = 200 ]"

echo; echo "===== A2: renew-ssl again finds nothing to do"
lomp renew-ssl "$DM" >"$SRC/renewA2.out" 2>&1; RC=$?; echo "renew-ssl rc=$RC"
check "A2: it succeeds" "[ $RC -eq 0 ]"
lacks "A2: and says nothing about WordPress" "WordPress" "$(cat "$SRC/renewA2.out")"
check "A2: the stored addresses are what they were" "[ \"\$(stored $DM)\" = 'home=https://$DM siteurl=https://$DM' ]"

echo; echo "===== B: an address somebody set is left alone"
setopt "$DM" home "http://elsewhere-wph.lomptest.net"; setopt "$DM" siteurl "http://$DM/wp"
wp "$DM" cache flush >/dev/null
lomp renew-ssl "$DM" >"$SRC/renewB.out" 2>&1; RC=$?; echo "renew-ssl rc=$RC"; grep -E 'WordPress' "$SRC/renewB.out" | cut -c1-220 | sed 's/^/   | /'
O="$(cat "$SRC/renewB.out")"
check "B: renew-ssl succeeded" "[ $RC -eq 0 ]"
check "B: both are what they were set to" "[ \"\$(stored $DM)\" = 'home=http://elsewhere-wph.lomptest.net siteurl=http://$DM/wp' ]"
has   "B: another host is named" "its home is http://elsewhere-wph.lomptest.net, which is not the plain address of this site; left as it is" "$O"
has   "B: a directory too" "its siteurl is http://$DM/wp, which is not the plain address of this site; left as it is" "$O"

echo; echo "===== C: an address pinned in wp-config.php"
setopt "$DM" home "http://$DM"; setopt "$DM" siteurl "http://$DM"; wp "$DM" cache flush >/dev/null
CFG="/home/$DM/public_html/wp-config.php"; cp -p "$CFG" "$SRC/wp-config.keep"
sed -i "s#^<?php#<?php\ndefine('WP_HOME', 'http://$DM');#" "$CFG"
lomp renew-ssl "$DM" >"$SRC/renewC.out" 2>&1; RC=$?; echo "renew-ssl rc=$RC"; grep -E 'WordPress|wp-config' "$SRC/renewC.out" | cut -c1-220 | sed 's/^/   | /'
O="$(cat "$SRC/renewC.out")"
check "C: renew-ssl succeeded" "[ $RC -eq 0 ]"
has   "C: it warns that WordPress still says http://" "WordPress still gives http://$DM as its home" "$O"
has   "C: and where to look" "WP_HOME and WP_SITEURL in /home/$DM/public_html/wp-config.php" "$O"
has   "C: siteurl, which is not pinned, is changed" "its siteurl is now https://$DM" "$O"
cp -p "$SRC/wp-config.keep" "$CFG"

echo; echo "===== D: a WordPress that wp-cli cannot run"
setopt "$DM" home "http://$DM"; setopt "$DM" siteurl "http://$DM"; wp "$DM" cache flush >/dev/null
sed -i "s#^<?php#<?php\nthis is no php (#" "$CFG"
lomp renew-ssl "$DM" >"$SRC/renewD.out" 2>&1; RC=$?; echo "renew-ssl rc=$RC"; grep -E 'WordPress|certificate is in place|SSL active' "$SRC/renewD.out" | cut -c1-220 | sed 's/^/   | /'
O="$(cat "$SRC/renewD.out")"
cp -p "$SRC/wp-config.keep" "$CFG"
check "D: the certificate command still succeeds" "[ $RC -eq 0 ]"
has   "D: with a warning" "WordPress could not be asked for its address" "$O"
has   "D: and SSL is reported active" "SSL active for $DM" "$O"
check "D: nothing was written" "[ \"\$(stored $DM)\" = 'home=http://$DM siteurl=http://$DM' ]"
lomp renew-ssl "$DM" >"$SRC/renewD2.out" 2>&1; RC=$?
check "D: once WordPress runs again, the next renew-ssl puts it right" "[ $RC -eq 0 ] && [ \"\$(stored $DM)\" = 'home=https://$DM siteurl=https://$DM' ]"

echo; echo "===== E: add wanted a certificate, DNS did not point here; then rename to a name that gets one"
drop
: >"$SRC/dns-elsewhere"
lomp add "$DM" --wordpress >"$SRC/addE.out" 2>&1; RC=$?; echo "add rc=$RC"; (( RC == 0 )) || tail -n 15 "$SRC/addE.out"
grep -E 'Certificate skipped|does not point' "$SRC/addE.out" | cut -c1-200 | sed 's/^/   | /'
rm -f "$SRC/dns-elsewhere"
check "E: add went through without a certificate" "[ $RC -eq 0 ] && [ \"\$(jq -r '\"\\(.ssl.enabled) \\(.ssl.wanted)\"' $STATE/$DM/domain.json)\" = 'false true' ]"
B="$(stored "$DM")"; echo "   stored before: $B"
check "E: WordPress was installed with http://" "[ '$B' = 'home=http://$DM siteurl=http://$DM' ]"
lomp rename "$DM" "$DM2" --no-redirect --yes >"$SRC/renameE.out" 2>&1; RC=$?; echo "rename rc=$RC"; grep -E 'WordPress: |page cache|HTTPS active|Renamed|\[warn\]|\[error\]' "$SRC/renameE.out" | cut -c1-220 | sed 's/^/   | /'
O="$(cat "$SRC/renameE.out")"
check "E: rename succeeded" "[ $RC -eq 0 ]"
check "E: the new name has its certificate" "[ \"\$(jq -r .ssl.enabled $STATE/$DM2/domain.json 2>/dev/null)\" = true ]"
A="$(stored "$DM2" 2>/dev/null)"; echo "   stored after:  $A"; echo "   wp.info after:  $(wpurl "$DM2")"
check "E: the database says https:// and the new name" "[ '$A' = 'home=https://$DM2 siteurl=https://$DM2' ]"
check "E: lomp's record too" "[ \"\$(wpurl $DM2)\" = 'https://$DM2' ]"
has   "E: it is said" "WordPress: its home is now https://$DM2 (was http://$DM2)" "$O"
check "E: the page cache was emptied once, by rename" "[ \"\$(grep -c 'page cache emptied' <<<\"\$O\")\" = 1 ]"
sleep 2
J="$(get $(rs "$DM2") "https://$DM2/wp-json/" | jq -c '{url, home}' 2>/dev/null)"; echo "   REST index: $J"
check "E: the REST index names the site with https and the new name" "[ '$J' = '{\"url\":\"https://$DM2\",\"home\":\"https://$DM2\"}' ]"

echo; echo "===== F: the flow the README describes (DNS fixed, then renew-ssl), on a site with www"
drop
: >"$SRC/dns-elsewhere"
lomp add "$DM" --wordpress --www >"$SRC/addF.out" 2>&1; RC=$?; echo "add rc=$RC"; (( RC == 0 )) || tail -n 15 "$SRC/addF.out"
rm -f "$SRC/dns-elsewhere"
B="$(stored "$DM")"; echo "   stored before: $B"
check "F: before the certificate the database says http://" "[ '$B' = 'home=http://$DM siteurl=http://$DM' ]"
lomp renew-ssl "$DM" >"$SRC/renewF.out" 2>&1; RC=$?; echo "renew-ssl rc=$RC"; grep -E 'WordPress: |\[error\]' "$SRC/renewF.out" | cut -c1-200 | sed 's/^/   | /'
check "F: renew-ssl succeeded" "[ $RC -eq 0 ]"
A="$(stored "$DM")"; echo "   stored after:  $A"
check "F: after it https://" "[ '$A' = 'home=https://$DM siteurl=https://$DM' ]"
# the address a www-primary site is installed with: the www name
setopt "$DM" home "http://www.$DM"; setopt "$DM" siteurl "http://www.$DM"; wp "$DM" cache flush >/dev/null
sed -i "s#^WP_URL=.*#WP_URL=http://www.$DM#" "$STATE/$DM/wp.info"
lomp renew-ssl "$DM" >"$SRC/renewF2.out" 2>&1; RC=$?; echo "renew-ssl rc=$RC"; grep -E 'WordPress: |\[error\]' "$SRC/renewF2.out" | cut -c1-200 | sed 's/^/   | /'
check "F: with the www name stored, renew-ssl succeeds" "[ $RC -eq 0 ]"
A="$(stored "$DM")"; echo "   stored after:  $A"; echo "   wp.info after:  $(wpurl "$DM")"
check "F: the www is kept, only the scheme changed" "[ '$A' = 'home=https://www.$DM siteurl=https://www.$DM' ]"
check "F: in lomp's record too" "[ \"\$(wpurl $DM)\" = 'https://www.$DM' ]"
exit 0
