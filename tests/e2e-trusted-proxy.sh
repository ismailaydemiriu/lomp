#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-trusted-proxy.sh - DESTRUCTIVE end-to-end test of "lomp trusted-proxy add|del|list".
#
#  What is checked is what a PHP page on a real OpenLiteSpeed sees as REMOTE_ADDR, asked from a
#  second network namespace: from the trusted proxy's address its X-Forwarded-For /
#  CF-Connecting-IP is believed, from any other address it is not; the Cloudflare refresh
#  ("update-cf-ips", which writes accessControl again) keeps the proxy; fail2ban never bans it;
#  with the origin locked to Cloudflare it gets its own UFW rule.
#
#  UFW is stood in for: WSL distros share one network namespace, and a real "ufw enable" here
#  would filter every distro of the machine.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It adds a site (tp-e2e.test), a veth pair and a
#  network namespace, switches the Cloudflare mode on and off, and reloads OpenLiteSpeed.
#  It needs the internet once (Cloudflare's ranges).
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-trusted-proxy.sh [tree to test, default: this checkout]
# =============================================================================
set -u
export LOMP_LANG=en LOMP_MENU_LANG=en
if [[ "${LOMPSTACK_INTEGRATION:-}" != "yes" ]]; then
  printf '%s\n' "This test adds a site and a network namespace and reloads OpenLiteSpeed." \
    "Run it only on a throwaway server:  LOMPSTACK_INTEGRATION=yes bash $0" >&2
  exit 2
fi
if [[ "$(id -u)" != 0 ]]; then printf 'Run it as root.\n' >&2; exit 2; fi
need() { printf 'Cannot run here: %s\n' "$1" >&2; exit 2; }
[[ -s /root/.server-setup/manifest.json ]] || need "lomp is not installed on this server (setup.sh install)"
[[ -x /usr/local/lsws/bin/lswsctrl ]] || need "OpenLiteSpeed is not installed"
PASS=0; FAIL=0
ok()    { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; if [ -n "${2:-}" ]; then printf '        %s\n' "${2:0:900}"; fi; }
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
M=/root/.server-setup/manifest.json
C=/usr/local/lsws/conf/httpd_config.conf
D=tp-e2e.test
PROXY=10.99.77.2 STRANGER=10.99.77.3 HOST=10.99.77.1
# the UFW stand-in (see the top)
cat >/usr/local/sbin/ufw <<'EOF'
#!/bin/sh
echo "ufw $*" >>/root/ufw-calls.log
case "$1" in status) echo "Status: active" ;; show) echo "ufw allow 22/tcp" ;; esac
exit 0
EOF
chmod +x /usr/local/sbin/ufw
: >/root/ufw-calls.log
cp "$M" "$T/manifest.orig"

cleanup() {
  ip netns del tpx 2>/dev/null; ip link del va 2>/dev/null
  # the manifest as it was (Cloudflare mode, lock, list), then OpenLiteSpeed rendered from it
  cp "$T/manifest.orig" "$M"
  $L trusted-proxy del "$PROXY" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

run() {   # name, expected rc, command... -> OUT
  local n="$1" want="$2" rc=0; shift 2
  OUT="$("$@" 2>&1)" || rc=$?
  if [[ "$rc" == "$want" ]]; then ok "$n (rc ${rc})"; else bad "$n" "rc ${rc}, wanted ${want}: ${OUT}"; fi
}
# REMOTE_ADDR as the page sees it, asked from <source> with the headers given
ra() {   # source curl-args...
  local src="$1" out="" i=0; shift
  for i in 1 2 3 4 5 6 7 8 9 10; do
    out="$(ip netns exec tpx curl -s -m 5 --interface "$src" -H "Host: ${D}" "$@" "http://${HOST}/ip.php" 2>/dev/null || true)"
    if [[ "$out" == RA=* ]]; then printf '%s' "${out#RA=}"; return 0; fi
    sleep 2
  done
  printf 'NO-ANSWER'
}
allow_line() { grep -E '^[[:space:]]*allow[[:space:]]' "$C" | head -n 1 | sed -E 's/^[[:space:]]*allow[[:space:]]+//'; }
top() { awk -v k="$1" '$1 == k { print $2; exit }' "$C"; }

sec "a site whose page prints REMOTE_ADDR, and a client in a second namespace"
if [[ ! -d "/home/${D}" ]]; then run "add ${D}" 0 $L add "$D" --non-interactive; fi
printf '<?php echo "RA=", $_SERVER["REMOTE_ADDR"], "\\n";\n' >"/home/${D}/public_html/ip.php"
chown --reference="/home/${D}/public_html" "/home/${D}/public_html/ip.php"
ip netns del tpx 2>/dev/null; ip link del va 2>/dev/null
ip netns add tpx
ip link add va type veth peer name vb
ip link set vb netns tpx
ip addr add "${HOST}/24" dev va; ip link set va up
ip netns exec tpx ip addr add "${PROXY}/24" dev vb
ip netns exec tpx ip addr add "${STRANGER}/24" dev vb
ip netns exec tpx ip link set vb up
eq "before: the proxy's header is not believed"         "$PROXY" "$(ra "$PROXY" -H 'X-Forwarded-For: 198.51.100.20')"

sec "add"
run "a network too wide is refused"                     1 $L trusted-proxy add 0.0.0.0/0
has "and why"                                           "too wide" "$OUT"
run "a name is refused"                                 1 $L trusted-proxy add proxy.example.com
lacks "nothing was kept"                                "trusted_proxies" "$(cat "$M")"
run "add the proxy"                                     0 $L trusted-proxy add "$PROXY"
has "it says what the proxy must send"                  'X-Forwarded-For $remote_addr' "$OUT"
eq  "kept in the manifest"                              "[\"${PROXY}\"]" "$(jq -c '.trusted_proxies' "$M")"
has "OpenLiteSpeed: a T entry"                          "${PROXY}T" "$(allow_line)"
eq  "useIpInProxyHeader 2"                              "2" "$(top useIpInProxyHeader)"
has "OpenLiteSpeed still runs"                          "active" "$(systemctl is-active lsws)"
eq  "the proxy's X-Forwarded-For is the visitor"        "198.51.100.20" "$(ra "$PROXY" -H 'X-Forwarded-For: 198.51.100.20')"
eq  "its CF-Connecting-IP first"                        "198.51.100.30" "$(ra "$PROXY" -H 'CF-Connecting-IP: 198.51.100.30' -H 'X-Forwarded-For: 198.51.100.20, 10.1.1.1')"
eq  "the proxy without a header is the proxy"           "$PROXY" "$(ra "$PROXY")"
eq  "anyone else's header is not believed"              "$STRANGER" "$(ra "$STRANGER" -H 'X-Forwarded-For: 198.51.100.20' -H 'CF-Connecting-IP: 198.51.100.30')"
has "fail2ban never bans it"                            "$PROXY" "$(cat /etc/fail2ban/jail.d/server-setup-allow.conf 2>/dev/null)"
run "add it again"                                      0 $L trusted-proxy add "${PROXY}/32"
has "said"                                              "already trusted" "$OUT"
eq  "still once"                                        "[\"${PROXY}\"]" "$(jq -c '.trusted_proxies' "$M")"
run "list"                                              0 $L trusted-proxy list
has "list shows it"                                     "$PROXY" "$OUT"

sec "the weekly Cloudflare refresh writes accessControl again: the proxy stays"
rm -f /root/.server-setup/cloudflare-ips.conf
jq '.cloudflare.enabled = true' "$M" >"$M.new" && cat "$M.new" >"$M" && rm -f "$M.new"
run "update-cf-ips"                                     0 $L update-cf-ips
has "Cloudflare's ranges are in"                        "173.245.48.0/20T" "$(allow_line)"
has "and the proxy still"                               "${PROXY}T" "$(allow_line)"
eq  "the proxy is still believed"                       "198.51.100.20" "$(ra "$PROXY" -H 'X-Forwarded-For: 198.51.100.20')"

sec "the origin lock to Cloudflare lets the proxy in on 80 and 443"
jq '.cloudflare.origin_lock = true' "$M" >"$M.new" && cat "$M.new" >"$M" && rm -f "$M.new"
: >/root/ufw-calls.log
run "add a second proxy while locked"                   0 $L trusted-proxy add 10.99.78.0/24
has "UFW: the first one let in"                         "allow from ${PROXY} to any port 80,443 proto tcp comment lompstack trusted proxy" "$(cat /root/ufw-calls.log)"
has "and the network"                                   "allow from 10.99.78.0/24 to any port 80,443 proto tcp comment lompstack trusted proxy" "$(cat /root/ufw-calls.log)"
has "HTTP/3 too"                                        "allow from ${PROXY} to any port 443 proto udp comment lompstack trusted proxy" "$(cat /root/ufw-calls.log)"
jq '.cloudflare.origin_lock = false' "$M" >"$M.new" && cat "$M.new" >"$M" && rm -f "$M.new"

sec "del"
run "del both"                                          0 $L trusted-proxy del "$PROXY" 10.99.78.0/24
eq  "the list is empty"                                 "[]" "$(jq -c '.trusted_proxies' "$M")"
lacks "no T entry of it"                                "${PROXY}T" "$(allow_line)"
has "Cloudflare's stay (its mode is on)"                "173.245.48.0/20T" "$(allow_line)"
eq  "the proxy is the visitor again"                    "$PROXY" "$(ra "$PROXY" -H 'X-Forwarded-For: 198.51.100.20')"
lacks "fail2ban may ban it again"                       "$PROXY" "$(cat /etc/fail2ban/jail.d/server-setup-allow.conf 2>/dev/null)"
jq '.cloudflare.enabled = false' "$M" >"$M.new" && cat "$M.new" >"$M" && rm -f "$M.new"
run "del of one not listed"                             0 $L trusted-proxy del "$PROXY"
has "said"                                              "not in the list" "$OUT"
eq  "nothing believed: useIpInProxyHeader 0"            "0" "$(top useIpInProxyHeader)"
eq  "allow ALL alone"                                   "ALL" "$(allow_line)"
has "OpenLiteSpeed still runs"                          "active" "$(systemctl is-active lsws)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
