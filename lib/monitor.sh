#!/usr/bin/env bash
# lib/monitor.sh - status, doctor (deep health check), healthcheck timer entry,
#                  notifications (e-mail via msmtp, Telegram, Discord/Slack webhooks).

NOTIFY_CONF="${STATE_DIR}/notify.conf"
MSMTP_CONF="/etc/msmtprc"
SSH_NOTIFY_SCRIPT="${INSTALL_DIR}/ssh-login-notify.sh"
NT_EMAIL="" NT_SMTP_HOST="" NT_SMTP_PORT="" NT_SMTP_USER="" NT_SMTP_PASS="" NT_SMTP_FROM="" NT_SMTP_TLS="on"
NT_TELEGRAM_TOKEN="" NT_TELEGRAM_CHAT="" NT_WEBHOOK_URL=""
declare -ga DOC_RESULTS=()
DOC_FAIL=0
DOC_WARN=0
DOC_OK=0

# =============================================================================
#  Notifications
# =============================================================================
_nt_get() { [[ -s "$NOTIFY_CONF" ]] && awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$NOTIFY_CONF" || true; }

lib_notify_load() {
  NT_EMAIL="$(_nt_get EMAIL)"; NT_SMTP_HOST="$(_nt_get SMTP_HOST)"; NT_SMTP_PORT="$(_nt_get SMTP_PORT)"
  NT_SMTP_USER="$(_nt_get SMTP_USER)"; NT_SMTP_PASS="$(_nt_get SMTP_PASS)"; NT_SMTP_FROM="$(_nt_get SMTP_FROM)"
  NT_SMTP_TLS="$(_nt_get SMTP_TLS)"; NT_TELEGRAM_TOKEN="$(_nt_get TELEGRAM_TOKEN)"; NT_TELEGRAM_CHAT="$(_nt_get TELEGRAM_CHAT)"
  NT_WEBHOOK_URL="$(_nt_get WEBHOOK_URL)"
  [[ -z "$NT_SMTP_TLS" ]] && NT_SMTP_TLS="on"
  return 0
}

lib_notify_configured() { lib_notify_load; [[ -n "$NT_EMAIL" || -n "$NT_TELEGRAM_TOKEN" || -n "$NT_WEBHOOK_URL" ]]; }

lib_notify_channels() {
  lib_notify_load
  local out=()
  [[ -n "$NT_EMAIL" ]] && out+=("email:${NT_EMAIL}")
  [[ -n "$NT_TELEGRAM_TOKEN" ]] && out+=("telegram")
  [[ -n "$NT_WEBHOOK_URL" ]] && out+=("webhook")
  ((${#out[@]})) && lib_join ', ' "${out[@]}" || printf 'none'
}

# lib_notify_send "subject" "body"  - best effort, never fails the caller
lib_notify_send() {
  local subject="$1" body="$2" host="" payload=""
  host="$(hostname -f 2>/dev/null || hostname)"
  lib_log_write NOTIFY "$subject"
  lib_notify_load
  (( OPT_DRY_RUN )) && { lib_info "[dry-run] would notify: ${subject}"; return 0; }
  if [[ -n "$NT_EMAIL" ]]; then
    if lib_have msmtp && [[ -s "$MSMTP_CONF" ]]; then
      printf 'To: %s\nFrom: %s\nSubject: [%s] %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' "$NT_EMAIL" "${NT_SMTP_FROM:-server-setup@${host}}" "$host" "$subject" "$body" \
        | msmtp -t >>"$LOG_FILE" 2>&1 || lib_log_write WARN "e-mail notification failed (msmtp)"
    elif lib_have sendmail; then
      printf 'To: %s\nSubject: [%s] %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' "$NT_EMAIL" "$host" "$subject" "$body" \
        | sendmail -t >>"$LOG_FILE" 2>&1 || lib_log_write WARN "e-mail notification failed (sendmail)"
    else
      lib_log_write WARN "e-mail notification skipped: no msmtp/sendmail (configure: setup.sh notify --email ... --smtp-host ...)"
    fi
  fi
  if [[ -n "$NT_TELEGRAM_TOKEN" && -n "$NT_TELEGRAM_CHAT" ]]; then
    curl -fsS --max-time 15 -o /dev/null -X POST "https://api.telegram.org/bot${NT_TELEGRAM_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${NT_TELEGRAM_CHAT}" --data-urlencode "text=[${host}] ${subject}"$'\n\n'"${body:0:3500}" >/dev/null 2>&1 \
      || lib_log_write WARN "telegram notification failed"
  fi
  if [[ -n "$NT_WEBHOOK_URL" ]]; then
    case "$NT_WEBHOOK_URL" in
      *discord*) payload="$(jq -n --arg t "[${host}] ${subject}"$'\n'"${body:0:1800}" '{content:$t}')" ;;
      *slack*)   payload="$(jq -n --arg t "[${host}] ${subject}"$'\n'"${body:0:3000}" '{text:$t}')" ;;
      *)         payload="$(jq -n --arg t "[${host}] ${subject}"$'\n'"${body:0:3000}" '{text:$t, content:$t}')" ;;
    esac
    curl -fsS --max-time 15 -o /dev/null -H 'Content-Type: application/json' -X POST --data "$payload" "$NT_WEBHOOK_URL" >/dev/null 2>&1 \
      || lib_log_write WARN "webhook notification failed"
  fi
  return 0
}

_nt_set() {   # key value  (rewrite notify.conf atomically, 0600)
  local key="$1" value="$2" tmp=""
  (( OPT_DRY_RUN )) && { lib_info "[dry-run] would set ${key} in ${NOTIFY_CONF}"; return 0; }
  mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR"
  tmp="$(lib_mktemp)"
  { [[ -s "$NOTIFY_CONF" ]] && grep -v "^${key}=" "$NOTIFY_CONF"; printf '%s=%s\n' "$key" "$value"; } >"$tmp" || true
  chmod 0600 "$tmp" && mv -f "$tmp" "$NOTIFY_CONF"
  return 0
}

lib_notify_msmtp_write() {
  local starttls="on"
  [[ "$NT_SMTP_PORT" == "465" ]] && starttls="off"
  lib_apt_install msmtp msmtp-mta || lib_warn "msmtp could not be installed"
  {
    printf '# Managed by lompstack\ndefaults\nauth on\ntls %s\ntls_starttls %s\ntls_trust_file /etc/ssl/certs/ca-certificates.crt\nlogfile /var/log/msmtp.log\n\n' "$NT_SMTP_TLS" "$starttls"
    printf 'account default\nhost %s\nport %s\nfrom %s\nuser %s\npassword %s\n' "$NT_SMTP_HOST" "${NT_SMTP_PORT:-587}" "${NT_SMTP_FROM:-$NT_EMAIL}" "$NT_SMTP_USER" "$NT_SMTP_PASS"
  } | lib_write_file "$MSMTP_CONF" 0600 root:root
  lib_ok "msmtp configured for ${NT_SMTP_HOST}:${NT_SMTP_PORT:-587}"
}

lib_notify_ssh_login() {   # on|off
  local mode="$1" line="session    optional     pam_exec.so quiet ${SSH_NOTIFY_SCRIPT}" tmp=""
  if [[ "$mode" == "on" ]]; then
    lib_mkdir "$INSTALL_DIR" 0755 root:root
    cat <<EOF | lib_write_file "$SSH_NOTIFY_SCRIPT" 0755 root:root
#!/usr/bin/env bash
# Managed by lompstack - PAM hook: notify on interactive SSH logins
[ "\${PAM_TYPE:-}" = "open_session" ] || exit 0
( "${BIN_LINK}" notify --send "SSH login on \$(hostname)" "User \${PAM_USER:-?} logged in from \${PAM_RHOST:-?} at \$(date '+%Y-%m-%d %H:%M:%S')" --quiet >/dev/null 2>&1 & )
exit 0
EOF
    if ! grep -qF "$SSH_NOTIFY_SCRIPT" /etc/pam.d/sshd 2>/dev/null; then
      tmp="$(lib_mktemp)"
      { cat /etc/pam.d/sshd; printf '# server-setup:ssh-notify\n%s\n' "$line"; } >"$tmp"
      lib_write_file /etc/pam.d/sshd 0644 root:root <"$tmp"
    fi
    lib_ok "SSH login notifications enabled (PAM)"
  else
    if grep -qF "$SSH_NOTIFY_SCRIPT" /etc/pam.d/sshd 2>/dev/null; then
      tmp="$(lib_mktemp)"
      grep -vF "$SSH_NOTIFY_SCRIPT" /etc/pam.d/sshd | grep -v '^# server-setup:ssh-notify$' >"$tmp" || true
      lib_write_file /etc/pam.d/sshd 0644 root:root <"$tmp"
    fi
    lib_ok "SSH login notifications disabled"
  fi
  lib_manifest_set_json '.notify.ssh_login' "$( [[ "$mode" == "on" ]] && printf 'true' || printf 'false')"
}

lib_notify_main() {
  local a="" test=0 show=0 send_subject="" send_body="" changed=0 ssh_login=""
  lib_require_tools
  [[ $# -gt 0 ]] || { lib_notify_show; return 0; }
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --email)          _nt_set EMAIL "${1:-}"; shift; changed=1 ;;
      --smtp-host)      _nt_set SMTP_HOST "${1:-}"; shift; changed=1 ;;
      --smtp-port)      _nt_set SMTP_PORT "${1:-}"; shift; changed=1 ;;
      --smtp-user)      _nt_set SMTP_USER "${1:-}"; shift; changed=1 ;;
      --smtp-pass)      _nt_set SMTP_PASS "${1:-}"; shift; changed=1 ;;
      --smtp-from)      _nt_set SMTP_FROM "${1:-}"; shift; changed=1 ;;
      --smtp-tls)       _nt_set SMTP_TLS "${1:-on}"; shift; changed=1 ;;
      --telegram-token) _nt_set TELEGRAM_TOKEN "${1:-}"; shift; changed=1 ;;
      --telegram-chat)  _nt_set TELEGRAM_CHAT "${1:-}"; shift; changed=1 ;;
      --webhook)        _nt_set WEBHOOK_URL "${1:-}"; shift; changed=1 ;;
      --ssh-login)      ssh_login="${1:-on}"; shift ;;
      --test)           test=1 ;;
      --show)           show=1 ;;
      --send)           send_subject="${1:-}"; send_body="${2:-}"; shift 2 ;;
      *) lib_die "Unknown option for notify: ${a}" "" "notify --email a@b.c [--smtp-host H --smtp-port P --smtp-user U --smtp-pass P --smtp-from F] --telegram-token T --telegram-chat C --webhook URL --ssh-login on|off --test --show" ;;
    esac
  done
  if [[ -n "$send_subject" ]]; then lib_notify_send "$send_subject" "$send_body"; return 0; fi
  lib_notify_load
  if (( changed )) && [[ -n "$NT_SMTP_HOST" ]]; then lib_notify_msmtp_write; fi
  if (( changed )); then
    lib_manifest_set '.notify.email' "$NT_EMAIL"
    lib_manifest_set_json '.notify.telegram' "$( [[ -n "$NT_TELEGRAM_TOKEN" ]] && printf 'true' || printf 'false')"
    lib_manifest_set_json '.notify.webhook' "$( [[ -n "$NT_WEBHOOK_URL" ]] && printf 'true' || printf 'false')"
    lib_ok "Notification settings saved (${NOTIFY_CONF}, 0600): $(lib_notify_channels)"
  fi
  [[ -n "$ssh_login" ]] && lib_notify_ssh_login "$ssh_login"
  (( show )) && lib_notify_show
  if (( test )); then
    lib_notify_configured || lib_die "No notification channel configured" "" "notify --email a@b.c / --telegram-token ... / --webhook URL"
    lib_notify_send "Test notification" "server-setup notifications are working on $(hostname) ($(lib_iso_now))."
    lib_ok "Test notification sent to: $(lib_notify_channels) (check the log for delivery errors)"
  fi
  return 0
}

lib_notify_show() {
  lib_notify_load
  printf '\n%sNotification channels%s\n' "$C_BLD" "$C_RST"
  lib_print_kv "E-mail"   "${NT_EMAIL:-not set}${NT_SMTP_HOST:+ via ${NT_SMTP_HOST}:${NT_SMTP_PORT:-587}}"
  lib_print_kv "Telegram" "$( [[ -n "$NT_TELEGRAM_TOKEN" ]] && printf 'configured (chat %s)' "$NT_TELEGRAM_CHAT" || printf 'not set')"
  lib_print_kv "Webhook"  "$( [[ -n "$NT_WEBHOOK_URL" ]] && printf '%s' "${NT_WEBHOOK_URL:0:40}..." || printf 'not set')"
  lib_print_kv "SSH login" "$( [[ "$(lib_manifest_get '.notify.ssh_login')" == "true" ]] && printf 'on' || printf 'off')"
  printf '\n'
}

# =============================================================================
#  status
# =============================================================================
_svc_state() {   # unit -> active|inactive|missing
  if ! lib_service_exists "$1" && ! systemctl cat "$1" >/dev/null 2>&1; then printf 'missing'; return 0; fi
  if lib_service_active "$1"; then printf 'active'; else printf 'inactive'; fi
}

lib_status_main() {
  local json=0 d="" svc="" st=""
  [[ "${1:-}" == "--json" ]] && json=1
  (( OPT_JSON )) && json=1
  lib_require_tools
  lib_system_analyze --no-net
  local -a services=(lsws mariadb redis-server fail2ban ufw certbot.timer)
  local -A sstate=()
  for svc in "${services[@]}"; do sstate["$svc"]="$(_svc_state "$svc")"; done
  local ram_used=$(( SYS_RAM_MB - SYS_RAM_AVAIL_MB ))
  local reboot="no"; lib_system_reboot_required && reboot="yes"
  local last_backup=""; last_backup="$(lib_manifest_get '.backup.last_run')"
  local installed_at=""; installed_at="$(lib_manifest_get '.installed_at')"

  if (( json )); then
    local sites="[]" s=""
    for d in $(lib_domains_list); do
      lib_domain_state_load "$d" || continue
      s="$(jq -n --arg d "$d" --arg mode "$D_MODE" --arg php "$D_PHP" --argjson ssl "$(_d_json_bool "$D_SSL")" \
             --arg days "$(lib_ssl_days_left "$d")" --arg last "$D_BACKUP_LAST" --arg status "$D_STATUS" \
             '{domain:$d, mode:$mode, php:$php, ssl:$ssl, ssl_days_left:(if $days=="" then null else ($days|tonumber) end), last_backup:$last, status:$status}')"
      sites="$(jq -n --argjson a "$sites" --argjson b "$s" '$a + [$b]')"
    done
    jq -n \
      --arg host "$SYS_HOSTNAME" --arg os "Ubuntu ${OS_VERSION_ID}" --arg ver "$SCRIPT_VERSION" --arg inst "$installed_at" \
      --arg lsws "${sstate[lsws]}" --arg mariadb "${sstate[mariadb]}" --arg redis "${sstate[redis-server]}" \
      --arg f2b "${sstate[fail2ban]}" --arg ufw "${sstate[ufw]}" --arg certbot "${sstate[certbot.timer]}" \
      --arg olsv "$(lib_ols_version)" --arg phpv "$(lib_php_summary_line)" --arg dbv "$(lib_db_version)" --arg redisv "$(lib_redis_version)" \
      --argjson ram_mb "$SYS_RAM_MB" --argjson ram_used_mb "$ram_used" --argjson swap_mb "$SYS_SWAP_MB" \
      --argjson disk_pct "$SYS_DISK_USED_PCT" --arg load "$SYS_LOAD" --arg uptime "$SYS_UPTIME" --arg reboot "$reboot" \
      --arg cf "$(lib_cf_status_line)" --arg admin "$(lib_panel_status_line)" \
      --arg notify "$(lib_notify_channels)" --arg schedule "$(lib_manifest_get '.backup.schedule')" \
      --arg last_backup "$last_backup" --argjson sites "$sites" --argjson apps "$(lib_app_list --json 2>/dev/null || printf '[]')" \
      '{host:$host, os:$os, script_version:$ver, installed_at:$inst,
        services:{lsws:$lsws, mariadb:$mariadb, redis:$redis, fail2ban:$f2b, ufw:$ufw, certbot_timer:$certbot},
        versions:{openlitespeed:$olsv, php:$phpv, mariadb:$dbv, redis:$redisv},
        resources:{ram_mb:$ram_mb, ram_used_mb:$ram_used_mb, swap_mb:$swap_mb, disk_used_pct:$disk_pct, load:$load, uptime:$uptime, reboot_required:($reboot=="yes")},
        cloudflare:$cf, webadmin:$admin, notifications:$notify, backup:{schedule:$schedule, last_run:$last_backup}, sites:$sites, apps:$apps}'
    return 0
  fi

  local revision=""; revision="$(lib_manifest_get '.install.revision')"
  lib_heading "Server status - ${SYS_HOSTNAME} (Ubuntu ${OS_VERSION_ID}, lompstack ${SCRIPT_VERSION}${revision:+ @${revision}}${installed_at:+, installed ${installed_at:0:10}})"
  printf '  %sServices%s\n' "$C_BLD" "$C_RST"
  for svc in "${services[@]}"; do
    st="${sstate[$svc]}"
    case "$st" in
      active)   printf '    %s●%s %-14s active\n' "$C_GRN" "$C_RST" "$svc" ;;
      inactive) printf '    %s●%s %-14s INACTIVE\n' "$C_RED" "$C_RST" "$svc" ;;
      *)        printf '    %s○%s %-14s not installed\n' "$C_DIM" "$C_RST" "$svc" ;;
    esac
  done
  printf '  %sVersions%s\n' "$C_BLD" "$C_RST"
  lib_print_kv "OpenLiteSpeed" "$(lib_ols_version)"
  lib_print_kv "PHP (LSPHP)"   "$(lib_php_summary_line)"
  lib_print_kv "MariaDB"       "$(lib_db_version)"
  lib_print_kv "Redis"         "$(lib_redis_version)"
  lib_print_kv "certbot"       "$(lib_pkg_version certbot)"
  printf '  %sResources%s\n' "$C_BLD" "$C_RST"
  lib_print_kv "RAM"   "$(lib_human_mb "$ram_used") used of $(lib_human_mb "$SYS_RAM_MB")$( (( SYS_SWAP_MB > 0 )) && printf ', swap %s' "$(lib_human_mb "$SYS_SWAP_MB")")"
  lib_print_kv "Disk"  "${SYS_DISK_USED_PCT}% used (${SYS_DISK_FREE_GB} GB free of ${SYS_DISK_TOTAL_GB} GB)"
  lib_print_kv "Load / uptime" "${SYS_LOAD} / ${SYS_UPTIME}"
  lib_print_kv "Reboot required" "$reboot"
  printf '  %sConfiguration%s\n' "$C_BLD" "$C_RST"
  lib_print_kv "WebAdmin"      "$(lib_panel_status_line)"
  lib_print_kv "Cloudflare"    "$(lib_cf_status_line)"
  lib_print_kv "Notifications" "$(lib_notify_channels)"
  lib_print_kv "Backups"       "schedule: $(lib_manifest_get '.backup.schedule' || true), last run: ${last_backup:-never}"
  printf '  %sSites%s\n' "$C_BLD" "$C_RST"
  local n=0
  for d in $(lib_domains_list); do
    lib_domain_state_load "$d" || continue
    n=$((n + 1))
    printf '    %-28s %-10s php:%-5s ssl:%-24s backup:%s\n' "$d" "$D_MODE" "${D_PHP:--}" "$( (( D_SSL )) && lib_ssl_status_line "$d" || printf 'none')" "${D_BACKUP_LAST:-never}"
  done
  (( n == 0 )) && printf '    (none)\n'
  local napps=0
  for d in $(lib_domains_list); do
    if lib_app_state_load "$d"; then napps=$((napps + 1)); fi
  done
  if (( napps > 0 )); then
    printf '  %sNode.js applications%s\n' "$C_BLD" "$C_RST"
    lib_app_list 2>/dev/null | sed 's/^/    /' || true
  fi
  printf '  %sRecent problems in %s%s\n' "$C_BLD" "$LOG_FILE" "$C_RST"
  if [[ -f "$LOG_FILE" ]]; then
    grep -E '\[(ERROR|WARN|ROLLBACK)\]' "$LOG_FILE" 2>/dev/null | tail -n 5 | sed 's/^/    /' || true
  fi
  printf '\n'
}

# =============================================================================
#  doctor
# =============================================================================
_doc_add() {   # STATUS name detail
  DOC_RESULTS+=("$1|$2|$3")
  case "$1" in FAIL) DOC_FAIL=$((DOC_FAIL + 1)) ;; WARN) DOC_WARN=$((DOC_WARN + 1)) ;; *) DOC_OK=$((DOC_OK + 1)) ;; esac
}

_doc_check_services() {
  local svc=""
  if lib_ols_is_installed; then
    if lib_ols_running; then
      _doc_add OK "openlitespeed" "running $(lib_ols_version)"
    elif lib_port_listening 80; then
      _doc_add FAIL "openlitespeed" "serving, but systemd lost track of the unit; nothing supervises it (fix: lompstack optimize, or systemctl stop lsws && systemctl start lsws)"
    else
      _doc_add FAIL "openlitespeed" "service lsws is not active (systemctl status lsws)"
    fi
    if lib_ols_config_test; then _doc_add OK "ols config test" "openlitespeed -t passed"
    else _doc_add FAIL "ols config test" "${OLS_TEST_OUTPUT:0:160}"; fi
  else
    _doc_add FAIL "openlitespeed" "not installed"
  fi
  lib_port_listening 80 && _doc_add OK "port 80/tcp" "listening" || _doc_add FAIL "port 80/tcp" "nothing listens on port 80"
  lib_port_listening 443 && _doc_add OK "port 443/tcp" "listening" || _doc_add FAIL "port 443/tcp" "nothing listens on port 443"
  lib_port_listening 443 udp && _doc_add OK "port 443/udp (QUIC)" "listening" || _doc_add WARN "port 443/udp (QUIC)" "HTTP/3 not listening (quicEnable / ufw 443/udp)"
  if lib_db_installed; then
    if lib_service_active mariadb && lib_db_ping; then _doc_add OK "mariadb" "ping ok ($(lib_db_version))"; else _doc_add FAIL "mariadb" "not running or not answering on ${DB_SOCKET}"; fi
  else _doc_add WARN "mariadb" "not installed"; fi
  if lib_redis_installed; then
    if lib_service_active "$REDIS_SERVICE" && lib_redis_ping; then _doc_add OK "redis" "PONG ($(lib_redis_version))"; else _doc_add FAIL "redis" "not running or auth failure (check ${REDIS_INFO})"; fi
  else _doc_add WARN "redis" "not installed"; fi
  if lib_pkg_installed fail2ban; then
    if lib_service_active fail2ban; then
      if fail2ban-client status 2>/dev/null | grep -q 'sshd'; then _doc_add OK "fail2ban" "active, sshd jail loaded"; else _doc_add WARN "fail2ban" "active but sshd jail missing"; fi
    else _doc_add FAIL "fail2ban" "service inactive"; fi
  else _doc_add WARN "fail2ban" "not installed"; fi
  if lib_have ufw; then
    if ufw status 2>/dev/null | head -n1 | grep -q 'Status: active'; then
      local p="" missing=()
      for p in $SYS_SSH_PORTS; do ufw status 2>/dev/null | grep -qE "^${p}/tcp" || missing+=("$p"); done
      ((${#missing[@]} == 0)) && _doc_add OK "ufw" "active, SSH port(s) ${SYS_SSH_PORTS} allowed" || _doc_add WARN "ufw" "active but SSH port(s) ${missing[*]} not explicitly allowed"
    else _doc_add FAIL "ufw" "firewall inactive"; fi
  else _doc_add WARN "ufw" "not installed"; fi
  local admin_rules=""; admin_rules="$(lib_ufw_port_rule_numbers "$ADMIN_PORT" 2>/dev/null | wc -l | tr -d ' ')"
  if lib_ols_admin_tunnel_only && (( admin_rules == 0 )); then
    _doc_add OK "webadmin exposure" "closed to the internet (SSH tunnel only)"
  elif ufw status 2>/dev/null | grep -qE "^${ADMIN_PORT}/tcp[[:space:]]+ALLOW IN[[:space:]]+Anywhere"; then
    _doc_add WARN "webadmin exposure" "port ${ADMIN_PORT} accepts connections from any address (setup.sh panel close)"
  else
    _doc_add OK "webadmin exposure" "restricted (${admin_rules} firewall rule(s) for port ${ADMIN_PORT})"
  fi
  # Running now is not the same as coming back after a reboot. Every "systemctl enable" in
  # this tool is written "|| true", so a failure there is invisible - and on a real install
  # "systemctl enable lsws" did fail, which would have left the server with no web server
  # after the next boot and nothing anywhere saying so.
  for svc in "$OLS_SERVICE" mariadb "$REDIS_SERVICE" fail2ban ufw; do
    lib_service_exists "$svc" || continue
    if lib_service_enabled "$svc"; then
      _doc_add OK "${svc} at boot" "enabled"
    else
      _doc_add FAIL "${svc} at boot" "not enabled: it will NOT start after a reboot (systemctl enable ${svc})"
    fi
  done
  for svc in unattended-upgrades; do
    if [[ "$(apt-config dump 2>/dev/null | awk -F'"' '/^APT::Periodic::Unattended-Upgrade /{print $2}')" == "1" ]]; then _doc_add OK "$svc" "enabled (security updates)"; else _doc_add WARN "$svc" "not enabled"; fi
  done
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then _doc_add OK "time sync" "NTP synchronised ($(timedatectl show -p Timezone --value 2>/dev/null))"; else _doc_add WARN "time sync" "clock not NTP-synchronised"; fi
}

_doc_check_resources() {
  if (( SYS_DISK_USED_PCT >= 95 )); then _doc_add FAIL "disk" "${SYS_DISK_USED_PCT}% used (${SYS_DISK_FREE_GB} GB free)"
  elif (( SYS_DISK_USED_PCT >= 85 )); then _doc_add WARN "disk" "${SYS_DISK_USED_PCT}% used (${SYS_DISK_FREE_GB} GB free) - above 85% threshold"
  else _doc_add OK "disk" "${SYS_DISK_USED_PCT}% used (${SYS_DISK_FREE_GB} GB free)"; fi
  if (( SYS_RAM_MB > 0 && SYS_RAM_AVAIL_MB * 100 / SYS_RAM_MB < 5 )); then _doc_add WARN "memory" "only $(lib_human_mb "$SYS_RAM_AVAIL_MB") available"
  else _doc_add OK "memory" "$(lib_human_mb "$SYS_RAM_AVAIL_MB") available of $(lib_human_mb "$SYS_RAM_MB")"; fi
  if (( SYS_SWAP_MB == 0 && SYS_RAM_MB < 2048 )); then _doc_add WARN "swap" "no swap on a $(lib_human_mb "$SYS_RAM_MB") host"; else _doc_add OK "swap" "$( (( SYS_SWAP_MB > 0 )) && lib_human_mb "$SYS_SWAP_MB" || printf 'not needed')"; fi
  lib_system_reboot_required && _doc_add WARN "reboot" "reboot required ($(tr '\n' ' ' </var/run/reboot-required.pkgs 2>/dev/null | cut -c1-80))" || _doc_add OK "reboot" "not required"
  [[ -f "$SYSCTL_FILE" ]] && _doc_add OK "kernel tuning" "$SYSCTL_FILE present" || _doc_add WARN "kernel tuning" "${SYSCTL_FILE} missing (run install/optimize)"
  local perm=""; perm="$(stat -c %a "$STATE_DIR" 2>/dev/null || true)"
  [[ "$perm" == "700" ]] && _doc_add OK "state dir" "${STATE_DIR} is 0700" || _doc_add FAIL "state dir" "${STATE_DIR} permissions are ${perm:-missing} (expected 700)"
}

_doc_check_ssl_infra() {
  if lib_service_active certbot.timer || lib_cron_has certbot-renew; then _doc_add OK "certbot renewal" "timer/cron active"; else _doc_add WARN "certbot renewal" "certbot.timer inactive and no cron fallback"; fi
  [[ -x "$CERTBOT_DEPLOY_HOOK" ]] && _doc_add OK "certbot deploy hook" "installed" || _doc_add FAIL "certbot deploy hook" "${CERTBOT_DEPLOY_HOOK} missing"
  if lib_cf_enabled; then
    local age=""; age="$(lib_file_age_days "$CF_IPS_FILE")"
    if (( age > 14 )); then _doc_add WARN "cloudflare ips" "list is ${age} days old (update-cf-ips)"; else _doc_add OK "cloudflare ips" "list updated ${age} day(s) ago"; fi
    lib_cron_has cfips && _doc_add OK "cloudflare cron" "weekly update scheduled" || _doc_add WARN "cloudflare cron" "weekly update not scheduled"
    if [[ -s "$CF_INI" ]]; then
      [[ "$(stat -c %a "$CF_INI")" == "600" ]] && _doc_add OK "cloudflare token" "stored with 0600" || _doc_add FAIL "cloudflare token" "${CF_INI} is not 0600"
    fi
  fi
}

_doc_check_cron() {
  lib_cron_has healthcheck && _doc_add OK "healthcheck cron" "daily" || _doc_add WARN "healthcheck cron" "not scheduled (re-run install)"
  local pending=""
  if [[ -n "$(lib_ols_htaccess_docroots)" ]]; then
    if lib_cron_has htaccess; then _doc_add OK "htaccess cron" "a changed .htaccess takes effect within a minute"
    else _doc_add WARN "htaccess cron" "not scheduled: a changed .htaccess stays inactive until OpenLiteSpeed restarts (re-run install)"; fi
    pending="$(lib_ols_htaccess_pending)"
    if [[ -n "$pending" ]]; then
      _doc_add WARN "htaccess" "${pending} changed after OpenLiteSpeed started and is not in effect yet (setup.sh htaccess-check)"
    fi
  fi
  local sched=""; sched="$(lib_manifest_get '.backup.schedule')"
  if [[ -n "$sched" ]]; then
    lib_cron_has backup && _doc_add OK "backup cron" "$sched" || _doc_add WARN "backup cron" "schedule '${sched}' configured but no cron entry"
    local last=""; last="$(lib_manifest_get '.backup.last_run')"
    if [[ -n "$last" ]]; then
      local age=$(( ( $(date +%s) - $(date -d "$last" +%s 2>/dev/null || date +%s) ) / 86400 ))
      (( age > 2 )) && _doc_add WARN "last backup run" "${age} days ago" || _doc_add OK "last backup run" "${last:0:16}"
    else _doc_add WARN "last backup run" "never"; fi
  else _doc_add WARN "backup schedule" "not configured (install --backup-schedule \"daily 03:00\")"; fi
}

_doc_check_domains() {
  local d="" code="" days="" maps="" ver=""
  local -a cfg_vhosts=()
  while read -r d; do [[ -n "$d" && "$d" != "$OLS_DEFAULT_VHOST" ]] && cfg_vhosts+=("$d"); done < <(lib_ols_conf_vhosts)
  for d in $(lib_domains_list); do
    lib_domain_state_load "$d" || { _doc_add FAIL "site ${d}" "domain.json unreadable"; continue; }
    [[ -d "${D_HOME}/public_html" ]] || _doc_add FAIL "site ${d}: files" "${D_HOME}/public_html missing"
    id -u "$D_USER" >/dev/null 2>&1 || _doc_add FAIL "site ${d}: user" "system user ${D_USER} missing"
    [[ -f "${LSWS_VHOSTS_DIR}/${d}/vhconf.conf" ]] || _doc_add FAIL "site ${d}: vhconf" "${LSWS_VHOSTS_DIR}/${d}/vhconf.conf missing"
    if lib_ols_conf_block_exists virtualhost "$d"; then
      maps="$(lib_ols_conf_map_get "$OLS_LISTENER_HTTP" "$d")"
      [[ -n "$maps" ]] && _doc_add OK "site ${d}: vhost" "configured (${maps})" || _doc_add FAIL "site ${d}: vhost" "no listener map in ${OLS_LISTENER_HTTP}"
    else
      _doc_add FAIL "site ${d}: vhost" "virtualhost block missing in httpd_config.conf (state/config mismatch)"
    fi
    code="$(lib_http_code "http://127.0.0.1/" -H "Host: ${d}")"
    # a Node.js site answers 503 while its application is stopped on purpose or has no code
    local app_idle=0
    if lib_app_state_load "$d" && { (( ! APP_ENABLED )) || ! lib_app_runnable; }; then app_idle=1; fi
    case "$code" in
      200|301|302|303|307|308) _doc_add OK "site ${d}: http" "HTTP ${code}" ;;
      000|5*)
        if (( app_idle )); then _doc_add WARN "site ${d}: http" "HTTP ${code}: its application is stopped or has no code yet (setup.sh app status ${d})"
        else _doc_add FAIL "site ${d}: http" "HTTP ${code}"; fi ;;
      *)      _doc_add WARN "site ${d}: http" "HTTP ${code}" ;;
    esac
    if (( D_SSL )); then
      if lib_ssl_deployed "$d"; then
        days="$(lib_ssl_days_left "$d")"
        if [[ -z "$days" ]]; then _doc_add WARN "site ${d}: ssl" "cannot read certificate"
        elif (( days < 7 )); then _doc_add FAIL "site ${d}: ssl" "expires in ${days} days"
        elif (( days < 30 )); then _doc_add WARN "site ${d}: ssl" "expires in ${days} days"
        else _doc_add OK "site ${d}: ssl" "expires in ${days} days"; fi
        code="$(lib_http_code "https://${d}/" -k --resolve "${d}:443:127.0.0.1")"
        [[ "$code" =~ ^(200|301|302|303|307|308)$ ]] || _doc_add WARN "site ${d}: https" "HTTP ${code}"
      else _doc_add FAIL "site ${d}: ssl" "enabled in state but no deployed certificate"; fi
    elif (( D_SSL_WANTED )); then
      _doc_add WARN "site ${d}: ssl" "wanted but not active (setup.sh renew-ssl ${d})"
    fi
    if [[ -n "$D_DB_NAME" ]] && lib_db_installed; then
      lib_db_exists "$D_DB_NAME" && _doc_add OK "site ${d}: db" "${D_DB_NAME} present" || _doc_add FAIL "site ${d}: db" "database ${D_DB_NAME} missing"
    fi
    if [[ -n "$D_PHP" ]] && ! lib_php_installed "$D_PHP"; then _doc_add FAIL "site ${d}: php" "LSPHP ${D_PHP} not installed"; fi
    local pp="" pt=""
    while read -r pp pt; do
      [[ -n "$pp" ]] || continue
      if lib_tcp_open "${pt%:*}" "${pt##*:}"; then _doc_add OK "site ${d}: proxy ${pp}" "${pt} answers"
      else _doc_add WARN "site ${d}: proxy ${pp}" "nothing listens on ${pt}, so requests to ${pp} get 503"; fi
    done <<<"$D_PATH_PROXIES"
  done
  for d in "${cfg_vhosts[@]}"; do
    lib_domain_registered "$d" || _doc_add WARN "unmanaged vhost ${d}" "present in httpd_config.conf but not in state"
  done
  for ver in $(lib_php_installed_versions); do
    lib_ols_conf_block_exists extprocessor "lsphp${ver//./}" || _doc_add WARN "php ${ver}" "no server-level extprocessor (run optimize)"
  done
}

_doc_check_log_leaks() {
  [[ -f "$LOG_FILE" ]] || { _doc_add OK "log secrets" "no log yet"; return 0; }
  local hits=""
  hits="$(grep -Eic "$(lib_secret_leak_pattern)" "$LOG_FILE" 2>/dev/null || true)"
  hits="${hits:-0}"
  if (( hits > 0 )); then _doc_add FAIL "log secrets" "${hits} line(s) in ${LOG_FILE} look like unmasked credentials"; else _doc_add OK "log secrets" "no credential patterns in ${LOG_FILE}"; fi
  [[ "$(stat -c %a "$LOG_FILE" 2>/dev/null)" == "600" ]] || _doc_add WARN "log permissions" "${LOG_FILE} is not 0600"
}

# Node.js applications: the service starts at boot and runs, every wanted process is online
# and not crash-looping, the web port is bound to loopback, and every scheduled job has its
# cron entry. pm2 is only asked while the service runs: any pm2 command starts a daemon, and
# one outside systemd would break the unit.
_doc_check_apps() {
  local d="" unit="" info="" st="" cpu="" mem="" up="" rs="" addr="" n="" jl="" workers="" web=0 wanted=0
  local name="" kind="" status="" restarts="" sched=""
  if [[ -f "${APP_UNIT_DIR}/pm2-root.service" ]]; then
    n="$(jq 'length' /root/.pm2/dump.pm2 2>/dev/null || printf '0')"
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
      _doc_add WARN "pm2 as root" "${n} process(es) from an older install run as root; move each into a site: setup.sh add <domain> --node"
    fi
  fi
  for d in $(lib_domains_list); do
    lib_app_state_load "$d" || continue
    lib_domain_state_load "$d" || continue
    unit="$(lib_app_unit_name "$D_IDENT")"
    workers="$(lib_app_workers_json "$d")"
    web=0; wanted=0; jl=""
    if (( ! APP_ENABLED )); then _doc_add OK "app ${d}" "stopped on purpose"
    elif ! lib_app_runnable; then _doc_add WARN "app ${d}" "no code yet: ${APP_RESULT_MSG}"
    else web=1; wanted=1; fi
    if jq -e 'any(.[]; (.cron // "") == "" and .enabled != false)' <<<"$workers" >/dev/null 2>&1; then wanted=1; fi
    if (( wanted )); then
      if lib_service_enabled "$unit"; then _doc_add OK "app ${d}: boot" "${unit} enabled"
      else _doc_add FAIL "app ${d}: boot" "${unit} is not enabled, the app will not start after a reboot (setup.sh app start ${d})"; fi
      if lib_service_active "$unit"; then jl="$(_app_jlist)"
      else _doc_add FAIL "app ${d}: service" "${unit} is not running (setup.sh app start ${d})"; fi
    fi
    if (( web )) && [[ -n "$jl" ]]; then
      info="$(_app_info_from "$jl" web)"
      st="" cpu="" mem="" up="" rs=""
      read -r st cpu mem up rs <<<"$info"
      case "${st:-missing}" in
        online)  _doc_add OK "app ${d}: process" "online, ${rs:-0} restart(s)" ;;
        missing) _doc_add FAIL "app ${d}: process" "not in PM2 (setup.sh app restart ${d})" ;;
        *)       _doc_add FAIL "app ${d}: process" "${st} (setup.sh app logs ${d})" ;;
      esac
      if [[ "${rs:-0}" =~ ^[0-9]+$ ]] && (( rs >= 10 )); then
        _doc_add WARN "app ${d}: restarts" "${rs} restarts, it keeps crashing (setup.sh app logs ${d})"
      fi
      addr="$(ss -tlnH "sport = :${APP_PORT}" 2>/dev/null | awk 'NR == 1 {print $4}' || true)"
      case "$addr" in
        "")                    _doc_add FAIL "app ${d}: port" "nothing listens on ${APP_PORT}; the app must listen on process.env.PORT" ;;
        127.0.0.1:*|\[::1\]:*) _doc_add OK "app ${d}: port" "listens on ${addr}" ;;
        *)                     _doc_add WARN "app ${d}: port" "listens on ${addr} (every interface): the firewall keeps it private, but bind it to 127.0.0.1" ;;
      esac
    fi
    while IFS=$'\t' read -r name kind status restarts sched <&3; do
      [[ -n "$name" ]] || continue
      if [[ "$kind" == job ]]; then
        if [[ "$status" == stopped ]]; then _doc_add OK "app ${d}: job ${name}" "paused on purpose"
        elif lib_cron_has "job:${d}:${name}"; then _doc_add OK "app ${d}: job ${name}" "scheduled ${sched}"
        else _doc_add FAIL "app ${d}: job ${name}" "no cron entry, it never runs (setup.sh app start ${d} --process ${name})"; fi
        continue
      fi
      case "$status" in
        stopped) _doc_add OK "app ${d}: worker ${name}" "stopped on purpose" ;;
        online)  _doc_add OK "app ${d}: worker ${name}" "online, ${restarts} restart(s)" ;;
        *)       if [[ -n "$jl" ]]; then _doc_add FAIL "app ${d}: worker ${name}" "${status} (setup.sh app logs ${d} --process ${name})"; fi ;;
      esac
      if [[ "$status" != stopped && "$restarts" =~ ^[0-9]+$ ]] && (( restarts >= 10 )); then
        _doc_add WARN "app ${d}: worker ${name} restarts" "${restarts} restarts, it keeps crashing (setup.sh app logs ${d} --process ${name})"
      fi
    done 3< <(jq -r '.[] | [.name, .kind, .status, (.restarts | tostring), (.schedule // "")] | @tsv' <<<"$(_app_workers_status "$workers" "$jl")" || true)
  done
}

lib_doctor_run() {
  DOC_RESULTS=(); DOC_FAIL=0; DOC_WARN=0; DOC_OK=0
  lib_system_analyze --no-net
  _doc_check_services
  _doc_check_resources
  _doc_check_ssl_infra
  _doc_check_cron
  _doc_check_domains
  _doc_check_apps
  _doc_check_log_leaks
}

lib_doctor_main() {
  local json=0 quiet="$OPT_QUIET" r="" st="" name="" detail=""
  [[ "${1:-}" == "--json" ]] && json=1
  (( OPT_JSON )) && json=1
  lib_require_tools
  lib_doctor_run
  if (( json )); then
    printf '%s\n' "${DOC_RESULTS[@]}" | jq -R 'split("|") | {status:.[0], check:.[1], detail:.[2]}' | jq -s --argjson f "$DOC_FAIL" --argjson w "$DOC_WARN" --argjson o "$DOC_OK" \
      '{summary:{ok:$o, warn:$w, fail:$f, healthy:($f==0)}, checks:.}'
  else
    (( quiet )) || printf '\n%s%-6s %-34s %s%s\n' "$C_BLD" "STATUS" "CHECK" "DETAIL" "$C_RST"
    for r in "${DOC_RESULTS[@]}"; do
      st="${r%%|*}"; name="${r#*|}"; detail="${name#*|}"; name="${name%%|*}"
      case "$st" in
        OK)   (( quiet )) || printf '%s%-6s%s %-34s %s\n' "$C_GRN" "OK" "$C_RST" "$name" "$detail" ;;
        WARN) printf '%s%-6s%s %-34s %s\n' "$C_YEL" "WARN" "$C_RST" "$name" "$detail" ;;
        FAIL) printf '%s%-6s%s %-34s %s\n' "$C_RED" "FAIL" "$C_RST" "$name" "$detail" ;;
      esac
    done
    printf '\n%sSummary:%s %d ok, %d warning(s), %d failure(s)\n' "$C_BLD" "$C_RST" "$DOC_OK" "$DOC_WARN" "$DOC_FAIL"
  fi
  lib_log_write INFO "doctor: ${DOC_OK} ok, ${DOC_WARN} warn, ${DOC_FAIL} fail"
  (( DOC_FAIL == 0 ))
}

# Daily healthcheck (cron): run doctor silently, notify when something is wrong.
lib_healthcheck_main() {
  lib_require_tools
  OPT_QUIET=1
  lib_doctor_run
  local r="" st="" name="" detail="" body=""
  for r in "${DOC_RESULTS[@]}"; do
    st="${r%%|*}"; name="${r#*|}"; detail="${name#*|}"; name="${name%%|*}"
    [[ "$st" == "OK" ]] && continue
    body+="${st}: ${name} - ${detail}"$'\n'
  done
  lib_log_write INFO "healthcheck: ${DOC_OK} ok, ${DOC_WARN} warn, ${DOC_FAIL} fail"
  if (( DOC_FAIL > 0 || DOC_WARN > 0 )); then
    lib_notify_send "Healthcheck: ${DOC_FAIL} failure(s), ${DOC_WARN} warning(s)" "$body"
  fi
  return 0
}
