#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-images.sh - DESTRUCTIVE end-to-end test of "install --images": an image server,
#  nginx alone, on a disposable Ubuntu 22.04 / 24.04 (a WSL distro or a throwaway VM) as root.
#
#  A real install (a dry run first on a fresh machine), sites added and removed, what each one
#  answers (cache headers, svg sandbox, no script source, no dotted names, GET/HEAD only, names
#  nobody added closed), uploads made readable, list/status/doctor/optimize, what the server
#  refuses, https with a self-made certificate standing in for Let's Encrypt, an install re-run,
#  a rename (the old name answering 301, over http and https) and a self-update.
#
#  UFW is stood in for: WSL distros share one network namespace, and a real "default deny
#  incoming" would close the other distros too. Never run it on a server you use.
#    sudo bash tests/e2e-images.sh [source tree, default: this checkout]
# =============================================================================
set -u
PASS=0; FAILN=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAILN=$((FAILN + 1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2"; }
check() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
has()  { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "missing [$2] in: ${3:0:400}"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "unexpected [$2]"; fi; }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

export DEBIAN_FRONTEND=noninteractive
TREE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC=/root/lomp-e2e-images
rm -rf "$SRC"; mkdir -p "$SRC"
cp -r "$TREE/setup.sh" "$TREE/lib" "$SRC/"
chmod +x "$SRC/setup.sh"

# the UFW stand-in
cat >/usr/local/sbin/ufw <<'EOF'
#!/bin/sh
echo "ufw $*" >>/root/ufw-calls.log
case "$1" in status) echo "Status: active" ;; show) echo "ufw allow 22/tcp" ;; esac
exit 0
EOF
chmod +x /usr/local/sbin/ufw
: >/root/ufw-calls.log

run() {   # name, expected rc, command...
  local n="$1" want="$2" out="" rc=0; shift 2
  out="$("$@" 2>&1)" || rc=$?
  LAST_OUT="$out"
  if [[ "$rc" == "$want" ]]; then ok "$n (rc=$rc)"; else bad "$n (rc=$rc, wanted $want)" "$(printf '%s' "$out" | tail -n 15)"; fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@" || true; }
hdrs() { curl -s -D - -o /dev/null "$@" || true; }

# a clean start on a distro an earlier run used
if [[ -x /usr/local/sbin/lomp ]]; then
  for d in img.test cdn.test new.test; do /usr/local/sbin/lomp remove "$d" --yes >/dev/null 2>&1 || true; done
  rm -rf /home/img.test /home/cdn.test /home/new.test
fi
if [[ ! -e /root/.server-setup/manifest.json ]]; then
  echo "== a fresh server: the dry run first"
  run "install --images --dry-run" 0 "$SRC/setup.sh" install --images --dry-run --non-interactive --skip-upgrade --no-color
  check "  installed nothing" test ! -e /etc/nginx/nginx.conf
  check "  and recorded nothing" test ! -e /root/.server-setup/manifest.json
  has "  says what it would do" "would install nginx" "$LAST_OUT"
fi
echo "== install --images"
run "install --images" 0 "$SRC/setup.sh" install --images --non-interactive --skip-upgrade --no-color --email e2e@example.com
printf '%s\n' "$LAST_OUT" | tail -n 25
L=/usr/local/sbin/lomp
check "lomp installed" test -x "$L"
check "nginx active" systemctl is-active --quiet nginx
check "nginx -t passes" nginx -t -q
eq "role recorded" "images" "$(jq -r .params.role /root/.server-setup/manifest.json)"
eq "one worker per core" "worker_processes $(nproc);" "$(grep -o 'worker_processes [0-9]*;' /etc/nginx/nginx.conf)"
check "no OpenLiteSpeed" test ! -e /usr/local/lsws/bin/openlitespeed
check "no MariaDB" test ! -e /usr/sbin/mariadbd
check "welcome site gone" test ! -e /etc/nginx/sites-enabled/default
check "package config kept" test -f /etc/nginx/nginx.conf.lomp-orig
check "renewal hook" test -x /etc/letsencrypt/renewal-hooks/deploy/99-lomp-nginx.sh
check "no OLS hook" test ! -e /etc/letsencrypt/renewal-hooks/deploy/99-server-setup-ols.sh
has "cron: perms every 10 min" "nginx-perms" "$(cat /etc/cron.d/server-setup)"
lacks "cron: no htaccess check" "htaccess-check" "$(cat /etc/cron.d/server-setup)"
has "ufw allowed 80" "ufw allow 80/tcp" "$(cat /root/ufw-calls.log)"
eq "unknown name: closed (000 = no answer)" "000" "$(code -H 'Host: nobody.test' http://127.0.0.1/)"

echo "== add"
run "add img.test" 0 "$L" add img.test --no-ssl --no-color
run "add cdn.test --www --cache-days 365" 0 "$L" add cdn.test --no-ssl --www --cache-days 365 --no-color
run "add twice refused" 1 "$L" add img.test --no-ssl --no-color
has "  with why" "already exists" "$LAST_OUT"
P=/home/img.test/public_html
mkdir -p "$P/photos"
head -c 2048 /dev/urandom >"$P/photos/a.jpg"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>' >"$P/logo.svg"
printf '<?php echo 1;' >"$P/a.php"; printf 'SECRET=1' >"$P/.env"
chmod 0600 "$P/photos/a.jpg"; chmod 0700 "$P/photos"
_c="$(code -H 'Host: img.test' http://127.0.0.1/photos/a.jpg)"
if [[ "$_c" != 200 ]]; then ok "a 0600 upload is not readable to nginx ($_c)"; else bad "a 0600 upload is not readable to nginx"; fi
run "nginx-perms" 0 "$L" nginx-perms
eq "  after the 10-minute check it is" "200" "$(code -H 'Host: img.test' http://127.0.0.1/photos/a.jpg)"
H="$(hdrs -H 'Host: img.test' http://127.0.0.1/photos/a.jpg)"
has "jpg: 30 days" "Cache-Control: public, max-age=2592000" "$H"
has "jpg: any site may show it" "Access-Control-Allow-Origin: *" "$H"
has "jpg: type" "Content-Type: image/jpeg" "$H"
lacks "no version in Server" "nginx/" "$H"
H="$(hdrs -H 'Host: img.test' http://127.0.0.1/logo.svg)"
has "svg: sandboxed" "Content-Security-Policy: default-src 'none'" "$H"
eq "php source not served" "404" "$(code -H 'Host: img.test' http://127.0.0.1/a.php)"
eq ".env not served" "404" "$(code -H 'Host: img.test' http://127.0.0.1/.env)"
eq "POST refused" "405" "$(code -X POST -H 'Host: img.test' http://127.0.0.1/photos/a.jpg)"
eq "missing file" "404" "$(code -H 'Host: img.test' http://127.0.0.1/nope.png)"
eq "acme path served" "404" "$(code -H 'Host: img.test' http://127.0.0.1/.well-known/acme-challenge/x)"
echo token >/var/www/acme/.well-known/acme-challenge/tok1
eq "acme token served" "200" "$(code -H 'Host: img.test' http://127.0.0.1/.well-known/acme-challenge/tok1)"
rm -f /var/www/acme/.well-known/acme-challenge/tok1
cp "$P/photos/a.jpg" /home/cdn.test/public_html/b.webp; chmod 0644 /home/cdn.test/public_html/b.webp
H="$(hdrs -H 'Host: cdn.test' http://127.0.0.1/b.webp)"
has "cdn: a year" "max-age=31536000" "$H"
has "cdn: webp type" "Content-Type: image/webp" "$H"
eq "www.cdn.test answers" "200" "$(code -H 'Host: www.cdn.test' http://127.0.0.1/b.webp)"
eq "www.img.test does not" "000" "$(code -H 'Host: www.img.test' http://127.0.0.1/photos/a.jpg)"
sleep 1; systemctl reload nginx; sleep 1
has "access log written" "GET /photos/a.jpg" "$(cat /var/log/lomp-sites/img.test/access.log 2>/dev/null)"
check "logs link in home" test -L /home/img.test/logs
has "fail2ban web jail lists the site" "/var/log/lomp-sites/img.test/access.log" "$(cat /etc/fail2ban/jail.d/server-setup-web.conf)"
check "fail2ban running" systemctl is-active --quiet fail2ban

mkdir -p /home/new.test/public_html; cp "$P/photos/a.jpg" /home/new.test/public_html/n.png; chmod 0644 /home/new.test/public_html/n.png
run "add new.test over files already there" 0 "$L" add new.test --no-ssl --no-color
eq "  served the moment add returns" "200" "$(code -H 'Host: new.test' http://127.0.0.1/n.png)"
run "remove new.test" 0 "$L" remove new.test --yes --no-color
eq "  and gone the moment remove returns" "000" "$(code -H 'Host: new.test' http://127.0.0.1/n.png)"
echo "== list / status / doctor / optimize"
run "list" 0 "$L" list --no-color
has "  img.test listed" "img.test" "$LAST_OUT"; has "  cache 365d" "365d" "$LAST_OUT"
run "list --json" 0 "$L" list --json
eq "  json mode" "images images" "$(printf '%s' "$LAST_OUT" | jq -r '.[].mode' | tr '\n' ' ' | sed 's/ $//')"
run "status" 0 "$L" status --no-color
has "  nginx line" "worker(s)" "$LAST_OUT"
run "status --json" 0 "$L" status --json
eq "  json role" "images" "$(printf '%s' "$LAST_OUT" | jq -r .role)"
run "doctor" 0 "$L" doctor --no-color
printf '%s\n' "$LAST_OUT" | tail -n 16
run "healthcheck" 0 "$L" healthcheck
run "optimize: nothing to do" 0 "$L" optimize --yes --no-color
has "  says so" "already tuned" "$LAST_OUT"
cp -p /etc/nginx/nginx.conf /root/nginx.conf.bak
sed -i 's/worker_connections [0-9]*;/worker_connections 512;/' /etc/nginx/nginx.conf
run "doctor sees a hand-edited size" 0 "$L" doctor --no-color
has "  warns" "nginx tuning" "$LAST_OUT"
run "optimize puts it back" 0 "$L" optimize --yes --no-color
check "  identical again" cmp -s /etc/nginx/nginx.conf /root/nginx.conf.bak

echo "== what an image server refuses"
run "db refused" 1 "$L" db list --no-color
has "  with why" "is not part of an image server" "$LAST_OUT"
run "wordpress refused" 1 "$L" wordpress img.test --no-color
run "add --wordpress refused" 1 "$L" add x.test --wordpress --no-color
run "install --role web refused" 1 "$L" install --role web --non-interactive --no-color
has "  with why" "This is an image server" "$LAST_OUT"
run "htaccess-check is quiet" 0 "$L" htaccess-check
eq "  and silent" "" "$LAST_OUT"

echo "== https (a self-made certificate stands in for Let's Encrypt)"
D=/etc/server-setup/ssl/img.test; mkdir -p "$D"; chmod 0700 /etc/server-setup/ssl "$D"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj /CN=img.test \
  -keyout "$D/privkey.pem" -out "$D/fullchain.pem" >/dev/null 2>&1
jq '.ssl.enabled = true' /root/.server-setup/domains/img.test/domain.json >/tmp/j && mv /tmp/j /root/.server-setup/domains/img.test/domain.json
run "migrate writes the https site" 0 "$L" migrate --no-color
has "  443 in the site" "listen 443 ssl" "$(cat /etc/nginx/lomp/sites/img.test.conf)"
eq "http sends on to https" "301" "$(code -H 'Host: img.test' http://127.0.0.1/photos/a.jpg)"
eq "but answers Let's Encrypt over http" "404" "$(code -H 'Host: img.test' http://127.0.0.1/.well-known/acme-challenge/none)"
H="$(curl -sk --http2 -D - -o /dev/null --resolve img.test:443:127.0.0.1 https://img.test/photos/a.jpg || true)"
has "https over HTTP/2" "HTTP/2 200" "$H"
has "  cached" "max-age=2592000" "$H"
eq "TLS to an unknown name is refused" "000" "$(curl -sk -o /dev/null -w '%{http_code}' --resolve nobody.test:443:127.0.0.1 https://nobody.test/ || true)"
run "doctor with https" 0 "$L" doctor --no-color
has "  sees the certificate" "https, certificate" "$LAST_OUT"
run "renew-ssl without DNS ends with why" 1 "$L" renew-ssl cdn.test --no-color
printf '%s\n' "$LAST_OUT" | tail -n 4

echo "== remove / re-run"
run "remove cdn.test" 0 "$L" remove cdn.test --yes --no-color
check "  files gone" test ! -e /home/cdn.test
check "  site file gone" test ! -e /etc/nginx/lomp/sites/cdn.test.conf
eq "  no longer answered" "000" "$(code -H 'Host: cdn.test' http://127.0.0.1/b.webp)"
run "remove --keep-files" 0 "$L" remove img.test --yes --keep-files --keep-ssl --no-color
check "  files kept" test -s /home/img.test/public_html/photos/a.jpg
run "add it again over its kept files" 0 "$L" add img.test --no-ssl --no-color
eq "  served again" "200" "$(code -H 'Host: img.test' http://127.0.0.1/photos/a.jpg)"
run "install re-run" 0 "$SRC/setup.sh" install --non-interactive --skip-upgrade --no-color
check "  nginx still fine" nginx -t -q
eq "  still served" "200" "$(code -H 'Host: img.test' http://127.0.0.1/photos/a.jpg)"
run "update (apt, no upgrade wait)" 0 "$L" update --dry-run --no-color
run "logrotate config parses" 0 logrotate -d /etc/logrotate.d/lomp-nginx-sites
echo "== rename: the old name answers 301"
D=/etc/server-setup/ssl/img.test; mkdir -p "$D"; chmod 0700 /etc/server-setup/ssl "$D"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj /CN=img.test \
  -keyout "$D/privkey.pem" -out "$D/fullchain.pem" >/dev/null 2>&1
jq '.ssl.enabled = true' /root/.server-setup/domains/img.test/domain.json >/tmp/j && mv /tmp/j /root/.server-setup/domains/img.test/domain.json
run "  img.test on https first" 0 "$L" migrate --no-color
run "rename img.test pic.test" 0 "$L" rename img.test pic.test --no-ssl --yes --no-color
printf '%s\n' "$LAST_OUT" | tail -n 4
check "  files moved" test -s /home/pic.test/public_html/photos/a.jpg
check "  nothing left under the old name" test ! -e /home/img.test
eq "  the new name serves them at once" "200" "$(code -H 'Host: pic.test' http://127.0.0.1/photos/a.jpg)"
H="$(hdrs -H 'Host: img.test' 'http://127.0.0.1/photos/a.jpg?v=2')"
has "  old http: 301" "301 Moved Permanently" "$H"
has "  to the same path under the new name" "Location: http://pic.test/photos/a.jpg?v=2" "$H"
H="$(curl -sk -D - -o /dev/null --resolve img.test:443:127.0.0.1 https://img.test/photos/a.jpg || true)"
has "  old https: 301 too, with its own certificate" "location: http://pic.test/photos/a.jpg" "${H,,}"
run "  list" 0 "$L" list --no-color
has "  shows the redirect" "-> pic.test" "$LAST_OUT"
run "  doctor" 0 "$L" doctor --no-color
has "  knows it" "redirects to pic.test" "$LAST_OUT"
D=/etc/server-setup/ssl/pic.test; mkdir -p "$D"; chmod 0700 "$D"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj /CN=pic.test \
  -keyout "$D/privkey.pem" -out "$D/fullchain.pem" >/dev/null 2>&1
jq '.ssl.enabled = true' /root/.server-setup/domains/pic.test/domain.json >/tmp/j && mv /tmp/j /root/.server-setup/domains/pic.test/domain.json
run "  the new name gets https" 0 "$L" migrate --no-color
H="$(hdrs -H 'Host: img.test' http://127.0.0.1/photos/a.jpg)"
has "  the old name now sends to https" "Location: https://pic.test/photos/a.jpg" "$H"
eq "  and the new one serves over https" "200" "$(curl -sk -o /dev/null -w '%{http_code}' --resolve pic.test:443:127.0.0.1 https://pic.test/photos/a.jpg || true)"
run "  a redirect cannot be renamed" 1 "$L" rename img.test x.test --yes --no-color
run "rename back to the old name is refused while the redirect is there" 1 "$L" rename pic.test img.test --yes --no-color
run "remove the redirect" 0 "$L" remove img.test --yes --no-color
eq "  the old name is closed" "000" "$(code -H 'Host: img.test' http://127.0.0.1/photos/a.jpg)"
run "rename back, without a redirect" 0 "$L" rename pic.test img.test --no-ssl --no-redirect --yes --no-color
eq "  served under the old name again" "200" "$(code -H 'Host: img.test' http://127.0.0.1/photos/a.jpg)"
eq "  and pic.test is gone" "000" "$(code -H 'Host: pic.test' http://127.0.0.1/photos/a.jpg)"
check "  its state too" test ! -e /root/.server-setup/domains/pic.test
check "  nginx fine" nginx -t -q
run "self-update from the tree" 0 "$L" self-update --from "$SRC" --no-color
printf '\n%d passed, %d failed\n' "$PASS" "$FAILN"
(( FAILN == 0 ))
