#!/usr/bin/env bash
# lib/install.sh - "install" orchestration (base packages, security, OLS, PHP,
#                  MariaDB, Redis, SSL infra, optional runtimes, cron, self-install),
#                  plus "update" and "optimize".

INS_WITH_NODE=0 INS_NODE_MAJOR=20 INS_WITH_PYTHON=0 INS_WITH_NETDATA=0 INS_CLOUDFLARE=0 INS_CF_TOKEN=""
INS_MARIADB="" INS_REDIS_PERSIST=0 INS_AUTO_REBOOT=0 INS_SKIP_UPGRADE=0 INS_BACKUP_SCHEDULE=""
INS_ADMIN_ACCESS_SET=0   # was --admin-access / --admin-ip given on THIS run?

# =============================================================================
#  Arguments
# =============================================================================
lib_install_parse_args() {
  local a="" _p=""
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --php)             PHP_VERSION="${1:-}"; shift ;;
      --timezone)        TIMEZONE="${1:-}"; shift ;;
      --admin-ip)        ADMIN_ALLOWED_IP="${1:-}"; ADMIN_ACCESS="ip"; INS_ADMIN_ACCESS_SET=1; shift ;;
      --admin-access)    ADMIN_ACCESS="${1:-}"; INS_ADMIN_ACCESS_SET=1; shift ;;
      --admin-port)      ADMIN_PORT="${1:-}"; shift ;;
      --email)           DEFAULT_EMAIL="${1:-}"; shift ;;
      --ssh-port)        SSH_PORT="${1:-}"; shift ;;
      --with-node)       INS_WITH_NODE=1 ;;
      --node)            INS_NODE_MAJOR="${1:-20}"; INS_WITH_NODE=1; shift ;;
      --with-python)     INS_WITH_PYTHON=1 ;;
      --with-netdata)    INS_WITH_NETDATA=1 ;;
      --cloudflare)      INS_CLOUDFLARE=1 ;;
      --cf-api-token)    INS_CF_TOKEN="${1:-}"; shift ;;
      --mariadb)         INS_MARIADB="${1:-}"; shift ;;
      --redis-persist)   INS_REDIS_PERSIST=1 ;;
      --backup-schedule) INS_BACKUP_SCHEDULE="${1:-}"; shift ;;
      --backup-keep)     BACKUP_KEEP="${1:-7}"; shift ;;
      --db-buffer-percent)  DB_BUFFER_PERCENT="${1:-}"; shift ;;
      --redis-max-percent)  REDIS_MAX_PERCENT="${1:-}"; shift ;;
      --fail2ban-ignore-ip) FAIL2BAN_IGNORE_IP="${1:-}"; shift ;;
      --auto-reboot)     INS_AUTO_REBOOT=1 ;;
      --skip-upgrade)    INS_SKIP_UPGRADE=1 ;;
      --non-interactive) OPT_NON_INTERACTIVE=1 ;;
      -h|--help)         lib_usage; exit 0 ;;
      *) lib_die "Unknown option for install: ${a}" "" "see: setup.sh help" ;;
    esac
  done
  lib_php_valid_version "$PHP_VERSION" || lib_die "Invalid --php '${PHP_VERSION}'" "expected e.g. 8.3" "--php 8.3"
  if [[ -n "$DEFAULT_EMAIL" ]]; then
    lib_email_valid "$DEFAULT_EMAIL" || lib_die "Invalid --email '${DEFAULT_EMAIL}'" \
      "the address goes into httpd_config.conf and into mail headers, so it may not contain spaces, quotes, backslashes or line breaks" \
      "--email you@example.com"
  fi
  [[ "$ADMIN_PORT" =~ ^[0-9]{2,5}$ ]] && (( ADMIN_PORT >= 1024 && ADMIN_PORT <= 65535 )) \
    || lib_die "Invalid --admin-port '${ADMIN_PORT}'" "expected a port between 1024 and 65535" "--admin-port 7574"
  # lib_ssh_ports is called directly: SYS_SSH_PORTS is still the module default "22" here,
  # because lib_system_analyze only runs after the arguments are parsed. Unquoted on
  # purpose (several ports possible); an "if" body, not a trailing "&&", so the loop
  # cannot end on a false test and return 1 under errexit.
  for _p in 80 443 3306 6379 $(lib_ssh_ports); do
    if [[ "$ADMIN_PORT" == "$_p" ]]; then
      lib_die "--admin-port ${ADMIN_PORT} is already used by another service" \
        "the WebAdmin panel cannot share a port with the web server, database, cache or SSH" \
        "pick a free port, e.g. --admin-port 7574"
    fi
  done
  [[ -z "$SSH_PORT" || ( "$SSH_PORT" =~ ^[0-9]{1,5}$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ) ]] || lib_die "Invalid --ssh-port '${SSH_PORT}'" "" "--ssh-port 2222"
  case "$ADMIN_ACCESS" in
    tunnel|ip|open) ;;
    *) lib_die "Invalid --admin-access '${ADMIN_ACCESS}'" "expected tunnel, ip or open" \
         "--admin-access tunnel (default, SSH tunnel) | --admin-ip <your IP> | --admin-access open" ;;
  esac
  if [[ "$ADMIN_ALLOWED_IP" == "auto" ]]; then
    ADMIN_ALLOWED_IP="$(lib_admin_client_ip)"
    if [[ -n "$ADMIN_ALLOWED_IP" ]]; then
      lib_info "--admin-ip auto: using ${ADMIN_ALLOWED_IP} (the address this SSH session comes from)"
      lib_warn "If that address is dynamic you will lose the panel when it changes. 'setup.sh panel open' reopens it at any time."
    else
      lib_warn "--admin-ip auto: no SSH session detected, falling back to tunnel mode"
      ADMIN_ACCESS="tunnel"
    fi
  fi
  [[ -z "$ADMIN_ALLOWED_IP" || "$ADMIN_ALLOWED_IP" =~ ^[0-9a-fA-F.:/]+$ ]] || lib_die "Invalid --admin-ip '${ADMIN_ALLOWED_IP}'" "" "--admin-ip 1.2.3.4, 1.2.3.0/24 or auto"
  if [[ "$ADMIN_ACCESS" == "ip" && -z "$ADMIN_ALLOWED_IP" ]]; then
    lib_warn "--admin-access ip needs --admin-ip <address>; falling back to tunnel mode"
    ADMIN_ACCESS="tunnel"
  fi
  [[ "$ADMIN_ACCESS" == "ip" ]] || ADMIN_ALLOWED_IP=""
  [[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] || lib_die "Invalid backup keep count '${BACKUP_KEEP}'" "" "--backup-keep 7"
  [[ "$INS_NODE_MAJOR" =~ ^[0-9]{2}$ ]] || lib_die "Invalid --node '${INS_NODE_MAJOR}'" "" "--node 20"
  [[ -n "$INS_BACKUP_SCHEDULE" ]] || INS_BACKUP_SCHEDULE="$BACKUP_SCHEDULE"
  # Re-runs: keep previously chosen values when the flag is not repeated (idempotent re-run)
  if [[ -s "$STATE_DIR/manifest.json" ]] && lib_have jq; then
    # Only inherit the stored mode when the operator did NOT ask for one. Testing
    # ADMIN_ACCESS == tunnel cannot tell "not given" from "explicitly tunnel", which made
    # it impossible to close a panel that had once been opened.
    if (( ! INS_ADMIN_ACCESS_SET )); then
      local prev_access=""; prev_access="$(lib_manifest_get '.params.admin_access')"
      if [[ -n "$prev_access" ]]; then
        ADMIN_ACCESS="$prev_access"
        [[ "$ADMIN_ACCESS" == "ip" ]] && ADMIN_ALLOWED_IP="$(lib_manifest_get '.params.admin_ip')"
      fi
    fi
    [[ -n "$DEFAULT_EMAIL" ]]      || DEFAULT_EMAIL="$(lib_manifest_get '.params.email')"
    [[ -n "$INS_BACKUP_SCHEDULE" ]] || INS_BACKUP_SCHEDULE="$(lib_manifest_get '.params.backup_schedule')"
    [[ -n "$FAIL2BAN_IGNORE_IP" ]] || FAIL2BAN_IGNORE_IP="$(lib_manifest_get '.params.fail2ban_ignore_ip')"
    [[ -n "$DB_BUFFER_PERCENT" ]]  || DB_BUFFER_PERCENT="$(lib_manifest_get '.params.db_buffer_percent')"
    [[ -n "$REDIS_MAX_PERCENT" ]]  || REDIS_MAX_PERCENT="$(lib_manifest_get '.params.redis_max_percent')"
    [[ "$(lib_manifest_get '.params.redis_persist')" == "true" ]] && INS_REDIS_PERSIST=1
    [[ "$(lib_manifest_get '.params.auto_reboot')" == "true" ]] && INS_AUTO_REBOOT=1
    [[ "$(lib_manifest_get '.components.netdata')" == "true" ]] && INS_WITH_NETDATA=1
    [[ -n "$(lib_manifest_get '.components.node')" ]] && INS_WITH_NODE=1
    [[ -n "$(lib_manifest_get '.components.python')" ]] && INS_WITH_PYTHON=1
  fi
  return 0
}

# =============================================================================
#  install
# =============================================================================
lib_install_main() {
  lib_install_parse_args "$@"
  lib_require_tools
  lib_state_init
  local rerun=0
  lib_installed && rerun=1
  (( rerun )) && lib_info "Server was provisioned on $(lib_manifest_get '.installed_at') - verifying and repairing the configuration (idempotent re-run)"
  local total=21
  lib_steps_begin "$total"

  # First, deliberately: every later step can fail, and when one does the operator needs a
  # working "lomp doctor" to find out why. This used to be step 18, so a run that died at
  # step 11 left no command installed at all - "lomp" was simply not found.
  lib_step "Command installation (lomp)"
  lib_install_self

  lib_step "System analysis"
  lib_system_analyze
  lib_system_report
  lib_system_profile
  lib_system_profile_report
  (( SYS_RAM_MB < 900 )) && lib_warn "Less than 1 GB RAM: expect tight limits (MariaDB buffer pool ${CALC_DB_BUFFER_MB} MB)"
  case "$SYS_ARCH" in amd64|arm64) ;; *) lib_warn "Architecture ${SYS_ARCH} is not covered by the LiteSpeed repository; installation may fail" ;; esac
  (( OPT_DRY_RUN )) && lib_warn "DRY RUN: nothing will be changed; the plan below shows what a real run would do"

  lib_step "Base packages and system upgrade"
  lib_install_base_packages

  lib_step "Timezone and NTP"
  lib_system_timezone_apply
  lib_system_ntp_apply

  lib_step "Kernel parameters, limits and swap"
  lib_system_sysctl_apply
  lib_system_limits_apply
  lib_system_swap_ensure

  lib_step "Unattended security updates"
  lib_install_unattended

  lib_step "Firewall (UFW)"
  lib_install_ufw

  lib_step "SSH hardening"
  lib_install_ssh_harden

  lib_step "Fail2ban"
  lib_install_fail2ban

  lib_step "OpenLiteSpeed repository and package"
  lib_ols_repo_setup
  lib_ols_install

  lib_step "PHP (LSPHP ${PHP_VERSION})"
  lib_php_install "$PHP_VERSION"
  lib_php_cli_links "$PHP_VERSION"
  lib_manifest_set '.components.php.default' "$PHP_VERSION"

  lib_step "OpenLiteSpeed configuration and WebAdmin"
  lib_ols_admin_setup
  lib_ols_configure_server
  (( OPT_DRY_RUN )) || lib_ols_running || lib_ols_restart
  [[ "$ADMIN_ACCESS" == "open" ]] && lib_warn "WebAdmin port ${ADMIN_PORT} is reachable from ANY IP (--admin-access open). Prefer 'tunnel' unless you really need this."

  lib_step "MariaDB"
  lib_db_install "$INS_MARIADB"
  lib_db_secure
  lib_db_apply_tuning

  lib_step "Redis"
  lib_redis_install "$INS_REDIS_PERSIST"

  lib_step "SSL infrastructure (certbot)"
  [[ -n "$INS_CF_TOKEN" ]] && lib_cf_store_token "$INS_CF_TOKEN"
  lib_ssl_install

  lib_step "Cloudflare real-IP mode"
  if (( INS_CLOUDFLARE )) || lib_cf_enabled; then lib_cf_enable; else lib_info "Cloudflare mode disabled (enable with --cloudflare)"; fi

  lib_step "Optional runtimes (Node.js / Python / Netdata)"
  (( INS_WITH_NODE ))    && lib_install_node
  (( INS_WITH_PYTHON ))  && lib_install_python
  (( INS_WITH_NETDATA )) && lib_install_netdata
  (( INS_WITH_NODE || INS_WITH_PYTHON || INS_WITH_NETDATA )) || lib_info "none requested (--with-node / --with-python / --with-netdata)"

  lib_step "Log rotation"
  lib_install_logrotate
  lib_domain_logrotate_regen
  lib_domain_fail2ban_regen

  lib_step "Scheduled tasks"
  lib_install_cron

  lib_step "Manifest"
  lib_install_manifest "$rerun"

  lib_step "Summary"
  lib_install_summary "$rerun"
}

# -----------------------------------------------------------------------------
lib_install_base_packages() {
  lib_apt_update
  if (( INS_SKIP_UPGRADE )); then
    lib_info "apt upgrade skipped (--skip-upgrade)"
  elif (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would run apt-get upgrade"
  else
    lib_info "Upgrading installed packages (this can take a while)..."
    lib_run apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade \
      || lib_warn "apt-get upgrade reported errors (see log); continuing"
  fi
  lib_apt_install curl wget git ca-certificates gnupg lsb-release jq unzip tar gzip rsync openssl python3 cron logrotate \
    dnsutils acl htop ufw fail2ban unattended-upgrades \
    || lib_die "Base package installation failed" "apt error" "check network / apt sources and re-run"
  lib_ok "Base packages present"
}

lib_install_unattended() {
  local reboot="false"; (( INS_AUTO_REBOOT )) && reboot="true"
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::Download-Upgradeable-Packages "1";\nAPT::Periodic::AutocleanInterval "7";\n' \
    | lib_write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 root:root
  cat <<EOF | lib_write_file /etc/apt/apt.conf.d/52server-setup-unattended 0644 root:root
// Managed by lompstack - security updates only, no automatic reboot unless --auto-reboot
#clear Unattended-Upgrade::Allowed-Origins;
Unattended-Upgrade::Allowed-Origins {
  "\${distro_id}:\${distro_codename}-security";
  "\${distro_id}ESMApps:\${distro_codename}-apps-security";
  "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "${reboot}";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::SyslogEnable "true";
EOF
  lib_systemctl enable unattended-upgrades >/dev/null 2>&1 || true
  lib_ok "unattended-upgrades: security updates only, automatic reboot ${reboot} (reboot-required is reported by the daily healthcheck)"
}

lib_install_ufw() {
  local p=""
  lib_apt_install ufw
  # a previous run may have opened a different WebAdmin port; that rule has to go
  local old_port=""; old_port="$(lib_manifest_get '.params.admin_port')"
  if [[ -n "$old_port" && "$old_port" != "$ADMIN_PORT" ]]; then
    lib_info "WebAdmin port changed ${old_port} -> ${ADMIN_PORT}; removing the old firewall rule"
    lib_ufw_delete_port_rules "$old_port"
  fi
  # never "ufw reset": existing rules are kept, ours are added idempotently
  lib_ufw_rule default deny incoming
  lib_ufw_rule default allow outgoing
  for p in $SYS_SSH_PORTS $SSH_PORT; do lib_ufw_rule allow "${p}/tcp"; done
  lib_ufw_rule allow 80/tcp
  lib_ufw_rule allow 443/tcp
  lib_ufw_rule allow 443/udp
  case "$ADMIN_ACCESS" in
    ip)
      lib_ufw_delete_port_rules "$ADMIN_PORT"
      lib_ufw_rule allow from "$ADMIN_ALLOWED_IP" to any port "$ADMIN_PORT" proto tcp
      (( INS_WITH_NETDATA )) && lib_ufw_rule allow from "$ADMIN_ALLOWED_IP" to any port 19999 proto tcp
      ;;
    open)
      lib_ufw_rule allow "${ADMIN_PORT}/tcp"
      ;;
    tunnel)
      # the panel is not exposed at all: no firewall rule and the listener binds to 127.0.0.1
      lib_ufw_delete_port_rules "$ADMIN_PORT"
      ;;
  esac
  if (( ! OPT_DRY_RUN )); then
    if ! ufw status 2>/dev/null | head -n1 | grep -q 'Status: active'; then
      ufw show added 2>/dev/null | grep -qE "allow ${SYS_SSH_PORTS%% *}/tcp" || lib_die "Refusing to enable UFW without an SSH allow rule" "SSH port ${SYS_SSH_PORTS} rule missing" "add it manually: ufw allow ${SYS_SSH_PORTS%% *}/tcp"
      lib_run ufw --force enable || lib_die "ufw enable failed" "" "check 'ufw status' and the log"
    fi
    lib_systemctl enable ufw >/dev/null 2>&1 || true
  fi
  lib_manifest_set_json '.components.ufw' true
  local admin_desc=""
  case "$ADMIN_ACCESS" in
    ip)     admin_desc="WebAdmin ${ADMIN_PORT} only from ${ADMIN_ALLOWED_IP}" ;;
    open)   admin_desc="WebAdmin ${ADMIN_PORT} open to everyone" ;;
    *)      admin_desc="WebAdmin ${ADMIN_PORT} closed (SSH tunnel only)" ;;
  esac
  lib_ok "UFW active: SSH ${SYS_SSH_PORTS}${SSH_PORT:+ + $SSH_PORT}, 80/tcp, 443/tcp+udp, ${admin_desc}"
}

# "sshd -t" refuses to run without its privilege separation directory, and /run is a tmpfs
# that is empty after every boot. On a socket-activated host - the default on Ubuntu 24.04 -
# connections are served by ssh@.service instances while ssh.service, the unit that declares
# RuntimeDirectory=sshd, may never start at all. /run/sshd is then simply absent and EVERY
# sshd -t fails with "Missing privilege separation directory: /run/sshd", which is a runtime
# gap rather than anything wrong with the configuration. Create it as systemd would.
lib_ssh_privsep_dir_ensure() {   # [dir]
  local d="${1:-/run/sshd}"
  [[ -d "$d" ]] && return 0
  mkdir -p "$d" || return 1
  chmod 0755 "$d" || true
  chown root:root "$d" 2>/dev/null || true
  return 0
}

lib_install_ssh_harden() {
  local dropin="/etc/ssh/sshd_config.d/99-server-setup.conf" login_user="" h="" keys_ok=0 content="" prev="" had_prev=0
  local ports_before="$SYS_SSH_PORTS" port_changed=0
  if [[ ! -f /etc/ssh/sshd_config ]] || ! lib_have sshd; then
    lib_warn "openssh-server is not installed (/etc/ssh/sshd_config missing); SSH hardening skipped"
    return 0
  fi
  login_user="${SUDO_USER:-root}"
  for h in "$(getent passwd "$login_user" 2>/dev/null | cut -d: -f6)" /root; do
    [[ -n "$h" && -s "${h}/.ssh/authorized_keys" ]] && keys_ok=1
  done
  content="# Managed by lompstack (sshd drop-in; sshd -t verified before activation)"$'\n'
  content+="PubkeyAuthentication yes"$'\n'"PermitEmptyPasswords no"$'\n'"X11Forwarding no"$'\n'"MaxAuthTries 4"$'\n'
  content+="LoginGraceTime 30"$'\n'"ClientAliveInterval 300"$'\n'"ClientAliveCountMax 2"$'\n'
  if (( keys_ok )); then
    content+="PasswordAuthentication no"$'\n'"PermitRootLogin prohibit-password"$'\n'
  else
    lib_warn "No authorized_keys found for $( [[ "$login_user" == "root" ]] && printf 'root' || printf '%s or root' "$login_user"): password authentication stays ENABLED."
    lib_note "Add your public key (ssh-copy-id), then re-run install to disable password logins."
  fi
  if [[ -n "$SSH_PORT" ]] && [[ " ${SYS_SSH_PORTS} " != *" ${SSH_PORT} "* ]]; then
    content+="Port ${SSH_PORT}"$'\n'
    port_changed=1
  fi
  if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
    lib_warn "sshd_config has no Include for sshd_config.d; adding it"
    { printf 'Include /etc/ssh/sshd_config.d/*.conf\n'; cat /etc/ssh/sshd_config; } | lib_write_file /etc/ssh/sshd_config 0644 root:root
  fi
  [[ -f "$dropin" ]] && { prev="$(lib_mktemp)"; cp "$dropin" "$prev"; had_prev=1; }
  lib_mkdir /etc/ssh/sshd_config.d 0755 root:root
  printf '%s' "$content" | lib_write_file "$dropin" 0644 root:root
  if (( ! LIB_FILE_CHANGED )); then lib_ok "SSH hardening already in place"; return 0; fi
  (( OPT_DRY_RUN )) && return 0
  local ssh_rc=0 ssh_test="" base_rc=0 base_test=""
  lib_ssh_privsep_dir_ensure
  ssh_test="$(sshd -t 2>&1)" || ssh_rc=$?
  if (( ssh_rc != 0 )); then
    printf '%s\n' "$ssh_test" >>"$LOG_FILE" 2>/dev/null || true
    lib_error "sshd -t rejected the configuration; restoring the previous one"
    if (( had_prev )); then cp "$prev" "$dropin"; else rm -f "$dropin"; fi
    ssh_test="$(tr '\n' '\t' <<<"$ssh_test" | sed 's/\t$//; s/\t/ | /g')"
    # Re-test WITHOUT our drop-in. "sshd rejected the file we just wrote" and "this host's
    # sshd_config was already broken" need different answers, and blaming our own change
    # for someone else's syntax error sends the operator looking in the wrong file.
    base_test="$(sshd -t 2>&1)" || base_rc=$?
    if (( base_rc == 0 )); then
      lib_die "SSH configuration test failed (previous configuration restored, SSH untouched)" \
        "sshd rejected the drop-in this tool writes: ${ssh_test:-no output from sshd -t}" \
        "report the line above; SSH itself is unchanged and still working"
    fi
    base_test="$(tr '\n' '\t' <<<"$base_test" | sed 's/\t$//; s/\t/ | /g')"
    lib_die "This server's SSH configuration was already invalid before this run" \
      "sshd -t fails with our drop-in removed as well: ${base_test:-no output from sshd -t}" \
      "fix the file and line sshd names above (check /etc/ssh/sshd_config and /etc/ssh/sshd_config.d/*.conf), then re-run"
  fi
  if (( port_changed )); then
    lib_info "Switching SSH to port ${SSH_PORT} (old port(s) ${ports_before} stay allowed in UFW until you remove them)"
    lib_systemctl daemon-reload
    if lib_service_active ssh.socket; then lib_systemctl restart ssh.socket || true; fi
    lib_systemctl restart ssh || lib_systemctl restart sshd || true
    sleep 2
    if ! lib_port_listening "$SSH_PORT"; then
      lib_error "sshd is not listening on ${SSH_PORT}; reverting"
      if (( had_prev )); then cp "$prev" "$dropin"; else rm -f "$dropin"; fi
      lib_systemctl daemon-reload; lib_service_active ssh.socket && lib_systemctl restart ssh.socket; lib_systemctl restart ssh || true
      lib_die "SSH port change failed and was reverted" "sshd did not bind port ${SSH_PORT}" "check 'journalctl -u ssh' and 'ss -tlnp'"
    fi
    lib_ok "SSH listening on port ${SSH_PORT} - test a NEW connection before closing this one: ssh -p ${SSH_PORT} ${login_user}@${SYS_PUBLIC_IPV4:-<ip>}"
    lib_note "afterwards remove the old rule: ufw delete allow ${ports_before%% *}/tcp"
  else
    lib_systemctl reload ssh || lib_systemctl reload sshd || true
    lib_ok "SSH hardened (keys: $( (( keys_ok )) && printf 'password auth disabled, root prohibit-password' || printf 'password auth kept'))"
  fi
}

lib_install_fail2ban() {
  local ignore="127.0.0.1/8 ::1" ports=""
  [[ -n "$ADMIN_ALLOWED_IP" ]] && ignore+=" ${ADMIN_ALLOWED_IP}"
  [[ -n "$FAIL2BAN_IGNORE_IP" ]] && ignore+=" ${FAIL2BAN_IGNORE_IP}"
  ports="$(printf '%s' "${SYS_SSH_PORTS} ${SSH_PORT}" | tr -s ' ' '\n' | sed '/^$/d' | sort -un | paste -sd, -)"
  lib_apt_install fail2ban
  cat <<EOF | lib_write_file "$FAIL2BAN_JAIL_FILE" 0644 root:root
# Managed by lompstack - base jails (web jails live in $(basename "$FAIL2BAN_WEB_JAIL_FILE"))
[DEFAULT]
backend = systemd
ignoreip = ${ignore}
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ${ports}
maxretry = 5

[recidive]
enabled = true
backend = auto
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime = 1w
findtime = 1d
maxretry = 5
EOF
  local changed="$LIB_FILE_CHANGED"
  lib_cf_fail2ban_action_write
  lib_domain_fail2ban_regen
  lib_systemctl enable fail2ban >/dev/null 2>&1 || true
  if (( ! OPT_DRY_RUN )); then
    if lib_service_active fail2ban; then (( changed )) && { lib_run fail2ban-client reload || lib_warn "fail2ban reload failed"; }
    else lib_systemctl restart fail2ban || lib_warn "fail2ban failed to start (journalctl -u fail2ban)"; fi
  fi
  lib_manifest_set_json '.components.fail2ban' true
  lib_ok "Fail2ban: sshd (port ${ports}) + recidive, ignoreip ${ignore}"
}

lib_install_logrotate() {
  cat <<EOF | lib_write_file "$LOGROTATE_SELF_FILE" 0644 root:root
# Managed by lompstack
${LOG_FILE} {
  weekly
  rotate 12
  compress
  delaycompress
  missingok
  notifempty
  dateext
  create 0600 root root
}
EOF
  if ! grep -rqs '/var/log/mysql' /etc/logrotate.d/ 2>/dev/null; then
    cat <<EOF | lib_write_file /etc/logrotate.d/server-setup-mariadb-slow 0644 root:root
# Managed by lompstack - MariaDB slow query log
${DB_SLOW_LOG} {
  weekly
  rotate 8
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
  dateext
}
EOF
  fi
  lib_ok "logrotate configured (${LOGROTATE_SELF_FILE}, ${LOGROTATE_SITES_FILE})"
}

lib_install_cron() {
  lib_cron_set healthcheck "15 6 * * * root ${BIN_LINK} healthcheck"
  if [[ -n "$INS_BACKUP_SCHEDULE" ]]; then
    lib_backup_schedule "$INS_BACKUP_SCHEDULE" "$(lib_manifest_get '.backup.schedule_flags')"
  fi
  lib_cf_enabled && lib_cf_schedule
  lib_ok "Scheduled tasks in ${CRON_FILE} (healthcheck daily 06:15$( lib_cf_enabled && printf ', cloudflare ips weekly')$( [[ -n "$INS_BACKUP_SCHEDULE" ]] && printf ', backups %s' "$INS_BACKUP_SCHEDULE"))"
}

# Copy this checkout to INSTALL_DIR and link the command. The source directory is
# remembered so "self-update" can find the checkout later, when the running copy is the
# installed one and $SCRIPT_DIR points at INSTALL_DIR.
lib_install_self() {   # [source_dir]
  local src="${1:-$SCRIPT_DIR}" f=""
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would install a copy to ${INSTALL_DIR} and link ${BIN_LINK}"; return 0; fi
  mkdir -p "${INSTALL_DIR}/lib" && chmod 0755 "$INSTALL_DIR"
  if [[ "$src" != "$INSTALL_DIR" ]]; then
    # never replace a working installation with a checkout that does not even parse
    bash -n "${src}/setup.sh" || lib_die "${src}/setup.sh has a syntax error" "the checkout is broken" "fix it or check out a known good revision"
    for f in "$src"/lib/*.sh; do
      bash -n "$f" || lib_die "${f} has a syntax error" "the checkout is broken" "fix it or check out a known good revision"
    done
    # staged then swapped, so a failure halfway through never leaves a half-copied install
    rm -rf "${INSTALL_DIR}/lib.new" "${INSTALL_DIR}/lib.old"
    cp -a "${src}/lib" "${INSTALL_DIR}/lib.new"
    chmod 0644 "${INSTALL_DIR}"/lib.new/*.sh
    install -m 0755 "${src}/setup.sh" "${INSTALL_DIR}/setup.sh.new"
    [[ -d "${INSTALL_DIR}/lib" ]] && mv "${INSTALL_DIR}/lib" "${INSTALL_DIR}/lib.old"
    mv "${INSTALL_DIR}/lib.new" "${INSTALL_DIR}/lib"
    mv -f "${INSTALL_DIR}/setup.sh.new" "${INSTALL_DIR}/setup.sh"
    rm -rf "${INSTALL_DIR}/lib.old"
    lib_manifest_set '.install.source_dir' "$src"
    if [[ -d "${src}/.git" ]] && lib_have git; then
      lib_manifest_set '.install.revision' "$(git -C "$src" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
    fi
  fi
  ln -sfn "${INSTALL_DIR}/setup.sh" "$BIN_LINK"
  # short alias, but never clobber an unrelated program that happens to own the name
  if [[ -e "$BIN_SHORT" && ! -L "$BIN_SHORT" ]]; then
    lib_warn "${BIN_SHORT} already exists and is not our symlink; short alias not created"
  elif [[ -L "$BIN_SHORT" && "$(readlink -f "$BIN_SHORT")" != "$(readlink -f "${INSTALL_DIR}/setup.sh")" && -e "$(readlink -f "$BIN_SHORT")" ]]; then
    lib_warn "${BIN_SHORT} points somewhere else; short alias not created"
  else
    ln -sfn "${INSTALL_DIR}/setup.sh" "$BIN_SHORT"
  fi
  lib_ok "Installed to ${INSTALL_DIR}; run it as '$(basename "$BIN_SHORT")' or '$(basename "$BIN_LINK")' from anywhere"
}

# =============================================================================
#  self-update - refresh the installed copy from the checkout it came from
# =============================================================================
lib_selfupdate_main() {
  local src="" before="" after="" a=""
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --from) src="${1:-}"; shift ;;
      -h|--help) printf 'Usage: lomp self-update [--from /path/to/checkout]\n'; return 0 ;;
      *) lib_die "Unknown option for self-update: ${a}" "" "self-update [--from /path/to/checkout]" ;;
    esac
  done
  lib_require_tools
  lib_require_installed
  [[ -n "$src" ]] || src="$(lib_manifest_get '.install.source_dir')"
  [[ -n "$src" ]] || src="$SCRIPT_DIR"
  [[ -d "$src" && -f "${src}/setup.sh" ]] || lib_die "No usable checkout found at '${src}'" \
    "the directory lompstack was installed from is gone or was never recorded" \
    "clone it again and point at it: lomp self-update --from /opt/lompstack"
  if [[ "$src" == "$INSTALL_DIR" ]]; then
    lib_die "The installed copy is its own source" "there is no separate checkout to update from" \
      "git clone the repository, then: lomp self-update --from /path/to/clone"
  fi

  if [[ -d "${src}/.git" ]] && lib_have git; then
    before="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
    lib_info "Fetching the latest revision into ${src}"
    lib_run git -C "$src" pull --ff-only \
      || lib_die "git pull failed in ${src}" "local edits or a diverged branch" "inspect it: git -C ${src} status"
    after="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
    if [[ "$before" == "$after" ]]; then lib_ok "Already at the latest revision (${after})"
    else lib_ok "Checkout updated: ${before} -> ${after}"; fi
  else
    lib_info "${src} is not a git checkout; copying it as it is"
  fi

  lib_install_self "$src"
  lib_manifest_set '.install.updated_at' "$(lib_iso_now)"
  lib_ok "Now running lompstack ${SCRIPT_VERSION}$( [[ -n "$(lib_manifest_get '.install.revision')" ]] && printf ' (%s)' "$(lib_manifest_get '.install.revision')")"
  lib_note "Nothing on the server was reconfigured. Run 'sudo lomp doctor' to check its state."
}

lib_install_manifest() {
  local rerun="$1"
  (( OPT_DRY_RUN )) && return 0
  lib_manifest_set '.version' "$SCRIPT_VERSION"
  (( rerun )) || lib_manifest_set '.installed_at' "$(lib_iso_now)"
  [[ -n "$(lib_manifest_get '.installed_at')" ]] || lib_manifest_set '.installed_at' "$(lib_iso_now)"
  lib_manifest_set '.last_install_run' "$(lib_iso_now)"
  lib_manifest_set_json '.os' "$(jq -n --arg id "$OS_ID" --arg v "$OS_VERSION_ID" --arg c "$OS_CODENAME" --arg a "$SYS_ARCH" '{id:$id, version:$v, codename:$c, arch:$a}')"
  lib_manifest_set '.components.openlitespeed' "$(lib_ols_version)"
  lib_manifest_set '.components.mariadb' "$(lib_db_version)"
  lib_manifest_set '.components.redis' "$(lib_redis_version)"
  lib_manifest_set '.params.admin_access' "$ADMIN_ACCESS"
  lib_manifest_set_json '.params' "$(jq -n --arg tz "$TIMEZONE" --arg ap "$ADMIN_PORT" --arg ai "$ADMIN_ALLOWED_IP" --arg em "$DEFAULT_EMAIL" \
      --arg aa "$ADMIN_ACCESS" \
      --arg ssh "${SYS_SSH_PORTS}${SSH_PORT:+ $SSH_PORT}" --arg php "$PHP_VERSION" --arg keep "$BACKUP_KEEP" --arg sched "$INS_BACKUP_SCHEDULE" \
      --argjson rp "$( (( INS_REDIS_PERSIST )) && printf 'true' || printf 'false')" --argjson ar "$( (( INS_AUTO_REBOOT )) && printf 'true' || printf 'false')" \
      --arg f2b "$FAIL2BAN_IGNORE_IP" --arg dbp "$DB_BUFFER_PERCENT" --arg rdp "$REDIS_MAX_PERCENT" \
      '{timezone:$tz, admin_port:$ap, admin_access:$aa, admin_ip:$ai, email:$em, ssh_ports:$ssh, php:$php, backup_keep:$keep, backup_schedule:$sched,
        redis_persist:$rp, auto_reboot:$ar, fail2ban_ignore_ip:$f2b, db_buffer_percent:$dbp, redis_max_percent:$rdp}')"
  lib_manifest_set_json '.profile' "$(lib_system_profile_json)"
  lib_ok "Manifest updated (${STATE_DIR}/manifest.json)"
}

lib_install_summary() {
  local rerun="$1"
  printf '\n%s%s=== Installation %s ===%s\n' "$C_BLD" "$C_GRN" "$( (( rerun )) && printf 'verified' || printf 'completed')" "$C_RST"
  case "$ADMIN_ACCESS" in
    tunnel)
      lib_print_kv "WebAdmin" "closed to the internet (safe with a dynamic IP)"
      lib_note "open a tunnel from your own computer:"
      lib_note "  $(lib_ols_admin_tunnel_cmd)"
      lib_note "then browse to $(lib_ols_admin_url)"
      lib_note "or just run 'sudo lomp panel' to open it for your address for an hour"
      ;;
    ip)   lib_print_kv "WebAdmin" "$(lib_ols_admin_url)  (only from ${ADMIN_ALLOWED_IP})" ;;
    open) lib_print_kv "WebAdmin" "$(lib_ols_admin_url)  (reachable from anywhere)" ;;
  esac
  lib_print_kv "WebAdmin login"  "user admin, password: sudo lomp credentials --all"
  lib_print_kv "Sites root"     "${SITES_ROOT}/<domain>/public_html"
  lib_print_kv "Add a site"     "setup.sh add example.com [--www] [--wordpress] [--proxy 127.0.0.1:3000]"
  lib_print_kv "Health"         "setup.sh status | setup.sh doctor"
  lib_print_kv "Notifications"  "$(lib_notify_channels)  (setup.sh notify --email you@example.com ...)"
  lib_print_kv "Log"            "$LOG_FILE"
  lib_system_reboot_required && lib_warn "A reboot is required to finish kernel/package updates (reboot at your convenience)."
  (( OPT_DRY_RUN )) && lib_warn "DRY RUN finished - no changes were made."
  printf '\n'
  (( OPT_DRY_RUN )) || lib_notify_send "Installation $( (( rerun )) && printf 'verified' || printf 'completed')" \
    "setup.sh ${SCRIPT_VERSION} finished on $(hostname). OLS $(lib_ols_version), PHP $(lib_php_summary_line), MariaDB $(lib_db_version), Redis $(lib_redis_version)." || true
}

# =============================================================================
#  panel - WebAdmin access (built for administrators without a static IP)
# =============================================================================
PANEL_TIMER_UNIT="lompstack-panel-close"

_panel_self() { if [[ -x "$BIN_LINK" ]]; then printf '%s' "$BIN_LINK"; else printf '%s' "$SCRIPT_PATH"; fi; }
_panel_mode() { local m; m="$(lib_manifest_get '.params.admin_access')"; printf '%s' "${m:-tunnel}"; }

_panel_timer_pending() { systemctl is-active --quiet "${PANEL_TIMER_UNIT}.timer" 2>/dev/null; }

_panel_timer_cancel() {
  (( OPT_DRY_RUN )) && return 0
  systemctl stop "${PANEL_TIMER_UNIT}.timer" >/dev/null 2>&1 || true
  systemctl stop "${PANEL_TIMER_UNIT}.service" >/dev/null 2>&1 || true
  return 0
}

_panel_timer_schedule() {   # minutes
  local m="$1"
  (( m > 0 )) || { lib_warn "No automatic close scheduled: run 'lomp panel close' when you are done"; return 0; }
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would close the port again automatically in ${m} minute(s)"; return 0; fi
  lib_have systemd-run || { lib_warn "systemd-run unavailable: the port stays open until 'lomp panel close'"; return 0; }
  _panel_timer_cancel
  if systemd-run --quiet --on-active="${m}min" --unit="$PANEL_TIMER_UNIT" \
       --description="lompstack: close the WebAdmin port again" \
       "$(_panel_self)" panel close --yes --quiet >/dev/null 2>&1; then
    lib_ok "The port closes again automatically in ${m} minute(s)"
  else
    lib_warn "Could not schedule the automatic close; run 'lomp panel close' when you are done"
  fi
}

# Apply a listener binding and make sure it really took effect.
_panel_apply_bind() {   # address
  local addr="$1"
  lib_ols_change_begin
  lib_ols_admin_bind "$addr"
  lib_ols_change_commit "WebAdmin listener"
  (( OPT_DRY_RUN )) && return 0
  sleep 1
  if [[ "$addr" == "127.0.0.1" ]]; then
    if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "^(0\.0\.0\.0|\*|\[::\]):${ADMIN_PORT}\$"; then
      lib_ols_restart; lib_ols_wait_ready 40 || lib_warn "OpenLiteSpeed took long to come back; check systemctl status lsws"
    fi
  else
    lib_port_listening "$ADMIN_PORT" || { lib_ols_restart; lib_ols_wait_ready 40 || lib_warn "OpenLiteSpeed took long to come back"; }
  fi
  return 0
}

# One-line summary used by "status".
lib_panel_status_line() {
  local mode=""; mode="$(_panel_mode)"
  case "$mode" in
    ip)   printf 'port %s only from %s' "$ADMIN_PORT" "$(lib_manifest_get '.params.admin_ip')" ;;
    open) printf 'port %s open to everyone' "$ADMIN_PORT" ;;
    *)    printf 'closed, SSH tunnel only (setup.sh panel)' ;;
  esac
  _panel_timer_pending && printf ' [temporarily open]'
  return 0
}

lib_panel_status() {
  local mode="" bind="" rules=""
  mode="$(_panel_mode)"
  bind="$(lib_ols_admin_current_bind)"
  lib_system_analyze --no-net
  printf '\n%sWebAdmin access%s\n' "$C_BLD" "$C_RST"
  lib_print_kv "Configured mode" "${mode}$( [[ "$mode" == "ip" ]] && printf ' (%s)' "$(lib_manifest_get '.params.admin_ip')")"
  lib_print_kv "Listener"        "${bind:-unknown}"
  rules="$(lib_ufw_port_rule_numbers "$ADMIN_PORT" | wc -l | tr -d ' ')"
  lib_print_kv "Firewall"        "$( (( rules > 0 )) && printf '%s UFW rule(s) allow port %s' "$rules" "$ADMIN_PORT" || printf 'port %s is not opened' "$ADMIN_PORT")"
  if _panel_timer_pending; then
    lib_print_kv "Auto-close" "scheduled ($(systemctl show "${PANEL_TIMER_UNIT}.timer" -p NextElapseUSecRealtime --value 2>/dev/null || true))"
  fi
  lib_print_kv "URL"             "$(lib_ols_admin_url)"
  lib_print_kv "Login"           "user admin, password: sudo lomp credentials --all"
  printf '\n  %sFrom your own computer, without opening any port:%s\n' "$C_BLD" "$C_RST"
  printf '    %s\n' "$(lib_ols_admin_tunnel_cmd)"
  printf '    then browse to https://127.0.0.1:%s\n' "$ADMIN_PORT"
  printf '\n  %sOr open the port for your current address for a while:%s\n' "$C_BLD" "$C_RST"
  printf '    sudo lomp panel open            # your SSH address, 60 minutes\n'
  printf '    sudo lomp panel open --minutes 15\n'
  printf '    sudo lomp panel close\n\n'
}

lib_panel_open() {
  local ip="auto" minutes=60 a=""
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --ip)      ip="${1:-auto}"; shift ;;
      --minutes) minutes="${1:-60}"; shift ;;
      *) lib_die "Unknown option for panel open: ${a}" "" "panel open [--ip auto|<IP>|any] [--minutes N]" ;;
    esac
  done
  [[ "$minutes" =~ ^[0-9]+$ ]] || lib_die "Invalid --minutes '${minutes}'" "expected a whole number" "--minutes 30 (0 = no automatic close)"
  if [[ "$ip" == "auto" ]]; then
    ip="$(lib_admin_client_ip)"
    [[ -n "$ip" ]] || lib_die "Could not detect your address" \
      "this is not an SSH session, so SSH_CONNECTION is empty" \
      "pass it yourself: panel open --ip 1.2.3.4, or use the SSH tunnel shown by 'panel status'"
    lib_info "Opening port ${ADMIN_PORT} for ${ip} (the address this SSH session comes from)"
  elif [[ "$ip" == "any" ]]; then
    lib_warn "This exposes the WebAdmin login to the whole internet."
    lib_confirm "Really open port ${ADMIN_PORT} to everyone?" n || lib_die "Cancelled" "" "use 'panel open' without --ip any"
  else
    [[ "$ip" =~ ^[0-9a-fA-F.:/]+$ ]] || lib_die "Invalid --ip '${ip}'" "" "--ip 1.2.3.4 or --ip 1.2.3.0/24"
  fi
  # before _panel_apply_bind, not after: lib_ols_listener_address reads SYS_IPV6, which is
  # still its module default 0 until lib_system_analyze runs. Binding "*" (IPv4 only) while
  # the UFW rule was opened for the operator's IPv6 address produced a panel reported as
  # open that nothing could reach.
  lib_system_analyze
  _panel_apply_bind "$(lib_ols_listener_address)"
  lib_ufw_delete_port_rules "$ADMIN_PORT"
  if [[ "$ip" == "any" ]]; then lib_ufw_rule allow "${ADMIN_PORT}/tcp"
  else lib_ufw_rule allow from "$ip" to any port "$ADMIN_PORT" proto tcp; fi
  _panel_timer_schedule "$minutes"
  lib_system_analyze
  local url="" pass=""
  url="$(lib_ols_admin_url)"
  pass="$(awk -F= '$1=="PASSWORD"{sub(/^[^=]*=/, ""); print; exit}' "${STATE_DIR}/openlitespeed-admin.info" 2>/dev/null || true)"
  printf '\n%s%sWebAdmin is open - click or paste this into your browser%s\n' "$C_BLD" "$C_GRN" "$C_RST"
  printf '\n    %s%s%s\n\n' "$C_BLD" "$url" "$C_RST"
  lib_print_kv "User"     "admin"
  lib_print_kv "Password" "${pass:-run: lompstack credentials --all}"
  lib_print_kv "Open for" "$( [[ "$ip" == "any" ]] && printf 'everyone' || printf '%s' "$ip")$( (( minutes > 0 )) && printf ', %s minute(s)' "$minutes")"
  printf '\n  Your browser will warn about the certificate: it is self-signed, that is expected.\n'
  printf '  Close it again at any time with: sudo lomp panel close\n\n'
  lib_log_write INFO "panel opened for ${ip} for ${minutes} minute(s)"
}

lib_panel_close() {
  local mode="" admin_ip=""
  lib_system_analyze --no-net
  mode="$(_panel_mode)"
  admin_ip="$(lib_manifest_get '.params.admin_ip')"
  _panel_timer_cancel
  lib_ufw_delete_port_rules "$ADMIN_PORT"
  case "$mode" in
    ip)
      [[ -n "$admin_ip" ]] && lib_ufw_rule allow from "$admin_ip" to any port "$ADMIN_PORT" proto tcp
      _panel_apply_bind "$(lib_ols_listener_address)"
      lib_ok "Back to the configured mode: port ${ADMIN_PORT} only from ${admin_ip}"
      ;;
    open)
      lib_ufw_rule allow "${ADMIN_PORT}/tcp"
      _panel_apply_bind "$(lib_ols_listener_address)"
      lib_ok "Back to the configured mode: port ${ADMIN_PORT} open to everyone"
      ;;
    *)
      _panel_apply_bind 127.0.0.1
      lib_ok "WebAdmin closed again: the port is firewalled and the listener is bound to 127.0.0.1"
      lib_note "reach it any time with: $(lib_ols_admin_tunnel_cmd)"
      ;;
  esac
  lib_log_write INFO "panel closed (mode ${mode})"
}

lib_panel_main() {
  local action="open"
  # "panel", "panel open", "panel --minutes 15" and "panel status" must all work
  if (($# > 0)); then
    case "$1" in
      -h|--help) printf 'Usage: setup.sh panel [open|status|close] [--ip auto|<IP>|any] [--minutes N]\n'; return 0 ;;
      -*) ;;                       # options without an action: open
      *)  action="$1"; shift ;;
    esac
  fi
  lib_require_tools
  lib_require_installed
  lib_params_load
  case "$action" in
    open)
      # bare "panel" opens it; without an SSH session there is no address to open for,
      # so fall back to showing the tunnel instructions instead of failing
      if [[ $# -eq 0 ]] && [[ -z "$(lib_admin_client_ip)" ]]; then
        lib_warn "Could not work out which address you are connecting from, so nothing was opened."
        lib_note "Give it explicitly with: sudo lompstack panel --ip <your address>"
        lib_note "Do not know your address? Run this on your own computer: curl -s https://api.ipify.org"
        lib_panel_status
        return 0
      fi
      lib_panel_open "$@"
      ;;
    status) lib_panel_status ;;
    close)  lib_panel_close ;;
    *) lib_die "Unknown panel action '${action}'" "expected open, status or close" "setup.sh panel" ;;
  esac
}

# =============================================================================
#  Optional runtimes
# =============================================================================
lib_install_node() {
  local list="/etc/apt/sources.list.d/nodesource.list"
  lib_apt_key_install "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" /etc/apt/keyrings/nodesource.gpg
  printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' "$INS_NODE_MAJOR" | lib_write_file "$list" 0644 root:root
  (( LIB_FILE_CHANGED )) && LIB_APT_UPDATED=0
  lib_apt_install nodejs || lib_die "Node.js installation failed" "apt error" "check the NodeSource repository"
  (( OPT_DRY_RUN )) && { lib_info "[dry-run] would install PM2 + pm2-logrotate and register pm2 with systemd"; return 0; }
  if ! lib_have pm2; then lib_run npm install -g pm2 || lib_die "PM2 installation failed" "npm error" "npm install -g pm2"; fi
  lib_run pm2 startup systemd -u root --hp /root || lib_warn "pm2 startup failed (see log)"
  lib_run pm2 install pm2-logrotate || lib_warn "pm2-logrotate could not be installed"
  lib_run pm2 set pm2-logrotate:max_size 10M || true
  lib_run pm2 set pm2-logrotate:retain 14 || true
  lib_run pm2 save --force || true
  lib_systemd_override pm2-root "LimitNOFILE=65535" "LimitNPROC=8192"
  lib_manifest_set '.components.node' "$(node -v 2>/dev/null || true)"
  lib_ok "Node.js $(node -v 2>/dev/null) + PM2 $(pm2 -v 2>/dev/null) ready (apps: setup.sh add app.example.com --proxy 127.0.0.1:3000; keep app files in /home/<domain>/app)"
}

lib_install_python() {
  lib_apt_install python3 python3-venv python3-pip || lib_die "Python installation failed" "apt error" "check the log"
  lib_manifest_set '.components.python' "$(python3 --version 2>/dev/null | awk '{print $2}')"
  lib_ok "Python $(python3 --version 2>/dev/null | awk '{print $2}') with venv/pip (policy: one venv per app under /home/<domain>/app/.venv, no global pip installs)"
}

_ini_set() {   # file section key value  (simple INI editor, keeps other content)
  local file="$1" section="$2" key="$3" value="$4" tmp=""
  tmp="$(lib_mktemp)"
  if [[ -f "$file" ]]; then cp "$file" "$tmp"; else : >"$tmp"; fi
  awk -v s="$section" -v k="$key" -v v="$value" '
    BEGIN{ insec=0; done=0; found=0 }
    /^[[:space:]]*\[/ { if (insec && !done) { print "    " k " = " v; done=1 } ; insec = ($0 ~ "^[[:space:]]*\\[" s "\\][[:space:]]*$"); if (insec) found=1 }
    { if (insec && !done && $0 ~ "^[[:space:]]*#?[[:space:]]*" k "[[:space:]]*=") { print "    " k " = " v; done=1; next } print }
    END{ if (!found) { print "[" s "]"; print "    " k " = " v } else if (!done) print "    " k " = " v }' "$tmp" >"${tmp}.2"
  lib_write_file "$file" <"${tmp}.2"
  rm -f "$tmp" "${tmp}.2"
}

lib_install_netdata() {
  local conf="" d="" ks=""
  if ! lib_have netdata && [[ ! -x /opt/netdata/bin/netdata && ! -x /usr/sbin/netdata ]]; then
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would install Netdata via the official kickstart script"; return 0; fi
    ks="$(lib_mktemp)"
    curl -fsSL --max-time 60 -o "$ks" https://get.netdata.cloud/kickstart.sh || lib_die "Netdata kickstart download failed" "network" "retry later"
    lib_run bash "$ks" --stable-channel --disable-telemetry --non-interactive --dont-wait || lib_die "Netdata installation failed" "kickstart error" "see the log"
  fi
  for d in /etc/netdata /opt/netdata/etc/netdata; do [[ -d "$d" ]] && { conf="${d}/netdata.conf"; break; }; done
  if [[ -n "$conf" ]]; then
    _ini_set "$conf" web "bind to" "$( [[ -n "$ADMIN_ALLOWED_IP" ]] && printf '*' || printf '127.0.0.1')"
    _ini_set "$conf" web "allow connections from" "localhost${ADMIN_ALLOWED_IP:+ $ADMIN_ALLOWED_IP}"
    _ini_set "$conf" web "allow dashboard from" "localhost${ADMIN_ALLOWED_IP:+ $ADMIN_ALLOWED_IP}"
    (( OPT_DRY_RUN )) || lib_systemctl restart netdata || lib_warn "netdata restart failed"
  fi
  lib_manifest_set_json '.components.netdata' true
  lib_ok "Netdata on port 19999: localhost${ADMIN_ALLOWED_IP:+ + $ADMIN_ALLOWED_IP}$( [[ -z "$ADMIN_ALLOWED_IP" ]] && printf ' (use an SSH tunnel: ssh -L 19999:127.0.0.1:19999 ...)')"
}

# =============================================================================
#  update
# =============================================------------------------------
_ver_report_line() { printf '  %-16s %-18s -> %s\n' "$1" "${2:-none}" "${3:-none}"; }

lib_update_main() {
  lib_require_tools
  lib_require_installed
  lib_system_analyze --no-net
  lib_steps_begin 6
  local ts="" snap="" before_ols="" before_db="" before_redis="" before_php="" after_ols="" after_db="" after_redis="" after_php=""
  ts="$(lib_ts)"

  lib_step "Configuration backups"
  snap="${STATE_DIR}/archive/update-${ts}"
  if (( ! OPT_DRY_RUN )); then
    mkdir -p "$snap" && chmod 0700 "$snap"
    tar -czf "${snap}/etc-configs.tar.gz" -C / etc/mysql etc/redis etc/ssh etc/fail2ban etc/ufw etc/sysctl.d etc/logrotate.d etc/cron.d 2>/dev/null || true
    lib_ols_is_installed && lib_ols_snapshot_take >/dev/null
    for d in "$LSWS_HOME"/lsphp[0-9][0-9]/etc; do [[ -d "$d" ]] && tar -czf "${snap}/$(basename "$(dirname "$d")")-etc.tar.gz" -C "$(dirname "$d")" etc 2>/dev/null || true; done
  fi
  lib_ok "Configs archived under ${snap}"

  lib_step "Versions before"
  before_ols="$(lib_ols_version)"; before_db="$(lib_db_version)"; before_redis="$(lib_redis_version)"; before_php="$(lib_php_summary_line)"
  lib_info "OLS ${before_ols:-none}, MariaDB ${before_db:-none}, Redis ${before_redis:-none}, PHP ${before_php}"

  lib_step "Package update"
  LIB_APT_UPDATED=0
  lib_apt_update
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] upgradable packages:"; apt list --upgradable 2>/dev/null | sed 's/^/        /' | head -n 40 || true
  else
    lib_run apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade || lib_die "apt-get upgrade failed" "see the log" "fix apt problems (apt-get -f install) and re-run"
    lib_run apt-get -y -q autoremove || true
  fi

  lib_step "Versions after"
  after_ols="$(lib_ols_version)"; after_db="$(lib_db_version)"; after_redis="$(lib_redis_version)"; after_php="$(lib_php_summary_line)"
  _ver_report_line "OpenLiteSpeed" "$before_ols" "$after_ols"
  _ver_report_line "MariaDB" "$before_db" "$after_db"
  _ver_report_line "Redis" "$before_redis" "$after_redis"
  _ver_report_line "PHP" "$before_php" "$after_php"
  if [[ -n "$before_db" && "${before_db%%.*}" != "${after_db%%.*}" ]]; then lib_warn "MariaDB MAJOR version changed (${before_db} -> ${after_db}); run mariadb-upgrade if not done automatically"; fi
  lib_note "Major version jumps are never performed automatically. MariaDB: setup.sh install --mariadb <ver>; PHP: setup.sh install --php <ver> (or add --php per site)."

  lib_step "Service restarts (mariadb -> redis -> lsws) with health checks"
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would restart services whose packages changed"
  else
    if [[ "$before_db" != "$after_db" ]] && lib_db_installed; then
      lib_systemctl restart mariadb; lib_db_wait_ready 60 || lib_die "MariaDB unhealthy after update" "journalctl -u mariadb" "restore ${snap}/etc-configs.tar.gz if needed"
      lib_have mariadb-upgrade && lib_run mariadb-upgrade --protocol=socket --socket="$DB_SOCKET" || true
      lib_ok "MariaDB restarted and healthy"
    else lib_ok "MariaDB unchanged (no restart)"; fi
    if [[ "$before_redis" != "$after_redis" ]] && lib_redis_installed; then
      lib_systemctl restart "$REDIS_SERVICE"; sleep 1; lib_redis_ping || lib_die "Redis unhealthy after update" "journalctl -u redis-server" ""
      lib_ok "Redis restarted and healthy"
    else lib_ok "Redis unchanged (no restart)"; fi
    if [[ "$before_ols" != "$after_ols" || "$before_php" != "$after_php" ]] && lib_ols_is_installed; then
      lib_ols_config_test || lib_die "OpenLiteSpeed config test failed after update" "$OLS_TEST_OUTPUT" "inspect ${LSWS_HOME}/logs/error.log"
      lib_ols_restart; lib_ols_wait_ready 40 || lib_die "OpenLiteSpeed unhealthy after update" "journalctl -u lsws" ""
      lib_php_restart_workers
      lib_ok "OpenLiteSpeed restarted and healthy"
    else lib_ok "OpenLiteSpeed/PHP unchanged (no restart)"; fi
  fi

  lib_step "Housekeeping"
  lib_cf_enabled && { lib_cf_update_ips || true; }
  lib_install_self
  lib_manifest_set '.components.openlitespeed' "$after_ols"
  lib_manifest_set '.components.mariadb' "$after_db"
  lib_manifest_set '.components.redis' "$after_redis"
  lib_manifest_set '.last_update' "$(lib_iso_now)"
  lib_system_reboot_required && lib_warn "Reboot required to activate the new kernel/libraries."
  lib_ok "Update finished"
}

# =============================================================================
#  optimize
# =============================================================================
_opt_diff() {   # title file  (new content on stdin) -> prints diff, returns 0 when changes exist
  local title="$1" file="$2" new=""
  new="$(lib_mktemp)"; cat >"$new"
  if [[ -f "$file" ]] && cmp -s "$new" "$file"; then rm -f "$new"; return 1; fi
  printf '\n%s--- %s (%s)%s\n' "$C_BLD" "$title" "$file" "$C_RST"
  if [[ -f "$file" ]]; then diff -u "$file" "$new" | tail -n +3 | head -n 80 || true; else printf '(new file, %s lines)\n' "$(wc -l <"$new" | tr -d ' ')"; fi
  rm -f "$new"
  return 0
}

lib_optimize_main() {
  lib_require_tools
  lib_require_installed
  lib_ols_service_repair
  lib_system_analyze
  lib_system_report
  lib_system_profile
  lib_system_profile_report
  local changes=() ver=""
  lib_heading "Proposed changes"
  lib_system_render_sysctl | _opt_diff "Kernel parameters" "$SYSCTL_FILE" && changes+=(sysctl)
  lib_system_render_limits | _opt_diff "Limits" "$LIMITS_FILE" && changes+=(limits)
  for ver in $(lib_php_installed_versions); do
    lib_php_ini_paths "$ver"
    if [[ -n "$PHP_INI_SCAN_DIR" ]]; then
      lib_php_render_ini | _opt_diff "PHP ${ver}" "${PHP_INI_SCAN_DIR%/}/99-server-setup.ini" && changes+=("php:${ver}")
    fi
  done
  lib_db_installed && { lib_db_render_tuning | _opt_diff "MariaDB" "$MARIADB_TUNED_FILE" && changes+=(mariadb); }
  if lib_redis_installed && [[ -n "$(lib_redis_password)" ]]; then
    lib_redis_render_conf "$(lib_redis_password)" "$( [[ "$(lib_manifest_get '.params.redis_persist')" == "true" ]] && printf 1 || printf 0)" \
      | _opt_diff "Redis" "$REDIS_INCLUDE" && changes+=(redis)
  fi
  if lib_ols_is_installed; then
    lib_ols_tx_begin
    lib_ols_tx_apply_server_settings
    lib_cf_enabled && lib_cf_tx_apply 1
    if ! cmp -s "$OLS_TX_FILE" "$LSWS_CONF"; then
      printf '\n%s--- OpenLiteSpeed (%s)%s\n' "$C_BLD" "$LSWS_CONF" "$C_RST"
      lib_ols_tx_diff | tail -n +3 | head -n 80
      changes+=(ols)
    fi
    lib_ols_tx_abort
  fi
  if ((${#changes[@]} == 0)); then lib_ok "Everything is already tuned for this hardware; nothing to do."; return 0; fi
  printf '\n'
  lib_confirm "Apply these changes (${changes[*]})?" y || { lib_info "No changes applied."; return 0; }
  local c=""
  for c in "${changes[@]}"; do
    case "$c" in
      sysctl)  lib_system_sysctl_apply ;;
      limits)  lib_system_limits_apply ;;
      php:*)   lib_php_write_ini "${c#php:}"; lib_php_restart_workers ;;
      mariadb) lib_db_apply_tuning ;;
      redis)   lib_redis_install "$( [[ "$(lib_manifest_get '.params.redis_persist')" == "true" ]] && printf 1 || printf 0)" ;;
      ols)
        lib_ols_change_begin
        lib_ols_tx_begin
        lib_ols_tx_apply_server_settings
        lib_cf_enabled && lib_cf_tx_apply 1
        lib_ols_tx_commit
        lib_ols_change_commit "optimize" ;;
    esac
  done
  (( OPT_DRY_RUN )) || lib_manifest_set_json '.profile' "$(lib_system_profile_json)"
  lib_ok "Optimisation applied"
}
