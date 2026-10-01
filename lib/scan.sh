#!/usr/bin/env bash
# lib/scan.sh - scan: looks through a site's PHP files for what a web shell is made of (eval of
#               decoded or request data, commands run from the request, packed code, the names of
#               known shells) and lists the files to open. It reads; it never changes a file.

SCAN_STRONG_TOTAL=0   # files with strong signs, over every site of the run
SCAN_LOOK_TOTAL=0     # files worth a look

# The checks, one line of a file at a time, each reported once per file. Everything runs in
# BEGIN and reads the files with getline: a file that went away after find named it (a cache
# writes and deletes .php files all day) is then one unread file, where mawk would end the
# whole batch on it. A file's name and its text are the site's - an attacker's, in the case
# this command is for - so both are cut down to printable characters before they are printed.
#   P <H|L> <path below the home>            a file with findings, strongest first
#   F <H|L> <line> <what> <the text there>   one finding of that file
#   N <files read> <files that could not be read>
lib_scan_awk() {
  cat <<'SCAN_AWK'
function clean(s) { gsub(/\t/, " ", s); gsub(/[^ -~]/, "?", s); return s }
function name(s)  { gsub(/[\001-\037\177]/, "?", s); gsub(/\302[\200-\237]/, "?", s); return s }
function hit(sev, label, text) {
  if (label in seen) return
  seen[label] = 1
  if (sev == "H") strong = 1
  found[++nf] = sev "\t" fnr "\t" label "\t" clean(substr(text, 1, 100))
}
function check(line,   l, t, n, i, parts) {
  l = tolower(line)
  if (kind == "conf") {
    if (match(l, /auto_(prepend|append)_file/)) hit("L", "a file run before or after every script", substr(line, RSTART))
    if (match(l, /(addhandler|addtype|sethandler).*php/)) hit("L", "file types handed to PHP", substr(line, RSTART))
    return
  }
  if (kind == "other") {
    if (match(l, /<\?(php|=)/)) hit("H", "PHP code in a file that is not named as a script", substr(line, RSTART))
    return
  }
  if (match(l, /c99shell|r57shell|wso ?shell|b374k|filesman([^a-z]|$)|weevely|indoxploit|p0wny|phpspy|alfa ?shell|priv8|hacked by/))
    hit("H", "the name of a known web shell", substr(line, RSTART))
  if (index(l, "(")) {
    if (match(l, /(^|[^a-z0-9_>:$])(eval|assert)[ \t]*\([ \t@]*(base64_decode|gzinflate|gzuncompress|gzdecode|str_rot13|strrev|hex2bin|urldecode|rawurldecode|convert_uudecode)[ \t]*\(/))
      hit("H", "eval of decoded data", substr(line, RSTART))
    if (match(l, /(^|[^a-z0-9_>:$])(eval|assert)[ \t]*\([^;]*\$_(post|get|request|cookie|files|server)/))
      hit("H", "eval of what the request sent", substr(line, RSTART))
    if (match(l, /(^|[^a-z0-9_>:$])(system|exec|shell_exec|passthru|popen|proc_open|pcntl_exec)[ \t]*\([^;]*\$_(post|get|request|cookie)/))
      hit("H", "a command made of what the request sent", substr(line, RSTART))
    if (match(l, /\$_(post|get|request|cookie)[ \t]*\[[^]]*\]\(/))
      hit("H", "a function named by the request", substr(line, RSTART))
    if (match(l, /(^|[^a-z0-9_>:$])(include|require)(_once)?[ \t(@]*\$_(post|get|request|cookie)/))
      hit("H", "include of a file the request names", substr(line, RSTART))
    if (match(l, /(gzinflate|gzuncompress|gzdecode|str_rot13|strrev|convert_uudecode)[ \t]*\([ \t@]*(base64_decode|str_rot13|gzinflate|gzuncompress|strrev|hex2bin)[ \t]*\(/))
      hit("L", "decoding inside decoding (packed code)", substr(line, RSTART))
    if (match(l, /\$[a-z_][a-z0-9_]*[ \t]*\([ \t@]*\$_(post|get|request|cookie)[ \t]*\[/))
      hit("L", "a function held in a variable, called with request data", substr(line, RSTART))
    if (match(l, /preg_replace[ \t]*\([ \t]*['"][^'"]*[\/#~|@!%}][imsxuadj]*e[imsxuadj]*['"][ \t]*,/))
      hit("L", "preg_replace with the e modifier (runs code on PHP 5)", substr(line, RSTART))
    if (match(l, /(^|[^a-z0-9_>:$])(file_put_contents|fwrite|fputs)[ \t]*\([^;]*\$_(post|get|request|cookie)/))
      hit("L", "what the request sent, written to a file", substr(line, RSTART))
    t = l
    if (index(l, "chr") && gsub(/chr[ \t]*\([ \t]*[0-9]+[ \t]*\)[ \t]*\./, "", t) >= 8)
      hit("L", "text put together from chr() pieces", substr(line, index(l, "chr")))
    if (wide) {
      if (match(l, /(^|[^a-z0-9_>:$])eval[ \t]*\(/)) hit("L", "uses eval()", substr(line, RSTART))
      if (match(l, /base64_decode[ \t]*\(/)) hit("L", "uses base64_decode()", substr(line, RSTART))
      if (match(l, /(^|[^a-z0-9_>:$])(system|exec|shell_exec|passthru|popen|proc_open|pcntl_exec)[ \t]*\(/))
        hit("L", "starts a process (exec, system, shell_exec ...)", substr(line, RSTART))
      if (match(l, /(^|[^a-z0-9_>:$])(create_function|assert)[ \t]*\(/)) hit("L", "uses create_function() or assert()", substr(line, RSTART))
    }
  }
  if (match(l, /(^|[^a-z0-9_>:$])(include|require)(_once)?[ \t(@]*['"](https?|ftp|data|php):/))
    hit("H", "include from an address or a stream", substr(line, RSTART))
  if (index(l, "\\x")) {
    t = l
    n = gsub(/\\x[0-9a-f][0-9a-f]/, "", t)
    if (n >= 20) hit("L", "text hidden as \\x escapes (" n " on one line)", substr(line, index(l, "\\x")))
  }
  # an embedded picture (data:...;base64,) is long and encoded too, and is nothing to look at
  if (length(l) >= 1000) {
    t = l
    gsub(/base64,[a-z0-9+\/=]+/, " ", t)
    gsub(/[^a-z0-9+\/=]+/, " ", t)
    n = split(t, parts, " ")
    for (i = 1; i <= n; i++) if (length(parts[i]) >= 1000) {
      hit("L", "a long encoded string (" length(parts[i]) " characters)", substr(line, index(l, parts[i])))
      break
    }
  }
}
function scan(file,   line, rel, low, r, i) {
  rel = file
  if (index(file, home) == 1) rel = substr(file, length(home) + 1)
  low = tolower(rel)
  kind = "php"
  if (low ~ /(^|\/)\.(htaccess|user\.ini)$/) kind = "conf"
  else if (low ~ /\.ico$/) kind = "other"
  nf = 0; strong = 0; fnr = 0
  split("", seen)
  if (kind == "php" && low ~ /(^|\/)uploads?\//) hit("L", "a script in an upload directory", "")
  while ((r = (getline line < file)) > 0) { fnr++; check(line) }
  close(file)
  if (r < 0 && fnr == 0) { unread++; return }
  files++
  if (nf == 0) return
  print "P\t" (strong ? "H" : "L") "\t" name(rel)
  for (i = 1; i <= nf; i++) print "F\t" found[i]
}
BEGIN {
  files = 0; unread = 0
  for (a = 1; a < ARGC; a++) scan(ARGV[a])
  print "N\t" files "\t" unread
}
SCAN_AWK
}

# Every script of a home, and the three kinds of file that make another file run as one or hide
# one: .htaccess, .user.ini and an icon. Links are not followed and the home's filesystem is not
# left; the bytes are read as bytes, whatever the site's files are encoded in.
_scan_run() {   # home wide
  LC_ALL=C find -P "$1" -xdev -type f \( -iname '*.php' -o -iname '*.phtml' -o -iname '*.php[0-9]' \
      -o -iname '*.phar' -o -iname '*.pht' -o -iname '*.inc' -o -iname '*.ico' \
      -o -name '.htaccess' -o -name '.user.ini' \) \
    -exec awk -v home="$1/" -v wide="$2" "$(lib_scan_awk)" {} + 2>/dev/null || true
}

lib_scan_usage() {
  cat <<'EOF'
Usage: lomp scan <domain>... | --all [--wide]

  Looks through a site's PHP files for what web shells are made of, and lists the files to
  open. It changes nothing.
    STRONG  eval of decoded data or of what the request sent, a command or an include made of
            what the request sent, PHP code in an icon, the name of a known shell
    LOOK    packed or hidden code (decoding inside decoding, long encoded strings, \x escapes,
            chr() chains), a script in an upload directory, request data written to a file,
            auto_prepend_file in .htaccess or .user.ini

  --wide    also list every file that uses eval, base64_decode, exec, system, shell_exec,
            passthru, popen, proc_open, assert or create_function. Plugins use them too: on
            a WordPress site this is a long list.
EOF
}

# One site. The findings go to the terminal only: the log gets the counts.
lib_scan_site() {   # domain wide
  local domain="$1" wide="$2" home="" kind="" a="" b="" c="" d="" sev="" block=""
  local files=0 unread=0 nh=0 nl=0 strong="" look=""
  home="$(lib_domain_home "$domain")"
  if [[ -L "$home" || ! -d "$home" ]]; then
    lib_error "${domain}: ${home} is not a directory; not scanned"
    return 1
  fi
  lib_info "${domain}: reading the PHP files in ${home}"
  while IFS=$'\t' read -r kind a b c d; do
    case "$kind" in
      N) if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]]; then files=$((files + a)); unread=$((unread + b)); fi ;;
      P) if [[ -n "$block" ]]; then if [[ "$sev" == "H" ]]; then strong+="$block"; else look+="$block"; fi; fi
         sev="$a"
         if [[ "$sev" == "H" ]]; then
           nh=$((nh + 1)); printf -v block '  %sSTRONG%s  %s\n' "$C_RED" "$C_RST" "$b"
         else
           nl=$((nl + 1)); printf -v block '  %sLOOK%s    %s\n' "$C_YEL" "$C_RST" "$b"
         fi ;;
      F) if [[ "$b" == "0" ]]; then block+="$(printf '          %s' "$c")"$'\n'
         else block+="$(printf '          line %s: %s' "$b" "$c")"$'\n'; fi
         if [[ -n "$d" ]]; then block+="$(printf '            %s%s%s' "$C_DIM" "$d" "$C_RST")"$'\n'; fi ;;
      *) ;;
    esac
  done < <(_scan_run "$home" "$wide")
  if [[ -n "$block" ]]; then if [[ "$sev" == "H" ]]; then strong+="$block"; else look+="$block"; fi; fi
  if [[ -n "${strong}${look}" ]]; then printf '\n%s%s\n' "$strong" "$look"; fi
  SCAN_STRONG_TOTAL=$((SCAN_STRONG_TOTAL + nh)); SCAN_LOOK_TOTAL=$((SCAN_LOOK_TOTAL + nl))
  if (( unread > 0 )); then lib_note "${unread} file(s) went away or could not be read while scanning"; fi
  if (( nh > 0 )); then
    lib_warn "${domain}: ${nh} file(s) with strong signs of a web shell, ${nl} more worth a look (${files} files read)"
  elif (( nl > 0 )); then
    lib_info "${domain}: nothing with strong signs; ${nl} file(s) worth a look (${files} files read)"
  else
    lib_ok "${domain}: nothing found in ${files} files"
  fi
  return 0
}

lib_scan_main() {
  local a="" all=0 wide=0 d="" failed=0
  local -a domains=()
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      --all)          all=1 ;;
      --wide)         wide=1 ;;
      -h|--help|help) lib_scan_usage; return 0 ;;
      -*)             lib_scan_usage >&2; lib_die "Unknown option for scan: ${a}" "" "see the usage above" ;;
      *)              domains+=("${a,,}") ;;
    esac
  done
  if (( all )) && ((${#domains[@]} > 0)); then lib_die "--all and a domain cannot be combined" "" "lomp scan --all"; fi
  if (( ! all )) && ((${#domains[@]} == 0)); then
    lib_scan_usage >&2
    lib_die "Domain missing" "" "lomp scan example.com   (every site: lomp scan --all)"
  fi
  for d in "${domains[@]}"; do
    lib_domain_valid "$d" || lib_die "Invalid domain name '${d}'" "" "lomp list"
    lib_domain_registered "$d" || lib_die "Site ${d} is not registered" "" "lomp list"
  done
  if (( all )); then
    mapfile -t domains < <(lib_domains_list)
    if ((${#domains[@]} == 0)); then lib_info "No sites have been added yet."; return 0; fi
  fi
  SCAN_STRONG_TOTAL=0; SCAN_LOOK_TOTAL=0
  for d in "${domains[@]}"; do
    lib_scan_site "$d" "$wide" || failed=$((failed + 1))
  done
  if (( SCAN_STRONG_TOTAL + SCAN_LOOK_TOTAL > 0 )); then
    lib_note "A match is a reason to open the file, not a verdict: plugins and libraries use these functions too."
    lib_note "Nothing was changed. A shell is rarely alone: once one is confirmed, restore the site from a backup"
    lib_note "taken before it arrived, or replace the application's files with clean copies, then change the"
    lib_note "passwords (lomp db passwd <domain>) and run: lomp harden <domain>"
  fi
  (( failed == 0 ))
}
