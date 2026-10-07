#!/usr/bin/env bash
# lib/import.sh - import: the sites of another server, brought here over SSH. It looks at what
#                 the other server serves (OpenLiteSpeed's virtual hosts, and the directories
#                 under /home, /var/www and /www/wwwroot that are named after a domain), lists
#                 them, asks which ones to bring, adds the sites that are not here yet, copies
#                 the files as the site's own user and the database a WordPress names, and
#                 points wp-config.php at the database it has here. The mailboxes of a
#                 domain follow it: the addresses the other server's Dovecot knows, with the
#                 passwords they had where the hashes can be read, the mail itself, and the
#                 domain's aliases and forwarders. A new site gets the PHP version it ran
#                 there, and its cron jobs run here as the site's own user.
#                 Nothing is changed on the other server.

IMP_SSH_TARGET=""
IMP_REMOTE_USER=""
declare -ga IMP_SSH_OPTS=()
# one entry per site found, the same index in each ("mail": a domain with mailboxes and no site)
declare -ga IMP_DOMAIN=() IMP_ROOT=() IMP_KB=() IMP_KIND=() IMP_DB=() IMP_WWW=() IMP_CONF=() IMP_PHP=()
# ... and the two PHP limits this server keeps per site, as megabytes ("-": not known)
declare -ga IMP_MEM=() IMP_UPL=()
IMP_DEF_MEM=0 IMP_DEF_UPL=0
# one entry per cron job found: the document root it belongs to, when it runs, what it runs
declare -ga IMP_CRON_ROOT=() IMP_CRON_WHEN=() IMP_CRON_CMD=()
IMP_OPT_FULL=0
# one entry per certificate found: the domain, the certificate file there, its key file
declare -ga IMP_CERT_DOMAIN=() IMP_CERT_FILE=() IMP_CERT_KEY=()
# one entry per database a site has beside its first: the directory, the name, the file that names it
declare -ga IMP_XDB_ROOT=() IMP_XDB_NAME=() IMP_XDB_CONF=()
IMP_OPT_NO_SSL=0
# the CA file a certificate is checked against ("": the system's), and what counts as now (tests)
IMP_SSL_CAFILE="${IMP_SSL_CAFILE:-}"
IMP_SSL_NOW="${IMP_SSL_NOW:-}"
IMP_OPT_NO_CRON=0
IMP_OPT_CHECK=0 IMP_OPT_FIX=0
# directories that are served there under no name this server could give a site
declare -ga IMP_NAMELESS=()
# ... and what the listing said of each, for the day one is given a name (lib_import_nameless_take)
declare -ga IMP_NL_KB=() IMP_NL_KIND=() IMP_NL_DB=() IMP_NL_CONF=() IMP_NL_PHP=() IMP_NL_MEM=() IMP_NL_UPL=()
IMP_TAKEN=0 IMP_ASKED=""
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
Kullanım: setup.sh import <[user@]host> [seçenekler]
  Siteleri başka bir sunucudan SSH üzerinden bu sunucuya getirir: dosyalar sitenin
  public_html dizinine, sitenin kendi kullanıcısı olarak; bir WordPress'in veritabanı da
  buradaki site veritabanına aktarılır ve wp-config.php ona göre ayarlanır. Henüz burada
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
  --db NAME              --path ile: getirilecek veritabanı, sitenin kendi dosyaları
                         hangisi olduğunu söylemiyorsa
  --no-db  --no-files    Veritabanları ya da dosyalar dışarıda bırakılır
  --no-mail              Posta kutuları dışarıda bırakılır
  --no-cron              Cron işleri dışarıda bırakılır
  --no-ssl               Sertifikalar dışarıda bırakılır
  --full                 Yalnızca son aktarımdan beri orada değişenleri değil, her dosyayı yeniden kopyalar
  --check                Hiçbir şeyi değiştirmez: sitenin orada ve burada olan her dosya ve dizinini
                         karşılaştırır, eksik olanları (en üst yolları) ve boyutu farklı olanları söyler
  --fix                  --check ile: eksik olanları getirir, yalnızca onları (hiçbir şey ezilmez)
  --only-mail            Yalnızca posta kutuları getirilir: burada site olmayan alan adı bir
                         posta alan adı olur (yalnızca posta için kurulmuş sunucuda hep böyledir)
  Bu sunucuda posta kuruluysa seçilen alan adının posta kutuları da onunla gelir: öteki
  sunucudaki Dovecot'un bildiği adresler ve Maildir dizinlerindeki postalar, buradakilerle
  birleştirilir - burada hiçbir şey silinmez. Öteki sunucu lomp ya da CyberPanel ise kutular
  şifrelerini korur; değilse her birine yeni şifre verilir ve bir kez gösterilir. Alan adının
  takma adları ve iletmeleri de gelir (lomp'un kendi dosyaları, CyberPanel tablosu ve
  Postfix'in sanal takma ad dosyaları); burada zaten olan bir takma ad olduğu gibi kalır.
  DNS kayıtlarına dokunulmaz: MX'i siz taşıyana kadar posta orada alınmaya devam eder
  (setup.sh mail dns <domain>).
  Eklenen site, bu sunucu kurabiliyorsa öteki sunucuda çalıştığı PHP sürümünü alır (OpenLiteSpeed
  yapılandırmasından okunur); memory_limit ve upload_max_filesize değerleri de
  bu sunucunun verdiğinden büyükse korunur. Burada zaten olan site kendi ayarlarını korur.
  Sitenin orada sunduğu sertifika da anahtarıyla birlikte gelir; böylece site, DNS taşınmadan
  önce burada HTTPS ile yanıt verir: OpenLiteSpeed sanal konağının gösterdiği ya da certbot'un
  o alan adı için tuttuğu sertifika. Yalnızca bir tarayıcı bugün o alan adı için kabul
  edecekse (ya da bir Cloudflare origin sertifikasıysa) alınır; burada sertifikası olan site
  kendisininkini korur. Aktarılan sertifika yenilenmez: DNS buraya yönlenince
  "setup.sh renew-ssl --missing" böyle her siteye kendi sertifikasını alır.
  Sitenin cron işleri de onunla gelir ve burada sitenin kendi kullanıcısı olarak çalışır:
  dosyalarının sahibi olan hesabın crontab'ı ile root'un crontab'ında ve /etc/cron.d içinde
  sitenin dizinini ya da alan adını içeren satırlar; yollar bu sunucuya göre yeniden yazılır.
  Siz oradan kaldırana kadar öteki sunucuda da çalışmaya devam ederler.
  "setup.sh import cron <domain>" bir siteye verilenleri listeler, --clear hepsini kaldırır.
  Öteki sunucunun bir porta ilettiği ad da gelir: portunu bir Node.js uygulaması (package.json
  bulunan bir dizin) dinliyorsa o uygulamayla bir Node.js sitesi olarak eklenir - node_modules
  olmadan kodu, portu, başlatılma biçimi; kaynak bir lomp ise ortam değişkenleri, worker ve
  zamanlanmış işleri de - ve burada kurulur, derlenir, başlatılır; başka her ad aynı adrese
  bir proxy olur ve orada yanıt veren şey getirilmez.
  Daha önce aktarılmış bir site için yalnızca o zamandan beri öteki sunucuda oluşturulan ya da
  değişen dosyalar gelir (öteki sunucunun her dosya için tuttuğu zamana göre); bu arada burada
  değiştirilen ya da silinen dosya burada olduğu gibi kalır, --full ise her şeyi yeniden kopyalar.
  Oradaki belge kökü, üstünde "artisan" dosyası olan bir "public" dizini ise (Laravel), üstündeki
  uygulama da sitenin ana dizinine, public_html'in yanına gelir. cache, .cache ve caches adlı dizinler
  hiç kopyalanmaz.
  Kullanıcı (varsayılan root) sitelerin dosyalarını okuyabilmelidir; posta kutularını ve öteki
  hesapların crontab'larını yalnızca root görür. Kopyalanmayanlar: sieve filtreleri,
  sertifikalar ve --db ile adı verilmedikçe WordPress dışındaki uygulamaların veritabanları.
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
  --db NAME              With --path: the database to bring, when the site's own files do not
                         say which
  --no-db  --no-files    Leave the databases, or the files, out
  --no-mail              Leave the mailboxes out
  --no-cron              Leave the cron jobs out
  --no-ssl               Leave the certificates out
  --full                 Copy every file again, not only what changed there since the last import
  --check                Change nothing: compare every file and directory of the site there with
                         what is here, and name what is missing (the topmost paths) and what has
                         another size
  --fix                  With --check: bring what is missing, and only that (nothing is overwritten)
  --only-mail            Bring only the mailboxes: a domain that is no site here becomes a
                         mail domain (this is what happens on a server installed for mail alone)
  The mailboxes of a chosen domain come with it when this server runs mail: the addresses the
  other server's Dovecot knows and the mail in their Maildirs, merged into what is here -
  nothing here is deleted. They keep their passwords when the other server is a lomp or a
  CyberPanel; otherwise each gets a new one, shown once. The domain's aliases and forwarders
  come too (lomp's own, CyberPanel's, and the ones in Postfix's virtual alias files); one
  that exists here already stays as it is. The DNS records are not touched: mail goes on
  arriving there until you move the MX (setup.sh mail dns <domain>).
  A site that is added gets the PHP version it runs there (read from OpenLiteSpeed's
  configuration) when this server can install it, and its memory_limit and
  upload_max_filesize where they are above what this server gives; a site that is here
  keeps its own.
  The certificate a site answers with there comes too, with its key, so that the site
  answers over HTTPS here before its DNS has moved: the one its OpenLiteSpeed virtual host
  names, or the one certbot keeps for the domain. It is taken only when a browser would
  accept it for the domain today (or it is a Cloudflare origin certificate); a site that has
  a certificate here keeps its own. An imported certificate is not renewed: once the DNS
  points here, "setup.sh renew-ssl --missing" gets every such site one of its own.
  The cron jobs of a site come with it and run here as the site's user: the crontab of the
  account that owns its files, and the lines of root's crontab and /etc/cron.d that name its
  directory or its domain, with the paths rewritten for this server. They go on running on
  the other server too until you take them out there. "setup.sh import cron <domain>" lists
  the ones a site was given, and --clear removes them.
  A name that the other server passes on to a port comes too: one whose port a Node.js
  application listens on (a directory with a package.json) is added as a Node.js site with
  that application - its code without node_modules, the port, the way it is started; from a
  lomp also its environment values, workers and jobs - and is installed, built and started
  here; any other becomes a proxy to the same address, and what answers there is not brought.
  A site that was imported before gets only the files that were made or changed on the other
  server since then (by the time the other server itself noted for each file); a file that
  was changed or deleted here in the meantime is left as it is here, and --full copies
  everything again.
  When the document root there is a "public" directory with an "artisan" file above it (Laravel),
  the application above it comes into the site's home too, beside public_html. Directories named
  cache, .cache and caches are never copied.
  The user (default root) has to be able to read the sites' files, and only root sees the
  mailboxes and the other accounts' crontabs. Not copied: sieve filters, certificates, and
  the databases of applications other than WordPress unless --db names one.
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

# A cron job as another server lists it: when (five fields, or @daily and its kind - not
# @reboot, which is no schedule) and a command of printable characters on one line. Cron
# ignores a whole file that holds one line it cannot read, and the file these go into also
# carries the backups and the certificate renewals.
_import_cron_ok() {   # when command
  local w='^(@(yearly|annually|monthly|weekly|daily|midnight|hourly)|[0-9*/,-]+( [0-9*/,-]+){2}( [0-9A-Za-z*/,-]+){2})$'
  [[ "$1" =~ $w ]] || return 1
  [[ -n "${2// /}" && ${#2} -le 1000 ]] || return 1
  # (the mark this server's own entries end in is not something a job may carry)
  [[ "$2" != *"# server-setup:"* ]] || return 1
  [[ "$2" != *[![:print:]]* ]]
}

# The cron jobs found for one document root, as indexes into IMP_CRON_*, one per line.
_import_cron_of() {   # document root
  local k=0
  for (( k = 0; k < ${#IMP_CRON_ROOT[@]}; k++ )); do
    if [[ "${IMP_CRON_ROOT[k]}" == "$1" ]]; then printf '%d\n' "$k"; fi
  done
  return 0
}

# A size as php.ini writes one (128M, 1G, 65536K, a number of bytes) -> megabytes, or "-" for
# what is no limit to carry over: nothing, "-1" (none at all), or more than this server would
# ever give one request.
_import_size_mb() {   # value
  local v="${1^^}" mb=0
  case "$v" in
    [0-9]*G) v="${v%G}"; [[ "$v" =~ ^[0-9]{1,3}$ ]] || { printf -- '-'; return 0; }; mb=$(( v * 1024 )) ;;
    [0-9]*M) v="${v%M}"; [[ "$v" =~ ^[0-9]{1,6}$ ]] || { printf -- '-'; return 0; }; mb=$(( 10#$v )) ;;
    [0-9]*K) v="${v%K}"; [[ "$v" =~ ^[0-9]{1,10}$ ]] || { printf -- '-'; return 0; }; mb=$(( 10#$v / 1024 )) ;;
    *)       [[ "$v" =~ ^[0-9]{1,13}$ ]] || { printf -- '-'; return 0; }; mb=$(( 10#$v / 1048576 )) ;;
  esac
  if (( mb >= 1 && mb <= 16384 )); then printf '%d' "$mb"; else printf -- '-'; fi
}

# What a new site gets on this server when nothing is said, in megabytes.
_import_php_defaults() {
  lib_system_profile
  IMP_DEF_MEM="$CALC_PHP_MEMORY_MB"; IMP_DEF_UPL="$CALC_PHP_UPLOAD_MB"
}

# The limits a site that is added is given: the ones it had there where they are larger than
# what this server gives by itself - a site is not made smaller by moving. Prints the options
# for "add", one word a line.
_import_php_limits() {   # index
  if [[ "${IMP_MEM[$1]}" != "-" ]] && (( IMP_MEM[$1] > IMP_DEF_MEM )); then printf -- '--memory\n%dM\n' "${IMP_MEM[$1]}"; fi
  if [[ "${IMP_UPL[$1]}" != "-" ]] && (( IMP_UPL[$1] > IMP_DEF_UPL )); then printf -- '--upload\n%dM\n' "${IMP_UPL[$1]}"; fi
  return 0
}

# Can this server run a site on that PHP: it is installed, or the package is there to install.
_import_php_available() {   # version
  lib_php_installed "$1" || apt-cache show "$(lib_php_tag "$1")" >/dev/null 2>&1
}

# ---- the cron jobs a site was given ------------------------------------------------
# They are kept with the site's state, one "when<TAB>command" a line, with {HOME} for the
# site's home and {PHP} for its PHP: what is written into cron is made from that, so a site
# that is renamed, or moved to another PHP, has its jobs follow.
lib_import_cron_file() { printf '%s/cron.imported' "$(lib_domain_state_dir "$1")"; }

lib_import_cron_apply() {   # domain  (nothing kept for it: its entries, if any, go)
  local domain="$1" f="" when="" cmd="" n=0 php="php" entries=""
  f="$(lib_import_cron_file "$domain")"
  if [[ ! -s "$f" ]]; then lib_cron_remove_prefix "imported:${domain}:"; return 0; fi
  lib_domain_state_load "$domain" || return 1
  if [[ -n "$D_PHP" ]]; then php="$(lib_php_cli "$D_PHP")"; fi
  while IFS=$'\t' read -r when cmd; do
    _import_cron_ok "$when" "$cmd" || continue
    cmd="${cmd//"{HOME}"/"$D_HOME"}"; cmd="${cmd//"{PHP}"/"$php"}"
    n=$((n + 1))
    entries+="$(printf 'imported:%s:%d\t%s %s %s' "$domain" "$n" "$when" "$D_USER" "$cmd")"$'\n'
  done <"$f"
  printf '%s' "$entries" | lib_cron_replace_prefix "imported:${domain}:"
}

# A command of the other server, for this one: the site's directory there becomes its
# directory here, and an LSPHP named by its version becomes the site's own.
_import_cron_rewrite() {   # command, document root there
  local cmd="$1" root="$2" up=""
  cmd="${cmd//"$root"/"{HOME}/public_html"}"
  up="${root%/*}"
  if [[ "${root##*/}" == "public_html" && "$up" == /*/* ]]; then cmd="${cmd//"$up"/"{HOME}"}"; fi
  sed -E 's#/usr/local/lsws/lsphp[0-9]+/bin/(ls)?php#{PHP}#g' <<<"$cmd"
}

lib_import_cron() {   # index, domain
  local i="$1" domain="$2" k="" f="" n=0 tmp=""
  local -a mine=()
  mapfile -t mine < <(_import_cron_of "${IMP_ROOT[i]}")
  ((${#mine[@]} > 0)) || return 0
  f="$(lib_import_cron_file "$domain")"
  tmp="$(lib_mktemp)"
  for k in "${mine[@]}"; do
    printf '%s\t%s\n' "${IMP_CRON_WHEN[k]}" "$(_import_cron_rewrite "${IMP_CRON_CMD[k]}" "${IMP_ROOT[i]}")" >>"$tmp"
    n=$((n + 1))
  done
  # the other server is what says which jobs there are: a second run replaces the first one's
  lib_write_file "$f" 0600 root:root <"$tmp"
  rm -f "$tmp"
  lib_import_cron_apply "$domain" || { lib_warn "the cron jobs of ${domain} could not be written (setup.sh doctor)"; return 0; }
  lib_domain_state_load "$domain"
  lib_ok "${n} cron job(s) of ${domain} now run here as ${D_USER}:"
  grep -F -- "# server-setup:imported:${domain}:" "$CRON_FILE" 2>/dev/null | sed -e 's/ # server-setup:imported:.*$//' -e 's/^/        /' || true
  lib_warn "They still run on the other server as well: take them out there once ${domain} has moved, or here with: setup.sh import cron ${domain} --clear"
}

# "import cron <domain> [--clear]": the jobs a site was given, or none of them any more.
lib_import_cron_main() {   # domain [--clear]
  local domain="${1:-}" clear=0 f=""
  domain="${domain,,}"
  [[ "${2:-}" != "--clear" ]] || clear=1
  [[ -z "${2:-}" || "$clear" == 1 ]] || lib_die "Unknown option for import cron: ${2}" "" "setup.sh import cron <domain> [--clear]"
  lib_domain_arg_ok "$domain" && lib_domain_registered "$domain" \
    || lib_die "Site ${domain:-(none)} is not registered" "" "setup.sh import cron <domain> [--clear]"
  f="$(lib_import_cron_file "$domain")"
  if [[ ! -s "$f" ]]; then lib_info "${domain} was given no cron jobs by an import"; return 0; fi
  if (( clear )); then
    if (( OPT_DRY_RUN )); then lib_info "[dry-run] would remove the imported cron jobs of ${domain}"; return 0; fi
    rm -f -- "$f"
    lib_import_cron_apply "$domain"
    lib_ok "The imported cron jobs of ${domain} are gone"
    return 0
  fi
  grep -F -- "# server-setup:imported:${domain}:" "$CRON_FILE" 2>/dev/null | sed -e 's/ # server-setup:imported:.*$//' || true
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
#   S <domain|-> <document root> <kilobytes> <static|php|wordpress> <database|-> <www 0|1> <wp-config.php|-> <ols|dir|path> <PHP version|-> <memory_limit|-> <upload_max_filesize|->
#   C <document root> <when: five fields or @word> <command>
#   T <domain> <certificate file> <key file>
#   D <document root> <one more database> <the file that names it>
#   M <address> <its Maildir|-> <kilobytes> <password hash|->
#   A <alias address, or @domain> <where it goes, addresses divided by commas>
# The database of a site that is no WordPress is the one its own configuration files name
# (lib_import_remote_lib). Plain sh, awk and sed: the other server is whatever it is. LOMP_IMPORT_ONLY names one
# directory to describe instead; LOMP_IMPORT_ROOT stands in front of the fixed paths, and
# LOMP_IMPORT_OWNER is the account every site's files are said to belong to (both for tests).
# What both scripts that run on the other server share - and what this server runs on the
# files once they are here: where an application keeps its database login, and what it is.
#   dbconf FILE [NAME]  F <name|user|pass|host> <line> <column> <length> <the value as written>
#                       (NAME: what the file is called, when FILE is a copy of it)
#   dbconf_val FILE F   one of them, as PHP reads it
#   dbconf_cnf FILE     a client option file with that login
#   dbconf_files DIR    the files worth looking into, the ones nearest the top first
#   dbconf_pick DIR     the file to take the login from
# The login is looked for the ways PHP applications write it: define('DB_NAME', ...), a
# variable or an array key (db_name, dbname, database, veritabani ...; user, kullanici ...;
# password, sifre ...; host, sunucu ...), KEY=value in a .env, a PDO "mysql:host=...;dbname=...",
# and the arguments of mysqli_connect() or new mysqli(). A name that says "database" outright
# (db_user) counts before one that could be anything's (user). Plain sh and awk; no single
# quote inside the awk program, which the shell holds in a pair of them.
lib_import_remote_lib() {
  cat <<'IMPORT_LIB'
TAB="$(printf '\t')"
dbconf() {
  awk -v fn="${2:-$1}" '
  function ok(f, v) {
    if (f == "name") return v ~ /^[A-Za-z0-9_-]+$/
    if (f == "user") return v ~ /^[A-Za-z0-9_.@-]+$/
    if (f == "host") return v ~ /^[A-Za-z0-9_.:\/-]+$/
    return 1
  }
  function put(f, prio, col, len,   v) {
    v = substr(L, col, len)
    if (!ok(f, v)) return
    if ((f in best) && best[f] <= prio) return
    best[f] = prio; rec[f] = NR "\t" col "\t" len "\t" v
  }
  function quoted(p, q,   i, c) {
    for (i = p; i <= length(L); i++) {
      c = substr(L, i, 1)
      if (c == "\\") { i++; continue }
      if (c == q) { VLEN = i - p; return 1 }
    }
    return 0
  }
  function key(f, prio, keys,   re, p) {
    re = "(^|[^a-z0-9_])(" keys ")[\047\"]?[ \t]*\\]?[ \t]*(=>|=|:|,)[ \t]*[\047\"]"
    if (!match(LOW, re)) return
    p = RSTART + RLENGTH
    if (quoted(p, substr(L, p - 1, 1))) put(f, prio, p, VLEN)
  }
  function bare(f, prio, keys,   re, p, v) {
    re = "^[ \t]*(export[ \t]+)?(" keys ")[ \t]*=[ \t]*"
    if (!match(LOW, re)) return
    p = RSTART + RLENGTH
    v = substr(L, p); sub(/[ \t\r]+$/, "", v)
    if (v ~ /^[\047"]/) return
    sub(/[ \t]+#.*$/, "", v)
    put(f, prio, p, length(v))
  }
  function dsn(f, word,   p, rest, n) {
    if (!match(LOW, word "=")) return
    p = RSTART + RLENGTH; rest = substr(L, p)
    n = match(rest, /[;\047" )]/)
    put(f, 2, p, (n ? n - 1 : length(rest)))
  }
  function call(   p, n, rest, col, len) {
    if (!match(LOW, /(mysqli_connect|mysqli_real_connect|new[ \t]+mysqli|mysql_p?connect)[ \t]*\(/)) return
    p = RSTART + RLENGTH; n = 0
    while (n < 4) {
      rest = substr(L, p)
      if (!match(rest, /^[ \t]*[\047"]/)) break
      p += RLENGTH
      if (!quoted(p, substr(L, p - 1, 1))) break
      n++; col[n] = p; len[n] = VLEN
      p += VLEN + 1
      rest = substr(L, p)
      if (!match(rest, /^[ \t]*,/)) break
      p += RLENGTH
    }
    if (n < 3) return
    put("host", 2, col[1], len[1]); put("user", 2, col[2], len[2]); put("pass", 2, col[3], len[3])
    if (n == 4) put("name", 2, col[4], len[4])
  }
  function seldb(   p, rest) {
    if (!match(LOW, /mysqli?_select_db[ \t]*\(/)) return
    p = RSTART + RLENGTH; rest = substr(L, p)
    if (!match(rest, /[\047"]/)) return
    p += RSTART
    if (quoted(p, substr(L, p - 1, 1))) put("name", 2, p, VLEN)
  }
  BEGIN {
    K["name", 1] = "db_name|dbname|db_database|database_name|db_adi|dbadi|veritabani|vt_adi|mysql_database|mysql_db"
    K["user", 1] = "db_username|db_user|dbusername|dbuser|db_kullanici|mysql_username|mysql_user"
    K["pass", 1] = "db_password|db_passwd|db_pass|dbpassword|dbpasswd|dbpass|db_sifre|db_pwd|mysql_password|mysql_pass"
    K["host", 1] = "db_hostname|db_host|dbhost|db_server|dbserver|mysql_host"
    K["name", 3] = "database|db"
    K["user", 3] = "username|kullanici_adi|kullanici|user|kadi"
    K["pass", 3] = "password|passwd|pass|pwd|sifre|parola"
    K["host", 3] = "hostname|host|server|sunucu"
    env = (fn ~ /\.env[^\/]*$/ || fn ~ /\.ini$/)
  }
  /^[ \t]*(\/\/|#|\*|\/\*|;)/ { next }
  {
    L = $0; LOW = tolower($0)
    key("name", 1, K["name", 1]); key("user", 1, K["user", 1]); key("pass", 1, K["pass", 1]); key("host", 1, K["host", 1])
    if (env) { bare("name", 1, K["name", 1]); bare("user", 1, K["user", 1]); bare("pass", 1, K["pass", 1]); bare("host", 1, K["host", 1]) }
    if (index(LOW, "mysql:")) { dsn("name", "dbname"); dsn("host", "host") }
    call(); seldb()
    key("name", 3, K["name", 3]); key("user", 3, K["user", 3]); key("pass", 3, K["pass", 3]); key("host", 3, K["host", 3])
    if (env) { bare("name", 3, K["name", 3]); bare("user", 3, K["user", 3]); bare("pass", 3, K["pass", 3]); bare("host", 3, K["host", 3]) }
  }
  END { for (f in rec) print "F\t" f "\t" rec[f] }
  ' "$1" 2>/dev/null
}
dbconf_val() {
  dbconf "$1" | awk -F"$TAB" -v f="$2" '$2 == f { print $6; exit }' | sed -e "s/\\\\\\(['\"\\\\]\\)/\\1/g"
}
dbconf_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
dbconf_cnf() {
  cu="$(dbconf_val "$1" user)"; cp="$(dbconf_val "$1" pass)"; ch="$(dbconf_val "$1" host)"
  [ -n "$cu" ] || return 1
  printf '[client]\nuser="%s"\npassword="%s"\n' "$(dbconf_esc "$cu")" "$(dbconf_esc "$cp")"
  case "$ch" in
    ''|localhost) ;;
    *:/*) printf 'socket="%s"\n' "${ch#*:}" ;;
    *:*)  printf 'host="%s"\nport=%s\n' "${ch%%:*}" "${ch##*:}" ;;
    *)    printf 'host="%s"\n' "$ch" ;;
  esac
}
dbconf_files() {
  {
    find "$1" -maxdepth 3 \( -name node_modules -o -name vendor -o -name cache -o -name uploads -o -name .git \) -prune -o -type f -size -200k \
      \( -iname 'config*.php' -o -iname 'configuration.php' -o -iname 'settings*.php' -o -iname 'db*.php' -o -iname 'database*.php' \
         -o -iname 'conn*.php' -o -iname 'baglan*.php' -o -iname 'ayar*.php' -o -iname 'vt*.php' -o -iname 'veritabani*.php' \
         -o -iname 'local*.php' -o -iname 'env.php' -o -iname '*.inc.php' -o -iname 'config*.inc' -o -name '.env' -o -name 'wp-config.php' \) -print 2>/dev/null
    [ ! -f "${1%/*}/.env" ] || printf '%s\n' "${1%/*}/.env"
  } | awk '{ n = gsub(/\//, "/"); print n "\t" $0 }' | sort -n | cut -f2- | sed -n '1,60p'
}
dbconf_pick() {
  pclient="$(command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null || true)"
  dbconf_files "$1" | while IFS= read -r pf; do
    pn="$(dbconf_val "$pf" name)"; pu="$(dbconf_val "$pf" user)"
    [ -n "$pn" ] && [ -n "$pu" ] || continue
    if [ -n "$pclient" ]; then
      pc="$(umask 077; mktemp)" || continue
      dbconf_cnf "$pf" >"$pc"
      if "$pclient" --defaults-extra-file="$pc" -N -B -e 'SELECT 1' "$pn" >/dev/null 2>&1; then rm -f "$pc"; printf 'T\t%s\n' "$pf"; break; fi
      rm -f "$pc"
    fi
    printf 'N\t%s\n' "$pf"
  done | awk -F"$TAB" '$1 == "T" { print $2; t = 1; exit } $1 == "N" && n == "" { n = $2 } END { if (!t && n != "") print n }'
}
# The certificate a name answers with: the pair its virtual host names, or the one certbot
# keeps under the name. Only where the two files are - what is in them is judged over here.
ssl_row() {   # domain [virtual host configuration]
  case "$1" in ''|-|*[!a-z0-9.-]*) return 0 ;; esac
  sc=""; sk=""
  if [ -n "${2:-}" ] && [ -r "$2" ]; then
    sc="$(awk '$1 == "certFile" { print $2; exit }' "$2" 2>/dev/null)"; sk="$(awk '$1 == "keyFile" { print $2; exit }' "$2" 2>/dev/null)"
  fi
  if [ ! -s "$sc" ] || [ ! -s "$sk" ]; then
    sc="${R:-}/etc/letsencrypt/live/$1/fullchain.pem"; sk="${R:-}/etc/letsencrypt/live/$1/privkey.pem"
  fi
  [ -s "$sc" ] && [ -s "$sk" ] || return 0
  printf 'T\t%s\t%s\t%s\n' "$1" "$sc" "$sk"
}
# The databases a site has beside its first: every other one a configuration file under it
# names AND that can be opened - by the account that runs this, or with the login in that
# file. A name nothing opens is a sample file's, or a database that is gone.
db_rows() {   # directory, its first database ("-": none)
  xclient="$(command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null || true)"
  [ -n "$xclient" ] || return 0
  xseen=" $2 "
  dbconf_files "$1" | while IFS= read -r xf; do
    xn="$(dbconf_val "$xf" name)"
    [ -n "$xn" ] || continue
    case "$xn" in *[!A-Za-z0-9_-]*) continue ;; esac
    case "$xseen" in *" $xn "*) continue ;; esac
    if ! "$xclient" -N -B -e 'SELECT 1' "$xn" >/dev/null 2>&1; then
      xc="$(umask 077; mktemp)" || continue
      dbconf_cnf "$xf" >"$xc" 2>/dev/null && "$xclient" --defaults-extra-file="$xc" -N -B -e 'SELECT 1' "$xn" >/dev/null 2>&1
      xr=$?
      rm -f "$xc"
      [ "$xr" = 0 ] || continue
    fi
    # (only now: a name one file could not open may be opened by the next that names it)
    xseen="$xseen$xn "
    printf 'D\t%s\t%s\t%s\n' "$1" "$xn" "$xf"
  done
}
IMPORT_LIB
}

lib_import_remote_scan() {
  lib_import_remote_lib
  lib_importapp_remote_lib
  cat <<'IMPORT_SCAN'
R="${LOMP_IMPORT_ROOT:-}"
ONLY="${LOMP_IMPORT_ONLY:-}"
TAB="$(printf '\t')"
printf 'U\t%s\n' "$(id -un 2>/dev/null || echo unknown)"
# The cron jobs of one site: every line of the crontab of the account that owns its files when
# that account is the site's own (its files lie in its home), and from anybody else's crontab
# - root's, /etc/cron.d - the lines that name the site's directory or its domain. What lomp
# itself schedules on a server it runs is not among them: this server schedules its own.
cron_lines() {   # file, 1 when each line names its user, 1 when every line counts, docroot, domain
  [ -r "$1" ] || return 0
  awk -v sys="$2" -v all="$3" -v root="$4" -v dom="$5" '
    /^[ \t]*#/ || /^[ \t]*$/ || /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/ { next }
    {
      line = $0; gsub(/\t/, " ", line); sub(/^ +/, "", line)
      n = (substr(line, 1, 1) == "@") ? 1 : 5
      when = ""
      for (i = 1; i <= n; i++) {
        if (!match(line, /^[^ ]+ +/)) next
        f = substr(line, 1, RLENGTH); sub(/ +$/, "", f)
        when = when (i > 1 ? " " : "") f
        line = substr(line, RLENGTH + 1)
      }
      if (sys == 1) { if (!match(line, /^[^ ]+ +/)) next; line = substr(line, RLENGTH + 1) }
      if (line == "") next
      if (all != 1 && index(line, root) == 0 && (dom == "-" || index(line, dom) == 0)) next
      print "C\t" root "\t" when "\t" line
    }' "$1" 2>/dev/null
}
cron_rows() {   # domain docroot
  owner="${LOMP_IMPORT_OWNER:-$(stat -c %U "$2" 2>/dev/null)}"
  ohome=""
  [ -z "$owner" ] || ohome="$(awk -F: -v u="$owner" '$1 == u { print $6; exit }' "$R/etc/passwd" 2>/dev/null)"
  own=0
  case "$owner" in ''|root|UNKNOWN) ;; *) case "$2/" in "${ohome:-/nowhere}"/*) [ "$ohome" = / ] || own=1 ;; esac ;; esac
  for sp in "$R/var/spool/cron/crontabs" "$R/var/spool/cron"; do
    [ -d "$sp" ] || continue
    for f in "$sp"/*; do
      [ -f "$f" ] || continue
      if [ "$own" = 1 ] && [ "${f##*/}" = "$owner" ]; then cron_lines "$f" 0 1 "$2" "$1"
      else cron_lines "$f" 0 0 "$2" "$1"; fi
    done
  done
  for f in "$R/etc/crontab" "$R/etc/cron.d"/*; do
    case "${f##*/}" in server-setup|lompstack*) continue ;; esac
    cron_lines "$f" 1 0 "$2" "$1"
  done
}
row() {   # domain docroot www source [PHP version, memory_limit, upload_max_filesize]
  root="${2%/}"
  [ -d "$root" ] || return 0
  kind=static; conf=-; db=-
  if [ -f "$root/wp-config.php" ]; then kind=wordpress; conf="$root/wp-config.php"
  elif [ -f "$root/wp-settings.php" ] && [ -f "${root%/*}/wp-config.php" ]; then kind=wordpress; conf="${root%/*}/wp-config.php"
  elif [ -n "$(find "$root" -maxdepth 1 -name '*.php' 2>/dev/null | sed -n 1p)" ]; then kind=php; fi
  if [ "$kind" = wordpress ]; then
    db="$(sed -n "s/^[[:space:]]*define([[:space:]]*['\"]DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$conf" 2>/dev/null | sed -n 1p)"
    [ -n "$db" ] || db=-
  elif [ "$kind" = php ]; then
    # some other application: the file that holds its database login, if one can be told
    c="$(dbconf_pick "$root")"
    if [ -n "$c" ]; then
      n="$(dbconf_val "$c" name)"
      if [ -n "$n" ]; then conf="$c"; db="$n"; fi
    fi
  fi
  kb="$(du -sk "$root" 2>/dev/null | cut -f1)"
  printf 'S\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$root" "${kb:-0}" "$kind" "$db" "$3" "$conf" "$4" "${5:--}" "${6:--}" "${7:--}"
  cron_rows "$1" "$root"
  if [ "$kind" != static ]; then db_rows "$root" "$db"; fi
}
# One PHP setting as a site has it: what its virtual host overrides, else its .user.ini, else
# the php.ini of the PHP it runs.
ini_of() {   # setting, virtual host configuration, document root, PHP version
  iv="$(awk -v k="$1" '($1 == "php_admin_value" || $1 == "php_value") && $2 == k { print $3; exit }' "$2" 2>/dev/null)"
  for ini in "$3/.user.ini" "$(find "$L/lsphp$(printf '%s' "$4" | tr -d .)/etc" -name php.ini 2>/dev/null | sed -n 1p)"; do
    [ -z "$iv" ] || break
    [ -r "$ini" ] || continue
    iv="$(awk -F= -v k="$1" '!/^[ \t]*[;#]/ { key = $1; gsub(/[ \t]/, "", key); if (key == k) { v = $2; sub(/;.*/, "", v); gsub(/[ \t"\r]/, "", v); print v; exit } }' "$ini" 2>/dev/null)"
  done
  printf '%s' "${iv:--}"
}
# "lsphp74" somewhere in a configuration file -> 7.4
php_of() {   # file
  [ -r "$1" ] || return 0
  sed -n 's/.*lsphp\([0-9]\)\([0-9]\).*/\1.\2/p' "$1" 2>/dev/null | sed -n 1p
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
    if command -v doveadm >/dev/null 2>&1; then p="$(doveadm mailbox path -u "$u" INBOX 2>/dev/null | sed -n 1p)"; fi
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
# the names that are passed on to a port instead (lib/importapp.sh)
app_rows

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
    # the PHP this virtual host runs: its own processor, or the one the server gives everybody
    pv="$(php_of "$cf")"
    [ -n "$pv" ] || pv="$(awk '/^[ \t]*extprocessor[ \t]/ { e = 1 } e && $1 == "path" { print; exit }' "$L/conf/httpd_config.conf" 2>/dev/null | sed -n 's/.*lsphp\([0-9]\)\([0-9]\).*/\1.\2/p')"
    pm="$(ini_of memory_limit "$cf" "$dr" "$pv")"; pu="$(ini_of upload_max_filesize "$cf" "$dr" "$pv")"
    app_ols "$cf" "$dm"
    dml=" $(printf '%s' "$dm" | tr 'A-Z' 'a-z') "
    seen=" "
    set -f
    for d in $dml; do
      [ "$d" != '*' ] && [ "$d" != - ] || continue
      b="${d#www.}"
      case "$seen" in *" $b "*) continue ;; esac
      seen="$seen$b "
      case "$dml" in *" www.$b "*) w=1 ;; *) w=0 ;; esac
      row "$b" "$dr" "$w" ols "$pv" "$pm" "$pu"
      ssl_row "$b" "$cf"
    done
    set +f
    [ "$seen" != " " ] || row - "$dr" 0 ols "$pv" "$pm" "$pu"
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
      # no index page: under /home that is somebody's home directory and no site. Where a
      # web server keeps what it serves (/var/www/html, a panel's wwwroot) it is one as soon
      # as anything is in it - an application whose pages are further down, a download area.
      if [ ! -f "$dir/index.php" ] && [ ! -f "$dir/index.html" ]; then
        # (not what a server keeps there for itself: the ACME challenges, CGI programs)
        case "$name" in acme|cgi-bin|letsencrypt) continue ;; esac
        case "$base" in */var/www|*/www/wwwroot) [ -n "$(ls -A "$dir" 2>/dev/null | sed -n 1p)" ] || continue ;; *) continue ;; esac
      fi
      root="$dir"
    fi
    case "$name" in
      *[!a-z0-9.-]*) name=- ;;
      *.*) name="${name#www.}" ;;
      *) name=- ;;
    esac
    row "$name" "$root" 0 dir
    ssl_row "$name"
  done
done
exit 0
IMPORT_SCAN
}

# Writes one database to stdout, gzipped. DB names it; CONF, when given, is the file - a
# wp-config.php, or another application's configuration - whose login is used if the account
# that runs this cannot read the database by itself. That
# login goes into a file only this account can read, never onto a command line.
lib_import_remote_dump() {
  lib_import_remote_lib
  cat <<'IMPORT_DUMP'
set -u
set -o pipefail 2>/dev/null || true
DB="${DB:-}"; CONF="${CONF:-}"
dumper="$(command -v mariadb-dump 2>/dev/null || command -v mysqldump 2>/dev/null || true)"
client="$(command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null || true)"
[ -n "$dumper" ] || { echo "lomp-import: no mysqldump or mariadb-dump on this server" >&2; exit 3; }
opts="--single-transaction --quick --triggers --default-character-set=utf8mb4"
if "$dumper" --help 2>/dev/null | grep -- '--no-tablespaces' >/dev/null; then opts="$opts --no-tablespaces"; fi
if [ -n "$client" ] && "$client" -N -B -e 'SELECT 1' "$DB" >/dev/null 2>&1; then
  "$dumper" $opts --routines "$DB" | gzip -c
  exit $?
fi
[ -n "$CONF" ] && [ -r "$CONF" ] || { echo "lomp-import: this account cannot open the database $DB, and there is no configuration file to take a login from" >&2; exit 4; }
umask 077
cnf="$(mktemp)" || exit 5
trap 'rm -f "$cnf"' EXIT
dbconf_cnf "$CONF" >"$cnf" || { echo "lomp-import: no database user in $CONF" >&2; exit 4; }
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
  local tag="" domain="" root="" kb="" kind="" db="" www="" conf="" php="" mem="" upl="" x="" dup=0 k=0
  IMP_DOMAIN=() IMP_ROOT=() IMP_KB=() IMP_KIND=() IMP_DB=() IMP_WWW=() IMP_CONF=() IMP_PHP=() IMP_NAMELESS=()
  IMP_NL_KB=() IMP_NL_KIND=() IMP_NL_DB=() IMP_NL_CONF=() IMP_NL_PHP=() IMP_NL_MEM=() IMP_NL_UPL=()
  IMP_MEM=() IMP_UPL=()
  IMP_CRON_ROOT=() IMP_CRON_WHEN=() IMP_CRON_CMD=()
  IMP_BOX=() IMP_BOX_DIR=() IMP_BOX_KB=() IMP_BOX_HASH=() IMP_ALIAS=() IMP_ALIAS_TO=()
  IMP_REMOTE_USER=""
  IMP_CERT_DOMAIN=() IMP_CERT_FILE=() IMP_CERT_KEY=()
  IMP_XDB_ROOT=() IMP_XDB_NAME=() IMP_XDB_CONF=()
  lib_importapp_reset
  while IFS=$'\t' read -r tag domain root kb kind db www conf _ php mem upl _; do
    # a name that is passed on to a port, and its database (lib/importapp.sh)
    if [[ "$tag" == "P" ]]; then lib_importapp_row "$domain" "$root" "$kb" "$kind" "$db" "$www" "$conf" "$php" "$mem" "$upl"; continue; fi
    if [[ "$tag" == "D" ]]; then
      # one more database of a site: the directory, the name, the file
      _import_path_ok "$domain" && _import_dbname_ok "$root" && _import_path_ok "$kb" || continue
      dup=0
      for (( k = 0; k < ${#IMP_XDB_ROOT[@]}; k++ )); do
        if [[ "${IMP_XDB_ROOT[k]}" == "$domain" && "${IMP_XDB_NAME[k]}" == "$root" ]]; then dup=1; break; fi
      done
      (( dup )) || { IMP_XDB_ROOT+=("$domain"); IMP_XDB_NAME+=("$root"); IMP_XDB_CONF+=("$kb"); }
      continue
    fi
    if [[ "$tag" == "T" ]]; then
      # a certificate: the name, and where its two files are
      domain="${domain,,}"
      lib_domain_valid "$domain" && _import_path_ok "$root" && _import_path_ok "$kb" || continue
      dup=0
      for x in ${IMP_CERT_DOMAIN[@]+"${IMP_CERT_DOMAIN[@]}"}; do
        if [[ "$x" == "$domain" ]]; then dup=1; break; fi
      done
      (( dup )) || { IMP_CERT_DOMAIN+=("$domain"); IMP_CERT_FILE+=("$root"); IMP_CERT_KEY+=("$kb"); }
      continue
    fi
    if [[ "$tag" == "Q" ]]; then lib_importapp_db_row "$domain" "$root" "$kb"; continue; fi
    if [[ "$tag" == "C" ]]; then
      # document root, when, command - in the variables of a site line. The command is the
      # rest of the line, tabs and all, and is taken only when cron here could run it as it is.
      _import_path_ok "$domain" || continue
      kb="${kb}${kind:+ ${kind}}${db:+ ${db}}${www:+ ${www}}${conf:+ ${conf}}"
      _import_cron_ok "$root" "$kb" || continue
      dup=0
      for (( k = 0; k < ${#IMP_CRON_ROOT[@]}; k++ )); do
        if [[ "${IMP_CRON_ROOT[k]}" == "$domain" && "${IMP_CRON_WHEN[k]}" == "$root" && "${IMP_CRON_CMD[k]}" == "$kb" ]]; then dup=1; break; fi
      done
      (( dup )) && continue
      IMP_CRON_ROOT+=("$domain"); IMP_CRON_WHEN+=("$root"); IMP_CRON_CMD+=("$kb")
      continue
    fi
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
      if (( ! dup )); then
        IMP_NAMELESS+=("$root"); IMP_NL_KB+=("$kb"); IMP_NL_KIND+=("$kind"); IMP_NL_DB+=("$db"); IMP_NL_CONF+=("$conf")
        if lib_php_valid_version "${php:-}"; then IMP_NL_PHP+=("$php"); else IMP_NL_PHP+=("-"); fi
        IMP_NL_MEM+=("$(_import_size_mb "${mem:-}")"); IMP_NL_UPL+=("$(_import_size_mb "${upl:-}")")
      fi
      continue
    fi
    for x in ${IMP_DOMAIN[@]+"${IMP_DOMAIN[@]}"}; do
      if [[ "$x" == "$domain" ]]; then dup=1; break; fi
    done
    (( dup )) && continue
    IMP_DOMAIN+=("$domain"); IMP_ROOT+=("$root"); IMP_KB+=("$kb"); IMP_KIND+=("$kind")
    IMP_DB+=("$db"); IMP_WWW+=("$www"); IMP_CONF+=("$conf")
    if lib_php_valid_version "${php:-}"; then IMP_PHP+=("$php"); else IMP_PHP+=("-"); fi
    IMP_MEM+=("$(_import_size_mb "${mem:-}")"); IMP_UPL+=("$(_import_size_mb "${upl:-}")")
  done
  lib_importapp_merge
  # a domain that has mailboxes or aliases there and no site: an entry of its own, of the kind "mail"
  (( IMP_MAIL_ROWS )) || return 0
  for x in ${IMP_BOX[@]+"${IMP_BOX[@]}"} ${IMP_ALIAS[@]+"${IMP_ALIAS[@]}"}; do
    domain="${x#*@}"; dup=0
    for db in ${IMP_DOMAIN[@]+"${IMP_DOMAIN[@]}"}; do
      if [[ "$db" == "$domain" ]]; then dup=1; break; fi
    done
    (( dup )) && continue
    IMP_DOMAIN+=("$domain"); IMP_ROOT+=("-"); IMP_KB+=(0); IMP_KIND+=("mail")
    IMP_DB+=("-"); IMP_WWW+=(0); IMP_CONF+=("-"); IMP_PHP+=("-"); IMP_MEM+=("-"); IMP_UPL+=("-")
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
lib_import_here() {   # domain [mail | node | proxy]
  local mode=""
  # a name that is passed on to a port goes into a site that is passed on, and into no other
  if [[ "${2:-}" == "node" || "${2:-}" == "proxy" ]]; then
    if lib_domain_registered "$1"; then
      mode="$(lib_json_get "$(lib_domain_json "$1")" '.mode')"
      if [[ "$mode" == "proxy" ]]; then printf 'exists'; else printf 'a %s site here' "${mode:-php}"; fi
    elif lib_redirect_exists "$1"; then printf 'a redirect here'
    else printf 'new'; fi
    return 0
  fi
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
    lib_tprintf '  %3s  %-34s %9s  %-9s  %-20s  %-9s  %-8s  %-12s  %s\n' "#" "DOMAIN" "SIZE" "TYPE" "DATABASE" "MAILBOXES" "ALIASES" "HERE" "DIRECTORY THERE"
    for (( i = 0; i < n; i++ )); do
      what=""; kb="${IMP_KB[i]}"
      if [[ "${IMP_KIND[i]}" == "mail" ]] || (( IMP_OPT_ONLY_MAIL )); then what="mail"
      elif [[ "${IMP_KIND[i]}" == "node" || "${IMP_KIND[i]}" == "proxy" ]]; then what="${IMP_KIND[i]}"; fi
      # the cell says it in a word or two: "a proxy site here" under HERE is "proxy site"
      here="$(lib_import_here "${IMP_DOMAIN[i]}" "$what")"; here="${here#a }"; here="${here% here}"
      boxes="$(_import_boxes_of "${IMP_DOMAIN[i]}" | wc -l | tr -d ' ')"
      if (( boxes > 0 )); then kb=$(( kb + $(_import_mail_kb "${IMP_DOMAIN[i]}") )); else boxes="-"; fi
      als="$(_import_aliases_of "${IMP_DOMAIN[i]}" | wc -l | tr -d ' ')"
      (( als > 0 )) || als="-"
      lib_tprintf '  %3d  %-34s %9s  %-9s  %-20s  %-9s  %-8s  %-12s  %s\n' "$((i + 1))" "${IMP_DOMAIN[i]}" "$(_import_mb "$kb")" \
        "${IMP_KIND[i]}" "${IMP_DB[i]}" "$boxes" "$als" "$here" "${IMP_ROOT[i]}"
    done
  else
    lib_warn "No site with a domain name was found on ${IMP_SSH_TARGET}"
  fi
  if ((${#IMP_NAMELESS[@]} > 0)); then
    # numbered on from the sites: asked "which ones", the number brings the directory, and the
    # domain it is to be here is asked then
    lib_tr "Served there under no domain name (its number brings one, and you are asked for the domain; or --path <directory> --as <domain>):"
    printf '\n%s\n' "$LIB_TR"
    for (( i = 0; i < ${#IMP_NAMELESS[@]}; i++ )); do
      lib_tprintf '  %3d  %-34s %9s  %-9s  %-20s  %s\n' "$(( n + i + 1 ))" "-" "$(_import_mb "${IMP_NL_KB[i]:-0}")" "${IMP_NL_KIND[i]:--}" "${IMP_NL_DB[i]:--}" "${IMP_NAMELESS[i]}"
    done
  fi
  printf '\n'
}

# A directory that is served there under no name becomes an entry like any site's, under the
# domain it is given here. The index of the entry in IMP_TAKEN. Status 1: no such directory,
# no domain name, or a name the list has already.
lib_import_nameless_take() {   # index among the nameless (from 0), domain
  local k="$1" domain="${2,,}" x=""
  [[ "$k" =~ ^[0-9]+$ ]] && (( k < ${#IMP_NAMELESS[@]} )) || return 1
  lib_domain_valid "$domain" || return 1
  for x in ${IMP_DOMAIN[@]+"${IMP_DOMAIN[@]}"}; do
    [[ "$x" != "$domain" ]] || return 1
  done
  IMP_DOMAIN+=("$domain"); IMP_ROOT+=("${IMP_NAMELESS[k]}"); IMP_KB+=("${IMP_NL_KB[k]:-0}"); IMP_KIND+=("${IMP_NL_KIND[k]:-static}")
  IMP_DB+=("${IMP_NL_DB[k]:--}"); IMP_WWW+=(0); IMP_CONF+=("${IMP_NL_CONF[k]:--}"); IMP_PHP+=("${IMP_NL_PHP[k]:--}")
  IMP_MEM+=("${IMP_NL_MEM[k]:--}"); IMP_UPL+=("${IMP_NL_UPL[k]:--}")
  IMP_TAKEN=$(( ${#IMP_DOMAIN[@]} - 1 ))
}

# The domain a directory without a name is to be here, asked on the terminal: three tries,
# and nothing leaves the directory where it is. The answer in IMP_ASKED ("": left).
_import_nameless_ask() {   # directory
  local ans="" try=0
  IMP_ASKED=""
  for (( try = 0; try < 3; try++ )); do
    lib_tr "${1}: which domain is it to be here? (nothing: leave it there)"
    printf '%s%s%s: ' "$C_BLD" "$LIB_TR" "$C_RST"
    read -r ans || ans=""
    ans="${ans//[[:space:]]/}"; ans="${ans,,}"
    [[ -n "$ans" ]] || return 0
    if lib_domain_valid "$ans"; then IMP_ASKED="$ans"; return 0; fi
    lib_warn "\"${ans}\" is not a domain name (example.com)"
  done
  return 0
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

# The database login in a file that is here, found the way it was found there.
lib_import_dbconf() {   # file [the name it goes by] -> the F lines
  sh -c "$(lib_import_remote_lib)"'
dbconf "$1" "$2"' sh "$1" "${2:-$1}"
}

# That file with the login of this server in its place: only the values change, each where it
# stands, and everything around them stays as it was written. Status 3: name, user and
# password were not all there.
lib_import_dbconf_rewrite() {   # file, its F lines (a file); name user password -> stdout
  LOMP_DB_NAME="$3" LOMP_DB_USER="$4" LOMP_DB_PASS="$5" awk '
    BEGIN { FS = "\t"; new["name"] = ENVIRON["LOMP_DB_NAME"]; new["user"] = ENVIRON["LOMP_DB_USER"]; new["pass"] = ENVIRON["LOMP_DB_PASS"]; new["host"] = "localhost" }
    FILENAME == ARGV[1] { if ($1 == "F") { n++; f[n] = $2; ln[n] = $3 + 0; col[n] = $4 + 0; len[n] = $5 + 0 } next }
    {
      line = $0
      # the values of this line, the rightmost first, so that the columns of the others hold
      do {
        pick = 0
        for (i = 1; i <= n; i++) if (ln[i] == FNR && !used[i] && (!pick || col[i] > col[pick])) pick = i
        if (pick) { line = substr(line, 1, col[pick] - 1) new[f[pick]] substr(line, col[pick] + len[pick]); used[pick] = 1; did[f[pick]] = 1 }
      } while (pick)
      print line
    }
    END { if (!(("name" in did) && ("user" in did) && ("pass" in did))) exit 3 }' "$2" "$1"
}

# Every configuration file of a site that names the database it had there, pointed at the one
# it has here. The names of the files that were changed come back in IMP_FIXED.
IMP_FIXED=""
_import_dbconf_fix() {   # document root, the database's name there, a work directory [, its name here when it is not the site's first]
  local docroot="$1" old="$2" work="$3" new="${4:-$DBI_NAME}" f="" name=""
  IMP_FIXED=""
  [[ "${DBI_NAME}${DBI_USER}${DBI_PASS}" =~ ^[A-Za-z0-9_]+$ ]] || return 0
  while IFS= read -r f; do
    [[ -n "$f" && ( "$f" == "$docroot"/* || "$f" == "${docroot%/*}/.env" ) ]] || continue
    lib_domain_as_user cat "$f" >"${work}/conf.in" 2>/dev/null || continue
    lib_import_dbconf "${work}/conf.in" "$f" >"${work}/conf.pos" 2>/dev/null || continue
    name="$(awk -F'\t' '$2 == "name" { print $6; exit }' "${work}/conf.pos")"
    [[ -n "$name" && "$name" == "$old" ]] || continue
    lib_import_dbconf_rewrite "${work}/conf.in" "${work}/conf.pos" "$new" "$DBI_USER" "$DBI_PASS" >"${work}/conf.out" || continue
    lib_domain_as_user tee "$f" <"${work}/conf.out" >/dev/null || continue
    IMP_FIXED+="${IMP_FIXED:+, }$( [[ "$f" == "$docroot"/* ]] && printf '%s' "${f#"$docroot"/}" || printf '%s' "${f##*/}" )"
  done < <(lib_domain_as_user sh -c "$(lib_import_remote_lib)"'
dbconf_files "$1"' sh "$docroot" 2>/dev/null || true)
  rm -f -- "${work}/conf.in" "${work}/conf.pos" "${work}/conf.out"
  return 0
}

# ---- what was copied last time ----------------------------------------------------
# After the files of a site have come over, the moment that copy began - by the other server's
# own clock - is kept with the site, with what names that server and the directory. The next
# import from the same directory of the same server then asks only for what changed there
# since: by ctime, the time a server notes itself when a file is made or changed and that no
# unpacked archive or copied file can set back.
lib_import_mark_file() { printf '%s/import.mark' "$(lib_domain_state_dir "$1")"; }

# The other server's clock and what tells it from any other: "<epoch> <id>", or nothing.
_import_remote_now() {
  local got="" ts="" id=""
  got="$(_import_ssh 'printf "%s %s\n" "$(date +%s)" "$(cat /etc/machine-id 2>/dev/null || hostname)"' </dev/null 2>>"$LOG_FILE" || true)"
  read -r ts id _ <<<"$got"
  [[ "$ts" =~ ^[0-9]{9,11}$ && "$id" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 1
  printf '%s %s' "$ts" "$id"
}

# The time of the last copy of that directory of that server into this site, or nothing.
_import_mark_get() {   # domain, the server's id, the directory there
  local f="" id="" root="" ts=""
  f="$(lib_import_mark_file "$1")"
  [[ -s "$f" ]] || return 1
  IFS=$'\t' read -r id root ts _ <"$f" || true
  [[ "$id" == "$2" && "$root" == "$3" && "$ts" =~ ^[0-9]{9,11}$ ]] || return 1
  printf '%s' "$ts"
}

# What the other server packed, unpacked by the site's own user. The directories that are here
# keep their modes: public_html's own is this server's business.
_import_unpack() {   # document root  (the archive on stdin)
  lib_domain_as_user tar -C "$1" --no-overwrite-dir -xzpf - 2>>"$LOG_FILE"
}

# What is in a directory, one line each: "<type> <size, files only> <path>", tab-divided, the
# paths as "./x/y". Whoever runs find has to be able to read the directory. Cache directories
# are left out (this server builds its own), and so is the directory named in $1, when given.
_import_list_cmd() {   # [directory to leave out]
  local skip=""
  [[ -z "${1:-}" ]] || skip="-path ./${1} -prune -o "
  printf '%s' "find . -mindepth 1 \( -name cache -o -name .cache -o -name caches \) -prune -o ${skip}-type f -printf 'f\t%s\t%p\n' -o -printf '%y\t0\t%p\n'"
}

# A Laravel (or Symfony-style) application is served from its public directory and keeps the rest
# above it: the directory above, when that is what the document root there is.
_import_app_root() {   # the document root there
  local up=""
  [[ "${1##*/}" == "public" ]] || return 1
  up="${1%/*}"
  _import_path_ok "$up" || return 1
  _import_ssh "test -f '${up}/artisan' || test -f '${up}/bin/console'" </dev/null 2>>"$LOG_FILE" || return 1
  printf '%s' "$up"
}

# What the other server has under one directory and this server lacks, as a report; with fix=1
# the missing ones are brought too. A file whose size differs is named and left as it is: this
# server may have changed it (wp-config.php, on purpose). Status 1: something is missing, and
# still is.
_import_compare() {   # what there, directory there, directory here, directory to leave out there, fix 0|1, there-name here-name
  local label="$1" root="$2" here="$3" skip="$4" fix="$5" work="" rn=0 miss=0 diff=0 denied=0 top=0
  work="$(lib_mktemp -d)"
  lib_info "Listing ${label}: what is there and what is here ..."
  _import_ssh "cd '${root}' && $(_import_list_cmd "$skip")" </dev/null >"${work}/there" 2>"${work}/there.err" \
    || [[ -s "${work}/there" ]] \
    || { lib_warn "The files of ${root} could not be listed: $(tail -n 1 "${work}/there.err" 2>/dev/null | tr -c '[:print:]' ' ')"; rm -rf "$work"; return 1; }
  # (find's status is 1 when it could not enter some directory: what it saw is still the list)
  denied="$(grep -c 'Permission denied' "${work}/there.err" 2>/dev/null || true)"
  lib_domain_as_user bash -c "cd '${here}' && $(_import_list_cmd "${6:-}")" </dev/null >"${work}/here" 2>/dev/null || true
  rn="$(wc -l <"${work}/there" | tr -d ' ')"
  # missing = the topmost missing paths (what is inside a missing directory is missing too),
  # missing.all = the rest of them
  : >"${work}/missing"; : >"${work}/missing.all"; : >"${work}/differs"
  awk -F'\t' -v out="${work}/missing" -v dfile="${work}/differs" '
    NR == FNR { here[$3] = $1 "\t" $2; next }
    {
      if (!($3 in here)) { miss[$3] = $1; next }
      split(here[$3], h, "\t")
      if ($1 == "f" && h[1] == "f" && h[2] != $2) print $3 "\t" $2 "\t" h[2] > dfile
    }
    END {
      for (p in miss) {
        q = p; sub(/\/[^\/]*$/, "", q)
        print p "\t" miss[p] > ((q in miss) ? out ".all" : out)
      }
    }' "${work}/here" "${work}/there"
  top="$(wc -l <"${work}/missing" | tr -d ' ')"
  miss="$(( top + $(wc -l <"${work}/missing.all") ))"
  diff="$(wc -l <"${work}/differs" | tr -d ' ')"
  lib_info "There: ${rn} file(s) and director(ies). Missing here: ${miss}. Different size: ${diff}."
  if (( denied > 0 )); then
    lib_warn "${IMP_REMOTE_USER:-the user} could not read ${denied} place(s) there: whatever is inside them is not in this comparison either (see ${LOG_FILE})"
    cat "${work}/there.err" >>"$LOG_FILE" 2>/dev/null || true
  fi
  if (( miss > 0 )); then
    lib_warn "Not here (the topmost ones, up to 40):"
    sort "${work}/missing" | sed -n '1,40p' | awk -F'\t' '{ printf "        %s%s\n", $1, ($2 == "d" ? "/" : "") }'
    if (( top > 40 )); then lib_note "... and $(( top - 40 )) more; the whole list is in ${LOG_FILE}"; fi
    cat "${work}/missing" "${work}/missing.all" | cut -f1 | sed "s|^|missing: ${root}/|" >>"$LOG_FILE" 2>/dev/null || true
  fi
  if (( diff > 0 )); then
    lib_note "${diff} file(s) have another size here than there (changed on either side since, or half copied). Left alone; the first ones:"
    lib_tr "(there %s bytes, here %s)"
    head -n 10 "${work}/differs" | awk -F'\t' -v f="$LIB_TR" '{ printf "        %s  " f "\n", $1, $2, $3 }'
  fi
  if (( miss == 0 )); then
    rm -rf "$work"
    lib_ok "Everything that is there is here: ${label}"
    return 0
  fi
  if (( ! fix )); then
    rm -rf "$work"
    return 1
  fi
  lib_info "Copying the ${miss} missing path(s) into ${here} as ${D_USER} ..."
  cat "${work}/missing" "${work}/missing.all" | cut -f1 | tr '\n' '\0' \
    | _import_ssh "tar -C '${root}' --null --no-recursion -T - -czf - ; r=\$?; [ \"\$r\" -le 1 ]" 2>>"$LOG_FILE" \
    | _import_unpack "$here" \
    || { rm -rf "$work"; lib_warn "What was missing could not all be copied (see ${LOG_FILE})"; return 1; }
  rm -rf "$work"
  lib_ok "The missing files are here: ${here}"
  return 0
}

# --check for one site: its document root, and the application above it when there is one.
_import_check_site() {   # index, fix 0|1
  local i="$1" fix="${2:-0}" domain="" root="" docroot="" app="" bad=0
  domain="${IMP_DOMAIN[i]}"; root="${IMP_ROOT[i]}"
  lib_heading "${domain}  <-  ${IMP_SSH_TARGET}:${root}"
  if ! lib_domain_registered "$domain"; then
    lib_warn "${domain} is not a site here yet: nothing to compare (import it first)"
    return 1
  fi
  lib_domain_state_load "$domain"
  docroot="${D_HOME}/public_html"
  [[ -d "$docroot" && ! -L "$docroot" ]] || { lib_warn "${docroot} is not a directory"; return 1; }
  _import_compare "$root" "$root" "$docroot" "" "$fix" || bad=1
  if app="$(_import_app_root "$root")"; then
    _import_compare "the application above it, ${app}" "$app" "$D_HOME" "public" "$fix" "public_html" || bad=1
  fi
  if (( bad && ! fix )); then
    lib_note "Bring what is missing, and nothing else: setup.sh import ${IMP_SSH_TARGET} --only ${domain} --check --fix"
  fi
  return "$bad"
}

# The other databases found for one directory, as indexes into IMP_XDB_*, one per line -
# the site's first database (it may be named by more than one file) left out.
_import_xdb_of() {   # directory, its first database
  local k=0
  for (( k = 0; k < ${#IMP_XDB_ROOT[@]}; k++ )); do
    if [[ "${IMP_XDB_ROOT[k]}" == "$1" && "${IMP_XDB_NAME[k]}" != "$2" ]]; then printf '%d\n' "$k"; fi
  done
  return 0
}

# The other databases of a site: each into a database of its own here, opened by the site's
# one user, and every file that named it there pointed at it here.
lib_import_xdbs() {   # domain, directory there, its first database, directory here, work directory, 1 when the site is new
  local domain="$1" root="$2" first="$3" here="$4" work="$5" created="$6" k="" n=0
  local -a mine=()
  mapfile -t mine < <(_import_xdb_of "$root" "$first")
  ((${#mine[@]} > 0)) || return 0
  lib_db_info_load "$domain" || return 0
  for k in "${mine[@]}"; do
    lib_db_extra_add "$domain" "${IMP_XDB_NAME[k]}" \
      || lib_die "A database for ${IMP_XDB_NAME[k]} could not be made" "SQL error (see the log)" "check MariaDB, then run the import again"
    lib_import_db "$domain" "${IMP_XDB_NAME[k]}" "${IMP_XDB_CONF[k]}" "$work" "$created" "$DBX_NAME"
    lib_ok "Database ${IMP_XDB_NAME[k]} imported into ${DBX_NAME}"
    _import_dbconf_fix "$here" "${IMP_XDB_NAME[k]}" "$work" "$DBX_NAME"
    if [[ -n "$IMP_FIXED" ]]; then lib_ok "Its login is now the one of this server (${DBX_NAME}), in: ${IMP_FIXED}"
    else lib_warn "The file that names ${IMP_XDB_NAME[k]} still has the login of the other server: the database is ${DBX_NAME} here (setup.sh credentials ${domain})"; fi
    n=$((n + 1))
  done
  return 0
}

# One database of the other server into the site's own here: dumped there, checked for being
# whole, and imported. Dies - with nothing imported - when any of that fails.
lib_import_db() {   # domain, database there, the file that names its login ("-": none), work directory, 1 when the site is new [, another database of the site to fill]
  local domain="$1" db="$2" conf="$3" work="$4" created="$5" into="${6:-}" dump="" n=0
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
  { if [[ -n "$into" ]]; then lib_db_restore_name "$into" "$dump"; else lib_db_restore_domain "$domain" "$dump"; fi; } \
    || lib_die "The database of ${domain} could not be imported" "an SQL error (see the log)" \
         "its tables may be half replaced: run the import again$( (( created )) || printf ', or go back with: setup.sh restore %s --file <the pre-import archive>' "$domain")"
}

# ---- certificates -------------------------------------------------------------------
# Is this pair one to put in front of visitors: the key is the certificate's, the certificate
# names the domain, it has more than a day left, and a client accepts it - checked against
# the CAs this server trusts, with the chain the file brings. A Cloudflare origin certificate
# is accepted by Cloudflare alone, and that is who asks for it. Says why not on stdout.
_import_cert_ok() {   # domain, certificate file, key file
  local d="$1" cert="$2" key="$3" a="" b="" names="" end="" now="" issuer="" subject="" parent=""
  openssl x509 -noout -in "$cert" >/dev/null 2>&1 || { printf 'what was sent is no certificate'; return 1; }
  a="$(openssl x509 -noout -pubkey -in "$cert" 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
  b="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
  [[ -n "$a" && "$a" == "$b" ]] || { printf 'its key is not the key of the certificate'; return 1; }
  names="$(openssl x509 -noout -ext subjectAltName -in "$cert" 2>/dev/null | tr ',' '\n' | sed -n 's/.*DNS:[[:space:]]*\([^[:space:],]\{1,\}\).*/\1/p' | tr 'A-Z' 'a-z')"
  parent="${d#*.}"
  grep -qxF -- "$d" <<<"$names" || grep -qxF -- "*.${parent}" <<<"$names" || { printf 'it does not name %s' "$d"; return 1; }
  end="$(lib_ssl_expiry_epoch "$cert")"; now="${IMP_SSL_NOW:-$(date +%s)}"
  [[ "$end" =~ ^[0-9]+$ ]] && (( end > now + 86400 )) || { printf 'it has run out, or does so within a day'; return 1; }
  issuer="$(openssl x509 -noout -issuer -in "$cert" 2>/dev/null | sed 's/^issuer= *//')"
  subject="$(openssl x509 -noout -subject -in "$cert" 2>/dev/null | sed 's/^subject= *//')"
  [[ "$issuer" != "$subject" ]] || { printf 'it is self-signed: no browser accepts it'; return 1; }
  if [[ "$issuer" == *"CloudFlare Origin"* ]]; then return 0; fi
  if [[ -n "$IMP_SSL_CAFILE" ]]; then openssl verify -purpose sslserver -CAfile "$IMP_SSL_CAFILE" -untrusted "$cert" "$cert" >/dev/null 2>&1
  else openssl verify -purpose sslserver -untrusted "$cert" "$cert" >/dev/null 2>&1; fi \
    || { printf 'no browser would accept it: its chain does not lead to a CA this server trusts'; return 1; }
  return 0
}

# The certificate the site answered with there, in front of the site here - so that HTTPS
# answers before the DNS has moved. It is nobody's to renew: marked as imported, it is one of
# the sites "renew-ssl --missing" gets a certificate of their own once the DNS points here.
lib_import_ssl() {   # domain  (the site is here)
  local domain="$1" k=0 found=-1 work="" why="" dst="" exp=""
  for (( k = 0; k < ${#IMP_CERT_DOMAIN[@]}; k++ )); do
    if [[ "${IMP_CERT_DOMAIN[k]}" == "$domain" ]]; then found=$k; break; fi
  done
  (( found >= 0 )) || return 0
  lib_domain_registered "$domain" || return 0
  lib_domain_state_load "$domain"
  if (( D_SSL )) && lib_ssl_deployed "$domain" && [[ "$(lib_json_get_raw "$(lib_domain_json "$domain")" '.ssl.imported')" != "true" ]]; then
    lib_note "${domain} has a certificate of its own here; the one of the other server was left there"
    return 0
  fi
  work="$(lib_mktemp -d)"; chmod 0700 "$work"
  ( umask 077
    _import_ssh "cat '${IMP_CERT_FILE[found]}'" </dev/null >"${work}/fullchain.pem" 2>>"$LOG_FILE" \
      && _import_ssh "cat '${IMP_CERT_KEY[found]}'" </dev/null >"${work}/privkey.pem" 2>>"$LOG_FILE" ) \
    || { lib_warn "The certificate of ${domain} could not be read there; the site answers over HTTP until it has one (setup.sh renew-ssl ${domain})"; rm -rf "$work"; return 0; }
  if ! why="$(_import_cert_ok "$domain" "${work}/fullchain.pem" "${work}/privkey.pem")"; then
    lib_warn "The certificate of ${domain} was not brought: ${why}. The site answers over HTTP until it has one (setup.sh renew-ssl ${domain})"
    rm -rf "$work"; return 0
  fi
  if (( D_WWW )) && ! openssl x509 -noout -ext subjectAltName -in "${work}/fullchain.pem" 2>/dev/null | lib_grepq -iE "DNS:(www\.${domain//./\\.}|\*\.${domain//./\\.})([, ]|\$)"; then
    lib_warn "The certificate of ${domain} does not name www.${domain}: that name will show a certificate warning until the site has one of its own"
  fi
  dst="${SSL_DEPLOY_DIR}/${domain}"
  lib_mkdir "$SSL_DEPLOY_DIR" 0700 root:root
  lib_mkdir "$dst" 0700 root:root
  cp "${work}/fullchain.pem" "${dst}/fullchain.pem.new" && cp "${work}/privkey.pem" "${dst}/privkey.pem.new" && chmod 0600 "${dst}"/*.new \
    && mv -f "${dst}/fullchain.pem.new" "${dst}/fullchain.pem" && mv -f "${dst}/privkey.pem.new" "${dst}/privkey.pem" \
    || { lib_warn "The certificate of ${domain} could not be put in place (see the log)"; rm -rf "$work"; return 0; }
  rm -rf "$work"
  exp="$(openssl x509 -enddate -noout -in "${dst}/fullchain.pem" 2>/dev/null | cut -d= -f2)"
  D_SSL=1; D_SSL_WANTED=1
  lib_domain_state_save
  lib_json_set "$(lib_domain_json "$domain")" '.ssl.enabled = true | .ssl.imported = true | .ssl.cert_name = $n | .ssl.expires = $e | .ssl.updated_at = $ts' \
    --arg n "$domain" --arg e "$exp" --arg ts "$(lib_iso_now)"
  printf 'CERT_NAME=%s\nEXPIRES=%s\nDEPLOYED=%s\nISSUER=%s\nIMPORTED=%s\n' "$domain" "$exp" "$(lib_iso_now)" "$(lib_ssl_issuer "$domain")" "$IMP_SSH_TARGET" \
    >"$(lib_domain_state_dir "$domain")/ssl.info"
  chmod 0600 "$(lib_domain_state_dir "$domain")/ssl.info"
  lib_domain_apply_config "serve ${domain} with the certificate it had on the other server" \
    || { lib_warn "The certificate of ${domain} is in place, but the web server did not take it (setup.sh doctor)"; return 0; }
  lib_log_write INFO "certificate of ${domain} imported from ${IMP_SSH_TARGET} (expires ${exp})"
  lib_ok "${domain} answers over HTTPS with the certificate it had there (it runs out ${exp})"
  if lib_ssl_cert_origin "$domain"; then
    lib_note "It is a Cloudflare origin certificate: fine for as long as ${domain} is behind Cloudflare, and nothing here renews it or needs to (renew-ssl --missing passes it over)"
  else
    lib_note "Nobody renews that one. Once the DNS of ${domain} points here: setup.sh renew-ssl ${domain}   (or --missing, for every such site)"
  fi
}

_import_add() {   # domain add-options...
  SERVER_SETUP_LOCKED=1 "$SCRIPT_PATH" add "$@" --yes --quiet
}

# The address a WordPress gives itself, from the database that was just imported.
_import_wp_home() {   # wp-config.php (a copy root can read)
  local prefix=""
  prefix="$(sed -n "s/^[[:space:]]*\$table_prefix[[:space:]]*=[[:space:]]*['\"]\([A-Za-z0-9_]*\)['\"].*/\1/p" "$1" | sed -n 1p)"
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
  elif [[ "${IMP_KIND[i]}" == "node" || "${IMP_KIND[i]}" == "proxy" ]]; then
    lib_importapp_site "$i"
  else
    lib_import_site_part "$i"
  fi
  if (( ! IMP_OPT_NO_SSL && ! IMP_OPT_ONLY_MAIL )) && [[ "${IMP_KIND[i]}" != "mail" ]]; then lib_import_ssl "$domain"; fi
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
  local created=0 work="" dump="" n=0 home="" host="" imported=0 cfg="" now="" since="" list="" changed=0 got="" app=""
  local -a newer=()
  local -a args=()
  domain="${IMP_DOMAIN[i]}"; root="${IMP_ROOT[i]}"; kind="${IMP_KIND[i]}"; db="${IMP_DB[i]}"
  www="${IMP_WWW[i]}"; conf="${IMP_CONF[i]}"
  lib_heading "${domain}  <-  ${IMP_SSH_TARGET}:${root}"
  lib_rollback_clear
  work="$(lib_mktemp -d)"

  # ---- the site ------------------------------------------------------------
  if ! lib_domain_registered "$domain"; then
    args=(--no-ssl)
    if [[ "$kind" == "static" && "$db" == "-" ]]; then args+=(--static --no-db)
    elif [[ "${IMP_PHP[i]}" != "-" ]]; then
      # the PHP it runs there, when this server can have it
      if _import_php_available "${IMP_PHP[i]}"; then args+=(--php "${IMP_PHP[i]}")
      else lib_warn "${domain} runs PHP ${IMP_PHP[i]} there, which this server cannot install: it gets PHP ${PHP_VERSION}"; fi
    fi
    # (a static site is given none by "add", whatever is said)
    mapfile -t -O "${#args[@]}" args < <(_import_php_limits "$i")
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
    # What to ask for: everything, or what changed there since the last copy of this very
    # directory. The list is made over there, into a file whose name comes back with its count.
    now=""; since=""; list=""; changed=0
    now="$(_import_remote_now || true)"
    if (( ! created && ! IMP_OPT_FULL )) && [[ -n "$now" ]]; then
      since="$(_import_mark_get "$domain" "${now#* }" "$root" || true)"
    fi
    if [[ -n "$since" ]]; then
      got="$(_import_ssh "cd '${root}' && l=\$(mktemp) && find . -mindepth 1 \( -name cache -o -name .cache -o -name caches \) -prune -o -newerct '@${since}' -print0 >\"\$l\" && printf '%s %s\n' \"\$(tr -cd '\\000' <\"\$l\" | wc -c)\" \"\$l\"" </dev/null 2>>"$LOG_FILE" || true)"
      read -r changed list _ <<<"$got"
      if ! [[ "$changed" =~ ^[0-9]+$ ]] || ! _import_path_ok "$list"; then
        # an older find, or no room for the list: everything, then
        since=""; list=""; changed=0
      fi
    fi
    # tar's status 1 is "a file changed while it was read": the other server is live. The
    # directories that are here keep their modes (public_html's own is this server's business).
    if [[ -n "$since" ]] && (( changed == 0 )); then
      _import_ssh "rm -f '${list}'" </dev/null 2>>"$LOG_FILE" || true
      lib_info "No file of ${domain} changed there since $(date -d "@${since}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$since"): nothing to copy (--full copies everything again)"
    elif [[ -n "$since" ]]; then
      lib_info "Copying the ${changed} file(s) and directories that changed there since $(date -d "@${since}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$since") into ${docroot} as ${D_USER} ..."
      _import_ssh "tar -C '${root}' --null --no-recursion -T '${list}' -czf - ; r=\$?; rm -f '${list}'; [ \"\$r\" -le 1 ]" </dev/null 2>>"$LOG_FILE" \
        | _import_unpack "$docroot" \
        || lib_die "The files of ${domain} could not all be copied" \
             "the connection dropped, the disk is full, or ${IMP_SSH_TARGET} cannot read everything in ${root} (see the log)" \
             "what was copied stays; run the import again to complete it"
    else
      lib_info "Copying the files ($(_import_mb "${IMP_KB[i]}")) into ${docroot} as ${D_USER} ..."
      _import_ssh "tar -C '${root}' --exclude=cache --exclude=.cache --exclude=caches -czf - . ; r=\$?; [ \"\$r\" -le 1 ]" </dev/null 2>>"$LOG_FILE" \
        | _import_unpack "$docroot" \
        || lib_die "The files of ${domain} could not all be copied" \
             "the connection dropped, the disk is full, or ${IMP_SSH_TARGET} cannot read everything in ${root} (see the log)" \
             "what was copied stays; run the import again to complete it"
    fi
    # an application that keeps the rest of itself above its public directory (Laravel): that
    # goes into the site's home, beside public_html, which is what its public directory is here
    if app="$(_import_app_root "$root")"; then
      newer=(); [[ -z "$since" ]] || newer=(--newer="@${since}")
      lib_info "Copying the application above it (${app}) into ${D_HOME}, apart from public ..."
      _import_ssh "tar -C '${app}' --exclude=./public --exclude=./public_html --exclude=./private --exclude=./logs --exclude=cache --exclude=.cache --exclude=caches ${newer[*]:-} -czf - . ; r=\$?; [ \"\$r\" -le 1 ]" </dev/null 2>>"$LOG_FILE" \
        | _import_unpack "$D_HOME" \
        || lib_die "The application of ${domain} could not all be copied" \
             "the connection dropped, the disk is full, or ${IMP_SSH_TARGET} cannot read everything in ${app} (see the log)" \
             "what was copied stays; run the import again to complete it"
      # what the application calls its public directory is public_html here
      if [[ ! -e "${D_HOME}/public" && ! -L "${D_HOME}/public" ]]; then lib_domain_as_user ln -s public_html "${D_HOME}/public" || true; fi
    fi
    # the copy is whole: the next one starts from the moment this one began
    if [[ -n "$now" ]]; then
      printf '%s\t%s\t%s\n' "${now#* }" "$root" "${now%% *}" >"$(lib_import_mark_file "$domain")" 2>/dev/null \
        && chmod 0600 "$(lib_import_mark_file "$domain")" || true
    fi
    # a wp-config.php kept one directory above the document root there
    if [[ "$kind" == "wordpress" && "$conf" != "-" && "$conf" != "${root}/wp-config.php" ]]; then
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
      lib_import_db "$domain" "$db" "$conf" "$work" "$created"
      imported=1
      lib_ok "Database ${db} imported into ${DBI_NAME}"
    fi
  fi
  # ---- the other databases the site has ----------------------------------------
  if (( ! IMP_OPT_NO_DB )) && [[ "$D_MODE" != "static" ]]; then
    lib_import_xdbs "$domain" "$root" "$db" "$docroot" "$work" "$created"
    lib_db_info_load "$domain" || true
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
    _import_dbconf_fix "$docroot" "$db" "$work"
    if [[ -n "$IMP_FIXED" ]]; then
      lib_ok "The application's database login is now the one of this server (${DBI_NAME}), in: ${IMP_FIXED}"
    else
      lib_warn "The application's own settings still name the database of the other server: put in the one of this server (setup.sh credentials ${domain})"
    fi
  fi
  rm -f -- "${work}/wp-config.in" "${work}/wp-config.out" 2>/dev/null || true
  lib_rollback_clear
  if (( ! created )) && [[ "${IMP_PHP[i]}" != "-" && -n "$D_PHP" && "${IMP_PHP[i]}" != "$D_PHP" ]]; then
    lib_note "${domain} runs PHP ${IMP_PHP[i]} there and PHP ${D_PHP} here; the site here keeps its own"
  fi
  if (( ! created )) && [[ -n "$D_PHP" ]]; then
    if [[ "${IMP_MEM[i]}" != "-" && -n "$D_MEMORY" ]] && (( IMP_MEM[i] > $(lib_size_to_mb "$D_MEMORY") )); then
      lib_note "${domain} has a memory_limit of ${IMP_MEM[i]}M there and ${D_MEMORY} here; the site here keeps its own"
    fi
    if [[ "${IMP_UPL[i]}" != "-" && -n "$D_UPLOAD" ]] && (( IMP_UPL[i] > $(lib_size_to_mb "$D_UPLOAD") )); then
      lib_note "${domain} takes uploads of ${IMP_UPL[i]}M there and ${D_UPLOAD} here; the site here keeps its own"
    fi
  fi
  if (( ! IMP_OPT_NO_CRON )); then lib_import_cron "$i" "$domain"; fi
  lib_log_write INFO "imported ${domain} from ${IMP_SSH_TARGET}:${root} (database: ${db})"
  lib_ok "${domain} is here: ${docroot}"
}

# =============================================================================
#  import command
# =============================================================================
lib_import_main() {
  if [[ "${1:-}" == "cron" ]]; then shift; lib_require_tools; lib_require_installed; lib_import_cron_main "$@"; return 0; fi
  local a="" target="" port="22" key="" pwfile="" list=0 all=0 only="" no_create=0 path="" as="" dbname=""
  local i=0 n=0 here="" ans="" x="" total_kb=0 avail_kb=0 found=0 okc=0 what="" mkb=0 mail_kb=0 crons=0 limits="" xdbs="" k=""
  local -a chosen=() todo=() failed=() picked=()
  local nl=0
  IMP_OPT_NO_DB=0; IMP_OPT_NO_FILES=0; IMP_OPT_NO_MAIL=0; IMP_OPT_ONLY_MAIL=0; IMP_OPT_NO_CRON=0; IMP_OPT_FULL=0; IMP_OPT_CHECK=0; IMP_OPT_FIX=0; IMP_OPT_NO_SSL=0
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
      --no-cron)       IMP_OPT_NO_CRON=1 ;;
      --no-ssl)        IMP_OPT_NO_SSL=1 ;;
      --full)          IMP_OPT_FULL=1 ;;
      --check)         IMP_OPT_CHECK=1 ;;
      --fix)           IMP_OPT_FIX=1 ;;
      --no-mail)      IMP_OPT_NO_MAIL=1 ;;
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
  (( ! IMP_OPT_FIX || IMP_OPT_CHECK )) || lib_die "--fix belongs to --check" "it brings what --check found missing" "setup.sh import ${target:-<server>} --only <domain> --check --fix"
  (( ! (IMP_OPT_CHECK && (IMP_OPT_ONLY_MAIL || IMP_OPT_FULL || IMP_OPT_NO_FILES)) )) || lib_die "--check compares files, and nothing else" "it does not go with --only-mail, --full or --no-files" "leave one of them out"
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
    nl=${#IMP_NAMELESS[@]}
    # (a directory without a name can be picked where somebody is there to name it)
    if (( n == 0 )) && ! { (( nl > 0 && ! all )) && [[ -z "$only" ]] && lib_is_interactive; }; then
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
      # "all" is every site that has a name; a number past them is a directory without one
      found=$(( n + nl ))
      if [[ "${ans,,}" =~ ^[[:space:]]*(all|a|\*|hepsi|h)[[:space:]]*$ ]]; then found="$n"; fi
      mapfile -t picked < <(lib_import_pick "$ans" "$found" || true)
      ((${#picked[@]} > 0)) || { lib_import_disconnect; lib_die "\"${ans}\" is not a choice from the list" "" "numbers such as 1,3 or 2-5, or all"; }
      for i in "${picked[@]}"; do
        if (( i < n )); then chosen+=("$i"); continue; fi
        _import_nameless_ask "${IMP_NAMELESS[i - n]}"
        if [[ -z "$IMP_ASKED" ]]; then lib_note "${IMP_NAMELESS[i - n]}: left where it is"; continue; fi
        if lib_import_nameless_take "$(( i - n ))" "$IMP_ASKED"; then chosen+=("$IMP_TAKEN")
        else lib_warn "${IMP_NAMELESS[i - n]}: left where it is, ${IMP_ASKED} is in the list already"; fi
      done
      if ((${#chosen[@]} == 0)); then lib_import_disconnect; lib_info "Nothing was imported"; return 0; fi
    else
      lib_import_disconnect
      lib_die "Which sites?" "nobody is there to ask" "add --all or --only a.com,b.com   (--list only shows them)"
    fi
  fi

  if (( IMP_OPT_CHECK )); then
    for i in "${chosen[@]}"; do
      if [[ "${IMP_KIND[i]}" == "mail" ]]; then lib_note "${IMP_DOMAIN[i]}: mailboxes only, no files to compare"; continue; fi
      if [[ "${IMP_KIND[i]}" == "node" || "${IMP_KIND[i]}" == "proxy" ]]; then lib_note "${IMP_DOMAIN[i]}: passed on to a port there; --check compares the files of sites only"; continue; fi
      if _import_check_site "$i" "$(( IMP_OPT_FIX && ! OPT_DRY_RUN ))"; then okc=$((okc + 1)); else failed+=("${IMP_DOMAIN[i]}"); fi
    done
    lib_import_disconnect
    if ((${#failed[@]} > 0)); then
      lib_die "Not whole: ${failed[*]}" "something of it is missing here, or could not be compared (see above)" "$( (( IMP_OPT_FIX )) && printf 'run --check again to see what is left' || printf 'bring what is missing with --check --fix')"
    fi
    return 0
  fi
  _import_php_defaults
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
    if [[ "${IMP_KIND[i]}" == "node" || "${IMP_KIND[i]}" == "proxy" ]]; then
      # a name that is passed on to a port (lib/importapp.sh)
      here="$(lib_import_here "$x" "${IMP_KIND[i]}")"
      case "$here" in
        new)    if (( no_create )); then lib_note "${x}: left out, it is not a site here (--no-create)"; continue; fi ;;
        exists) ;;
        *)      lib_warn "${x}: left out, it is ${here}"; continue ;;
      esac
      if [[ "${IMP_KIND[i]}" == "node" ]]; then
        lib_note "${x}: a Node.js application; ${IMP_ROOT[i]} ($(_import_mb "${IMP_KB[i]}"), without node_modules)$( [[ "${IMP_DB[i]}" == "-" ]] || printf ', database %s' "${IMP_DB[i]}")$( [[ "$here" == "new" ]] || printf '. It is here already: a backup is taken first')"
      else
        lib_note "${x}: passed on to a port there; here it becomes a proxy to the same address, and what answers there is not brought"
      fi
      todo+=("$i"); total_kb=$(( total_kb + IMP_KB[i] ))
      if [[ -n "$what" ]] && (( ! IMP_OPT_NO_MAIL )); then lib_note "${x}: and its ${what}"; mail_kb=$(( mail_kb + mkb )); fi
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
    if [[ "$here" == "new" && "${IMP_PHP[i]}" != "-" && "${IMP_KIND[i]}" != "static" ]]; then
      lib_note "${x}: it runs PHP ${IMP_PHP[i]} there, and gets that here"
    fi
    if [[ "$here" == "new" && "${IMP_KIND[i]}" != "static" ]]; then
      limits="$(_import_php_limits "$i" | tr '\n' ' ')"
      if [[ -n "$limits" ]]; then lib_note "${x}: it keeps the PHP limits it has there, which are above this server's own (${limits% })"; fi
    fi
    if (( ! IMP_OPT_NO_DB )) && [[ "${IMP_KIND[i]}" != "static" ]]; then
      xdbs="$(_import_xdb_of "${IMP_ROOT[i]}" "${IMP_DB[i]}" | while read -r k; do printf '%s ' "${IMP_XDB_NAME[k]}"; done)"
      if [[ -n "$xdbs" ]]; then lib_note "${x}: and the other database(s) its files name: ${xdbs% }"; fi
    fi
    crons="$(_import_cron_of "${IMP_ROOT[i]}" | wc -l | tr -d ' ')"
    if (( crons > 0 && ! IMP_OPT_NO_CRON )); then
      lib_note "${x}: and its ${crons} cron job(s), which will run here as well as there"
    fi
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
    lib_note "Not copied: sieve filters of the mail. The other server was only read."
  fi
  if ((${#failed[@]} > 0)); then
    lib_die "Not imported: ${failed[*]}" "see the errors above" "clear them up and run the import again for those: --only $(IFS=,; printf '%s' "${failed[*]}")"
  fi
  return 0
}
