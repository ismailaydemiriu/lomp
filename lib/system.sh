#!/usr/bin/env bash
# lib/system.sh - system analysis, resource profile, kernel/limits tuning,
#                 swap, timezone and NTP.

# ---- analysis results --------------------------------------------------------
SYS_ANALYZED=0
SYS_HOSTNAME="" SYS_KERNEL="" SYS_ARCH="" SYS_CPU_CORES=1 SYS_CPU_MODEL=""
SYS_RAM_MB=0 SYS_RAM_AVAIL_MB=0 SYS_SWAP_MB=0
SYS_DISK_DEV="" SYS_DISK_TYPE="unknown" SYS_DISK_TOTAL_GB=0 SYS_DISK_FREE_GB=0 SYS_DISK_USED_PCT=0
SYS_IFACES="" SYS_PRIMARY_IPV4="" SYS_PUBLIC_IPV4="" SYS_PUBLIC_IPV6="" SYS_IPV6=0
SYS_SSH_PORTS="22" SYS_VIRT="none" SYS_UPTIME="" SYS_LOAD=""

# ---- calculated profile ------------------------------------------------------
CALC_DB_BUFFER_PCT=0 CALC_DB_BUFFER_MB=0 CALC_DB_LOG_MB=0 CALC_DB_MAX_CONN=0 CALC_DB_TMP_MB=0
CALC_DB_TABLE_CACHE=0 CALC_DB_THREAD_CACHE=0 CALC_DB_IO_CAP=0 CALC_DB_IO_CAP_MAX=0 CALC_DB_IO_THREADS=0
CALC_REDIS_PCT=0 CALC_REDIS_MB=0
CALC_PHP_MEMORY_MB=0 CALC_PHP_UPLOAD_MB=0 CALC_PHP_POST_MB=0 CALC_PHP_MAX_EXEC=0 CALC_PHP_MAX_INPUT_VARS=0
CALC_OPCACHE_MB=0 CALC_OPCACHE_FILES=0 CALC_OPCACHE_STRINGS_MB=0
CALC_PHP_CHILDREN_TOTAL=0 CALC_PHP_CHILDREN_SITE=0
CALC_OLS_WORKERS=0 CALC_OLS_MAX_CONN=0 CALC_OLS_INMEM_MB=0 CALC_OLS_MMAP_MB=0
CALC_SWAP_MB=0

_sys_clamp() { local v="$1" lo="$2" hi="$3"; (( v < lo )) && v="$lo"; (( v > hi )) && v="$hi"; printf '%d' "$v"; }

# =============================================================================
#  Analysis
# =============================================================================
# lib_system_analyze [--no-net]   (results cached for the process lifetime)
lib_system_analyze() {
  local nonet=0
  [[ "${1:-}" == "--no-net" ]] && nonet=1
  (( SYS_ANALYZED )) && return 0

  SYS_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
  SYS_KERNEL="$(uname -r)"
  SYS_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  SYS_CPU_CORES="$(nproc 2>/dev/null || echo 1)"
  SYS_CPU_MODEL="$(awk -F: '/model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  [[ -z "$SYS_CPU_MODEL" ]] && SYS_CPU_MODEL="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' || true)"

  SYS_RAM_MB=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
  SYS_RAM_AVAIL_MB=$(( $(awk '/^MemAvailable:/{print $2}' /proc/meminfo) / 1024 ))
  SYS_SWAP_MB=$(( $(awk '/^SwapTotal:/{print $2}' /proc/meminfo) / 1024 ))

  # ---- disk -----------------------------------------------------------------
  local src="" base="" rota=""
  src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  base="$src"
  if [[ -n "$src" && "$src" == /dev/* ]]; then
    local parent="$src" next="" i=""
    for (( i = 0; i < 6; i++ )); do
      next="$(lsblk -no PKNAME "$parent" 2>/dev/null | head -n1 || true)"
      [[ -n "$next" ]] || break
      parent="/dev/${next}"
    done
    base="$parent"
  fi
  SYS_DISK_DEV="$base"
  if [[ "$base" == /dev/nvme* ]]; then
    SYS_DISK_TYPE="nvme"
  elif [[ -n "$base" && "$base" == /dev/* ]]; then
    rota="$(lsblk -dno ROTA "$base" 2>/dev/null | tr -d ' ' || true)"
    if [[ "$rota" == "0" ]]; then SYS_DISK_TYPE="ssd"
    elif [[ "$rota" == "1" ]]; then
      case "$base" in /dev/vd*|/dev/xvd*|/dev/sd*) SYS_DISK_TYPE="virtual" ;; *) SYS_DISK_TYPE="hdd" ;; esac
    fi
  fi
  read -r SYS_DISK_TOTAL_GB SYS_DISK_FREE_GB SYS_DISK_USED_PCT < <(df -BG --output=size,avail,pcent / 2>/dev/null | awk 'NR==2{gsub(/[G%]/,""); print $1, $2, $3}')
  SYS_DISK_TOTAL_GB="${SYS_DISK_TOTAL_GB:-0}"; SYS_DISK_FREE_GB="${SYS_DISK_FREE_GB:-0}"; SYS_DISK_USED_PCT="${SYS_DISK_USED_PCT:-0}"

  # ---- virtualisation / network --------------------------------------------
  SYS_VIRT="$(systemd-detect-virt 2>/dev/null || true)"; [[ -z "$SYS_VIRT" ]] && SYS_VIRT="none"
  SYS_IFACES="$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2}' | tr '\n' ' ' | sed 's/ $//')"
  SYS_PRIMARY_IPV4="$(lib_primary_ipv4 || true)"
  SYS_IPV6=0
  if [[ -f /proc/net/if_inet6 ]] && [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" == "0" ]] \
     && ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    SYS_IPV6=1
  fi
  if (( ! nonet )); then
    SYS_PUBLIC_IPV4="$(lib_public_ipv4)"
    (( SYS_IPV6 )) && SYS_PUBLIC_IPV6="$(lib_public_ipv6)"
  fi
  [[ -z "$SYS_PUBLIC_IPV4" ]] && SYS_PUBLIC_IPV4="$SYS_PRIMARY_IPV4"
  SYS_SSH_PORTS="$(lib_ssh_ports)"
  SYS_UPTIME="$(uptime -p 2>/dev/null | sed 's/^up //' || true)"
  SYS_LOAD="$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null || true)"
  SYS_ANALYZED=1
}

lib_system_report() {
  lib_system_analyze
  lib_heading "System analysis"
  lib_print_kv "Host / kernel"   "${SYS_HOSTNAME} / ${SYS_KERNEL}"
  lib_print_kv "OS"              "Ubuntu ${OS_VERSION_ID} (${OS_CODENAME}), ${SYS_ARCH}, virt: ${SYS_VIRT}"
  lib_print_kv "CPU"             "${SYS_CPU_CORES} core(s) ${SYS_CPU_MODEL:+- $SYS_CPU_MODEL}"
  lib_print_kv "RAM"             "$(lib_human_mb "$SYS_RAM_MB") total, $(lib_human_mb "$SYS_RAM_AVAIL_MB") available"
  lib_print_kv "Swap"            "$( (( SYS_SWAP_MB > 0 )) && lib_human_mb "$SYS_SWAP_MB" || printf 'none')"
  lib_print_kv "Disk (/)"        "${SYS_DISK_TOTAL_GB} GB total, ${SYS_DISK_FREE_GB} GB free (${SYS_DISK_USED_PCT}% used), type: ${SYS_DISK_TYPE} ${SYS_DISK_DEV:+[$SYS_DISK_DEV]}"
  lib_print_kv "Interfaces"      "${SYS_IFACES:-?}"
  lib_print_kv "IPv4"            "${SYS_PRIMARY_IPV4:-?} (public: ${SYS_PUBLIC_IPV4:-unknown})"
  lib_print_kv "IPv6"            "$( (( SYS_IPV6 )) && printf '%s' "${SYS_PUBLIC_IPV6:-enabled}" || printf 'not available')"
  lib_print_kv "SSH port(s)"     "${SYS_SSH_PORTS}"
  lib_print_kv "Uptime / load"   "${SYS_UPTIME:-?} / ${SYS_LOAD:-?}"
}

# =============================================================================
#  Resource profile (all tunables derive from RAM / CPU / disk type)
# =============================================================================
lib_system_profile() {
  lib_system_analyze --no-net
  local r="$SYS_RAM_MB" c="$SYS_CPU_CORES"
  (( c < 1 )) && c=1

  # ---- MariaDB ----------------------------------------------------------------
  if [[ -n "$DB_BUFFER_PERCENT" ]]; then
    [[ "$DB_BUFFER_PERCENT" =~ ^[0-9]+$ ]] || lib_die "DB_BUFFER_PERCENT must be a number" "got '${DB_BUFFER_PERCENT}'" "use 5..80"
    CALC_DB_BUFFER_PCT="$(_sys_clamp "$DB_BUFFER_PERCENT" 5 80)"
  else
    if   (( r <= 1024 )); then CALC_DB_BUFFER_PCT=25
    elif (( r <= 2048 )); then CALC_DB_BUFFER_PCT=35
    elif (( r <= 4096 )); then CALC_DB_BUFFER_PCT=40
    elif (( r <= 8192 )); then CALC_DB_BUFFER_PCT=45
    else                       CALC_DB_BUFFER_PCT=50; fi
  fi
  CALC_DB_BUFFER_MB=$(( r * CALC_DB_BUFFER_PCT / 100 ))
  (( CALC_DB_BUFFER_MB < 128 )) && CALC_DB_BUFFER_MB=128
  CALC_DB_BUFFER_MB=$(( CALC_DB_BUFFER_MB / 8 * 8 ))
  CALC_DB_LOG_MB="$(_sys_clamp $(( CALC_DB_BUFFER_MB / 4 )) 64 2048)"
  CALC_DB_MAX_CONN="$(_sys_clamp $(( r / 16 )) 100 500)"
  CALC_DB_TMP_MB="$(_sys_clamp $(( r / 64 )) 32 256)"
  CALC_DB_TABLE_CACHE="$(_sys_clamp $(( r )) 2000 8000)"
  CALC_DB_THREAD_CACHE="$(_sys_clamp $(( CALC_DB_MAX_CONN / 4 )) 16 128)"
  case "$SYS_DISK_TYPE" in
    nvme)        CALC_DB_IO_CAP=2000; CALC_DB_IO_CAP_MAX=4000 ;;
    ssd|virtual) CALC_DB_IO_CAP=1000; CALC_DB_IO_CAP_MAX=2000 ;;
    hdd)         CALC_DB_IO_CAP=200;  CALC_DB_IO_CAP_MAX=400 ;;
    *)           CALC_DB_IO_CAP=600;  CALC_DB_IO_CAP_MAX=1200 ;;
  esac
  CALC_DB_IO_THREADS="$(_sys_clamp "$c" 2 8)"

  # ---- Redis ------------------------------------------------------------------
  if [[ -n "$REDIS_MAX_PERCENT" ]]; then
    [[ "$REDIS_MAX_PERCENT" =~ ^[0-9]+$ ]] || lib_die "REDIS_MAX_PERCENT must be a number" "got '${REDIS_MAX_PERCENT}'" "use 2..30"
    CALC_REDIS_PCT="$(_sys_clamp "$REDIS_MAX_PERCENT" 2 30)"
  else
    if   (( r <= 2048 )); then CALC_REDIS_PCT=5
    elif (( r <= 8192 )); then CALC_REDIS_PCT=8
    else                       CALC_REDIS_PCT=10; fi
  fi
  CALC_REDIS_MB=$(( r * CALC_REDIS_PCT / 100 ))
  (( CALC_REDIS_MB < 64 )) && CALC_REDIS_MB=64

  # ---- PHP --------------------------------------------------------------------
  if   (( r <= 1024 )); then CALC_PHP_MEMORY_MB=128; CALC_OPCACHE_MB=64;  CALC_OPCACHE_FILES=10000; CALC_OPCACHE_STRINGS_MB=8
  elif (( r <= 2048 )); then CALC_PHP_MEMORY_MB=192; CALC_OPCACHE_MB=128; CALC_OPCACHE_FILES=20000; CALC_OPCACHE_STRINGS_MB=16
  elif (( r <= 4096 )); then CALC_PHP_MEMORY_MB=256; CALC_OPCACHE_MB=192; CALC_OPCACHE_FILES=30000; CALC_OPCACHE_STRINGS_MB=16
  elif (( r <= 8192 )); then CALC_PHP_MEMORY_MB=384; CALC_OPCACHE_MB=256; CALC_OPCACHE_FILES=50000; CALC_OPCACHE_STRINGS_MB=32
  else                       CALC_PHP_MEMORY_MB=512; CALC_OPCACHE_MB=512; CALC_OPCACHE_FILES=100000; CALC_OPCACHE_STRINGS_MB=64; fi
  CALC_PHP_UPLOAD_MB=64; (( r <= 1024 )) && CALC_PHP_UPLOAD_MB=32
  CALC_PHP_POST_MB=$(( CALC_PHP_UPLOAD_MB + 8 ))
  CALC_PHP_MAX_EXEC=120
  CALC_PHP_MAX_INPUT_VARS=5000

  # PHP worker budget: RAM minus OS, DB, Redis and OLS shares; ~48 MB per worker
  local os_reserve=$(( r / 10 )); (( os_reserve < 256 )) && os_reserve=256
  local ols_share=$(( c * 30 + 64 ))
  local budget=$(( r - os_reserve - CALC_DB_BUFFER_MB - CALC_REDIS_MB - ols_share ))
  (( budget < 192 )) && budget=192
  CALC_PHP_CHILDREN_TOTAL="$(_sys_clamp $(( budget * 7 / 10 / 48 )) 4 $(( c * 12 )))"
  CALC_PHP_CHILDREN_SITE="$(_sys_clamp $(( CALC_PHP_CHILDREN_TOTAL / 2 )) 2 $(( c * 4 )))"
  if (( CALC_PHP_CHILDREN_SITE > 32 )); then CALC_PHP_CHILDREN_SITE=32; fi   # per-site cap; raise with --php-children

  # ---- OpenLiteSpeed ----------------------------------------------------------
  CALC_OLS_WORKERS="$(_sys_clamp "$c" 1 16)"
  CALC_OLS_MAX_CONN="$(_sys_clamp $(( c * 2500 )) 2000 20000)"
  CALC_OLS_INMEM_MB="$(_sys_clamp $(( r / 40 )) 20 512)"
  CALC_OLS_MMAP_MB="$(_sys_clamp $(( r / 20 )) 40 1024)"

  # ---- Swap -------------------------------------------------------------------
  CALC_SWAP_MB=0
  if (( SYS_SWAP_MB == 0 && r < 4096 )); then
    CALC_SWAP_MB=2048
    if (( r < 1024 )); then CALC_SWAP_MB=1024; fi
  fi
  return 0
}

lib_system_profile_json() {
  jq -n \
    --argjson ram "$SYS_RAM_MB" --argjson cpu "$SYS_CPU_CORES" --arg disk "$SYS_DISK_TYPE" \
    --argjson dbpct "$CALC_DB_BUFFER_PCT" --argjson dbmb "$CALC_DB_BUFFER_MB" --argjson dblog "$CALC_DB_LOG_MB" \
    --argjson dbconn "$CALC_DB_MAX_CONN" --argjson redis "$CALC_REDIS_MB" --argjson phpmem "$CALC_PHP_MEMORY_MB" \
    --argjson opc "$CALC_OPCACHE_MB" --argjson chtot "$CALC_PHP_CHILDREN_TOTAL" --argjson chsite "$CALC_PHP_CHILDREN_SITE" \
    --argjson olsw "$CALC_OLS_WORKERS" --argjson olsc "$CALC_OLS_MAX_CONN" --arg ts "$(lib_iso_now)" \
    '{measured_at:$ts, ram_mb:$ram, cpu_cores:$cpu, disk_type:$disk,
      db:{buffer_pool_pct:$dbpct, buffer_pool_mb:$dbmb, log_file_mb:$dblog, max_connections:$dbconn},
      redis:{maxmemory_mb:$redis},
      php:{memory_limit_mb:$phpmem, opcache_mb:$opc, children_total:$chtot, children_per_site:$chsite},
      ols:{workers:$olsw, max_connections:$olsc}}'
}

lib_system_profile_report() {
  lib_heading "Calculated profile"
  lib_print_kv "MariaDB buffer pool" "${CALC_DB_BUFFER_MB} MB (${CALC_DB_BUFFER_PCT}% of RAM), log file ${CALC_DB_LOG_MB} MB, max_connections ${CALC_DB_MAX_CONN}"
  lib_print_kv "Redis maxmemory"     "${CALC_REDIS_MB} MB (${CALC_REDIS_PCT}%)"
  lib_print_kv "PHP"                 "memory_limit ${CALC_PHP_MEMORY_MB}M, upload ${CALC_PHP_UPLOAD_MB}M, OPcache ${CALC_OPCACHE_MB}M / ${CALC_OPCACHE_FILES} files"
  lib_print_kv "PHP workers"         "${CALC_PHP_CHILDREN_TOTAL} total budget, ${CALC_PHP_CHILDREN_SITE} per site (default)"
  lib_print_kv "OpenLiteSpeed"       "${CALC_OLS_WORKERS} worker(s), ${CALC_OLS_MAX_CONN} max connections, in-memory cache ${CALC_OLS_INMEM_MB} MB"
  lib_print_kv "Swap"                "$( (( CALC_SWAP_MB > 0 )) && printf 'create %s MB swapfile' "$CALC_SWAP_MB" || printf 'no change')"
}

# =============================================================================
#  Kernel parameters (only keys the running kernel exposes)
# =============================================================================
_sys_key_exists() { local p="/proc/sys/${1//./\/}"; [[ -e "$p" ]]; }

_sys_bbr_available() {
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && return 0
  (( OPT_DRY_RUN )) && return 1
  modprobe tcp_bbr >/dev/null 2>&1 || true
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

lib_system_render_sysctl() {
  local -a keys=(
    "vm.swappiness=10"
    "vm.dirty_ratio=15"
    "vm.dirty_background_ratio=5"
    "vm.overcommit_memory=1"
    "vm.vfs_cache_pressure=50"
    "fs.file-max=2097152"
    "fs.nr_open=2097152"
    "fs.inotify.max_user_watches=524288"
    "fs.inotify.max_user_instances=1024"
    "net.core.somaxconn=65535"
    "net.core.netdev_max_backlog=65536"
    "net.core.rmem_max=16777216"
    "net.core.wmem_max=16777216"
    "net.core.optmem_max=65536"
    "net.core.default_qdisc=fq"
    "net.ipv4.tcp_max_syn_backlog=65536"
    "net.ipv4.tcp_syncookies=1"
    "net.ipv4.tcp_fin_timeout=15"
    "net.ipv4.tcp_tw_reuse=1"
    "net.ipv4.tcp_keepalive_time=300"
    "net.ipv4.tcp_keepalive_intvl=30"
    "net.ipv4.tcp_keepalive_probes=5"
    "net.ipv4.ip_local_port_range=10240 65535"
    "net.ipv4.tcp_rmem=4096 87380 16777216"
    "net.ipv4.tcp_wmem=4096 65536 16777216"
    "net.ipv4.tcp_slow_start_after_idle=0"
    "net.ipv4.tcp_mtu_probing=1"
    "net.ipv4.tcp_fastopen=3"
    "net.ipv4.tcp_max_tw_buckets=1440000"
    "net.ipv4.udp_rmem_min=16384"
    "net.ipv4.udp_wmem_min=16384"
    "net.ipv4.conf.all.accept_redirects=0"
    "net.ipv4.conf.default.accept_redirects=0"
    "net.ipv4.conf.all.send_redirects=0"
    "net.ipv4.conf.default.send_redirects=0"
    "net.ipv4.conf.all.accept_source_route=0"
    "net.ipv4.conf.all.log_martians=1"
    "net.ipv6.conf.all.accept_redirects=0"
    "net.ipv6.conf.default.accept_redirects=0"
    "kernel.panic=10"
  )
  local kv="" k="" v="" skipped=()
  printf '# Managed by lompstack - kernel tuning for a web/database VPS\n'
  printf '# Regenerated by: setup.sh install / optimize  (profile: %s MB RAM, %s CPU)\n\n' "$SYS_RAM_MB" "$SYS_CPU_CORES"
  for kv in "${keys[@]}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    if _sys_key_exists "$k"; then printf '%s = %s\n' "$k" "$v"; else skipped+=("$k"); fi
  done
  if _sys_key_exists net.ipv4.tcp_congestion_control && _sys_bbr_available; then
    printf 'net.ipv4.tcp_congestion_control = bbr\n'
  fi
  if ((${#skipped[@]} > 0)); then printf '\n# not supported by this kernel (skipped): %s\n' "${skipped[*]}"; fi
}

lib_system_sysctl_apply() {
  lib_system_analyze --no-net
  lib_system_render_sysctl | lib_write_file "$SYSCTL_FILE" 0644 root:root
  if (( LIB_FILE_CHANGED )); then
    if (( ! OPT_DRY_RUN )); then
      lib_run sysctl -q -p "$SYSCTL_FILE" || lib_warn "some sysctl values could not be applied (see log)"
    fi
    lib_ok "Kernel parameters written to ${SYSCTL_FILE}"
  else
    lib_ok "Kernel parameters already configured"
  fi
}

lib_system_render_limits() {
  cat <<'EOF'
# Managed by lompstack - open file / process limits
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
*       soft    nproc   65535
*       hard    nproc   65535
EOF
}

lib_system_limits_apply() {
  lib_system_render_limits | lib_write_file "$LIMITS_FILE" 0644 root:root
  (( LIB_FILE_CHANGED )) && lib_ok "Limits written to ${LIMITS_FILE}" || lib_ok "Limits already configured"

  printf '# Managed by lompstack\n[Manager]\nDefaultLimitNOFILE=1048576\nDefaultLimitNPROC=65535\n' \
    | lib_write_file /etc/systemd/system.conf.d/99-production-server.conf 0644 root:root
  if (( LIB_FILE_CHANGED )); then
    lib_systemctl daemon-reload
    lib_ok "systemd default limits configured"
  fi
  return 0
}

# =============================================================================
#  Swap (never touches existing swap)
# =============================================================================
lib_system_swap_ensure() {
  lib_system_profile
  if (( SYS_SWAP_MB > 0 )); then lib_ok "Existing swap kept ($(lib_human_mb "$SYS_SWAP_MB"))"; return 0; fi
  if (( CALC_SWAP_MB == 0 )); then lib_ok "No swap needed (RAM $(lib_human_mb "$SYS_RAM_MB"))"; return 0; fi
  if [[ -f /swapfile ]]; then lib_warn "/swapfile exists but is not active; leaving it alone"; return 0; fi
  local need_gb=$(( CALC_SWAP_MB / 1024 + 2 ))
  if (( SYS_DISK_FREE_GB < need_gb )); then
    lib_warn "Not enough free disk to create a ${CALC_SWAP_MB} MB swapfile (free: ${SYS_DISK_FREE_GB} GB); skipping"
    return 0
  fi
  lib_info "Creating ${CALC_SWAP_MB} MB swapfile (/swapfile)"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would create /swapfile and add it to /etc/fstab"; return 0; fi
  if ! fallocate -l "${CALC_SWAP_MB}M" /swapfile 2>/dev/null; then
    lib_run dd if=/dev/zero of=/swapfile bs=1M count="$CALC_SWAP_MB" status=none || lib_die "Could not create /swapfile" "disk full?" "free some space"
  fi
  chmod 0600 /swapfile
  # Swap is an optimisation, not a requirement. Two environments this installer otherwise
  # supports refuse swapon: containers without CAP_SYS_ADMIN, and CoW filesystems such as
  # btrfs (where fallocate and mkswap both succeed first). Aborting the whole run over it
  # also used to leave the file behind, and the "exists but inactive" guard above then
  # skipped swap forever - so on failure the file is removed again.
  if ! lib_run mkswap /swapfile; then
    rm -f /swapfile
    lib_warn "mkswap failed on /swapfile; continuing without swap"
    return 0
  fi
  if ! lib_run swapon /swapfile; then
    rm -f /swapfile
    lib_warn "The kernel refused the swapfile (container without CAP_SYS_ADMIN, or a CoW filesystem such as btrfs)."
    lib_note "Continuing without swap. To add it by hand: see 'man swapon' for your filesystem, or use a swap partition."
    return 0
  fi
  lib_append_line_once /etc/fstab "/swapfile none swap sw 0 0"
  SYS_SWAP_MB="$CALC_SWAP_MB"
  lib_ok "Swapfile active ($(lib_human_mb "$CALC_SWAP_MB"))"
}

# =============================================================================
#  Timezone / NTP
# =============================================================================
lib_system_timezone_apply() {
  local cur=""
  [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]] || lib_die "Unknown timezone '${TIMEZONE}'" "no such zoneinfo entry" "use e.g. Europe/Istanbul (see timedatectl list-timezones)"
  cur="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)"
  if [[ "$cur" == "$TIMEZONE" ]]; then lib_ok "Timezone already ${TIMEZONE}"; return 0; fi
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would set timezone ${cur:-?} -> ${TIMEZONE}"; return 0; fi
  lib_run timedatectl set-timezone "$TIMEZONE" || lib_die "timedatectl set-timezone failed" "systemd-timedated unavailable" "set timezone manually"
  lib_ok "Timezone set to ${TIMEZONE}"
}

lib_system_ntp_apply() {
  if lib_service_active chrony || lib_service_active chronyd; then lib_ok "NTP: chrony is active"; return 0; fi
  if ! lib_pkg_installed systemd-timesyncd && lib_pkg_available systemd-timesyncd; then
    lib_apt_install systemd-timesyncd || lib_warn "could not install systemd-timesyncd"
  fi
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would enable NTP (timedatectl set-ntp true)"; return 0; fi
  if [[ "$(timedatectl show -p NTP --value 2>/dev/null || true)" == "yes" ]]; then
    lib_ok "NTP synchronisation already enabled"
  else
    lib_run timedatectl set-ntp true || lib_warn "could not enable NTP synchronisation"
    lib_ok "NTP synchronisation enabled (systemd-timesyncd)"
  fi
}

lib_system_reboot_required() { [[ -f /var/run/reboot-required ]]; }
