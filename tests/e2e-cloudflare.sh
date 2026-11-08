#!/usr/bin/env bash
# =============================================================================
#  tests/e2e-cloudflare.sh - DESTRUCTIVE end-to-end test of "lomp cloudflare on|off|status".
#
#  What is checked is what a PHP page on a real OpenLiteSpeed sees as REMOTE_ADDR, asked from a
#  second network namespace: from an address inside Cloudflare's ranges its CF-Connecting-IP
#  is believed once the mode is on, from any other address never, and with the mode off not
#  even from Cloudflare. A trusted proxy ("lomp trusted-proxy") outlives "off".
#
#  The Cloudflare address is one /32 (173.245.48.5) routed into the namespace: WSL distros share
#  one network namespace, and a whole range of Cloudflare's on it would take that range away
#  from every distro of the machine.
#
#  RUN ONLY ON A THROWAWAY SERVER, AS ROOT. It adds a site (cf-e2e.test), a veth pair and a
#  network namespace, switches the Cloudflare mode on and off, and reloads OpenLiteSpeed.
#  It needs the internet once (Cloudflare's ranges).
#
#      LOMPSTACK_INTEGRATION=yes bash tests/e2e-cloudflare.sh [tree to test, default: this checkout]
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
CRON=/etc/cron.d/server-setup
D=cf-e2e.test
CF=173.245.48.5 STRANGER=10.99.76.3 PROXY=10.99.76.2 HOST=10.99.76.1
CF_WAS="$(jq -r '.cloudflare.enabled' "$M")"

cleanup() {
  ip netns del cfx 2>/dev/null; ip link del vc 2>/dev/null
  # the mode as it was, rendered by lomp itself (a copy of httpd_config.conf taken before the
  # test would also take away the virtual host of the site the test added)
  $L trusted-proxy del "$PROXY" >/dev/null 2>&1 || true
  if [[ "$CF_WAS" == true ]]; then $L cloudflare on >/dev/null 2>&1 || true
  else $L cloudflare off >/dev/null 2>&1 || true; fi
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
    out="$(ip netns exec cfx curl -s -m 5 --interface "$src" -H "Host: ${D}" "$@" "http://${HOST}/ip.php" 2>/dev/null || true)"
    if [[ "$out" == RA=* ]]; then printf '%s' "${out#RA=}"; return 0; fi
    sleep 2
  done
  printf 'NO-ANSWER'
}
allow_line() { grep -E '^[[:space:]]*allow[[:space:]]' "$C" | head -n 1 | sed -E 's/^[[:space:]]*allow[[:space:]]+//'; }
top() { awk -v k="$1" '$1 == k { print $2; exit }' "$C"; }
mset() { jq "$1" "$M" >"$M.new" && cat "$M.new" >"$M" && rm -f "$M.new"; }

sec "a new server starts with the mode on (install without a Cloudflare option)"
if [[ "${CF_E2E_FRESH:-}" == yes ]]; then
  eq  "the manifest says on"                            "true" "$(jq -r '.cloudflare.enabled' "$M")"
  eq  "useIpInProxyHeader 2"                            "2" "$(top useIpInProxyHeader)"
  has "Cloudflare's ranges as T entries"                "173.245.48.0/20T" "$(allow_line)"
  has "the weekly refresh is scheduled"                 "update-cf-ips" "$(grep cfips "$CRON")"
else
  printf 'skipped (CF_E2E_FRESH=yes on a server installed just before)\n'
fi

sec "a site whose page prints REMOTE_ADDR; the mode turned off"
mset '.cloudflare.origin_lock = false | .trusted_proxies = []'
if [[ "$(jq -r '.cloudflare.enabled' "$M")" == true ]]; then run "cloudflare off" 0 $L cloudflare off; fi
if [[ ! -d "/home/${D}" ]]; then run "add ${D}" 0 $L add "$D" --non-interactive; fi
printf '<?php echo "RA=", $_SERVER["REMOTE_ADDR"], "\\n";\n' >"/home/${D}/public_html/ip.php"
chown --reference="/home/${D}/public_html" "/home/${D}/public_html/ip.php"
ip netns del cfx 2>/dev/null; ip link del vc 2>/dev/null
ip netns add cfx
ip link add vc type veth peer name vd
ip link set vd netns cfx
ip addr add "${HOST}/24" dev vc; ip link set vc up
ip route add "${CF}/32" dev vc
ip netns exec cfx ip addr add "${PROXY}/24" dev vd
ip netns exec cfx ip addr add "${STRANGER}/24" dev vd
ip netns exec cfx ip addr add "${CF}/32" dev vd
ip netns exec cfx ip link set vd up
run "status"                                            0 $L cloudflare status
has "status: off"                                       "Cloudflare mode" "$OUT"
has "status: says how to turn it on"                    "lomp cloudflare on" "$OUT"
has "status: the site, not behind Cloudflare"           "not behind Cloudflare" "$(grep -F "$D" <<<"$OUT")"
eq  "off: useIpInProxyHeader 0"                         "0" "$(top useIpInProxyHeader)"
eq  "off: Cloudflare's header is not believed"          "$CF" "$(ra "$CF" -H 'CF-Connecting-IP: 198.51.100.30')"

sec "on"
run "cloudflare on"                                     0 $L cloudflare on
has "said"                                              "Cloudflare mode enabled" "$OUT"
eq  "kept in the manifest"                              "true" "$(jq -r '.cloudflare.enabled' "$M")"
eq  "useIpInProxyHeader 2"                              "2" "$(top useIpInProxyHeader)"
has "Cloudflare's ranges as T entries"                  "173.245.48.0/20T" "$(allow_line)"
has "the weekly refresh is scheduled"                   "update-cf-ips" "$(grep cfips "$CRON")"
has "OpenLiteSpeed still runs"                          "active" "$(systemctl is-active lsws)"
eq  "from Cloudflare: CF-Connecting-IP is the visitor"  "198.51.100.30" "$(ra "$CF" -H 'CF-Connecting-IP: 198.51.100.30')"
eq  "from Cloudflare without the header: Cloudflare"    "$CF" "$(ra "$CF")"
eq  "anyone else's header is not believed"              "$STRANGER" "$(ra "$STRANGER" -H 'CF-Connecting-IP: 198.51.100.30' -H 'X-Forwarded-For: 198.51.100.20')"
eq  "a direct visitor is himself"                       "$STRANGER" "$(ra "$STRANGER")"
run "on again"                                          0 $L cloudflare on
has "said"                                              "already on" "$OUT"
eq  "the ranges once"                                   "1" "$(allow_line | grep -o '173.245.48.0/20T' | wc -l | tr -d ' ')"
run "status"                                            0 $L cloudflare status
has "status: on"                                        "CF-Connecting-IP" "$OUT"
has "status: what OLS is set to"                        "useIpInProxyHeader 2" "$OUT"

sec "off keeps a trusted proxy; refused while the origin is locked"
run "a trusted proxy"                                   0 $L trusted-proxy add "$PROXY"
mset '.cloudflare.origin_lock = true'
run "off while locked: refused"                         1 $L cloudflare off
has "and why"                                           "locked to Cloudflare" "$OUT"
eq  "still on"                                          "true" "$(jq -r '.cloudflare.enabled' "$M")"
mset '.cloudflare.origin_lock = false'
run "cloudflare off"                                    0 $L cloudflare off
has "said"                                              "Cloudflare mode disabled" "$OUT"
eq  "kept in the manifest"                              "false" "$(jq -r '.cloudflare.enabled' "$M")"
lacks "no Cloudflare range left"                        "173.245.48.0/20T" "$(allow_line)"
has "the proxy is still believed (OLS)"                 "${PROXY}T" "$(allow_line)"
eq  "so useIpInProxyHeader stays 2"                     "2" "$(top useIpInProxyHeader)"
# OpenLiteSpeed 1.9 at useIpInProxyHeader 2 knows Cloudflare's addresses by itself (measured
# 2026-11-08, after a full restart too): the command says so instead of claiming otherwise
has "and says Cloudflare is still believed at 2"        "still believes Cloudflare's own addresses" "$OUT"
eq  "(OLS: Cloudflare known by itself at 2)"            "198.51.100.30" "$(ra "$CF" -H 'CF-Connecting-IP: 198.51.100.30')"
eq  "the proxy's header still is"                       "198.51.100.20" "$(ra "$PROXY" -H 'X-Forwarded-For: 198.51.100.20')"
eq  "a stranger's header still is not"                  "$STRANGER" "$(ra "$STRANGER" -H 'CF-Connecting-IP: 198.51.100.30')"
run "the proxy removed"                                 0 $L trusted-proxy del "$PROXY"
eq  "nothing believed: useIpInProxyHeader 0"            "0" "$(top useIpInProxyHeader)"
eq  "allow ALL alone"                                   "ALL" "$(allow_line)"
eq  "now Cloudflare's header is not believed"           "$CF" "$(ra "$CF" -H 'CF-Connecting-IP: 198.51.100.30')"
run "off again"                                         0 $L cloudflare off
has "said"                                              "already off" "$OUT"
has "OpenLiteSpeed still runs"                          "active" "$(systemctl is-active lsws)"

sec "refusals"
run "an unknown action"                                 1 $L cloudflare maybe
has "said"                                              "Unknown cloudflare action" "$OUT"
run "help"                                              0 $L cloudflare help
has "usage"                                             "lomp cloudflare on | off | status" "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
