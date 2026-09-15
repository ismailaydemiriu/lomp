#!/usr/bin/env bash
# lib/proxy.sh - path proxies: publish an application under a path of an existing site,
#                e.g. example.com/api/ -> 127.0.0.1:3001, next to WordPress, PHP or static
#                files. State lives in .proxies[] of domain.json and is written only here
#                (lib_json_set), never by lib_domain_state_save, so its merge cannot bring a
#                removed entry back. lib_ols_render_vhconf renders it from D_PATH_PROXIES.

lib_proxy_usage() {
  cat <<'EOF'
Usage: setup.sh proxy list [<domain>] [--json]
       setup.sh proxy add <domain> <path> <host:port>
       setup.sh proxy remove <domain> <path>
  <path>       URL prefix such as /api/ (a missing slash is added). The application gets the
               full path, prefix included, so its routes must live under that prefix.
  <host:port>  where the application listens, e.g. 127.0.0.1:3001
WebSocket upgrades on the path are passed through as well.
EOF
}

lib_proxy_main() {
  local action="${1:-list}"
  if (($# > 0)); then shift; fi
  case "$action" in
    list)           lib_proxy_list "$@" ;;
    add)            lib_proxy_add "$@" ;;
    remove)         lib_proxy_remove "$@" ;;
    help|-h|--help) lib_proxy_usage ;;
    *) lib_proxy_usage >&2; lib_die "Unknown proxy action '${action}'" "" "setup.sh proxy list | add | remove" ;;
  esac
}

# "/api" -> "/api/". Segments are letters, digits and - _ . ~ and never start with a dot, so
# "/" itself, "/.well-known/" and dotfile paths (which the vhost refuses anyway) are rejected.
lib_proxy_path_normalize() {   # path -> normalized path, or status 1
  local p="${1:-}"
  [[ "$p" == /* ]] || p="/${p}"
  [[ "$p" == */ ]] || p="${p}/"
  [[ "$p" =~ ^(/[A-Za-z0-9_~-][A-Za-z0-9._~-]*)+/$ ]] || return 1
  printf '%s' "$p"
}

lib_proxy_target_valid() {   # host:port
  local t="${1:-}" port=""
  [[ "$t" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || return 1
  port="${t##*:}"
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

# OpenLiteSpeed does not make proxy handler names unique per virtual host and silently reuses
# an existing one, so the name carries the site ident and a hash of the path.
lib_proxy_handler_name() {   # ident path
  local h=""
  h="$(printf '%s' "$2" | sha1sum | cut -c1-8)"
  printf '%s_px_%s' "$1" "$h"
}

# Why this path cannot be proxied on the site currently in D_* (prints it), or status 1.
lib_proxy_conflict() {   # path
  local p="$1" s=""
  if [[ "$D_MODE" == "proxy" ]]; then
    for s in ${D_STATIC_PATHS//,/ }; do
      if [[ "$s" == "$p" ]]; then printf 'it is one of the static paths this proxy site serves from disk'; return 0; fi
    done
  fi
  return 1
}

lib_proxy_state_lines() {   # domain -> "path target" per line
  local f=""
  f="$(lib_domain_json "$1")"
  [[ -s "$f" ]] || return 0
  jq -r '(.proxies // [])[] | "\(.path) \(.target)"' "$f" 2>/dev/null || true
}

lib_proxy_state_set() {   # domain path target
  lib_json_set "$(lib_domain_json "$1")" \
    '.proxies = (((.proxies // []) | map(select(.path != $p))) + [{path: $p, target: $t}] | sort_by(.path))' \
    --arg p "$2" --arg t "$3"
}

lib_proxy_state_del() {   # domain path
  lib_json_set "$(lib_domain_json "$1")" '.proxies = ((.proxies // []) | map(select(.path != $p)))' --arg p "$2"
}

# The state file is restored from a copy if applying the new configuration fails; the
# OpenLiteSpeed side is rolled back by lib_ols_change_begin's own snapshot.
_proxy_state_guard() { lib_domain_state_guard "$@"; }

lib_proxy_add() {
  local domain="${1:-}" raw="${2:-}" target="${3:-}" path="" why="" old="" scheme="http"
  if [[ -z "$domain" || -z "$raw" || -z "$target" || $# -gt 3 ]]; then
    lib_proxy_usage >&2
    lib_die "proxy add needs a domain, a path and a target" "" "setup.sh proxy add example.com /api/ 127.0.0.1:3001"
  fi
  lib_require_tools
  domain="${domain,,}"
  lib_domain_registered "$domain" || lib_die "Site ${domain} is not registered" "" "setup.sh list"
  path="$(lib_proxy_path_normalize "$raw")" || lib_die "Invalid path '${raw}'" \
    "use a URL prefix of letters, digits and - _ . ~ (not / itself, no segment starting with a dot)" \
    "setup.sh proxy add ${domain} /api/ ${target}"
  lib_proxy_target_valid "$target" || lib_die "Invalid target '${target}'" "expected host:port" "setup.sh proxy add ${domain} ${path} 127.0.0.1:3001"
  lib_domain_state_load "$domain"
  why="$(lib_proxy_conflict "$path" || true)"
  [[ -z "$why" ]] || lib_die "Path ${path} cannot be proxied on ${domain}" "$why" "choose another path"
  old="$(printf '%s\n' "$D_PATH_PROXIES" | awk -v p="$path" '$1 == p {print $2; exit}')"
  # in memory first: a dry run renders the new configuration without writing any state
  D_PATH_PROXIES="$( { printf '%s\n' "$D_PATH_PROXIES" | awk -v p="$path" 'NF == 2 && $1 != p'; printf '%s %s\n' "$path" "$target"; } | LC_ALL=C sort )"
  _proxy_state_guard "$domain"
  lib_proxy_state_set "$domain" "$path" "$target"
  lib_domain_apply_config "path proxy ${path} -> ${target} on ${domain}"
  lib_rollback_clear
  if (( D_SSL )); then scheme="https"; fi
  if [[ -n "$old" && "$old" != "$target" ]]; then lib_ok "${scheme}://${domain}${path} now goes to ${target} (was ${old})"
  else lib_ok "${scheme}://${domain}${path} goes to ${target}"; fi
  if (( ! OPT_DRY_RUN )) && ! lib_tcp_open "${target%:*}" "${target##*:}"; then
    lib_warn "Nothing answers on ${target} yet; ${domain}${path} returns 503 until the application listens there"
  fi
  lib_note "The application receives the full path, prefix included: serve its routes under ${path%/}."
  return 0
}

lib_proxy_remove() {
  local domain="${1:-}" raw="${2:-}" path=""
  if [[ -z "$domain" || -z "$raw" || $# -gt 2 ]]; then
    lib_proxy_usage >&2
    lib_die "proxy remove needs a domain and a path" "" "setup.sh proxy remove example.com /api/"
  fi
  lib_require_tools
  domain="${domain,,}"
  lib_domain_registered "$domain" || lib_die "Site ${domain} is not registered" "" "setup.sh list"
  path="$(lib_proxy_path_normalize "$raw")" || lib_die "Invalid path '${raw}'" "" "setup.sh proxy list ${domain}"
  lib_domain_state_load "$domain"
  if ! printf '%s\n' "$D_PATH_PROXIES" | awk -v p="$path" '$1 == p {found = 1} END {exit !found}'; then
    lib_die "${domain} has no path proxy on ${path}" "" "setup.sh proxy list ${domain}"
  fi
  D_PATH_PROXIES="$(printf '%s\n' "$D_PATH_PROXIES" | awk -v p="$path" 'NF == 2 && $1 != p')"
  _proxy_state_guard "$domain"
  lib_proxy_state_del "$domain" "$path"
  lib_domain_apply_config "remove path proxy ${path} on ${domain}"
  lib_rollback_clear
  lib_ok "${domain}${path} is no longer proxied"
  return 0
}

lib_proxy_list() {
  local want="" json=0 a="" d="" p="" t="" state="" n=0 rows="[]"
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --json) json=1 ;;
      -*)     lib_die "Unknown option for proxy list: ${a}" "" "setup.sh proxy list [<domain>] [--json]" ;;
      *)      want="${a,,}" ;;
    esac
  done
  if (( OPT_JSON )); then json=1; fi
  lib_require_tools
  if [[ -n "$want" ]]; then lib_domain_registered "$want" || lib_die "Site ${want} is not registered" "" "setup.sh list"; fi
  if (( json )); then
    while read -r d; do
      [[ -n "$d" ]] || continue
      if [[ -n "$want" && "$d" != "$want" ]]; then continue; fi
      rows="$(jq -c --argjson a "$rows" --arg d "$d" '$a + ((.proxies // []) | map({domain: $d} + .))' "$(lib_domain_json "$d")")"
    done < <(lib_domains_list)
    printf '%s\n' "$rows"
    return 0
  fi
  printf '%s%-28s %-22s %-22s %s%s\n' "$C_BLD" "DOMAIN" "PATH" "TARGET" "APPLICATION" "$C_RST"
  while read -r d; do
    [[ -n "$d" ]] || continue
    if [[ -n "$want" && "$d" != "$want" ]]; then continue; fi
    while read -r p t; do
      [[ -n "$p" ]] || continue
      if lib_tcp_open "${t%:*}" "${t##*:}"; then state="answers"; else state="not listening"; fi
      printf '%-28s %-22s %-22s %s\n' "$d" "$p" "$t" "$state"
      n=$((n + 1))
    done < <(lib_proxy_state_lines "$d")
  done < <(lib_domains_list)
  if (( n == 0 )); then printf '(no path proxies - add one with: setup.sh proxy add example.com /api/ 127.0.0.1:3001)\n'; fi
  return 0
}
