#!/usr/bin/env bash
# lib/speed.sh - speed: finds where a slow site loses its time. It asks the site for its page a few
#                times from this machine, once straight to the web server and once the way a
#                visitor goes (DNS, Cloudflare), splits each answer into DNS / connect / TLS /
#                first byte / total, and looks at what the machine itself is short of. It reads;
#                it changes nothing.

SPEED_SLOW_LOCAL="1.0"     # seconds to the first byte, straight to the web server, that is slow
SPEED_WARM_LOCAL="0.4"     # ... that is worth a look
SPEED_EXTRA_PUBLIC="0.8"   # seconds the way to the visitor may add before it is named
SPEED_SLOW_DNS="0.3"
SPEED_SLOW_TLS="0.5"
SPEED_PROBLEMS=0           # sites over the run that had something to name

lib_speed_usage() {
  # a usage text is no single message lib/lang.sh could look up: its Turkish is here
  if [[ "${LIB_LANG:-en}" == "tr" ]]; then
    cat <<'EOF'
Kullanım: lomp speed <domain>... | --all [--runs N] [--local]

  Yavaş açılan bir sitenin zamanı nerede kaybettiğini bulur. Sayfayı bu makineden birkaç kez
  ister: bir kez doğrudan web sunucusuna (araya DNS ve Cloudflare girmeden), bir kez de
  ziyaretçinin yolundan (DNS, Cloudflare). Her yanıtı DNS / bağlantı / TLS / ilk bayt / toplam
  olarak ayırır, önbelleğin çalışıp çalışmadığına bakar ve makinenin neyi yetersiz bulduğunu
  gösterir (yük, bellek, swap, disk beklemesi). Hiçbir şeyi değiştirmez.

  --runs N  Her yol için istek sayısı (varsayılan 4, en çok 20). İlk istek "soğuk", sonrakiler
            "sıcak" sayılır; ikisinin farkı önbelleği gösterir.
  --local   Ziyaretçinin yolunu sınamaz; yalnızca doğrudan web sunucusuna sorar.
EOF
    return 0
  fi
  cat <<'EOF'
Usage: lomp speed <domain>... | --all [--runs N] [--local]

  Finds where a slow site loses its time. It asks for the page a few times from this machine:
  once straight to the web server (no DNS and no Cloudflare in between) and once the way a
  visitor goes (DNS, Cloudflare). Each answer is split into DNS / connect / TLS / first byte /
  total, the cache is looked for, and what the machine itself is short of is shown (load,
  memory, swap, disk wait). It changes nothing.

  --runs N  Requests per path (default 4, at most 20). The first is "cold", the rest "warm";
            the difference between them shows the cache.
  --local   Do not test the visitor's path; ask the web server directly only.
EOF
}

# a > b, as decimals
_speed_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) > (b + 0)) }'; }
_speed_ms() { awk -v s="$1" 'BEGIN { printf "%d ms", s * 1000 + 0.5 }'; }
# the middle one of the numbers it is given (at least one)
_speed_median() {
  printf '%s\n' "$@" | sort -n | awk '{ v[NR] = $1 } END {
    if (NR == 0) print 0; else if (NR % 2) print v[(NR + 1) / 2]; else print (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

# One request. Prints: dns connect tls first-byte total code bytes cache
# (cache = what the answer's cache headers said, "-" when it carried none). The times are
# cumulative from the start, as curl counts them; a time that did not happen is 0.
_speed_probe() {   # url [curl args...]
  local url="$1" hdr="" out="" cache=""
  shift
  hdr="$(lib_mktemp)"
  out="$(LC_ALL=C curl -s -o /dev/null -D "$hdr" --max-time 30 \
    -w '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{http_code} %{size_download}' \
    "$@" "$url" 2>/dev/null || true)"
  if ! [[ "$out" =~ ^[0-9.]+\ [0-9.]+\ [0-9.]+\ [0-9.]+\ [0-9.]+\ [0-9]{3}\ [0-9]+$ ]]; then out="0 0 0 0 0 000 0"; fi
  cache="$(awk -F': *' '{ l = tolower($1)
      if (l == "x-litespeed-cache" || l == "cf-cache-status" || l == "x-cache") {
        v = $2; gsub(/[\r\n]/, "", v); printf "%s%s=%s", (n++ ? "," : ""), l, v } }' "$hdr" 2>/dev/null || true)"
  rm -f -- "$hdr"
  printf '%s %s\n' "$out" "${cache:--}"
}

# The requests of one path, printed as they come. Fills SPEED_FIRST (the first byte of the
# first request), SPEED_WARM (the middle first byte of the others, or of the one there was),
# SPEED_DNS, SPEED_CONNECT, SPEED_TLS (of the last request), SPEED_CODE (of the last), and
# SPEED_CACHE (the cache headers of the last).
_speed_path() {   # label url runs [curl args...]
  local label="$1" url="$2" runs="$3" i=0 dns="" con="" tls="" ttfb="" total="" code="" size="" cache=""
  local -a warm=()
  shift 3
  SPEED_FIRST="0"; SPEED_WARM="0"; SPEED_DNS="0"; SPEED_CONNECT="0"; SPEED_TLS="0"; SPEED_CODE="000"; SPEED_CACHE="-"
  for ((i = 1; i <= runs; i++)); do
    read -r dns con tls ttfb total code size cache < <(_speed_probe "$url" "$@")
    lib_note "$(printf '%-8s #%-2s dns %-7s connect %-7s tls %-7s first byte %-8s total %-8s HTTP %s  %s' \
      "$label" "$i" "$(_speed_ms "$dns")" "$(_speed_ms "$(awk -v a="$con" -v b="$dns" 'BEGIN { print (a > b ? a - b : 0) }')")" \
      "$(_speed_ms "$(awk -v a="$tls" -v b="$con" 'BEGIN { print (a > b ? a - b : 0) }')")" \
      "$(_speed_ms "$ttfb")" "$(_speed_ms "$total")" "$code" "$cache")"
    if ((i == 1)); then SPEED_FIRST="$ttfb"; else warm+=("$ttfb"); fi
    SPEED_DNS="$dns"; SPEED_CONNECT="$(awk -v a="$con" -v b="$dns" 'BEGIN { print (a > b ? a - b : 0) }')"
    SPEED_TLS="$(awk -v a="$tls" -v b="$con" 'BEGIN { print (a > b ? a - b : 0) }')"
    SPEED_CODE="$code"; SPEED_CACHE="$cache"
  done
  if ((${#warm[@]} > 0)); then SPEED_WARM="$(_speed_median "${warm[@]}")"; else SPEED_WARM="$SPEED_FIRST"; fi
  return 0
}

# What the machine is short of. Prints one line per thing worth naming and counts it.
_speed_server() {
  local cpus=1 load="" tot=0 avail=0 swtot=0 swfree=0 t1=0 w1=0 t2=0 w2=0 line="" iow=""
  lib_heading "This server"
  cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"; [[ "$cpus" =~ ^[0-9]+$ && "$cpus" -ge 1 ]] || cpus=1
  read -r load _ </proc/loadavg || load="0"
  read -r tot avail swtot swfree < <(awk '
    /^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
    END { print t + 0, a + 0, st + 0, sf + 0 }' /proc/meminfo)
  read -r t1 w1 < <(awk '/^cpu / { t = 0; for (i = 2; i <= NF; i++) t += $i; print t, $6 }' /proc/stat)
  sleep 1
  read -r t2 w2 < <(awk '/^cpu / { t = 0; for (i = 2; i <= NF; i++) t += $i; print t, $6 }' /proc/stat)
  iow="$(awk -v t1="$t1" -v t2="$t2" -v w1="$w1" -v w2="$w2" 'BEGIN { d = t2 - t1; printf "%d", (d > 0 ? (w2 - w1) * 100 / d : 0) }')"

  lib_note "$(printf 'load %s on %s CPU(s), memory free %s of %s MB, swap used %s MB, disk wait %s%%' \
    "$load" "$cpus" "$((avail / 1024))" "$((tot / 1024))" "$(((swtot - swfree) / 1024))" "$iow")"
  if _speed_gt "$load" "$(awk -v c="$cpus" 'BEGIN { print c * 1.5 }')"; then
    lib_warn "The load (${load}) is above what ${cpus} CPU(s) can run at once: requests wait in a queue for a worker"
    SPEED_PROBLEMS=$((SPEED_PROBLEMS + 1))
  fi
  if ((tot > 0 && avail * 100 / tot < 10)); then
    lib_warn "Less than 10% of the memory is free ($((avail / 1024)) MB): the system drops caches and starts to swap"
    SPEED_PROBLEMS=$((SPEED_PROBLEMS + 1))
  fi
  if (((swtot - swfree) / 1024 > 200)); then
    lib_warn "$(((swtot - swfree) / 1024)) MB of swap is in use: a page that was pushed out to the disk is slow to come back"
    SPEED_PROBLEMS=$((SPEED_PROBLEMS + 1))
  fi
  if ((iow > 20)); then
    lib_warn "The CPUs spent ${iow}% of the last second waiting for the disk"
    SPEED_PROBLEMS=$((SPEED_PROBLEMS + 1))
  fi
  lib_note "busiest processes:"
  while read -r line; do
    [[ -n "$line" ]] && lib_note "  ${line}"
  done < <(ps -eo pcpu,pmem,comm --sort=-pcpu 2>/dev/null | awk 'NR > 1 && NR <= 6 { printf "%5s%% cpu %5s%% mem  %s\n", $1, $2, $3 }' || true)
  return 0
}

# One site. Returns 1 when the web server on this machine gave no answer at all.
_speed_site() {   # domain runs local
  local d="$1" runs="$2" only_local="$3"
  local l_first="" l_warm="" l_code="" l_cache="" p_warm="" p_dns="" p_tls="" p_code="" named=0 url=""
  lib_heading "$d"

  url="https://${d}/"
  _speed_path "local" "$url" "$runs" -k --resolve "${d}:443:127.0.0.1"
  if [[ "$SPEED_CODE" == "000" ]]; then
    lib_note "no answer over https on this machine; trying plain http"
    url="http://${d}/"
    _speed_path "local" "$url" "$runs" --resolve "${d}:80:127.0.0.1"
  fi
  l_first="$SPEED_FIRST"; l_warm="$SPEED_WARM"; l_code="$SPEED_CODE"; l_cache="$SPEED_CACHE"

  if (( ! only_local )); then
    _speed_path "visitor" "https://${d}/" "$runs"
    p_warm="$SPEED_WARM"; p_dns="$SPEED_DNS"; p_tls="$SPEED_TLS"; p_code="$SPEED_CODE"
  fi

  printf '\n'
  if [[ "$l_code" == "000" ]]; then
    lib_error "${d}: the web server on this machine did not answer (is OpenLiteSpeed running? lomp doctor)"
    SPEED_PROBLEMS=$((SPEED_PROBLEMS + 1))
    return 1
  fi
  if [[ "$l_code" =~ ^[45] ]]; then
    lib_warn "${d}: the page answers HTTP ${l_code}; what was timed is an error page, not the site"
    named=$((named + 1))
  fi
  if _speed_gt "$l_warm" "$SPEED_SLOW_LOCAL"; then
    lib_warn "${d}: the web server itself needs $(_speed_ms "$l_warm") to start answering, with no network in between. The time goes into PHP or the database: a heavy plugin or theme, a slow query, or no page cache (lomp logs ${d})"
    named=$((named + 1))
  elif _speed_gt "$l_warm" "$SPEED_WARM_LOCAL"; then
    lib_info "${d}: $(_speed_ms "$l_warm") to the first byte on the web server is more than a cached page needs"
  fi
  if _speed_gt "$l_first" "$(awk -v w="$l_warm" 'BEGIN { print w * 2 + 0.5 }')"; then
    lib_warn "${d}: the first request took $(_speed_ms "$l_first"), the later ones $(_speed_ms "$l_warm"): the page is made again after a while (a cache that expires or is not warm) or PHP starts cold"
    named=$((named + 1))
  fi
  if [[ "$l_cache" == "-" && "$l_code" == "200" ]] && _speed_gt "$l_warm" "$SPEED_WARM_LOCAL"; then
    lib_note "no cache header (x-litespeed-cache) on the answer: every visit runs PHP. Fine for a page that must be made fresh, slow for a WordPress page with a cache plugin missing"
  fi
  if (( ! only_local )); then
    if [[ "$p_code" == "000" ]]; then
      lib_warn "${d}: the visitor's path gave no answer (DNS, firewall or Cloudflare). A visitor sees a site that does not open, not a slow one"
      named=$((named + 1))
    else
      if _speed_gt "$p_warm" "$(awk -v l="$l_warm" -v e="$SPEED_EXTRA_PUBLIC" 'BEGIN { print l + e }')"; then
        lib_warn "${d}: a visitor waits $(_speed_ms "$p_warm") for the first byte, $(_speed_ms "$(awk -v p="$p_warm" -v l="$l_warm" 'BEGIN { print p - l }')") more than the web server needs. That is DNS, Cloudflare or the network between, not this machine"
        named=$((named + 1))
      fi
      if _speed_gt "$p_dns" "$SPEED_SLOW_DNS"; then
        lib_warn "${d}: the DNS answer took $(_speed_ms "$p_dns"): the name server of the domain is slow or far"
        named=$((named + 1))
      fi
      if _speed_gt "$p_tls" "$SPEED_SLOW_TLS"; then
        lib_warn "${d}: the TLS handshake took $(_speed_ms "$p_tls") on the visitor's path"
        named=$((named + 1))
      fi
    fi
  fi
  if ((named == 0)); then
    lib_ok "${d}: no slow part found from here ($(_speed_ms "$l_warm") on the web server)"
    lib_note "this is measured from the server: a visitor far away, on a slow phone or loading many files adds time that is not measured here"
  else
    SPEED_PROBLEMS=$((SPEED_PROBLEMS + 1))
  fi
  return 0
}

lib_speed_main() {
  local a="" all=0 only_local=0 runs=4 d="" failed=0
  local -a domains=()
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --all)          all=1 ;;
      --local)        only_local=1 ;;
      --runs)         (($# > 0)) || lib_die "--runs needs a number" "" "lomp speed example.com --runs 6"
                      runs="$1"; shift ;;
      --runs=*)       runs="${a#--runs=}" ;;
      -h|--help|help) lib_speed_usage; return 0 ;;
      -*)             lib_speed_usage >&2; lib_die "Unknown option for speed: ${a}" "" "see the usage above" ;;
      *)              domains+=("${a,,}") ;;
    esac
  done
  [[ "$runs" =~ ^[0-9]+$ ]] && ((runs >= 1 && runs <= 20)) || lib_die "--runs takes a number from 1 to 20" "" "lomp speed example.com --runs 6"
  if (( all )) && ((${#domains[@]} > 0)); then lib_die "--all and a domain cannot be combined" "" "lomp speed --all"; fi
  if (( ! all )) && ((${#domains[@]} == 0)); then
    lib_speed_usage >&2
    lib_die "Domain missing" "" "lomp speed example.com   (every site: lomp speed --all)"
  fi
  for d in "${domains[@]}"; do
    lib_domain_valid "$d" || lib_die "Invalid domain name '${d}'" "" "lomp list"
    lib_domain_registered "$d" || lib_die "Site ${d} is not registered" "" "lomp list"
  done
  if (( all )); then
    mapfile -t domains < <(lib_domains_list)
    if ((${#domains[@]} == 0)); then lib_info "No sites have been added yet."; return 0; fi
  fi
  command -v curl >/dev/null 2>&1 || lib_die "curl is not installed" "" "apt-get install curl"
  SPEED_PROBLEMS=0
  _speed_server
  for d in "${domains[@]}"; do
    _speed_site "$d" "$runs" "$only_local" || failed=$((failed + 1))
  done
  printf '\n'
  lib_log_write INFO "speed: ${#domains[@]} site(s), ${SPEED_PROBLEMS} with something named, ${failed} without an answer"
  (( failed == 0 ))
}
