#!/usr/bin/env bash
# lib/cloudflare.sh - Cloudflare real client IP (trusted proxy ranges only),
#                     IP list updates, API token storage, fail2ban ban propagation.

CF_IPS_FILE="${STATE_DIR}/cloudflare-ips.conf"
CF_IPV4_URL="https://www.cloudflare.com/ips-v4"
CF_IPV6_URL="https://www.cloudflare.com/ips-v6"
CF_API="https://api.cloudflare.com/client/v4"
CF_F2B_ACTION="/etc/fail2ban/action.d/server-setup-cloudflare.conf"
CF_F2B_AUTH="/etc/fail2ban/lomp-cf-auth.header"

lib_cf_enabled() { [[ "$(lib_manifest_get '.cloudflare.enabled')" == "true" ]]; }
lib_cf_token()   { [[ -s "$CF_INI" ]] && awk -F'=' '/^dns_cloudflare_api_token/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$CF_INI" || true; }
lib_cf_account_id() { lib_manifest_get '.cloudflare.account_id'; }

# Every Cloudflare API call goes through here. The token reaches curl in a configuration read
# from standard input, never as an argument: /proc/<pid>/cmdline is world-readable, so a token
# on a command line is a token every site user of this server can read.
# CF_API_TOKEN_OVERRIDE covers the calls made before the token has been stored.
_cf_api() {   # METHOD PATH [body-file]   -> response body on stdout
  local method="$1" path="$2" body="${3:-}" token=""
  token="${CF_API_TOKEN_OVERRIDE:-$(lib_cf_token)}"
  [[ -n "$token" ]] || return 1
  {
    printf 'silent\nshow-error\nmax-time = 20\n'
    printf 'request = "%s"\n' "$method"
    printf 'url = "%s%s"\n' "$CF_API" "$path"
    printf 'header = "Authorization: Bearer %s"\n' "$token"
    printf 'header = "Content-Type: application/json"\n'
    if [[ -n "$body" ]]; then printf 'data-binary = "@%s"\n' "$body"; fi
  } | curl -K - 2>/dev/null
}

# =============================================================================
#  IP ranges
# =============================================================================
# Download both lists into a temp file (validated). Prints the path; returns 1 on failure.
lib_cf_ips_download() {
  local tmp="" n=""
  tmp="$(lib_mktemp)"
  {
    curl -fsSL --retry 2 --max-time 20 "$CF_IPV4_URL" && printf '\n' && curl -fsSL --retry 2 --max-time 20 "$CF_IPV6_URL" && printf '\n'
  } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  sed -i 's/\r$//; /^[[:space:]]*$/d' "$tmp"
  if grep -qvE '^([0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}|[0-9a-fA-F:]+/[0-9]{1,3})$' "$tmp"; then rm -f "$tmp"; return 1; fi
  n="$(wc -l <"$tmp" | tr -d ' ')"
  (( n < 8 )) && { rm -f "$tmp"; return 1; }
  printf '%s' "$tmp"
}

# Refresh the stored list; apply to OLS when Cloudflare mode is enabled.
lib_cf_update_ips() {
  local tmp="" cur="" new="" changed=0
  if ! tmp="$(lib_cf_ips_download)" || [[ -z "$tmp" ]]; then
    lib_error "Cloudflare IP list download failed; keeping the existing list ($( [[ -s "$CF_IPS_FILE" ]] && printf 'updated %s' "$(lib_manifest_get '.cloudflare.ips_updated')" || printf 'none'))"
    lib_notify_send "Cloudflare IP update failed on $(hostname)" "Could not download ${CF_IPV4_URL} / ${CF_IPV6_URL}. The previous list is still in use." || true
    return 1
  fi
  cur="$( [[ -s "$CF_IPS_FILE" ]] && grep -v '^#' "$CF_IPS_FILE" | sort || true)"
  new="$(sort "$tmp")"
  if [[ "$cur" != "$new" ]]; then
    { printf '# Cloudflare IP ranges - fetched %s from %s and %s\n' "$(lib_iso_now)" "$CF_IPV4_URL" "$CF_IPV6_URL"; cat "$tmp"; } \
      | lib_write_file "$CF_IPS_FILE" 0600 root:root
    changed=1
    lib_manifest_set '.cloudflare.ips_updated' "$(lib_iso_now)"
    lib_ok "Cloudflare IP list updated ($(wc -l <"$tmp" | tr -d ' ') ranges)"
  else
    lib_ok "Cloudflare IP list unchanged ($(wc -l <"$tmp" | tr -d ' ') ranges)"
  fi
  rm -f "$tmp"
  lib_manifest_set '.cloudflare.ips_checked' "$(lib_iso_now)"
  if (( changed )) && lib_cf_enabled && lib_ols_is_installed; then
    lib_ols_change_begin
    lib_ols_tx_begin
    lib_cf_tx_apply 1
    lib_ols_tx_commit
    lib_ols_change_commit "Cloudflare trusted proxy list"
  fi
  return 0
}

lib_cf_ips_ensure() {
  [[ -s "$CF_IPS_FILE" ]] && return 0
  (( OPT_DRY_RUN )) && { lib_info "[dry-run] would download the Cloudflare IP ranges"; return 0; }
  lib_cf_update_ips || lib_die "Cloudflare IP ranges unavailable" "download failed" "check connectivity to www.cloudflare.com and retry"
}

# All given IPs inside Cloudflare ranges?  lib_cf_ips_are_cloudflare "1.2.3.4 5.6.7.8"
lib_cf_ips_are_cloudflare() {
  local ips="$1" ip="" list="$CF_IPS_FILE" tmp="" any=0
  if [[ ! -s "$list" ]]; then
    tmp="$(lib_cf_ips_download 2>/dev/null || true)"
    [[ -n "$tmp" ]] || return 1
    list="$tmp"
  fi
  for ip in $ips; do
    any=1
    lib_ip_in_cidr_list "$ip" "$list" || { [[ -n "$tmp" ]] && rm -f "$tmp"; return 1; }
  done
  [[ -n "$tmp" ]] && rm -f "$tmp"
  (( any ))
}

lib_cf_is_proxied() {   # domain -> 0 when all A/AAAA records are Cloudflare
  local a=""; a="$(lib_resolve A "$1" | tr '\n' ' ')$(lib_resolve AAAA "$1" | tr '\n' ' ')"
  [[ -n "${a// /}" ]] || return 1
  lib_cf_ips_are_cloudflare "$a"
}

# Inside an open OLS transaction: trusted ranges + useIpInProxyHeader.
lib_cf_tx_apply() {   # enabled(0/1)
  local enabled="${1:-1}" allow="ALL" cidr=""
  if (( enabled )) && [[ -s "$CF_IPS_FILE" ]]; then
    while read -r cidr; do
      [[ -z "$cidr" || "$cidr" == \#* ]] && continue
      allow+=", ${cidr}T"
    done <"$CF_IPS_FILE"
    lib_ols_tx_top_set useIpInProxyHeader 2
  else
    lib_ols_tx_top_set useIpInProxyHeader 0
  fi
  if ! lib_ols_tx_block_exists accessControl ""; then
    lib_ols_tx_block_put accessControl "" <<<$'accessControl  {\n  allow                   ALL\n}'
  fi
  lib_ols_tx_block_set accessControl "" allow "$allow"
}

# =============================================================================
#  Enable / token / fail2ban
# =============================================================================
lib_cf_enable() {
  lib_cf_ips_ensure
  if lib_ols_is_installed; then
    lib_ols_change_begin
    lib_ols_tx_begin
    lib_cf_tx_apply 1
    lib_ols_tx_commit
    lib_ols_change_commit "enable Cloudflare real-IP mode"
  fi
  lib_manifest_set_json '.cloudflare.enabled' true
  lib_cf_schedule
  lib_ok "Cloudflare mode enabled: X-Forwarded-For/CF-Connecting-IP trusted only from Cloudflare ranges (useIpInProxyHeader 2)"
  lib_note "Set the Cloudflare SSL mode to 'Full (strict)' once certificates are in place."
}

lib_cf_schedule() {
  lib_cron_set cfips "20 4 * * 0 root ${BIN_LINK} update-cf-ips --quiet"
}

# Store the API token (certbot dns-cloudflare format, 0600) and discover the account id.
lib_cf_store_token() {   # token
  local token="$1" verify="" acct=""
  [[ "$token" =~ ^[A-Za-z0-9_-]{20,}$ ]] || lib_die "Cloudflare API token looks invalid" "unexpected characters/length" "create a token at https://dash.cloudflare.com/profile/api-tokens"
  if (( ! OPT_DRY_RUN )); then
    verify="$(CF_API_TOKEN_OVERRIDE="$token" _cf_api GET /user/tokens/verify | jq -r '.result.status // "invalid"' 2>/dev/null || printf 'error')"
    if [[ "$verify" != "active" ]]; then
      lib_die "Cloudflare API token verification failed (${verify})" "token inactive/invalid or API unreachable" "check the token and its permissions (Zone:DNS:Edit, Account:Firewall Access Rules:Edit)"
    fi
    mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR"
    # umask, not a chmod afterwards: the token must never exist in a world-readable file, not
    # even for the instant between the two
    (umask 077; printf '# Cloudflare API token (certbot dns-cloudflare / fail2ban) - stored %s\ndns_cloudflare_api_token = %s\n' "$(lib_iso_now)" "$token" >"$CF_INI")
    chmod 0600 "$CF_INI"
    acct="$(CF_API_TOKEN_OVERRIDE="$token" _cf_api GET '/accounts?per_page=1' | jq -r '.result[0].id // empty' 2>/dev/null || true)"
    if [[ -n "$acct" ]]; then
      lib_manifest_set '.cloudflare.account_id' "$acct"
    else
      lib_warn "Could not determine the Cloudflare account id (token lacks account read permission?); fail2ban->Cloudflare bans disabled"
    fi
  else
    lib_info "[dry-run] would verify and store the Cloudflare API token in ${CF_INI}"
  fi
  lib_manifest_set_json '.cloudflare.api_token' true
  lib_apt_install python3-certbot-dns-cloudflare || lib_warn "python3-certbot-dns-cloudflare not installed; DNS-01 unavailable"
  lib_cf_fail2ban_action_write
  lib_ok "Cloudflare API token stored (${CF_INI}, 0600)"
}

# The Authorization header for the fail2ban action, in a file only root can read. A ban would
# otherwise run "curl -H 'Authorization: Bearer <token>'", and that command line is readable by
# every user on the server for as long as the ban takes.
lib_cf_f2b_auth_write() {
  local token=""
  token="$(lib_cf_token)"
  [[ -n "$token" ]] || return 0
  lib_mkdir "$(dirname "$CF_F2B_AUTH")" 0755 root:root
  printf 'Authorization: Bearer %s\n' "$token" | lib_write_file "$CF_F2B_AUTH" 0600 root:root secret
  return 0
}

# fail2ban action: account-level IP Access Rules through the API token.
lib_cf_fail2ban_action_write() {
  lib_pkg_installed fail2ban || return 0
  lib_cf_f2b_auth_write
  {
    cat <<'EOF'
# Managed by lompstack - ban/unban at the Cloudflare edge (account-level IP Access Rules)
# Requires an API token with "Account - Firewall Access Rules: Edit".
# The token is read from the header file below, never passed as an argument: a command line is
# world-readable through /proc while it runs.
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = curl -s -o /dev/null -X POST "<_cf_api_url>" \
              -H @<cfauth> -H "Content-Type: application/json" \
              --data '{"mode":"block","configuration":{"target":"<cftarget>","value":"<ip>"},"notes":"<notes>"}'
actionunban = id=$(curl -s -X GET "<_cf_api_url>?configuration.target=<cftarget>&configuration.value=<ip>&notes=<notes>&per_page=1" \
                -H @<cfauth> -H "Content-Type: application/json" | jq -r '.result[0].id // empty'); \
              if [ -n "$id" ]; then curl -s -o /dev/null -X DELETE "<_cf_api_url>/$id" -H @<cfauth>; fi

[Init]
EOF
    printf 'cfauth = %s\ncfaccount =\ncftarget = ip\nnotes = Fail2Ban-server-setup\n' "$CF_F2B_AUTH"
    printf '_cf_api_url = %s/accounts/<cfaccount>/firewall/access_rules/rules\n\n[Init?family=inet6]\ncftarget = ip6\n' "$CF_API"
  } | lib_write_file "$CF_F2B_ACTION" 0644 root:root
  return 0
}

# Extra "action" lines for web jails when bans must also reach Cloudflare. Only the account id
# goes into the jail file; the token stays in the 0600 header file.
lib_cf_fail2ban_action_lines() {
  local token="" acct=""
  token="$(lib_cf_token)"; acct="$(lib_cf_account_id)"
  [[ -n "$token" && -n "$acct" && -f "$CF_F2B_ACTION" ]] || return 0
  printf 'action = %%(action_)s\n         server-setup-cloudflare[cfaccount="%s"]\n' "$acct"
}

# =============================================================================
#  update-cf-ips command / status
# =============================================================================
lib_cf_update_main() {
  lib_require_tools
  lib_require_installed
  lib_cf_update_ips
}

lib_cf_status_line() {
  if lib_cf_enabled; then
    printf 'enabled (ranges: %s, updated: %s, token: %s)' \
      "$( [[ -s "$CF_IPS_FILE" ]] && grep -cv '^#' "$CF_IPS_FILE" || printf 0)" \
      "$(lib_manifest_get '.cloudflare.ips_updated' | cut -c1-10)" \
      "$( lib_ssl_cf_token_available && printf 'stored' || printf 'none')"
  else
    printf 'disabled'
  fi
}
