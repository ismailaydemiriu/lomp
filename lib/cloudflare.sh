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
#  Origin lock: the web ports answer Cloudflare and nobody else
# =============================================================================
# With the sites behind Cloudflare, anyone who learns the server's address can still reach the
# origin directly and walk around the edge - its WAF, its rate limits, its bot rules. Locking
# 80 and 443 to Cloudflare's own ranges closes that door. It also closes HTTP-01, so this is
# only offered where a token is stored and certificates can be issued over DNS-01 instead.
CF_UFW_COMMENT="lompstack cloudflare origin"

lib_cf_origin_locked() { [[ "$(lib_manifest_get '.cloudflare.origin_lock')" == "true" ]]; }

# How many ranges are in the list. grep -c prints 0 AND exits 1 when it counts nothing, so a
# "|| printf 0" fallback would print the number twice.
_cf_ips_count() {
  local n=""
  n="$(grep -vc '^#' "$CF_IPS_FILE" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# The ranges themselves, one per line.
_cf_ips_list() { grep -v '^#' "$CF_IPS_FILE" 2>/dev/null || true; }

# UFW rule numbers of the lock, highest first (deleting by number renumbers everything below).
_cf_ufw_lock_rules() {
  lib_have ufw || return 0
  ufw status numbered 2>/dev/null \
    | grep -F "$CF_UFW_COMMENT" \
    | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' \
    | sort -rn || true
}

# The same rules with the range each one names: "<number> <cidr>", highest number first.
_cf_ufw_lock_rule_ranges() {
  lib_have ufw || return 0
  ufw status numbered 2>/dev/null \
    | grep -F "$CF_UFW_COMMENT" \
    | sed -E 's/^\[[[:space:]]*([0-9]+)\][^#]*[[:space:]]([0-9a-fA-F.:]+\/[0-9]+)[[:space:]]+#.*/\1 \2/' \
    | grep -E '^[0-9]+ ' \
    | sort -rn || true
}

# Rules on 80 or 443 that are not the plain "open to everyone" ones and not the lock's own.
# They belong to the operator, and the lock is about to delete them.
_cf_ufw_foreign_web_rules() {
  lib_have ufw || return 0
  ufw status 2>/dev/null \
    | grep -E '^(80|443|80,443)/(tcp|udp)' \
    | grep -vF "$CF_UFW_COMMENT" \
    | grep -viE '[[:space:]]Anywhere[[:space:]]*(\(v6\))?[[:space:]]*$' || true
}

lib_cf_origin_unlock() {
  local n="" count=0 left=""
  lib_have ufw || return 0
  if (( OPT_DRY_RUN )); then lib_info "[dry-run] would open 80 and 443 to everyone again"; return 0; fi
  # the open rules go in first: between deleting the lock and opening the ports the sites
  # would be unreachable, and a failure in between would leave them that way
  lib_ufw_rule allow 80/tcp
  lib_ufw_rule allow 443/tcp
  lib_ufw_rule allow 443/udp
  while read -r n; do
    [[ -n "$n" ]] || continue
    lib_run ufw --force delete "$n" || lib_warn "could not delete UFW rule ${n}"
    count=$((count + 1))
  done < <(_cf_ufw_lock_rules)
  lib_manifest_set '.cloudflare.origin_lock' 'false'
  left="$(_cf_ufw_lock_rules | wc -l | tr -d ' ')"
  (( left == 0 )) || lib_warn "${left} Cloudflare rule(s) could not be deleted; they allow, so the ports are open, but 'ufw status numbered' will show them"
  lib_ok "The web ports are open to everyone again (${count} Cloudflare rule(s) removed)"
  lib_note "Certificates can use HTTP-01 again; nothing else changes"
  return 0
}

# Certificates that still renew over HTTP-01. With the origin locked, Let's Encrypt reaches
# port 80 only through Cloudflare, so a name that is not proxied - every mail name is not,
# deliberately - stops renewing. Named here because certbot will not say so until it fails.
_cf_webroot_lineages() {
  local f=""
  for f in /etc/letsencrypt/renewal/*.conf; do
    [[ -e "$f" ]] || continue
    grep -qE '^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*webroot' "$f" 2>/dev/null || continue
    f="${f##*/}"
    printf '%s\n' "${f%.conf}"
  done
}

lib_cf_origin_lock() {
  local r="" n=0 foreign="" stale=""
  lib_have ufw || lib_die "UFW is not installed" "" "the origin lock is built on it"
  [[ -n "$(lib_cf_token)" ]] || lib_die "The origin lock needs a Cloudflare API token first" \
    "with 80 closed to everyone but Cloudflare, Let's Encrypt cannot answer an HTTP-01 challenge; certificates have to come over DNS-01" \
    "printf '%s' \"\$TOKEN\" | lomp install --cf-api-token -"
  CF_LOCK_RENEWING=1 lib_cf_ips_ensure      # the refresh must not re-lock behind the question below
  lib_warn "After this, only Cloudflare can reach ports 80 and 443 on this server."
  lib_note "Every site must be proxied (orange cloud) or it stops answering. SSH, mail and the"
  lib_note "WebAdmin port are not touched. Undo it with: lomp firewall --web-open"
  foreign="$(_cf_ufw_foreign_web_rules)"
  if [[ -n "$foreign" ]]; then
    lib_warn "These firewall rules of yours on 80/443 are removed by the lock and not restored:"
    printf '%s\n' "$foreign" | sed 's/^/        /'
  fi
  stale="$(_cf_webroot_lineages)"
  if [[ -n "$stale" ]]; then
    lib_warn "These certificates still renew over HTTP-01, which the lock closes:"
    printf '%s' "$stale" | tr '\n' ' ' | sed 's/^/        /;s/$/\n/'
    lib_note "        re-issue each one afterwards: lomp renew-ssl <domain> --force, or lomp mail cert"
  fi
  lib_confirm "Lock the web ports to Cloudflare?" n || lib_die "Nothing was changed" "" ""
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would allow 80/443 from $(_cf_ips_count) Cloudflare ranges and remove the open rules"
    return 0
  fi
  # The ranges are read and allowed BEFORE the open rules are deleted. The other way round,
  # an empty list or a UFW that rejects every rule would leave 80 and 443 answering nobody -
  # every site on the machine offline, and no way in over HTTP to see why.
  local -a ranges=()
  while read -r r; do
    [[ -n "$r" && "$r" != \#* ]] || continue
    ranges+=("$r")
  done < <(_cf_ips_list)
  (( ${#ranges[@]} > 0 )) || lib_die "No Cloudflare ranges to allow" "the list in ${CF_IPS_FILE} is empty" "lomp update-cf-ips"
  for r in "${ranges[@]}"; do
    if lib_ufw_rule allow from "$r" to any port 80,443 proto tcp comment "$CF_UFW_COMMENT"; then
      n=$((n + 1))
    else
      lib_warn "could not allow ${r}"
    fi
    lib_ufw_rule allow from "$r" to any port 443 proto udp comment "$CF_UFW_COMMENT" || true
  done
  (( n > 0 )) || lib_die "Not one Cloudflare range could be allowed" \
    "UFW refused every rule, so the ports were left open" "ufw status, then try again"
  # a partly applied lock is not a lock: the edge addresses that were refused reach nothing
  (( n == ${#ranges[@]} )) || lib_warn "only ${n} of ${#ranges[@]} ranges could be allowed - the rest of Cloudflare's edge now gets no answer (IPv6 disabled in /etc/default/ufw?)"
  # only now: a range rule and an "anywhere" rule together are still open to everyone
  lib_ufw_delete_port_rules 80
  lib_ufw_delete_port_rules 443
  # and HTTP/3: OpenLiteSpeed answers QUIC on 443/udp, which lib_ufw_delete_port_rules (TCP
  # by name) leaves alone. Deleting it by rule spec takes the "Anywhere" rule and not the
  # per-range ones just added.
  lib_run ufw --force delete allow 443/udp || true
  lib_manifest_set '.cloudflare.origin_lock' 'true'
  lib_ok "Ports 80 and 443 now answer ${n} Cloudflare range(s) only"
  lib_note "Certificates from here on are issued over DNS-01; the weekly IP refresh keeps these rules in step"
  return 0
}

# Bring the rules in step with a changed range list. The ports are never opened in between:
# what is new is allowed first, and only the lock's own rules whose range is gone are removed.
lib_cf_origin_relock() {
  local r="" num="" cidr="" added=0 removed=0 list=""
  lib_have ufw || return 0
  list="$(_cf_ips_list)"
  [[ -n "$list" ]] || { CF_LAST_ERROR="the Cloudflare range list is empty"; return 1; }
  while read -r r; do
    [[ -n "$r" ]] || continue
    lib_ufw_rule allow from "$r" to any port 80,443 proto tcp comment "$CF_UFW_COMMENT" || { lib_warn "could not allow ${r}"; continue; }
    lib_ufw_rule allow from "$r" to any port 443 proto udp comment "$CF_UFW_COMMENT" || true
    added=$((added + 1))
  done <<<"$list"
  (( added > 0 )) || { CF_LAST_ERROR="not one range could be allowed"; return 1; }
  while read -r num cidr; do
    [[ -n "$num" && -n "$cidr" ]] || continue
    grep -qxF "$cidr" <<<"$list" && continue
    lib_run ufw --force delete "$num" || lib_warn "could not delete UFW rule ${num}"
    removed=$((removed + 1))
  done < <(_cf_ufw_lock_rule_ranges)
  lib_log_write INFO "origin lock renewed: ${added} range(s) allowed, ${removed} stale rule(s) removed"
  return 0
}

lib_cf_firewall_main() {
  local a="${1:-status}"
  case "$a" in
    --web-cloudflare-only|lock)  lib_cf_origin_lock ;;
    --web-open|open)             lib_cf_origin_unlock ;;
    status|--status|"")
      if lib_cf_origin_locked; then
        lib_print_kv "Web ports" "Cloudflare only ($(_cf_ufw_lock_rules | wc -l | tr -d ' ') rules)"
      else
        lib_print_kv "Web ports" "open to everyone (lomp firewall --web-cloudflare-only closes them to all but Cloudflare)"
      fi
      lib_print_kv "Cloudflare ranges" "$(_cf_ips_count) (refreshed $(lib_manifest_get '.cloudflare.ips_checked'))"
      ;;
    *) lib_die "Unknown firewall command: ${a}" "" "lomp firewall --web-cloudflare-only | --web-open | status" ;;
  esac
  return 0
}

# =============================================================================
#  DNS records through the API
# =============================================================================
# Everything below is written so that a dry run sends nothing at all, and so that lompstack
# only ever removes what it created: every record it writes carries a comment naming it.
CF_RECORD_TAG="${CF_RECORD_TAG:-lompstack:mail}"
CF_LAST_ERROR=""
declare -gA CF_ZONE_CACHE=()

# The zone a name belongs to. "mail.shop.example.com" may live in a zone called
# shop.example.com or example.com, so the labels are walked from the longest suffix down and
# the first zone this token can see wins.
lib_cf_zone_id() {   # name -> zone id on stdout
  local name="${1,,}" try="" out="" id=""
  CF_LAST_ERROR=""
  [[ -n "${CF_ZONE_CACHE[$name]:-}" ]] && { printf '%s' "${CF_ZONE_CACHE[$name]}"; return 0; }
  try="$name"
  while [[ "$try" == *.*.* || "$try" == *.* ]]; do
    out="$(_cf_api GET "/zones?name=${try}&status=active&per_page=1" || true)"
    id="$(jq -r '.result[0].id // empty' <<<"${out:-}" 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
      CF_ZONE_CACHE["$name"]="$id"
      printf '%s' "$id"
      return 0
    fi
    [[ "$try" == *.*.* ]] || break
    try="${try#*.}"
  done
  CF_LAST_ERROR="no Cloudflare zone for ${name} that this token can see"
  return 1
}

# What the API said went wrong. An empty join is still an empty string, and jq's // only
# catches null and false, so the fallback has to be chosen here and not in the filter.
_cf_error() {   # response-body [fallback]
  local msg=""
  msg="$(jq -r '[.errors[]?.message] | join("; ")' <<<"${1:-}" 2>/dev/null || true)"
  [[ -n "$msg" ]] || msg="${2:-the Cloudflare API did not answer}"
  printf '%s' "$msg"
}

# Every record of one type and name, as a JSON array.
# A failed call is NOT an empty answer: it returns non-zero. "There is nothing at this name"
# is exactly the reply that makes a caller add a second SPF or a second MX record, so one
# dropped request must never be able to say it.
lib_cf_records() {   # zone type name
  local z="$1" t="$2" n="$3" out="" res=""
  CF_LAST_ERROR=""
  out="$(_cf_api GET "/zones/${z}/dns_records?type=${t}&name=${n}&per_page=100" || true)"
  res="$(jq -c 'select(.success == true) | .result | select(type == "array")' <<<"${out:-}" 2>/dev/null || true)"
  if [[ -z "$res" ]]; then
    CF_LAST_ERROR="$(_cf_error "$out" "the record list could not be read")"
    return 1
  fi
  printf '%s' "$res"
  return 0
}

# Create or change one record. The body goes through a file so that nothing of it - and no
# token - is ever visible in the process list.
lib_cf_record_write() {   # zone [id] type name content [prio] [proxied]
  local z="$1" id="$2" t="$3" n="$4" c="$5" prio="${6:-}" proxied="${7:-false}" body="" out="" ok=""
  body="$(lib_mktemp)"
  if [[ "$t" == "MX" ]]; then
    jq -n --arg t "$t" --arg n "$n" --arg c "$c" --argjson p "${prio:-10}" --arg cm "$CF_RECORD_TAG" \
      '{type:$t, name:$n, content:$c, priority:$p, ttl:300, comment:$cm}' >"$body"
  elif [[ "$t" == "A" || "$t" == "AAAA" ]]; then
    # a proxied record has no TTL of its own - Cloudflare answers for it - and the API takes
    # only 1 ("automatic") there, so the two are chosen together
    jq -n --arg t "$t" --arg n "$n" --arg c "$c" --argjson px "$proxied" --arg cm "$CF_RECORD_TAG" \
      '{type:$t, name:$n, content:$c, ttl:(if $px then 1 else 300 end), proxied:$px, comment:$cm}' >"$body"
  else
    jq -n --arg t "$t" --arg n "$n" --arg c "$c" --arg cm "$CF_RECORD_TAG" \
      '{type:$t, name:$n, content:$c, ttl:300, comment:$cm}' >"$body"
  fi
  if [[ -n "$id" ]]; then out="$(_cf_api PUT "/zones/${z}/dns_records/${id}" "$body" || true)"
  else out="$(_cf_api POST "/zones/${z}/dns_records" "$body" || true)"; fi
  rm -f "$body"
  ok="$(jq -r '.success // false' <<<"${out:-}" 2>/dev/null || printf 'false')"
  if [[ "$ok" != "true" ]]; then
    CF_LAST_ERROR="$(_cf_error "$out" "the API refused the record")"
    return 1
  fi
  return 0
}

lib_cf_record_delete() {   # zone id
  local out="" ok=""
  out="$(_cf_api DELETE "/zones/${1}/dns_records/${2}" || true)"
  ok="$(jq -r 'if .result.id then "true" else (.success // false | tostring) end' <<<"${out:-}" 2>/dev/null || printf 'false')"
  [[ "$ok" == "true" ]] || { CF_LAST_ERROR="$(_cf_error "$out" "the API refused to delete ${2}")"; return 1; }
  return 0
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
  # ...unless this very refresh was started by the lock itself, which would then apply
  # before the operator has answered its own question
  if (( changed )) && [[ -z "${CF_LOCK_RENEWING:-}" ]] && lib_cf_origin_locked; then
    # the ranges moved, so the firewall rules that name them have to move too. Never by
    # unlocking first: that would open the origin to everyone for the length of the rebuild.
    lib_info "Cloudflare ranges changed; renewing the origin lock rules"
    ( CF_LOCK_RENEWING=1; lib_cf_origin_relock ) \
      || lib_warn "the origin lock could not be renewed: ${CF_LAST_ERROR:-see the log} (lomp firewall status)"
  fi
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
      "$(_cf_ips_count)" \
      "$(lib_manifest_get '.cloudflare.ips_updated' | cut -c1-10)" \
      "$( lib_ssl_cf_token_available && printf 'stored' || printf 'none')"
  else
    printf 'disabled'
  fi
}
