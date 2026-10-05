#!/usr/bin/env bash
# lib/import.sh - import: the sites of another server, brought here over SSH. It looks at what
#                 the other server serves (OpenLiteSpeed's virtual hosts, and the directories
#                 under /home, /var/www and /www/wwwroot that are named after a domain), lists
#                 them, asks which ones to bring, adds the sites that are not here yet, copies
#                 the files as the site's own user and the database a WordPress names, and
#                 points wp-config.php at the database it has here. The mailboxes of a
#                 domain follow it: the addresses the other server's Dovecot knows, with the
#                 passwords they had where the hashes can be read, the mail itself, and the
#                 domain's aliases and forwarders.
#                 Nothing is changed on the other server.

IMP_SSH_TARGET=""
IMP_REMOTE_USER=""
declare -ga IMP_SSH_OPTS=()
# one entry per site found, the same index in each ("mail": a domain with mailboxes and no site)
declare -ga IMP_DOMAIN=() IMP_ROOT=() IMP_KB=() IMP_KIND=() IMP_DB=() IMP_WWW=() IMP_CONF=()
# directories that are served there under no name this server could give a site
declare -ga IMP_NAMELESS=()
# one entry per mailbox found: address, its Maildir there, size, password hash ("-": not known)
declare -ga IMP_BOX=() IMP_BOX_DIR=() IMP_BOX_KB=() IMP_BOX_HASH=()
# one entry per alias or forwarder found: the address (or @domain), and where it goes
declare -ga IMP_ALIAS=() IMP_ALIAS_TO=()
IMP_MAIL_ROWS=1
IMP_OPT_NO_DB=0 IMP_OPT_NO_FILES=0 IMP_OPT_NO_MAIL=0 IMP_OPT_ONLY_MAIL=0

lib_import_usage() {
  # a usage text is no single message lib/lang.sh could look up: its Turkish is here
  if [[ "${LIB_LANG:-en}" == "tr" ]]; then
    cat <<'EOF'
Kullanım: setup.sh import <[user@]host> [options]
  Siteleri başka bir sunucudan SSH üzerinden bu sunucuya getirir: dosyalar sitenin
  public_html dizinine, sitenin kendi kullanıcısı olarak; bir WordPress'in veritabanı da
  buradaki site veritabanına aktarılır ve wp-config.php ona yönlendirilir. Henüz burada
  olmayan site önce eklenir (sertifikasız: DNS hâlâ öteki sunucuyu gösterir). Öteki sunucu
  yalnızca okunur.

  Seçenek olarak --all ya da --only verilmezse orada bulunan siteler listelenir ve hangilerini
  istediğiniz sorulur.

  --port N               Öteki sunucunun SSH portu (varsayılan 22)
  --key FILE             Giriş için kullanılacak özel anahtar
  --password-file FILE   İlk satırı SSH şifresi olan dosya. Ne --key ne de bu verilmişse ssh
                         şifreyi kendisi, bir kez sorar
  --list                 Yalnızca orada ne olduğunu gösterir
  --all                  Orada bulunan her site
  --only a.com,b.com     Yalnızca bunlar
  --no-create            Yalnızca burada zaten var olan siteler (ötekileri önce kendiniz ekleyin)
  --path DIR --as DOMAIN Öteki sunucunun bir dizini bu alan adı olarak; orada bir ad altında
                         sunulmayan site için (örneğin /usr/local/lsws/Example/html)
  --db NAME              Seçenek --path ise: getirilecek veritabanı, WordPress olmayan site için
  --no-db  --no-files    Veritabanları ya da dosyalar dışarıda bırakılır
  --no-mail              Posta kutuları dışarıda bırakılır
  --only-mail            Yalnızca posta kutuları getirilir: burada site olmayan alan adı bir
                         posta alan adı olur (yalnızca posta için kurulmuş sunucuda hep böyledir)
  Bu sunucuda posta kuruluysa seçilen alan adının posta kutuları da onunla gelir: öteki
  sunucudaki Dovecot'un bildiği adresler ve Maildir dizinlerindeki postalar, buradakilerle
  birleştirilir - burada hiçbir şey silinmez. Öteki sunucu lomp ya da CyberPanel ise kutular
  şifrelerini korur; değilse her birine yeni şifre verilir ve bir kez gösterilir. Alan adının
  takma adları ve yönlendirmeleri de gelir (lomp'un kendi dosyaları, CyberPanel tablosu ve
  Postfix'in sanal takma ad dosyaları); burada zaten olan bir takma ad olduğu gibi kalır.
  DNS kayıtlarına dokunulmaz: MX'i siz taşıyana kadar posta orada alınmaya devam eder
  (setup.sh mail dns <domain>).
  Kullanıcı (varsayılan root) sitelerin dosyalarını okuyabilmelidir; posta kutularını yalnızca
  root görür. Kopyalanmayanlar: sieve filtreleri, sertifikalar, cron işleri ve --db ile adı
  verilmedikçe WordPress dışındaki uygulamaların veritabanları.
EOF
    return 0
  fi
  cat <<'EOF'
Usage: setup.sh import <[user@]host> [options]
  Bring sites from another server to this one over SSH: the files into the site's
  public_html, as the site's own user, and the database of a WordPress into the site's
  database here, with wp-config.php pointed at it. A site that is not here yet is added
  first (without a certificate: the DNS still points to the other server). The other server
  is only read.

  Without --all or --only the sites found there are listed and you are asked which ones.

  --port N               SSH port of the other server (default 22)
  --key FILE             Private key to log in with
  --password-file FILE   File whose first line is the SSH password. Without --key and without
                         this, ssh asks for the password itself, once
  --list                 Only show what is there
  --all                  Every site found there
  --only a.com,b.com     These ones
  --no-create            Only the sites that already exist here (add the others yourself first)
  --path DIR --as DOMAIN One directory of the other server as this domain, for a site that is
                         served there under no name (such as /usr/local/lsws/Example/html)
  --db NAME              With --path: the database to bring, for a site that is no WordPress
  --no-db  --no-files    Leave the databases, or the files, out
  --no-mail              Leave the mailboxes out
  --only-mail            Bring only the mailboxes: a domain that is no site here becomes a
                         mail domain (this is what happens on a server installed for mail alone)
  The mailboxes of a chosen domain come with it when this server runs mail: the addresses the
  other server's Dovecot knows and the mail in their Maildirs, merged into what is here -
  nothing here is deleted. They keep their passwords when the other server is a lomp or a
  CyberPanel; otherwise each gets a new one, shown once. The domain's aliases and forwarders
  come too (lomp's own, CyberPanel's, and the ones in Postfix's virtual alias files); one
  that exists here already stays as it is. The DNS records are not touched: mail goes on
  arriving there until you move the MX (setup.sh mail dns <domain>).
  The user (default root) has to be able to read the sites' files, and only root sees the
  mailboxes. Not copied: sieve filters, certificates, cron jobs, and the databases of
  applications other than WordPress unless --db names one.
EOF
}

# What goes into a command line of the other server is only ever made of these characters.
_import_path_ok()   { [[ "$1" =~ ^/[A-Za-z0-9._/@+-]*$ && "$1" != *..* ]]; }
_import_dbname_ok() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$ ]]; }
_import_target_ok() { [[ "$1" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*@)?[A-Za-z0-9][A-Za-z0-9.:-]*$ ]]; }

# A password hash as the other server keeps it -> one this server's Dovecot can check, or "-".
# It goes into a file whose fields are divided by colons, so it is made of nothing else.
_import_hash() {   # hash
  local h="$1" bcrypt='^(\{CRYPT\})?(\$2[aby]\$[A-Za-z0-9./$]{20,100})$'
  local known='^\{(BLF-CRYPT|SHA512-CRYPT|SHA256-CRYPT|CRYPT|ARGON2ID|ARGON2I|SSHA512|SSHA256|SSHA|PBKDF2)\}[A-Za-z0-9./$=+,_-]{8,400}$'
  if [[ "$h" =~ $bcrypt ]]; then h="{BLF-CRYPT}${BASH_REMATCH[2]}"; fi
  if [[ "$h" =~ $known ]]; then printf '%s' "$h"; else printf -- '-'; fi
}

_import_ssh() { ssh "${IMP_SSH_OPTS[@]}" "$IMP_SSH_TARGET" "$@"; }

# The mailboxes found for one domain, as indexes into IMP_BOX, one per line.
_import_boxes_of() {   # domain
  local k=0
  for (( k = 0; k < ${#IMP_BOX[@]}; k++ )); do
    if [[ "${IMP_BOX[k]#*@}" == "$1" ]]; then printf '%d\n' "$k"; fi
  done
  return 0
}

# The aliases found for one domain, as indexes into IMP_ALIAS, one per line.
_import_aliases_of() {   # domain
  local k=0
  for (( k = 0; k < ${#IMP_ALIAS[@]}; k++ )); do
    if [[ "${IMP_ALIAS[k]#*@}" == "$1" ]]; then printf '%d\n' "$k"; fi
  done
  return 0
}

# "2 mailbox(es) (36 KB) and 3 alias(es)" - what a domain has there, for the plan.
_import_mail_what() {   # domain
  local b=0 a=0
  b="$(_import_boxes_of "$1" | wc -l | tr -d ' ')"; a="$(_import_aliases_of "$1" | wc -l | tr -d ' ')"
  if (( b > 0 && a > 0 )); then printf '%d mailbox(es) (%s) and %d alias(es)' "$b" "$(_import_mb "$(_import_mail_kb "$1")")" "$a"
  elif (( b > 0 )); then printf '%d mailbox(es) (%s)' "$b" "$(_import_mb "$(_import_mail_kb "$1")")"
  elif (( a > 0 )); then printf '%d alias(es)' "$a"; fi
}

_import_mail_kb() {   # domain -> kilobytes of its mail there
  local k="" kb=0
  while read -r k; do
    [[ -n "$k" ]] || continue
    kb=$(( kb + IMP_BOX_KB[k] ))
  done < <(_import_boxes_of "$1")
  printf '%d' "$kb"
}

_import_mb() {   # kilobytes -> "12 MB"
  local kb="${1:-0}"
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  if (( kb < 1024 )); then printf '%d KB' "$kb"; else printf '%d MB' "$(( (kb + 512) / 1024 ))"; fi
}

# =============================================================================
#  what runs on the other server
# =============================================================================
# Lists what is served there, one line each:
#   U <user it runs as>
#   S <domain|-> <document root> <kilobytes> <static|php|wordpress> <database|-> <www 0|1> <wp-config.php|-> <ols|dir|path>
#   M <address> <its Maildir|-> <kilobytes> <password hash|->
#   A <alias address, or @domain> <where it goes, addresses divided by commas>
# Plain sh, awk and sed: the other server is whatever it is. LOMP_IMPORT_ONLY names one
# directory to describe instead; LOMP_IMPORT_ROOT stands in front of the fixed paths (tests).
lib_import_remote_scan() {
  cat <<'IMPORT_SCAN'
R="${LOMP_IMPORT_ROOT:-}"
ONLY="${LOMP_IMPORT_ONLY:-}"
TAB="$(printf '\t')"
printf 'U\t%s\n' "$(id -un 2>/dev/null || echo unknown)"
row() {   # domain docroot www source
  root="${2%/}"
  [ -d "$root" ] || return 0
  kind=static; conf=-; db=-
  if [ -f "$root/wp-config.php" ]; then kind=wordpress; conf="$root/wp-config.php"
  elif [ -f "$root/wp-settings.php" ] && [ -f "${root%/*}/wp-config.php" ]; then kind=wordpress; conf="${root%/*}/wp-config.php"
  elif [ -n "$(find "$root" -maxdepth 1 -name '*.php' 2>/dev/null | head -n 1)" ]; then kind=php; fi
  if [ "$conf" != - ]; then
    db="$(sed -n "s/^[[:space:]]*define([[:space:]]*['\"]DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$conf" 2>/dev/null | head -n 1)"
    [ -n "$db" ] || db=-
  fi
  kb="$(du -sk "$root" 2>/dev/null | cut -f1)"
  printf 'S\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$root" "${kb:-0}" "$kind" "$db" "$3" "$conf" "$4"
}
# Mailboxes: the addresses Dovecot knows and where the mail of each lies. The password hashes
# are read where they are kept in a place that is known: lomp's own file, CyberPanel's table.
mail_rows() {
  hashes=""
  if [ -r "$R/etc/dovecot/lomp/passwd" ]; then
    hashes="$(awk -F: 'index($1, "@") > 0 && $2 != "" { print $1 "\t" $2 }' "$R/etc/dovecot/lomp/passwd" 2>/dev/null)"
  fi
  if [ -z "$hashes" ] && [ -d "$R/usr/local/CyberCP" ]; then
    client="$(command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null)"
    [ -z "$client" ] || hashes="$("$client" -N -B -e 'SELECT email, password FROM cyberpanel.e_users' 2>/dev/null)"
  fi
  users=""
  if command -v doveadm >/dev/null 2>&1; then users="$(doveadm user '*' 2>/dev/null)"; fi
  [ -n "$users" ] || users="$(printf '%s\n' "$hashes" | cut -f1)"
  printf '%s\n' "$users" | while IFS= read -r u; do
    case "$u" in *@*) ;; *) continue ;; esac
    case "$u" in *[!A-Za-z0-9@._+-]*) continue ;; esac
    n="${u%@*}"; d="${u#*@}"
    p=""
    if command -v doveadm >/dev/null 2>&1; then p="$(doveadm mailbox path -u "$u" INBOX 2>/dev/null | head -n 1)"; fi
    if [ -z "$p" ] || [ ! -d "$p/cur" ]; then
      p=""
      for c in "$R/home/vmail/$d/$n/Maildir" "$R/var/vmail/$d/$n/Maildir" "$R/var/vmail/vmail1/$d/$n/Maildir" \
               "$R/var/vmail/$d/$n" "$R/var/mail/vhosts/$d/$n"; do
        if [ -d "$c/cur" ]; then p="$c"; break; fi
      done
    fi
    kb=0
    [ -z "$p" ] || kb="$(du -sk "$p" 2>/dev/null | cut -f1)"
    h="$(printf '%s\n' "$hashes" | awk -F'\t' -v u="$u" '$1 == u { print $2; exit }')"
    printf 'M\t%s\t%s\t%s\t%s\n' "$u" "${p:--}" "${kb:-0}" "${h:--}"
  done
}
mail_rows
# Aliases and forwarders: lomp's own files, CyberPanel's table, and the text files Postfix is
# told to look its virtual aliases up in. The same address may come up twice; the first counts.
alias_rows() {
  for f in "$R/root/.server-setup/mail/aliases"/*; do
    [ -f "$f" ] || continue
    awk -F'\t' '!/^[ \t]*#/ && NF >= 2 && $1 != "" { t = $2; gsub(/[ \t]/, "", t); print "A\t" $1 "\t" t }' "$f" 2>/dev/null
  done
  if [ -d "$R/usr/local/CyberCP" ]; then
    client="$(command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null)"
    [ -z "$client" ] || "$client" -N -B -e 'SELECT source, destination FROM cyberpanel.e_forwardings' 2>/dev/null \
      | awk -F'\t' 'NF >= 2 && $1 != "" { t = $2; gsub(/[ \t]/, "", t); print "A\t" $1 "\t" t }'
  fi
  if command -v postconf >/dev/null 2>&1; then
    set -f
    for m in $(postconf -h virtual_alias_maps 2>/dev/null | tr ',' ' '); do
      case "$m" in hash:*|texthash:*|lmdb:*|btree:*) f="${m#*:}" ;; *) continue ;; esac
      case "$f" in */postfix/lomp/*) continue ;; esac
      [ -r "$f" ] || continue
      awk '!/^[ \t]*#/ && !/^[ \t]/ && NF >= 2 {
             t = ""
             for (i = 2; i <= NF; i++) { x = $i; gsub(/,/, " ", x); n = split(x, q, " "); for (j = 1; j <= n; j++) if (q[j] != "") t = t (t == "" ? "" : ",") q[j] }
             print "A\t" $1 "\t" t
           }' "$f" 2>/dev/null
    done
    set +f
  fi
}
alias_rows
if [ -n "$ONLY" ]; then row - "$ONLY" 0 path; exit 0; fi

# OpenLiteSpeed (lomp, CyberPanel, a plain install): the names are in the listeners' maps
L="$R/usr/local/lsws"
if [ -r "$L/conf/httpd_config.conf" ]; then
  awk '
    /^[ \t]*virtualhost[ \t]/ { v = $2; sub(/\{.*/, "", v); inv = 1; names[v] = 1; next }
    /^[ \t]*listener[ \t]/    { inl = 1; next }
    /^[ \t]*\}/               { inv = 0; inl = 0; next }
    inv && $1 == "vhRoot"     { vr[v] = $2 }
    inv && $1 == "configFile" { cf[v] = $2 }
    inl && $1 == "map"        { s = ""; for (i = 3; i <= NF; i++) s = s " " $i; gsub(/,/, " ", s); dm[$2] = dm[$2] s }
    END {
      for (v in names) {
        d = dm[v]; gsub(/^ +| +$/, "", d)
        printf "%s\t%s\t%s\t%s\n", v, (vr[v] == "" ? "-" : vr[v]), (cf[v] == "" ? "-" : cf[v]), (d == "" ? "-" : d)
      }
    }
  ' "$L/conf/httpd_config.conf" | while IFS="$TAB" read -r v vr cf dm; do
    [ "$cf" != - ] || continue
    [ "$vr" != - ] || vr="$v"
    vr="$(printf '%s' "$vr" | sed -e "s|\$SERVER_ROOT|$L|g" -e "s|\$VH_NAME|$v|g")"
    case "$vr" in /*) ;; *) vr="$L/$vr" ;; esac
    vr="${vr%/}"
    cf="$(printf '%s' "$cf" | sed -e "s|\$SERVER_ROOT|$L|g" -e "s|\$VH_NAME|$v|g" -e "s|\$VH_ROOT|$vr|g")"
    case "$cf" in /*) ;; *) cf="$L/$cf" ;; esac
    [ -r "$cf" ] || continue
    dr="$(awk '$1 == "docRoot" { print $2; exit }' "$cf" 2>/dev/null)"
    [ -n "$dr" ] || continue
    dr="$(printf '%s' "$dr" | sed -e "s|\$SERVER_ROOT|$L|g" -e "s|\$VH_NAME|$v|g" -e "s|\$VH_ROOT|$vr|g")"
    case "$dr" in /*) ;; *) dr="$vr/$dr" ;; esac
    dml=" $(printf '%s' "$dm" | tr 'A-Z' 'a-z') "
    seen=" "
    set -f
    for d in $dml; do
      [ "$d" != '*' ] && [ "$d" != - ] || continue
      b="${d#www.}"
      case "$seen" in *" $b "*) continue ;; esac
      seen="$seen$b "
      case "$dml" in *" www.$b "*) w=1 ;; *) w=0 ;; esac
      row "$b" "$dr" "$w" ols
    done
    set +f
    [ "$seen" != " " ] || row - "$dr" 0 ols
  done
fi

# Directories named after a domain (CyberPanel, aaPanel, Plesk, a server set up by hand), and
# the ones that are served under some other name (/home/<user>/public_html, /var/www/html)
for base in "$R/home" "$R/var/www" "$R/www/wwwroot" "$R/var/www/vhosts"; do
  [ -d "$base" ] || continue
  for dir in "$base"/*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    name="$(basename "$dir" | tr 'A-Z' 'a-z')"
    root=""
    for sub in public_html httpdocs htdocs html; do
      if [ -d "$dir/$sub" ]; then root="$dir/$sub"; break; fi
    done
    if [ -z "$root" ]; then
      [ -f "$dir/index.php" ] || [ -f "$dir/index.html" ] || continue
      root="$dir"
    fi
    case "$name" in
      *[!a-z0-9.-]*) name=- ;;
      *.*) name="${name#www.}" ;;
      *) name=- ;;
    esac
    row "$name" "$root" 0 dir
  done
done
exit 0
IMPORT_SCAN
}

# Writes one database to stdout, gzipped. DB names it; CONF, when given, is the wp-config.php
# whose login is used if the account that runs this cannot read the database by itself. That
# login goes into a file only this account can read, never onto a command line.
lib_import_remote_dump() {
  cat <<'IMPORT_DUMP'
set -u
set -o pipefail 2>/dev/null || true
DB="${DB:-}"; CONF="${CONF:-}"
dumper="$(command -v mariadb-dump 2>/dev/null || command -v mysqldump 2>/dev/null || true)"
client="$(command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null || true)"
[ -n "$dumper" ] || { echo "lomp-import: no mysqldump or mariadb-dump on this server" >&2; exit 3; }
opts="--single-transaction --quick --triggers --default-character-set=utf8mb4"
if "$dumper" --help 2>/dev/null | grep -q -- '--no-tablespaces'; then opts="$opts --no-tablespaces"; fi
if [ -n "$client" ] && "$client" -N -B -e 'SELECT 1' "$DB" >/dev/null 2>&1; then
  "$dumper" $opts --routines "$DB" | gzip -c
  exit $?
fi
[ -n "$CONF" ] && [ -r "$CONF" ] || { echo "lomp-import: this account cannot open the database $DB, and there is no wp-config.php to take a login from" >&2; exit 4; }
get() {
  sed -n "s/^[[:space:]]*define([[:space:]]*['\"]$1['\"][[:space:]]*,[[:space:]]*\(['\"]\)\(.*\)\1[[:space:]]*)[[:space:]]*;.*/\2/p" "$CONF" \
    | head -n 1 | sed -e "s/\\\\\\(['\\\\]\\)/\\1/g"
}
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
u="$(get DB_USER)"; p="$(get DB_PASSWORD)"; h="$(get DB_HOST)"
[ -n "$u" ] || { echo "lomp-import: no DB_USER in $CONF" >&2; exit 4; }
umask 077
cnf="$(mktemp)" || exit 5
trap 'rm -f "$cnf"' EXIT
{
  printf '[client]\nuser="%s"\npassword="%s"\n' "$(esc "$u")" "$(esc "$p")"
  case "$h" in
    ''|localhost) ;;
    *:/*) printf 'socket="%s"\n' "${h#*:}" ;;
    *:*)  printf 'host="%s"\nport=%s\n' "${h%%:*}" "${h##*:}" ;;
    *)    printf 'host="%s"\n' "$h" ;;
  esac
} >"$cnf"
"$dumper" --defaults-extra-file="$cnf" $opts "$DB" | gzip -c
IMPORT_DUMP
}

# =============================================================================
#  connection
# =============================================================================
# One connection that every later command shares, so a password is asked for once. It is ssh
# that asks, on the terminal; --password-file answers it through SSH_ASKPASS instead.
lib_import_connect() {   # port key password-file
  local port="$1" key="$2" pwfile="$3" dir=""
  dir="$(lib_mktemp -d)"
  IMP_SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=${dir}/s" -o ControlPersist=120
                -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15
                -o ServerAliveInterval=30 -o ServerAliveCountMax=4 -p "$port")
  if [[ -n "$key" ]]; then IMP_SSH_OPTS+=(-i "$key" -o IdentitiesOnly=yes); fi
  if [[ -n "$pwfile" ]]; then
    printf '#!/bin/sh\nhead -n 1 "$LOMP_IMPORT_PWFILE"\n' >"${dir}/askpass"
    chmod 0700 "${dir}/askpass"
    export LOMP_IMPORT_PWFILE="$pwfile" SSH_ASKPASS="${dir}/askpass" SSH_ASKPASS_REQUIRE=force
    IMP_SSH_OPTS+=(-o "PreferredAuthentications=password,keyboard-interactive" -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1)
  elif ! lib_is_interactive; then
    IMP_SSH_OPTS+=(-o BatchMode=yes)
  fi
  lib_info "Connecting to ${IMP_SSH_TARGET} (port ${port}) ..."
  _import_ssh true </dev/null \
    || lib_die "Could not log in to ${IMP_SSH_TARGET}" "wrong password or key, another SSH port, or the server does not let this user in" \
         "try it by hand: ssh -p ${port} ${IMP_SSH_TARGET}   (then: --port N, --key FILE or --password-file FILE)"
  _import_ssh 'command -v tar >/dev/null && command -v gzip >/dev/null && command -v awk >/dev/null' </dev/null \
    || lib_die "${IMP_SSH_TARGET} has no tar, gzip or awk" "the files are copied with them" "install them there, then run this again"
}

lib_import_disconnect() {
  ((${#IMP_SSH_OPTS[@]} > 0)) || return 0
  ssh "${IMP_SSH_OPTS[@]}" -O exit "$IMP_SSH_TARGET" >/dev/null 2>&1 || true
}

# =============================================================================
#  what is there
# =============================================================================
# The list the other server gave, into IMP_*. It is somebody else's output: a line counts only
# when every field is what it should be, and a domain or a directory only once.
lib_import_scan_parse() {   # reads the listing from stdin
  local tag="" domain="" root="" kb="" kind="" db="" www="" conf="" x="" dup=0
  IMP_DOMAIN=() IMP_ROOT=() IMP_KB=() IMP_KIND=() IMP_DB=() IMP_WWW=() IMP_CONF=() IMP_NAMELESS=()
  IMP_BOX=() IMP_BOX_DIR=() IMP_BOX_KB=() IMP_BOX_HASH=() IMP_ALIAS=() IMP_ALIAS_TO=()
  IMP_REMOTE_USER=""
  while IFS=$'\t' read -r tag domain root kb kind db www conf _; do
    if [[ "$tag" == "U" ]]; then
      if [[ "$domain" =~ ^[A-Za-z0-9._-]+$ ]]; then IMP_REMOTE_USER="$domain"; fi
      continue
    fi
    if [[ "$tag" == "M" ]]; then
      # address, Maildir, kilobytes, hash - in the variables the fields of a site line go to
      domain="${domain,,}"
      lib_mail_address_valid "$domain" || continue
      _import_path_ok "$root" || root="-"
      [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
      dup=0
      for x in ${IMP_BOX[@]+"${IMP_BOX[@]}"}; do
        if [[ "$x" == "$domain" ]]; then dup=1; break; fi
      done
      (( dup )) && continue
      IMP_BOX+=("$domain"); IMP_BOX_DIR+=("$root"); IMP_BOX_KB+=("$kb"); IMP_BOX_HASH+=("$(_import_hash "$kind")")
      continue
    fi
    if [[ "$tag" == "A" ]]; then
      # the alias and its targets, again in the variables of a site line. A target that is
      # no address is dropped, and an alias that is left with none is no alias.
      domain="${domain,,}"
      lib_mail_alias_key_valid "$domain" || continue
      kb=""
      for x in ${root//,/ }; do
        x="${x,,}"
        if lib_mail_address_valid "$x" && [[ ",${kb}," != *",${x},"* ]]; then kb="${kb:+${kb},}${x}"; fi
      done
      [[ -n "$kb" ]] || continue
      dup=0
      for x in ${IMP_ALIAS[@]+"${IMP_ALIAS[@]}"}; do
        if [[ "$x" == "$domain" ]]; then dup=1; break; fi
      done
      (( dup )) && continue
      IMP_ALIAS+=("$domain"); IMP_ALIAS_TO+=("$kb")
      continue
    fi
    [[ "$tag" == "S" ]] || continue
    _import_path_ok "$root" || continue
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    case "$kind" in static|php|wordpress) ;; *) continue ;; esac
    _import_dbname_ok "$db" || db="-"
    [[ "$www" == "1" ]] || www=0
    _import_path_ok "$conf" || conf="-"
    dup=0
    if [[ "$domain" == "-" ]] || ! lib_domain_valid "$domain"; then
      for x in ${IMP_ROOT[@]+"${IMP_ROOT[@]}"} ${IMP_NAMELESS[@]+"${IMP_NAMELESS[@]}"}; do
        if [[ "$x" == "$root" ]]; then dup=1; break; fi
      done
      (( dup )) || IMP_NAMELESS+=("$root")
      continue
    fi
    for x in ${IMP_DOMAIN[@]+"${IMP_DOMAIN[@]}"}; do
      if [[ "$x" == "$domain" ]]; then dup=1; break; fi
    done
    (( dup )) && continue
    IMP_DOMAIN+=("$domain"); IMP_ROOT+=("$root"); IMP_KB+=("$kb"); IMP_KIND+=("$kind")
    IMP_DB+=("$db"); IMP_WWW+=("$www"); IMP_CONF+=("$conf")
  done
  # a domain that has mailboxes or aliases there and no site: an entry of its own, of the kind "mail"
  (( IMP_MAIL_ROWS )) || return 0
  for x in ${IMP_BOX[@]+"${IMP_BOX[@]}"} ${IMP_ALIAS[@]+"${IMP_ALIAS[@]}"}; do
    domain="${x#*@}"; dup=0
    for db in ${IMP_DOMAIN[@]+"${IMP_DOMAIN[@]}"}; do
      if [[ "$db" == "$domain" ]]; then dup=1; break; fi
    done
    (( dup )) && continue
    IMP_DOMAIN+=("$domain"); IMP_ROOT+=("-"); IMP_KB+=(0); IMP_KIND+=("mail")
    IMP_DB+=("-"); IMP_WWW+=(0); IMP_CONF+=("-")
  done
  return 0
}

lib_import_scan() {   # [one directory, the domain it is to be]
  local only="${1:-}" as="${2:-}" out=""
  IMP_MAIL_ROWS=1
  # one directory under one name: the mailboxes of that name come along, no other entry does
  if [[ -n "$as" ]]; then IMP_MAIL_ROWS=0; fi
  out="$(lib_mktemp)"
  lib_info "Looking at what ${IMP_SSH_TARGET} serves ..."
  lib_import_remote_scan | _import_ssh "LOMP_IMPORT_ONLY='${only}' sh -s" >"$out" 2>>"$LOG_FILE" \
    || lib_die "Could not read the sites of ${IMP_SSH_TARGET}" "the connection dropped, or its shell could not run the listing (see the log)" "run it again"
  if [[ -n "$as" ]]; then
    awk -F'\t' -v OFS='\t' -v as="$as" '$1 == "S" { $2 = as } { print }' "$out" | lib_import_scan_parse
  else
    lib_import_scan_parse <"$out"
  fi
}

# What this server would do with a site of that name: "new", "exists", or why it cannot be one.
# With "mail" only its mailboxes are asked about, and any domain can have those.
lib_import_here() {   # domain [mail]
  local mode=""
  if [[ "${2:-}" == "mail" ]]; then
    if lib_domain_registered "$1" || { lib_mail_installed && lib_mail_domain_standalone "$1"; }; then printf 'exists'
    else printf 'new'; fi
    return 0
  fi
  if lib_domain_registered "$1"; then
    mode="$(lib_json_get "$(lib_domain_json "$1")" '.mode')"
    case "$mode" in php|wordpress|static|"") printf 'exists' ;; *) printf 'a %s site here' "$mode" ;; esac
  elif lib_redirect_exists "$1"; then printf 'a redirect here'
  else printf 'new'; fi
}

lib_import_list_print() {
  local i=0 n=${#IMP_DOMAIN[@]} here="" x="" boxes="" als="" kb=0 what=""
  if (( n > 0 )); then
    lib_tr "Sites on ${IMP_SSH_TARGET}"
    printf '\n%s%s%s\n' "$C_BLD" "$LIB_TR" "$C_RST"
    printf '  %3s  %-34s %9s  %-9s  %-20s  %-9s  %-7s  %-8s  %s\n' "#" "DOMAIN" "SIZE" "TYPE" "DATABASE" "MAILBOXES" "ALIASES" "HERE" "DIRECTORY THERE"
    for (( i = 0; i < n; i++ )); do
      what=""; kb="${IMP_KB[i]}"
      if [[ "${IMP_KIND[i]}" == "mail" ]] || (( IMP_OPT_ONLY_MAIL )); then what="mail"; fi
      here="$(lib_import_here "${IMP_DOMAIN[i]}" "$what")"
      boxes="$(_import_boxes_of "${IMP_DOMAIN[i]}" | wc -l | tr -d ' ')"
      if (( boxes > 0 )); then kb=$(( kb + $(_import_mail_kb "${IMP_DOMAIN[i]}") )); else boxes="-"; fi
      als="$(_import_aliases_of "${IMP_DOMAIN[i]}" | wc -l | tr -d ' ')"
      (( als > 0 )) || als="-"
      printf '  %3d  %-34s %9s  %-9s  %-20s  %-9s  %-7s  %-8s  %s\n' "$((i + 1))" "${IMP_DOMAIN[i]}" "$(_import_mb "$kb")" \
        "${IMP_KIND[i]}" "${IMP_DB[i]}" "$boxes" "$als" "$here" "${IMP_ROOT[i]}"
    done
  else
    lib_warn "No site with a domain name was found on ${IMP_SSH_TARGET}"
  fi
  if ((${#IMP_NAMELESS[@]} > 0)); then
    lib_tr "Served there under no domain name (bring one with --path <directory> --as <domain>):"
    printf '\n%s\n' "$LIB_TR"
    for x in "${IMP_NAMELESS[@]}"; do printf '       %s\n' "$x"; done
  fi
  printf '\n'
}

# "1,3 5-7" or "all" -> the chosen indexes (from 0), one per line. Status 1: not a choice.
lib_import_pick() {   # answer count
  local ans="${1,,}" n="$2" part="" a=0 b=0 k=0
  local -a out=()
  local -A seen=()
  ans="${ans//,/ }"
  [[ -n "${ans// /}" ]] || return 1
  if [[ "$ans" =~ ^[[:space:]]*(all|a|\*|hepsi|h)[[:space:]]*$ ]]; then
    for (( k = 0; k < n; k++ )); do printf '%d\n' "$k"; done
    return 0
  fi
  for part in $ans; do
    if [[ "$part" =~ ^([0-9]{1,4})-([0-9]{1,4})$ ]]; then a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
    elif [[ "$part" =~ ^[0-9]{1,4}$ ]]; then a=$((10#$part)); b=$a
    else return 1; fi
    (( a >= 1 && b <= n && a <= b )) || return 1
    for (( k = a; k <= b; k++ )); do
      [[ -z "${seen[$k]:-}" ]] || continue
      seen[$k]=1; out+=("$((k - 1))")
    done
  done
  printf '%s\n' "${out[@]}"
}

# =============================================================================
#  one site
# =============================================================================
# wp-config.php with the four database lines of this server. Status 3: name, user and password
# were not all found on a line of their own (the file is printed as it was read).
lib_import_wpconfig_rewrite() {   # stdin -> stdout; name user password
  LOMP_DB_NAME="$1" LOMP_DB_USER="$2" LOMP_DB_PASSWORD="$3" LOMP_DB_HOST="localhost" awk '
    {
      line = $0; sub(/\r$/, "", line)
      if (match(line, /^[ \t]*define\([ \t]*["\047]DB_(NAME|USER|PASSWORD|HOST)["\047][ \t]*,/)) {
        k = line; sub(/^[ \t]*define\([ \t]*["\047]/, "", k); sub(/["\047].*/, "", k)
        if (!(k in done)) {
          print "define( \047" k "\047, \047" ENVIRON["LOMP_" k] "\047 );"
          done[k] = 1; next
        }
      }
      print
    }
    END { if (!(("DB_NAME" in done) && ("DB_USER" in done) && ("DB_PASSWORD" in done))) exit 3 }'
}

_import_add() {   # domain add-options...
  SERVER_SETUP_LOCKED=1 "$SCRIPT_PATH" add "$@" --yes --quiet
}

# The address a WordPress gives itself, from the database that was just imported.
_import_wp_home() {   # wp-config.php (a copy root can read)
  local prefix=""
  prefix="$(sed -n "s/^[[:space:]]*\$table_prefix[[:space:]]*=[[:space:]]*['\"]\([A-Za-z0-9_]*\)['\"].*/\1/p" "$1" | head -n 1)"
  [[ -n "$prefix" ]] || prefix="wp_"
  lib_db_sql "SELECT option_value FROM \`${DBI_NAME}\`.\`${prefix}options\` WHERE option_name='home' LIMIT 1" 2>/dev/null || true
}

# One site in a shell of its own, with errexit armed in it - which it would not be as the
# condition of an "if". The status comes back in IMP_RC.
IMP_RC=0
_import_site_run() {   # index
  local prev=""
  prev="$(trap -p ERR || true)"
  trap - ERR
  set +e
  ( [[ -z "$prev" ]] || eval "$prev"; set -Eeuo pipefail; lib_import_site "$1" )
  IMP_RC=$?
  set -e
  [[ -z "$prev" ]] || eval "$prev"
  return 0
}

lib_import_site() {   # index
  local i="$1" domain="${IMP_DOMAIN[$1]}"
  if [[ "${IMP_KIND[i]}" == "mail" ]] || (( IMP_OPT_ONLY_MAIL )); then
    lib_heading "${domain}  <-  ${IMP_SSH_TARGET}: its mailboxes"
    lib_rollback_clear
  else
    lib_import_site_part "$i"
  fi
  if (( ! IMP_OPT_NO_MAIL )); then lib_import_mail "$domain"; fi
  return 0
}

# ---- mailboxes -----------------------------------------------------------------
_import_mail_on() {   # domain: mail for a site that is here, or the domain as a mail domain
  if lib_domain_registered "$1"; then SERVER_SETUP_LOCKED=1 "$SCRIPT_PATH" mail enable "$1" --no-dns --yes --quiet
  else SERVER_SETUP_LOCKED=1 "$SCRIPT_PATH" mail domain add "$1" --no-dns --yes --quiet; fi
}

# What was unpacked from the other server, merged into the mailbox: messages that are not
# here yet are added, with their folders and flags, and nothing that is here is deleted.
_import_mail_sync() {   # address staging-directory
  doveadm -o plugin/quota= sync -1 -R -u "$1" "maildir:${2}" >/dev/null 2>>"$LOG_FILE" || return 1
  doveadm quota recalc -u "$1" >/dev/null 2>&1 || true
  return 0
}

# Room for the mail that comes: the domain's usual quota, or twice what the mailbox holds.
_import_mail_quota() {   # usual quota, kilobytes there
  local q="$1" kb="$2" have=0 need=0
  [[ "$q" != "0" ]] || { printf '0'; return 0; }
  case "$q" in
    *G) have=$(( ${q%G} * 1024 )) ;;
    *M) have=$(( ${q%M} )) ;;
  esac
  need=$(( kb * 2 / 1024 ))
  if (( need > have )); then printf '%dG' "$(( (need + 1023) / 1024 ))"; else printf '%s' "$q"; fi
}

lib_import_mail() {   # domain
  local d="$1" k="" a="" hash="" quota="" usual="" stage="" pw="" made=0 kept=0 filled=0 failed=0
  local had="" to="" t="" set_n=0 stay_n=0 far=0
  local -a mine=() fresh=() als=()
  mapfile -t mine < <(_import_boxes_of "$d")
  mapfile -t als < <(_import_aliases_of "$d")
  (( ${#mine[@]} + ${#als[@]} > 0 )) || return 0
  if ! lib_mail_installed; then
    lib_warn "${d} has $(_import_mail_what "$d") there, and this server runs no mail: they were not brought"
    lib_note "Install it once, with the name it will send as, then bring them: setup.sh install --with-mail --mail-hostname mail.example.com   and   setup.sh import ${IMP_SSH_TARGET} --only ${d} --only-mail"
    return 0
  fi
  if ! lib_mail_domain_enabled "$d"; then
    lib_info "Turning on mail for ${d}; its DNS records are left as they are"
    _import_mail_on "$d" \
      || lib_die "Mail could not be turned on for ${d}" "see what 'mail enable' said above" "setup.sh mail status"
  fi
  # the aliases this server has for the domain before anything is made: those stay as they are
  if [[ -s "$(lib_mail_alias_file "$d")" ]]; then
    had="$(awk -F'\t' '!/^[[:space:]]*#/ && NF >= 2 { print $1 }' "$(lib_mail_alias_file "$d")" || true)"
  fi
  usual="$(lib_json_get "$(lib_mail_json "$d")" '.mail.quota_default')"
  lib_mail_quota_valid "${usual:-x}" || usual="$MAIL_QUOTA_DEFAULT"

  # ---- the mailboxes themselves --------------------------------------------------
  for k in "${mine[@]}"; do
    a="${IMP_BOX[k]}"
    if lib_mail_box_exists "$a"; then continue; fi
    # one address, one meaning: Postfix resolves an alias first
    if [[ -s "$(lib_mail_alias_file "$d")" ]] && awk -F'\t' -v k="$a" '$1 == k { found = 1 } END { exit !found }' "$(lib_mail_alias_file "$d")"; then
      lib_warn "${a} is an alias on this server and stays one: its mailbox was not brought"
      continue
    fi
    hash="${IMP_BOX_HASH[k]}"
    if [[ "$hash" == "-" ]]; then
      pw="$(lib_random_password 20)"
      hash="$(lib_mail_hash_password "$pw")" && [[ -n "$hash" ]] \
        || lib_die "The mailbox ${a} could not be made" "a password could not be hashed (is Dovecot installed?)" "setup.sh mail status"
      fresh+=("${a}   ${pw}")
    else
      kept=$((kept + 1))
    fi
    quota="$(_import_mail_quota "$usual" "${IMP_BOX_KB[k]}")"
    lib_mail_passwd_set "$a" "$hash" "$quota"
    lib_mail_domain_aliases_seed "$d" "$a"
    made=$((made + 1))
  done
  pw=""

  # ---- aliases and forwarders ------------------------------------------------------
  # After the mailboxes: the three addresses a first mailbox is given (postmaster, abuse, dmarc)
  # go where the other server sent them, when it had them.
  for k in ${als[@]+"${als[@]}"}; do
    a="${IMP_ALIAS[k]}"; to="${IMP_ALIAS_TO[k]}"
    if grep -qxF -- "$a" <<<"$had"; then stay_n=$((stay_n + 1)); continue; fi
    # one address, one meaning: here an address is a mailbox or an alias, never both
    if [[ "$a" != @* ]] && lib_mail_box_exists "$a"; then
      lib_warn "${a} is a mailbox here, so it was not made an alias as well: on the other server its mail goes to ${to}"
      continue
    fi
    lib_mail_alias_set "$d" "$a" "$to"
    set_n=$((set_n + 1))
    # a mailbox of another domain may send as an alias that is delivered into it, and that
    # mail has to leave signed for this domain
    for t in ${to//,/ }; do
      if [[ "${t#*@}" != "$d" ]] && lib_mail_box_exists "$t"; then far=1; fi
    done
  done
  if (( far )); then
    _mail_sendas_current || lib_warn "The mail configuration could not be brought up to date (${MAIL_LAST_ERROR}); mail sent as an alias of ${d} would leave unsigned: setup.sh mail regenerate"
  fi
  lib_mail_tables_apply || lib_die "The mail tables could not be rebuilt" "${MAIL_LAST_ERROR}" "setup.sh mail status"
  if (( made > 0 )); then
    lib_ok "${made} mailbox(es) of ${d} made here, ${kept} with the password they had there"
  fi
  if (( set_n > 0 )); then lib_ok "${set_n} alias(es) and forwarder(s) of ${d} set here"; fi
  if (( stay_n > 0 )); then lib_note "${stay_n} alias(es) of ${d} that this server already has were left as they are: setup.sh mail alias list ${d}"; fi

  # ---- the mail --------------------------------------------------------------------
  for k in "${mine[@]}"; do
    a="${IMP_BOX[k]}"
    # (not one that was left an alias above)
    lib_mail_box_exists "$a" || continue
    if [[ "${IMP_BOX_DIR[k]}" == "-" ]]; then
      lib_note "${a}: no Maildir of it was found there; no mail was copied"
      continue
    fi
    stage="$(_mail_stage_dir)" \
      || lib_die "The mail of ${a} was not copied" "no working directory could be made under ${MAIL_VMAIL_HOME}" "check the disk space"
    lib_info "Copying the mail of ${a} ($(_import_mb "${IMP_BOX_KB[k]}")) ..."
    # Dovecot's indexes are rebuilt here; what names the messages and their folders comes along
    if _import_ssh "tar -C '${IMP_BOX_DIR[k]}' --exclude='dovecot.index*' --exclude='dovecot.list.index*' --exclude='dovecot.mailbox.log*' -czf - . ; r=\$?; [ \"\$r\" -le 1 ]" </dev/null 2>>"$LOG_FILE" \
         | runuser -u "$MAIL_VMAIL_USER" -- tar -C "$stage" -xzf - 2>>"$LOG_FILE" \
       && _import_mail_sync "$a" "$stage"; then
      filled=$((filled + 1))
    else
      lib_warn "the mail of ${a} could not be brought (see ${LOG_FILE})"
      failed=$((failed + 1))
    fi
    _mail_stage_drop "$stage"
  done
  if (( filled > 0 )); then lib_ok "The mail of ${filled} mailbox(es) of ${d} is here; what was here before stayed"; fi
  # shown once and never logged, like a site's database password
  if ((${#fresh[@]} > 0)); then
    lib_warn "The passwords of these mailboxes could not be read there. Their new ones, shown only now:"
    printf '        %s\n' "${fresh[@]}"
    lib_note "Change one with: setup.sh mail box passwd <address>"
  fi
  lib_note "Mail for ${d} goes on arriving at the other server until its MX points here: setup.sh mail dns ${d}"
  if (( failed > 0 )); then
    lib_die "The mail of ${d} is only partly here" "${failed} mailbox(es) could not be filled" \
      "run it again for the mail alone: setup.sh import ${IMP_SSH_TARGET} --only ${d} --only-mail"
  fi
  return 0
}

lib_import_site_part() {   # index
  local i="$1" domain="" root="" kind="" db="" www="" conf="" docroot="" ids="" uid="" gid="" foreign=0
  local created=0 work="" dump="" n=0 home="" host="" imported=0 cfg=""
  local -a args=()
  domain="${IMP_DOMAIN[i]}"; root="${IMP_ROOT[i]}"; kind="${IMP_KIND[i]}"; db="${IMP_DB[i]}"
  www="${IMP_WWW[i]}"; conf="${IMP_CONF[i]}"
  lib_heading "${domain}  <-  ${IMP_SSH_TARGET}:${root}"
  lib_rollback_clear
  work="$(lib_mktemp -d)"

  # ---- the site ------------------------------------------------------------
  if ! lib_domain_registered "$domain"; then
    args=(--no-ssl)
    if [[ "$kind" == "static" && "$db" == "-" ]]; then args+=(--static --no-db); fi
    if (( www )); then args+=(--www); fi
    lib_info "Adding the site ${domain}"
    _import_add "$domain" "${args[@]}" \
      || lib_die "The site ${domain} could not be added" "see what 'add' said above" "clear that up, then run the import again"
    created=1
  fi
  lib_domain_state_load "$domain"
  docroot="${D_HOME}/public_html"
  case "$D_MODE" in
    php|wordpress|static) ;;
    *) lib_die "${domain} is a ${D_MODE} site here" "nothing is served from its public_html" "import it under another name: --path ${root} --as <domain>" ;;
  esac
  [[ -d "$docroot" && ! -L "$docroot" ]] \
    || lib_die "${docroot} is not a directory" "the document root of ${domain} is missing, or a link" "setup.sh doctor"
  if (( ! created )); then
    lib_info "A backup of ${domain} as it is now comes first"
    lib_backup_domain "$domain" --tag pre-import --keep 0 --no-mail \
      || lib_die "${domain} was not imported" "the backup of what is here could not be made: ${BK_ERROR}" "nothing was changed; check the disk space, then run it again"
  fi

  # ---- files ---------------------------------------------------------------
  if (( ! IMP_OPT_NO_FILES )); then
    if ! ids="$(_domain_fix_owner_ids "$D_HOME")"; then lib_die "The files of ${domain} were not copied" "$ids" "setup.sh doctor"; fi
    read -r uid gid <<<"$ids"
    foreign="$(_domain_wp_foreign_count "$docroot" "$uid" "$gid")"
    # what root uploaded there is something the site's user could not replace
    if (( foreign > 0 )); then
      lib_domain_fix_owner_guard
      lib_domain_fix_owner "$domain" \
        || lib_die "The files of ${domain} were not copied" "what is in ${docroot} could not all be handed to ${D_USER} (see above)" "clear that up, then run it again"
    fi
    if _domain_wp_placeholder "$docroot"; then lib_domain_as_user rm -f -- "${docroot}/index.html" || true; fi
    lib_info "Copying the files ($(_import_mb "${IMP_KB[i]}")) into ${docroot} as ${D_USER} ..."
    # tar's status 1 is "a file changed while it was read": the other server is live. The
    # directories that are here keep their modes (public_html's own is this server's business).
    _import_ssh "tar -C '${root}' --exclude=./wp-content/cache -czf - . ; r=\$?; [ \"\$r\" -le 1 ]" </dev/null 2>>"$LOG_FILE" \
      | lib_domain_as_user tar -C "$docroot" --no-overwrite-dir -xzpf - 2>>"$LOG_FILE" \
      || lib_die "The files of ${domain} could not all be copied" \
           "the connection dropped, the disk is full, or ${IMP_SSH_TARGET} cannot read everything in ${root} (see the log)" \
           "what was copied stays; run the import again to complete it"
    # a wp-config.php kept one directory above the document root there
    if [[ "$conf" != "-" && "$conf" != "${root}/wp-config.php" ]]; then
      _import_ssh "cat '${conf}'" </dev/null 2>>"$LOG_FILE" | lib_domain_as_user tee "${docroot}/wp-config.php" >/dev/null \
        || lib_warn "${conf} could not be copied: ${docroot}/wp-config.php is missing"
    fi
    lib_ok "Files of ${domain} copied into ${docroot}"
  fi

  # ---- database ------------------------------------------------------------
  if [[ "$db" != "-" ]] && (( ! IMP_OPT_NO_DB )); then
    if [[ "$D_MODE" == "static" ]]; then
      lib_warn "${domain} is a static site here: its database ${db} was left where it is"
    else
      if ! lib_db_info_load "$domain"; then lib_db_create_for_domain "$domain"; fi
      dump="${work}/dump.sql.gz"
      lib_info "Fetching the database ${db} ..."
      [[ "$conf" != "-" ]] || conf=""
      lib_import_remote_dump | _import_ssh "DB='${db}' CONF='${conf}' bash -s" >"$dump" 2>"${work}/dump.err" \
        || { cat "${work}/dump.err" >>"$LOG_FILE" 2>/dev/null || true
             lib_die "The database ${db} could not be fetched" "$(tail -n 1 "${work}/dump.err" 2>/dev/null | tr -c '[:print:]' ' ' || true)" \
               "the database here was not touched; the files are in place. Bring it yourself (setup.sh credentials ${domain}), or run the import again"; }
      n="$(gzip -dc "$dump" 2>/dev/null | tail -n 5 | grep -c 'Dump completed' || true)"
      (( n > 0 )) || lib_die "The copy of the database ${db} is not complete" "it does not end the way a dump ends: the connection dropped, or the disk there is full" \
        "the database here was not touched; run the import again"
      # MySQL 8's default collation is one MariaDB does not have
      n="$(gzip -dc "$dump" | grep -c 'utf8mb4_0900_ai_ci' || true)"
      if (( n > 0 )); then
        lib_info "The tables use MySQL 8's utf8mb4_0900_ai_ci, which MariaDB does not have: they become utf8mb4_unicode_520_ci"
        gzip -dc "$dump" | sed -e 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_520_ci/g' | gzip -c >"${work}/dump2.sql.gz"
        dump="${work}/dump2.sql.gz"
      fi
      lib_db_restore_domain "$domain" "$dump" \
        || lib_die "The database of ${domain} could not be imported" "an SQL error (see the log)" \
             "its tables may be half replaced: run the import again$( (( created )) || printf ', or go back with: setup.sh restore %s --file <the pre-import archive>' "$domain")"
      imported=1
      lib_ok "Database ${db} imported into ${DBI_NAME}"
    fi
  fi

  # ---- wp-config.php: the database it has here -------------------------------
  cfg="${docroot}/wp-config.php"
  if (( imported )) && lib_domain_as_user test -f "$cfg" 2>/dev/null; then
    lib_domain_as_user cat "$cfg" >"${work}/wp-config.in" 2>/dev/null || true
    if [[ "${DBI_NAME}${DBI_USER}${DBI_PASS}" =~ ^[A-Za-z0-9_]+$ ]] \
       && lib_import_wpconfig_rewrite "$DBI_NAME" "$DBI_USER" "$DBI_PASS" <"${work}/wp-config.in" >"${work}/wp-config.out" \
       && lib_domain_as_user tee "$cfg" <"${work}/wp-config.out" >/dev/null; then
      lib_ok "wp-config.php now names the database ${DBI_NAME} of this server"
    else
      lib_warn "wp-config.php still has the database login of the other server: put in the one of this server (setup.sh credentials ${domain})"
    fi
    home="$(_import_wp_home "${work}/wp-config.in")"
    host="${home#*://}"; host="${host%%/*}"; host="${host,,}"
    if [[ "$host" == "www.${domain}" ]]; then
      if (( created )); then
        # read back first: the database was written into the record after it was loaded
        lib_domain_state_load "$domain"
        D_WWW=1; D_WWW_PRIMARY=1
        lib_domain_state_save
        lib_domain_apply_config "serve ${domain} as www.${domain}" \
          || lib_warn "www.${domain} could not be set up: setup.sh doctor"
        lib_ok "This WordPress lives at www.${domain}: the site answers there, and ${domain} sends its visitors on to it"
      elif (( ! D_WWW || ! D_WWW_PRIMARY )); then
        lib_warn "This WordPress lives at www.${domain}, and the site here is not set up to answer under that name"
      fi
    elif [[ -n "$host" && "$host" != "$domain" ]]; then
      lib_warn "This WordPress says its address is ${home}, not ${domain}: its pages will send visitors there"
    fi
  elif (( imported )); then
    lib_note "The application's own settings still name the database of the other server; the one here: setup.sh credentials ${domain}"
  fi
  rm -f -- "${work}/wp-config.in" "${work}/wp-config.out" 2>/dev/null || true
  lib_rollback_clear
  lib_log_write INFO "imported ${domain} from ${IMP_SSH_TARGET}:${root} (database: ${db})"
  lib_ok "${domain} is here: ${docroot}"
}

# =============================================================================
#  import command
# =============================================================================
lib_import_main() {
  local a="" target="" port="22" key="" pwfile="" list=0 all=0 only="" no_create=0 path="" as="" dbname=""
  local i=0 n=0 here="" ans="" x="" total_kb=0 avail_kb=0 found=0 okc=0 what="" mkb=0 mail_kb=0
  local -a chosen=() todo=() failed=()
  IMP_OPT_NO_DB=0; IMP_OPT_NO_FILES=0; IMP_OPT_NO_MAIL=0; IMP_OPT_ONLY_MAIL=0
  while (($# > 0)); do
    a="$1"; shift
    case "$a" in
      -h|--help|help)  lib_import_usage; return 0 ;;
      --port)          port="${1:-}"; shift || true ;;
      --key)           key="${1:-}"; shift || true ;;
      --password-file) pwfile="${1:-}"; shift || true ;;
      --list)          list=1 ;;
      --all)           all=1 ;;
      --only)          only="${1:-}"; shift || true ;;
      --no-create)     no_create=1 ;;
      --path)          path="${1:-}"; shift || true ;;
      --as)            as="${1:-}"; as="${as,,}"; shift || true ;;
      --db)            dbname="${1:-}"; shift || true ;;
      --no-db)         IMP_OPT_NO_DB=1 ;;
      --no-files)      IMP_OPT_NO_FILES=1 ;;
      --no-mail)       IMP_OPT_NO_MAIL=1 ;;
      --only-mail)     IMP_OPT_ONLY_MAIL=1 ;;
      -*)              lib_import_usage >&2; lib_die "Unknown option for import: ${a}" "" "see the usage above" ;;
      *)               [[ -z "$target" ]] || lib_die "import takes one server at a time" "" "setup.sh import ${target}"
                       target="$a" ;;
    esac
  done
  if [[ -z "$target" ]]; then
    lib_import_usage >&2
    lib_die "The other server is missing" "" "setup.sh import root@203.0.113.10"
  fi
  _import_target_ok "$target" || lib_die "Invalid server '${target}'" "expected user@host or host, by name or address" "setup.sh import root@203.0.113.10"
  [[ "$target" == *@* ]] || target="root@${target}"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || lib_die "Invalid --port '${port}'" "" "--port 22"
  [[ -z "$key" || -r "$key" ]] || lib_die "The key ${key} cannot be read" "" "--key /root/.ssh/id_ed25519"
  [[ -z "$pwfile" || -r "$pwfile" ]] || lib_die "The password file ${pwfile} cannot be read" "" "a file with the password on its first line, mode 0600"
  (( ! (IMP_OPT_NO_DB && IMP_OPT_NO_FILES) )) || lib_die "--no-db and --no-files together leave nothing to bring" "" "drop one of them; the mailboxes alone come with --only-mail"
  (( ! (IMP_OPT_NO_MAIL && IMP_OPT_ONLY_MAIL) )) || lib_die "--no-mail and --only-mail together leave nothing to bring" "" "drop one of them"
  if [[ -n "$path" || -n "$as" ]]; then
    [[ -n "$path" && -n "$as" ]] || lib_die "--path and --as go together" "one directory there becomes one site here" "--path /usr/local/lsws/Example/html --as example.com"
    _import_path_ok "$path" || lib_die "Invalid --path '${path}'" "a full path made of letters, digits and . _ - + @ /" "--path /var/www/html"
    lib_domain_valid "$as" || lib_die "Invalid domain name '${as}'" "" "--as example.com"
    [[ -z "$only" ]] && (( ! all )) || lib_die "--path brings one directory" "--all and --only choose among the sites found there" "leave them out"
  fi
  [[ -z "$dbname" || -n "$path" ]] || lib_die "--db belongs to --path" "the database of a site that was found is read from its wp-config.php" "--path DIR --as DOMAIN --db NAME"
  [[ -z "$dbname" ]] || _import_dbname_ok "$dbname" || lib_die "Invalid --db '${dbname}'" "" "--db shop_db"
  lib_require_tools
  lib_require_installed
  # a server installed for mail alone takes the mailboxes and leaves the sites where they are
  if lib_server_mail_only && (( ! IMP_OPT_ONLY_MAIL )); then
    (( ! IMP_OPT_NO_MAIL )) || lib_die "This server is set up for mail only, so no site can be imported here" "it was installed with --mail-only" "leave --no-mail out to bring the mailboxes"
    lib_info "This server is set up for mail only: the mailboxes are brought, the sites are not"
    IMP_OPT_ONLY_MAIL=1
  fi
  if (( IMP_OPT_ONLY_MAIL )); then
    [[ -z "$path" ]] || lib_die "--path brings a directory, and --only-mail brings no files" "" "leave one of them out"
    lib_mail_installed || lib_die "This server runs no mail, so no mailbox can be brought here" "" "setup.sh install --with-mail --mail-hostname mail.example.com"
  fi
  lib_have ssh || lib_apt_install openssh-client || lib_die "ssh is not installed" "apt could not install it" "apt-get install openssh-client"

  IMP_SSH_TARGET="$target"
  lib_import_connect "$port" "$key" "$pwfile"
  lib_import_scan "$path" "$as"
  if [[ -n "$IMP_REMOTE_USER" && "$IMP_REMOTE_USER" != "root" ]]; then
    lib_warn "Logged in there as ${IMP_REMOTE_USER}, not root: sites whose files that user cannot read will be missing or incomplete"
  fi

  if [[ -n "$path" ]]; then
    # the one directory, under the name it was given
    if ((${#IMP_DOMAIN[@]} != 1)); then
      lib_import_disconnect
      lib_die "${path} is not a directory on ${IMP_SSH_TARGET}" "or ${IMP_REMOTE_USER:-the user} cannot read it" "check it there: ls -ld ${path}"
    fi
    if [[ -n "$dbname" ]]; then IMP_DB[0]="$dbname"; fi
    chosen=(0)
  fi

  if (( list )); then
    lib_import_list_print
    lib_import_disconnect
    return 0
  fi

  n=${#IMP_DOMAIN[@]}
  if [[ -z "$path" ]]; then
    lib_import_list_print
    if (( n == 0 )); then
      lib_import_disconnect
      lib_die "Nothing to import from ${IMP_SSH_TARGET}" "no directory there is served under a domain name" "name one yourself: --path <directory> --as <domain>"
    fi
    if (( all )); then
      for (( i = 0; i < n; i++ )); do chosen+=("$i"); done
    elif [[ -n "$only" ]]; then
      for x in ${only//,/ }; do
        x="${x,,}"; found=0
        for (( i = 0; i < n; i++ )); do
          if [[ "${IMP_DOMAIN[i]}" == "$x" ]]; then chosen+=("$i"); found=1; break; fi
        done
        (( found )) || { lib_import_disconnect; lib_die "${x} was not found on ${IMP_SSH_TARGET}" "it is not in the list above" "setup.sh import ${target} --list"; }
      done
    elif lib_is_interactive; then
      lib_tr "Which ones? Numbers (1,3 or 2-5), \"all\", or nothing to leave"
      printf '%s%s%s: ' "$C_BLD" "$LIB_TR" "$C_RST"
      read -r ans || ans=""
      if [[ -z "${ans// /}" ]]; then lib_import_disconnect; lib_info "Nothing was imported"; return 0; fi
      mapfile -t chosen < <(lib_import_pick "$ans" "$n" || true)
      ((${#chosen[@]} > 0)) || { lib_import_disconnect; lib_die "\"${ans}\" is not a choice from the list" "" "numbers such as 1,3 or 2-5, or all"; }
    else
      lib_import_disconnect
      lib_die "Which sites?" "nobody is there to ask" "add --all or --only a.com,b.com   (--list only shows them)"
    fi
  fi

  # ---- what will happen ------------------------------------------------------
  lib_heading "Import from ${IMP_SSH_TARGET}"
  for i in "${chosen[@]}"; do
    x="${IMP_DOMAIN[i]}"
    what="$(_import_mail_what "$x")"; mkb="$(_import_mail_kb "$x")"
    if [[ "${IMP_KIND[i]}" == "mail" ]] || (( IMP_OPT_ONLY_MAIL )); then
      # the mailboxes alone
      if [[ -z "$what" ]]; then lib_note "${x}: left out, it has no mailbox or alias there"; continue; fi
      if (( IMP_OPT_NO_MAIL )); then lib_note "${x}: left out, it has mailboxes there and no site (--no-mail)"; continue; fi
      if ! lib_mail_installed; then lib_note "${x}: left out, it has mailboxes there and no site, and this server runs no mail"; continue; fi
      if [[ "$(lib_import_here "$x" mail)" == "new" ]]; then
        if (( no_create )); then lib_note "${x}: left out, it is not a domain here (--no-create)"; continue; fi
        lib_note "${x}: ${what}; it becomes a mail domain here"
      else
        lib_note "${x}: ${what}, added to the mail it has here"
      fi
      todo+=("$i"); mail_kb=$(( mail_kb + mkb ))
      continue
    fi
    here="$(lib_import_here "$x")"
    case "$here" in
      new)
        if (( no_create )); then lib_note "${x}: left out, it is not a site here (--no-create)"; continue; fi
        lib_note "${x}: a new site; ${IMP_ROOT[i]} ($(_import_mb "${IMP_KB[i]}"))$( [[ "${IMP_DB[i]}" == "-" ]] || printf ', database %s' "${IMP_DB[i]}")" ;;
      exists)
        lib_note "${x}: is here already. Files with the same name are replaced, the others stay$( [[ "${IMP_DB[i]}" == "-" ]] || (( IMP_OPT_NO_DB )) || printf '; the tables of its database are replaced by those of %s' "${IMP_DB[i]}"). A backup is taken first" ;;
      *) lib_warn "${x}: left out, it is ${here}"; continue ;;
    esac
    todo+=("$i"); total_kb=$(( total_kb + IMP_KB[i] ))
    if [[ -n "$what" ]] && (( ! IMP_OPT_NO_MAIL )); then
      lib_note "${x}: and its ${what}"
      mail_kb=$(( mail_kb + mkb ))
    fi
  done
  if ((${#todo[@]} == 0)); then
    lib_import_disconnect
    lib_info "Nothing was imported"
    return 0
  fi
  avail_kb="$(df -Pk "$SITES_ROOT" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  if [[ "$avail_kb" =~ ^[0-9]+$ ]] && (( ! IMP_OPT_NO_FILES )) && (( total_kb + total_kb / 10 > avail_kb )); then
    lib_import_disconnect
    lib_die "Not enough room in ${SITES_ROOT}" "the sites are $(_import_mb "$total_kb") and $(_import_mb "$avail_kb") is free" "choose fewer sites, or make room"
  fi
  # a mailbox is unpacked beside where it goes before it is merged in: twice its size
  avail_kb="$(df -Pk "$MAIL_VMAIL_HOME" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  if [[ "$avail_kb" =~ ^[0-9]+$ ]] && (( mail_kb > 0 && mail_kb * 2 > avail_kb )); then
    lib_import_disconnect
    lib_die "Not enough room in ${MAIL_VMAIL_HOME}" "the mailboxes are $(_import_mb "$mail_kb"), twice that is needed while they are copied, and $(_import_mb "$avail_kb") is free" "choose fewer domains, make room, or leave the mail out with --no-mail"
  fi
  if (( OPT_DRY_RUN )); then
    lib_info "[dry-run] would import ${#todo[@]} site(s), $(_import_mb "$total_kb") of files and $(_import_mb "$mail_kb") of mail; nothing was copied"
    lib_import_disconnect
    return 0
  fi
  if ! lib_confirm "Import ${#todo[@]} site(s) from ${IMP_SSH_TARGET}?" n; then
    lib_import_disconnect
    lib_die "Nothing was imported" "not confirmed" "answer y, or add --yes"
  fi

  # Each site on its own: one that fails says why and leaves the others to go on.
  for i in "${todo[@]}"; do
    _import_site_run "$i"
    if (( IMP_RC == 0 )); then okc=$((okc + 1)); else failed+=("${IMP_DOMAIN[i]}"); fi
  done
  lib_import_disconnect
  lib_manifest_set '.updated_at' "$(lib_iso_now)"
  if (( okc > 0 )) && (( IMP_OPT_ONLY_MAIL )); then
    printf '\n'
    lib_ok "The mailboxes of ${okc} domain(s) were brought from ${IMP_SSH_TARGET}"
    lib_note "Not copied: sieve filters, and what a webmail keeps. The other server was only read."
  elif (( okc > 0 )); then
    lib_ols_htaccess_reload "the imported sites brought theirs" \
      || lib_warn "OpenLiteSpeed did not reload; rewrite rules work after: systemctl restart ${OLS_SERVICE}"
    printf '\n'
    lib_ok "${okc} site(s) imported from ${IMP_SSH_TARGET}"
    lib_note "They answer over HTTP here. To see one before its DNS moves, put this server's address and the domain into your own computer's hosts file."
    lib_note "Once a domain's DNS points here, its certificate: setup.sh renew-ssl <domain>"
    lib_note "Not copied: certificates, cron jobs, sieve filters of the mail. The other server was only read."
  fi
  if ((${#failed[@]} > 0)); then
    lib_die "Not imported: ${failed[*]}" "see the errors above" "clear them up and run the import again for those: --only $(IFS=,; printf '%s' "${failed[*]}")"
  fi
  return 0
}
