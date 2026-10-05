#!/usr/bin/env bash
# lib/harden.sh - what a PHP shell dropped into one site can do: per-site PHP limits
#                 (no process execution, open_basedir, no scripts in upload directories) and
#                 the site firewall (which local ports a site's user may reach).

# ---- per-site PHP ini ---------------------------------------------------------------
# Root's, readable by the site's group: PHP reads it as the site user, who must not change it.
HARDEN_PHP_INI_ROOT="/etc/lompstack/php"
HARDEN_PHP_INI_NAME="99-lompstack-site.ini"
# Process execution, and the two ways around its absence: putenv (LD_PRELOAD for the sendmail
# that mail() starts) and dl. mail() itself stays: sites send mail.
HARDEN_DISABLE_FUNCTIONS="exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec,pcntl_fork,putenv,dl"
HARDEN_PHP_CHANGED=""   # sites whose ini lib_harden_php_ini_write changed in this run

# ---- site firewall --------------------------------------------------------------------
SITEFW_DIR="/etc/lompstack/site-firewall"
SITEFW_SCRIPT="/usr/local/sbin/lomp-site-firewall"
SITEFW_UNIT="/etc/systemd/system/lomp-site-firewall.service"
SITEFW_CHAIN="LOMP-SITES"
# What a site's user may reach on this machine: DNS, the web server (a site calling itself),
# MariaDB and Redis. Everything else that listens here - the WebAdmin panel, SSH, another
# site's application, whatever the operator runs beside lomp - is refused.
SITEFW_TCP_PORTS="53,80,443,3306,6379"
SITEFW_UDP_PORTS="53,443"
SITEFW_MAIL_PORTS="25,465,587"

lib_harden_php_ini_dir() { printf '%s/%s' "$HARDEN_PHP_INI_ROOT" "$1"; }

lib_harden_render_php_ini() {
  local share=""; share="$(lib_php_home "$D_PHP")/share/"
  cat <<EOF
; Managed by lompstack for ${D_DOMAIN} - regenerated on every change; do not edit by hand.
; "lomp harden ${D_DOMAIN} --allow-exec" removes it.
disable_functions = ${HARDEN_DISABLE_FUNCTIONS}
open_basedir = ${D_HOME}/:$(lib_domain_log_dir "$D_DOMAIN")/:${share}:/tmp/
EOF
}

# The ini directory of the site in D_*, as its state says: written when process execution is
# blocked, removed when it is not. lib_ols_vhconf_write calls it, so whatever renders a vhost
# that points PHP at the directory has the directory in place.
lib_harden_php_ini_write() {
  local dir=""; dir="$(lib_harden_php_ini_dir "$D_DOMAIN")"
  if [[ "$D_SEC_EXEC" == "blocked" && ( "$D_MODE" == "php" || "$D_MODE" == "wordpress" ) ]]; then
    lib_mkdir "$HARDEN_PHP_INI_ROOT" 0755 root:root
    lib_mkdir "$dir" 0750 "root:${D_GROUP}"
    lib_harden_render_php_ini | lib_write_file "${dir}/${HARDEN_PHP_INI_NAME}" 0640 "root:${D_GROUP}"
    if (( LIB_FILE_CHANGED )); then HARDEN_PHP_CHANGED+="${HARDEN_PHP_CHANGED:+ }${D_DOMAIN}"; fi
  elif [[ -e "$dir" ]]; then
    lib_rm "$dir"
    HARDEN_PHP_CHANGED+="${HARDEN_PHP_CHANGED:+ }${D_DOMAIN}"
  fi
  return 0
}

# A site's lsphp reads its ini files when it starts, and outlives a reload of the server.
lib_harden_php_restart() {   # user
  (( OPT_DRY_RUN )) && return 0
  pkill -x -u "$1" lsphp >/dev/null 2>&1 || true
}

# =============================================================================
#  Site firewall
# =============================================================================
lib_sitefw_enabled() { [[ "$(lib_manifest_get '.params.site_firewall')" == "true" ]]; }

# "127.0.0.1:3000" / "http://127.0.0.1:3000/x" -> 3000 when the target is this machine
_sitefw_local_port() {
  local t="${1#*://}"; t="${t%%/*}"
  [[ "$t" =~ ^(127\.[0-9.]+|localhost|\[::1\]):([0-9]{1,5})$ ]] || return 0
  printf '%s\n' "${BASH_REMATCH[2]}"
}

# "uid port,port" per site, for iptables: the site's user and the local ports that are its own
# (its application, its path proxies).
lib_sitefw_sites() {
  local d="" uid="" ports="" pp="" pt=""
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_domain_state_load "$d" || continue
    uid="$(_sitefw_uid "$D_USER")"
    [[ "$uid" =~ ^[0-9]+$ ]] && (( uid > 0 )) || continue
    ports="$(_sitefw_local_port "$D_PROXY")"
    while read -r pp pt; do
      if [[ -n "$pp" && -n "$pt" ]]; then ports+=$'\n'"$(_sitefw_local_port "$pt")"; fi
    done <<<"$D_PATH_PROXIES"
    ports="$(sed '/^$/d' <<<"$ports" | sort -un | paste -sd, -)"
    printf '%s %s\n' "$uid" "$ports"
  done < <(lib_domains_list)
  return 0
}
_sitefw_uid() { id -u "$1" 2>/dev/null || true; }

# The rules, for iptables-restore --noflush: naming a chain there empties it, so loading the
# file replaces the two chains in one step and touches nothing else (UFW's chains included).
# Only connections a site's user opens to this machine come here (-o lo covers every local
# address, the public ones too). Answers pass, so an application the site runs can still answer
# the web server.
lib_sitefw_render() {   # 4|6
  local uid="" ports="" tcp="$SITEFW_TCP_PORTS" icmp="icmp"
  [[ "$1" == "6" ]] && icmp="ipv6-icmp"
  if lib_mail_installed; then tcp+=",${SITEFW_MAIL_PORTS}"; fi
  printf '# Managed by lompstack - regenerated when a site is added, removed or changes its ports\n'
  printf '*filter\n:%s - [0:0]\n:%s-LOCAL - [0:0]\n' "$SITEFW_CHAIN" "$SITEFW_CHAIN"
  printf -- '-A %s -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN\n' "$SITEFW_CHAIN"
  while read -r uid ports; do
    [[ -n "$uid" ]] || continue
    if [[ -n "$ports" ]]; then
      printf -- '-A %s -m owner --uid-owner %s -p tcp -m multiport --dports %s -j RETURN\n' "$SITEFW_CHAIN" "$uid" "$ports"
    fi
    printf -- '-A %s -m owner --uid-owner %s -j %s-LOCAL\n' "$SITEFW_CHAIN" "$uid" "$SITEFW_CHAIN"
  done < <(lib_sitefw_sites)
  printf -- '-A %s-LOCAL -p tcp -m multiport --dports %s -j RETURN\n' "$SITEFW_CHAIN" "$tcp"
  printf -- '-A %s-LOCAL -p udp -m multiport --dports %s -j RETURN\n' "$SITEFW_CHAIN" "$SITEFW_UDP_PORTS"
  printf -- '-A %s-LOCAL -p %s -j RETURN\n' "$SITEFW_CHAIN" "$icmp"
  printf -- '-A %s-LOCAL -p tcp -j REJECT --reject-with tcp-reset\n' "$SITEFW_CHAIN"
  printf -- '-A %s-LOCAL -j REJECT\n' "$SITEFW_CHAIN"
  printf 'COMMIT\n'
}

lib_sitefw_render_script() {
  cat <<EOF
#!/bin/sh
# Managed by lompstack - loads the site firewall (start) or takes it out (stop).
# The rules are in ${SITEFW_DIR}; "lomp harden" writes them.
d="${SITEFW_DIR}"; c="${SITEFW_CHAIN}"; rc=0
for v in 4 6; do
  if [ "\$v" = 4 ]; then ipt=iptables; else ipt=ip6tables; fi
  command -v "\$ipt" >/dev/null 2>&1 || continue
  if [ "\${1:-start}" = "stop" ]; then
    while "\$ipt" -D OUTPUT -o lo -j "\$c" 2>/dev/null; do :; done
    "\$ipt" -F "\$c" 2>/dev/null; "\$ipt" -F "\$c-LOCAL" 2>/dev/null
    "\$ipt" -X "\$c" 2>/dev/null; "\$ipt" -X "\$c-LOCAL" 2>/dev/null
    continue
  fi
  [ -s "\$d/rules.v\$v" ] || continue
  # a machine without IPv6 has nothing to protect there, and may refuse the rules
  if ! "\$ipt-restore" --noflush <"\$d/rules.v\$v"; then [ "\$v" = 6 ] || rc=1; continue; fi
  "\$ipt" -C OUTPUT -o lo -j "\$c" 2>/dev/null || "\$ipt" -I OUTPUT 1 -o lo -j "\$c" || { [ "\$v" = 6 ] || rc=1; }
done
exit "\$rc"
EOF
}

lib_sitefw_render_unit() {
  cat <<EOF
# Managed by lompstack
[Unit]
Description=lompstack site firewall (local ports a site's user may reach)
After=ufw.service network-pre.target
Before=lsws.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SITEFW_SCRIPT} start
ExecStop=${SITEFW_SCRIPT} stop

[Install]
WantedBy=multi-user.target
EOF
}

# Is the firewall in the kernel right now?
lib_sitefw_loaded() { iptables -C OUTPUT -o lo -j "$SITEFW_CHAIN" >/dev/null 2>&1; }

# Rules from the sites as they are now, and loaded. Nothing when the firewall is off.
lib_sitefw_regen() {
  local changed=0 v=""
  lib_sitefw_enabled || return 0
  lib_mkdir "$SITEFW_DIR" 0700 root:root
  for v in 4 6; do
    lib_sitefw_render "$v" | lib_write_file "${SITEFW_DIR}/rules.v${v}" 0600 root:root
    if (( LIB_FILE_CHANGED )); then changed=1; fi
  done
  if (( OPT_DRY_RUN )); then
    (( changed )) && lib_info "[dry-run] would load the site firewall rules again"
    return 0
  fi
  if (( changed )) || ! lib_sitefw_loaded; then
    "$SITEFW_SCRIPT" start >>"$LOG_FILE" 2>&1 \
      || lib_warn "The site firewall rules could not be loaded (see ${LOG_FILE}); sites reach local ports as before"
  fi
  return 0
}

lib_sitefw_enable() {
  if (( OPT_DRY_RUN )); then
    lib_sitefw_enabled || lib_info "[dry-run] would switch the site firewall on: a site's user reaches only ports ${SITEFW_TCP_PORTS} and its own application on this machine"
    return 0
  fi
  lib_have iptables-restore || { lib_warn "iptables-restore is missing; the site firewall was not switched on"; return 1; }
  lib_mkdir "$SITEFW_DIR" 0700 root:root
  lib_sitefw_render_script | lib_write_file "$SITEFW_SCRIPT" 0755 root:root
  lib_sitefw_render_unit | lib_write_file "$SITEFW_UNIT" 0644 root:root
  if (( LIB_FILE_CHANGED )); then systemctl daemon-reload >/dev/null 2>&1 || true; fi
  lib_manifest_set_json '.params.site_firewall' 'true'
  lib_sitefw_regen
  if ! lib_sitefw_loaded; then
    lib_manifest_set_json '.params.site_firewall' 'false'
    lib_warn "The kernel did not take the site firewall rules (no owner match in this environment?); it stays off"
    return 1
  fi
  systemctl enable lomp-site-firewall.service >/dev/null 2>&1 || lib_warn "could not enable lomp-site-firewall.service; the rules are gone after a reboot until 'lomp harden' runs again"
  return 0
}

lib_sitefw_disable() {
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would switch the site firewall off"; return 0; fi
  systemctl disable lomp-site-firewall.service >/dev/null 2>&1 || true
  if [[ -x "$SITEFW_SCRIPT" ]]; then "$SITEFW_SCRIPT" stop >>"$LOG_FILE" 2>&1 || true; fi
  lib_manifest_set_json '.params.site_firewall' 'false'
  return 0
}

# An install re-run used to write .params anew and took the setting with it (lib_install_manifest
# merges now). On a server that happened to, the rules are still loaded, and loaded again at
# every boot, but the firewall reads as off: a site added since has no rules of its own. Only
# that loss leaves the unit enabled beside no setting at all - switching the firewall off
# disables the unit and writes "false" - so it is known by that.
lib_sitefw_setting_lost() {
  [[ -z "$(lib_json_get_raw "$STATE_DIR/manifest.json" '.params.site_firewall')" ]] || return 1
  lib_service_enabled lomp-site-firewall.service
}

# What migrate does for the firewall: a lost setting is put back, and where the firewall is on,
# its loader, its unit and its rules are the ones this release writes.
lib_sitefw_migrate() {
  local lost=0
  if lib_sitefw_setting_lost; then
    lost=1
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would record the site firewall as on again: an install re-run dropped the setting, and a site added since has no rules of its own"
    else lib_manifest_set_json '.params.site_firewall' 'true'; fi
  fi
  if lib_sitefw_enabled; then lib_sitefw_enable || true; fi
  if (( lost && ! OPT_DRY_RUN )) && lib_sitefw_enabled; then
    lib_ok "The site firewall is recorded as on again: an install re-run had dropped the setting, and every site has its rules now"
  fi
  return 0
}

# =============================================================================
#  harden
# =============================================================================
lib_harden_usage() {
  # a usage text is no single message lib/lang.sh could look up: its Turkish is here
  if [[ "${LIB_LANG:-en}" == "tr" ]]; then
    cat <<'EOF'
Kullanım: lomp harden <domain>|--all [--allow-exec] [--allow-upload-php]
          lomp harden status
          lomp harden --firewall on|off

  Bir siteye bırakılmış bir PHP shell'inin yapabileceklerini sınırlar:
    - PHP süreç başlatamaz (exec, shell_exec, system, proc_open, popen ...) ve yalnızca
      sitenin kendi dosyalarını okur (open_basedir). WP-CLI ve cron işleri etkilenmez.
    - yükleme ve önbellek dizinlerindeki betikler (uploads/, files/, media/, cache/, tmp/)
      403 ile reddedilir; böylece yüklenen bir .php asla çalışmaz.
    - sitenin kullanıcısı bu makinede yalnızca DNS'e, web sunucusuna, MariaDB'ye, Redis'e ve
      sitenin kendi uygulamasına erişir - WebAdmin paneline, SSH'ye ya da dinleyen başka bir
      şeye erişemez.

  --allow-exec         bu site için süreç çalıştırmaya ve open_basedir'e dokunulmaz
                       (exec/proc_open gerektiren bir uygulama: bazı eklentiler, kuyruk worker'ları)
  --allow-upload-php   bu site için yükleme dizinlerindeki betiklerin çalışmasına izin verilir
  --firewall on|off    yalnızca site güvenlik duvarı açılır ya da kapatılır
EOF
    return 0
  fi
  cat <<'EOF'
Usage: lomp harden <domain>|--all [--allow-exec] [--allow-upload-php]
       lomp harden status
       lomp harden --firewall on|off

  Limits what a PHP shell dropped into a site can do:
    - PHP cannot start processes (exec, shell_exec, system, proc_open, popen ...) and reads
      only the site's own files (open_basedir). WP-CLI and cron jobs are not affected.
    - scripts in upload and cache directories (uploads/, files/, media/, cache/, tmp/) are
      refused with 403, so an uploaded .php never runs.
    - the site's user reaches only DNS, the web server, MariaDB, Redis and the site's own
      application on this machine - not the WebAdmin panel, SSH or anything else that listens.

  --allow-exec         leave process execution and open_basedir alone for this site (an
                       application that needs exec/proc_open: some plugins, queue workers)
  --allow-upload-php   let scripts in upload directories run for this site
  --firewall on|off    only switch the site firewall
EOF
}

lib_harden_status() {
  local d="" fw="off"
  if lib_sitefw_enabled; then if lib_sitefw_loaded; then fw="on"; else fw="on, but NOT loaded"; fi; fi
  lib_tr "Site firewall: ${fw}"; printf '%s\n\n' "$LIB_TR"
  lib_tprintf '%-34s %-10s %-22s %s\n' "SITE" "MODE" "PROCESS EXECUTION" "SCRIPTS IN UPLOAD DIRS"
  while read -r d; do
    [[ -n "$d" ]] || continue
    lib_domain_state_load "$d" || continue
    case "$D_MODE" in
      php)       lib_tprintf '%-34s %-10s %-22s %s\n' "$d" "$D_MODE" "${D_SEC_EXEC:-not decided}" "${D_SEC_UPLOAD:-not decided}" ;;
      wordpress) lib_tprintf '%-34s %-10s %-22s %s\n' "$d" "$D_MODE" "${D_SEC_EXEC:-not decided}" "blocked (wp-content/uploads)" ;;
      *)         lib_tprintf '%-34s %-10s %-22s %s\n' "$d" "$D_MODE" "-" "-" ;;
    esac
  done < <(lib_domains_list)
  return 0
}

_harden_code() { lib_http_code "http://127.0.0.1/" -H "Host: ${1}"; }

lib_harden_main() {
  local a="" all=0 exec_mode="blocked" upload_mode="blocked" fw="" d="" before="" after=""
  local -a targets=() sites=() broke=()
  local -A code_before=()
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      status) lib_harden_status; return 0 ;;
      --all) all=1 ;;
      --allow-exec) exec_mode="allowed" ;;
      --allow-upload-php) upload_mode="allowed" ;;
      --firewall) fw="${1:-}"; shift || true
                  [[ "$fw" == "on" || "$fw" == "off" ]] || lib_die "--firewall takes on or off" "" "lomp harden --firewall on" ;;
      -h|--help|help) lib_harden_usage; return 0 ;;
      -*) lib_die "Unknown option for harden: ${a}" "" "lomp harden --help" ;;
      *) targets+=("${a,,}") ;;
    esac
  done
  lib_require_tools
  lib_require_installed
  if [[ -n "$fw" && $all -eq 0 && ${#targets[@]} -eq 0 ]]; then
    if [[ "$fw" == "on" ]]; then
      if lib_sitefw_enable; then lib_ok "Site firewall on: a site's user reaches only ports ${SITEFW_TCP_PORTS} and its own application on this machine"; fi
    else lib_sitefw_disable; lib_ok "Site firewall off"; fi
    return 0
  fi
  if (( all )); then
    ((${#targets[@]} == 0)) || lib_die "Give a domain or --all, not both" "" "lomp harden --all"
    while read -r d; do [[ -n "$d" ]] && targets+=("$d"); done < <(lib_domains_list)
  fi
  ((${#targets[@]})) || { lib_harden_usage; return 0; }
  # What was typed is checked. With --all the names are the registry's own and are taken as
  # they come, the way fix-owner and scan take them: a state directory whose name is no domain
  # name - "restore" took any name until 1.0.87 - would otherwise stop the run here, before a
  # single site was hardened.
  if (( ! all )); then
    for d in "${targets[@]}"; do
      lib_domain_arg_ok "$d" || lib_die "Invalid domain name '${d}'" "" "lomp list"
      lib_domain_registered "$d" || lib_die "Site ${d} is not registered" "" "lomp list"
    done
  fi

  lib_ols_is_installed || lib_die "OpenLiteSpeed is not installed on this server" "" "run 'lompstack install' first"
  lib_system_profile
  HARDEN_PHP_CHANGED=""
  lib_ols_change_begin
  for d in "${targets[@]}"; do
    lib_domain_state_load "$d" || continue
    if [[ "$D_MODE" != "php" && "$D_MODE" != "wordpress" ]]; then
      lib_info "${d}: no PHP runs here (${D_MODE}); only the site firewall applies to it"
      continue
    fi
    sites+=("$d")
    (( OPT_DRY_RUN )) || code_before["$d"]="$(_harden_code "$d")"
    D_SEC_EXEC="$exec_mode"; D_SEC_UPLOAD="$upload_mode"
    lib_domain_state_save
    lib_ols_vhconf_write "$d"
  done
  if (( OLS_PENDING_RELOAD || ! OPT_DRY_RUN )); then lib_ols_change_commit "site hardening"; fi
  for d in "${sites[@]}"; do
    lib_domain_state_load "$d" || continue
    # a changed ini, or a vhost that now points PHP at one: either way only a new lsphp reads it
    lib_harden_php_restart "$D_USER"
    if (( OPT_DRY_RUN )); then
      lib_info "[dry-run] ${d}: process execution would be ${exec_mode}, scripts in upload directories ${upload_mode}"
      continue
    fi
    before="${code_before[$d]}"; after="$(_harden_code "$d")"
    if [[ "$before" =~ ^[23] && ! "$after" =~ ^[23] ]]; then broke+=("${d} (HTTP ${before} -> ${after})")
    else lib_ok "${d}: process execution ${exec_mode}, scripts in upload directories ${upload_mode} (HTTP ${after})"; fi
  done
  if ((${#broke[@]})); then
    lib_warn "These sites answered before and do not now: ${broke[*]}"
    lib_note "Their error log says which function they miss (lomp logs <domain>). To give one site process execution back: lomp harden <domain> --allow-exec"
  fi

  if [[ "$fw" != "off" ]]; then
    if lib_sitefw_enabled && (( ! OPT_DRY_RUN )); then lib_sitefw_regen; lib_ok "Site firewall is on"
    elif lib_sitefw_enable && (( ! OPT_DRY_RUN )); then
      lib_ok "Site firewall on: a site's user reaches only ports ${SITEFW_TCP_PORTS} and its own application on this machine"
    fi
  else
    lib_sitefw_disable
  fi
  ((${#broke[@]} == 0))
}
