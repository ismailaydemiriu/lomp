#!/usr/bin/env bash
# lib/lang.sh - command output in Turkish.
#
# The code prints its messages in English, and the log, --json and everything a script reads
# stay in English. On a terminal a message is looked up here just before it is shown: the
# table below gives the Turkish for the English text, with {1} {2} ... standing for the values
# in it. Nothing changes where a message is written, so a message that is not in the table -
# a new one, or one whose wording was changed - simply comes out in English.
#
#   which language   the one chosen once: "install" and the menu ask "Türkçe or English?" the
#                    first time they run on a terminal, and the answer is kept in
#                    STATE_DIR/lang; "Menu language" in the menu changes it. LOMP_LANG=tr|en
#                    overrides it for one run. Piped, redirected or with --json the output is
#                    English whatever was chosen, and so it is while nothing was chosen.
#   what is covered  the lines of lib_info, lib_ok, lib_warn, lib_error, lib_note, lib_step,
#                    lib_heading, lib_print_kv, lib_confirm and the three parts of lib_die.
#                    Tables and usage texts printed with printf are not.
#
# lib/common.sh holds LIB_LANG and a lib_tr that hands every text back as it is; this module
# replaces that lib_tr and is the only one that sets LIB_LANG.

declare -gA LIB_TR_EXACT=()      # message without values -> Turkish
declare -ga LIB_TR_RE=()         # message with values, as a regular expression
declare -ga LIB_TR_TO=()         # ... and its Turkish, {1} {2} for the values
declare -gA LIB_TR_BUCKET=()     # the first characters of such a message -> its numbers
LIB_TR_GENERAL=""                # the numbers of those that begin with a value
LIB_TR_KEYLEN=6
LIB_TR_BUILT=0
LIB_LANG_SESSION=""              # the answer of this run's question, also when it was not kept
LIB_LANG_ANSWER=""
declare -ga LIB_TR_PAIRS=()

# English text with {n} -> regular expression that takes the values as groups.
_lib_tr_regex() {   # text -> LIB_TR_REGEX
  local re="$1" c="" k=0 hole=$'\x01'
  for (( k = 1; k <= 9; k++ )); do re=${re//"{$k}"/"$hole"}; done
  re=${re//\\/\\\\}
  for c in . '[' ']' '(' ')' '*' '+' '?' '^' '$' '|' '{' '}'; do re=${re//"$c"/\\$c}; done
  re=${re//"$hole"/(.+)}
  LIB_TR_REGEX="^${re}\$"
}

lib_lang_build() {
  local i=0 n=0 en="" tr="" pre="" idx=0
  (( LIB_TR_BUILT )) && return 0
  n=${#LIB_TR_PAIRS[@]}
  for (( i = 0; i + 1 < n; i += 2 )); do
    en="${LIB_TR_PAIRS[i]}"; tr="${LIB_TR_PAIRS[i + 1]}"
    if [[ "$en" != *"{1}"* ]]; then LIB_TR_EXACT["$en"]="$tr"; continue; fi
    _lib_tr_regex "$en"
    idx=${#LIB_TR_RE[@]}
    LIB_TR_RE[idx]="$LIB_TR_REGEX"; LIB_TR_TO[idx]="$tr"
    pre="${en%%\{[1-9]\}*}"
    if (( ${#pre} >= LIB_TR_KEYLEN )); then LIB_TR_BUCKET["${pre:0:LIB_TR_KEYLEN}"]+="${idx} "
    else LIB_TR_GENERAL+="${idx} "; fi
  done
  # "<site>: <what happened>" - the second half is a message of its own
  idx=${#LIB_TR_RE[@]}
  LIB_TR_RE[idx]='^([^ :]+): (.+)$'; LIB_TR_TO[idx]='{1}: {2}'
  LIB_TR_GENERAL+="${idx} "
  LIB_TR_BUILT=1
}

# One text into Turkish. A value that is itself a message (it has a space in it) is looked up
# once more, one level deep. Status 1: there is no Turkish for it, LIB_TR is the text itself.
_lib_tr_one() {   # text, how deep values are followed -> LIB_TR
  local s="$1" depth="$2" i="" out="" k=0 key="" IFS=' '
  local -a m=()
  LIB_TR="$s"
  if [[ -n "${LIB_TR_EXACT[$s]:-}" ]]; then LIB_TR="${LIB_TR_EXACT[$s]}"; return 0; fi
  key="${s:0:LIB_TR_KEYLEN}"
  for i in ${LIB_TR_BUCKET[$key]:-} $LIB_TR_GENERAL; do
    [[ "$s" =~ ${LIB_TR_RE[i]} ]] || continue
    m=("${BASH_REMATCH[@]}")
    out="${LIB_TR_TO[i]}"
    for (( k = 1; k < ${#m[@]}; k++ )); do
      if (( depth > 0 )) && [[ "${m[k]}" == *" "* ]]; then
        _lib_tr_one "${m[k]}" $((depth - 1)) || true
        m[k]="$LIB_TR"
      fi
      out=${out//"{$k}"/"${m[k]}"}
    done
    LIB_TR="$out"
    return 0
  done
  LIB_TR="$s"
  return 1
}

lib_tr() {   # text -> LIB_TR (the text itself unless Turkish is shown and there is one)
  LIB_TR="${1:-}"
  [[ "$LIB_LANG" == "tr" && -n "${1:-}" ]] || return 0
  _lib_tr_one "$1" 2 || true
  return 0
}

# The language that was chosen for this server: tr, en or both (the menu's two-language view),
# or nothing while nobody was asked.
lib_lang_stored() {
  local v=""
  [[ -r "${STATE_DIR}/lang" ]] || return 0
  read -r v <"${STATE_DIR}/lang" || true
  case "$v" in tr|en|both) printf '%s' "$v" ;; esac
  return 0
}

# Kept in a file of its own rather than in the manifest: it is asked before the installation
# has written one. A failure to keep it is no failure of the command.
lib_lang_store() {   # tr | en | both
  if [[ ! -d "$STATE_DIR" ]]; then mkdir -p -m 0700 "$STATE_DIR" 2>/dev/null || return 0; fi
  printf '%s\n' "$1" >"${STATE_DIR}/lang" 2>/dev/null || true
  return 0
}

lib_lang_ask() {   # -> LIB_LANG_ANSWER (tr | en)
  local a=""
  printf '\n  Dil / Language\n    1) Türkçe\n    2) English\n  Seçim / Choice [1]: '
  read -r a </dev/tty || a=""
  case "${a,,}" in 2|en|english) LIB_LANG_ANSWER="en" ;; *) LIB_LANG_ANSWER="tr" ;; esac
}

# Decide the language of this run. Called once, by setup.sh, after the global flags are read.
lib_lang_load() {   # [command]
  local v="${LOMP_LANG:-}" cmd="${1:-}"
  LIB_LANG="en"
  if [[ -z "$v" ]]; then
    # what a script, a pipe, a cron mail or a JSON consumer reads never changes
    if (( ${OPT_JSON:-0} )) || ! [[ -t 1 ]]; then return 0; fi
    v="${LOMP_MENU_LANG:-}"
    [[ -n "$v" ]] || v="$(lib_lang_stored)"
    # nobody chose yet: the installation and the menu ask, once, and every later run follows
    if [[ -z "$v" && -t 0 && ( "$cmd" == "install" || "$cmd" == "menu" ) ]] \
       && (( ! ${OPT_NON_INTERACTIVE:-0} )) && (( EUID == 0 )); then
      lib_lang_ask
      v="$LIB_LANG_ANSWER"; LIB_LANG_SESSION="$v"
      (( ${OPT_DRY_RUN:-0} )) || lib_lang_store "$v"
    fi
  fi
  case "$v" in
    tr|both) LIB_LANG="tr"; lib_lang_build ;;
  esac
  return 0
}

# =============================================================================
#  The messages in Turkish
# =============================================================================
# One line per message: the English text as the code prints it, with {1} {2} ... where a
# value stands (a domain, a path, a number), and the Turkish for it, which may put the
# values in another order. Messages with values come longest first: the first that fits
# is taken. A message that has no line here, or whose English wording was changed in the
# code since, is shown in English.
LIB_TR_PAIRS=(
  'files KEPT' 'dosyalar KORUNUR'
  'database KEPT' 'veritabanı KORUNUR'
  'database DROPPED' 'veritabanı SİLİNİR'
  'certificate KEPT' 'sertifika KORUNUR'
  'certificate deleted' 'sertifika silinir'
  'Testing OpenLiteSpeed configuration...' 'OpenLiteSpeed yapılandırması sınanıyor...'
  'running' 'çalışıyor'
  'stopped' 'durduruldu'
  'none' 'yok'
  'wait for it to finish, then retry' 'bitmesini bekleyin, sonra yeniden deneyin'
  'Dependencies unchanged since the last install; not reinstalling them' 'Bağımlılıklar son kurulumdan beri değişmedi; yeniden kurulmuyor'
  'no Node.js application' 'Node.js uygulaması yok'
  'Domain missing' 'Alan adı eksik'
  'Application' 'Uygulama'
  'Repository' 'Depo'
  'Last deploy' 'Son deploy'
  'Start' 'Başlatma'
  'Memory limit' 'Bellek sınırı'
  'Wanted state' 'İstenen durum'
  'Service' 'Servis'
  'Process' 'Süreç'
  'Logs' 'Loglar'
  'Environment' 'Ortam'
  'Refused repository URL' 'Depo URL'\''si reddedildi'
  'use https://host/owner/repo.git, git@host:owner/repo.git or ssh://git@host/owner/repo.git, without a user, password or token inside' 'https://host/owner/repo.git, git@host:owner/repo.git ya da ssh://git@host/owner/repo.git kullanın; içinde kullanıcı, parola ya da token olmadan'
  '--branch needs a repository' '--branch bir depo ister'
  'Add it as a read-only deploy key of the repository (GitHub: Settings > Deploy keys;' 'Bunu deponun salt okunur deploy anahtarı olarak ekleyin (GitHub: Settings > Deploy keys;'
  'GitLab: Settings > Repository > Deploy keys), then deploy with the SSH URL:' 'GitLab: Settings > Repository > Deploy keys), sonra SSH URL'\''siyle deploy edin:'
  'No log to follow' 'İzlenecek log yok'
  'Nothing to change' 'Değiştirilecek bir şey yok'
  '--start and --script cannot be combined' '--start ve --script birlikte kullanılamaz'
  'use one of them' 'birini kullanın'
  'the command runs without a shell: words only, no quotes, pipes or &&' 'komut kabuk olmadan çalışır: yalnızca sözcükler; tırnak, pipe ya da && olmaz'
  'put it into a package.json script and use --start "npm run <name>"' 'bunu bir package.json script'\''ine koyun ve --start "npm run <ad>" kullanın'
  'a file inside the app directory, such as dist/main.js' 'app dizini içinde bir dosya, örneğin dist/main.js'
  'use e.g. 512M, 1G or none' 'örneğin 512M, 1G ya da none kullanın'
  'a PM2 application needs a Node.js (proxy) site' 'PM2 uygulaması için bir Node.js (proxy) sitesi gerekir'
  'choose another port' 'başka bir port seçin'
  'values are hidden; add --show to print them' 'değerler gizli; yazdırmak için --show ekleyin'
  'SQL error (see the log)' 'SQL hatası (loga bakın)'
  'check MariaDB' 'MariaDB'\''yi kontrol edin'
  'env set takes one name; the value is read from standard input' 'env set tek bir ad alır; değer standart girdiden okunur'
  'use A-Z, 0-9 and _ (PORT, HOME, PATH, LANG and PM2_* are set by lompstack)' 'A-Z, 0-9 ve _ kullanın (PORT, HOME, PATH, LANG ve PM2_* değerlerini lompstack ayarlar)'
  'Name the variables to remove' 'Kaldırılacak değişkenlerin adını verin'
  'use a-z, 0-9 and -, starting with a letter; web and all are taken' 'a-z, 0-9 ve - kullanın, harfle başlasın; web ve all adları ayrılmıştır'
  '--start is missing' '--start eksik'
  'the command the worker runs, e.g. "node worker.js" or "npm run queue"' 'worker'\''ın çalıştıracağı komut, örneğin "node worker.js" ya da "npm run queue"'
  'use e.g. 256M or 1G' 'örneğin 256M ya da 1G kullanın'
  'five fields - minute hour day month weekday - such as "*/5 * * * *", or @hourly, @daily, @weekly, @monthly' 'beş alan - dakika saat gün ay haftanın-günü - örneğin "*/5 * * * *", ya da @hourly, @daily, @weekly, @monthly'
  'A scheduled job takes no --port' 'Zamanlanmış bir iş --port almaz'
  'leave out --cron for a long-running worker with a port' 'port dinleyen sürekli bir worker için --cron'\''u çıkarın'
  'A scheduled job takes no --memory' 'Zamanlanmış bir iş --memory almaz'
  '--timeout limits how long a run may take' '--timeout bir çalışmanın ne kadar sürebileceğini sınırlar'
  'a number followed by s, m, h or d' 'bir sayı ve ardından s, m, h ya da d'
  '--timeout belongs to a scheduled job' '--timeout zamanlanmış bir işe aittir'
  'add --cron "SCHEDULE", or leave out --timeout' '--cron "ZAMANLAMA" ekleyin ya da --timeout'\''u çıkarın'
  'use a directory inside the site'\''s home' 'sitenin home dizini içinde bir dizin kullanın'
  'PM2 is not installed (setup.sh install --with-node)' 'PM2 kurulu değil (setup.sh install --with-node)'
  'git is not installed and could not be installed' 'git kurulu değil ve kurulamadı'
  'proxy add needs a domain, a path and a target' 'proxy add bir alan adı, bir yol ve bir hedef ister'
  'use a URL prefix of letters, digits and - _ . ~ (not / itself, no segment starting with a dot)' 'harf, rakam ve - _ . ~ içeren bir URL öneki kullanın (/ tek başına olmaz, hiçbir bölüm noktayla başlamaz)'
  'expected host:port' 'host:port bekleniyor'
  'choose another path' 'başka bir yol seçin'
  'proxy remove needs a domain and a path' 'proxy remove bir alan adı ve bir yol ister'
  'Rollback finished.' 'Geri alma tamamlandı.'
  'Cannot detect operating system' 'İşletim sistemi belirlenemiyor'
  '/etc/os-release missing' '/etc/os-release yok'
  'Run on Ubuntu 22.04 or 24.04' 'Ubuntu 22.04 ya da 24.04 üzerinde çalıştırın'
  'Only Ubuntu 22.04 (jammy) and 24.04 (noble) are supported' 'Yalnızca Ubuntu 22.04 (jammy) ve 24.04 (noble) desteklenir'
  'Use a supported Ubuntu LTS release' 'Desteklenen bir Ubuntu LTS sürümü kullanın'
  'Another setup.sh instance is already running' 'Başka bir setup.sh zaten çalışıyor'
  'Wait for it to finish (ps aux | grep setup.sh)' 'Bitmesini bekleyin (ps aux | grep setup.sh)'
  'apt failure' 'apt hatası'
  'check network / apt sources' 'ağı / apt kaynaklarını kontrol edin'
  'fix the reported problem and re-run the same command' 'bildirilen sorunu düzeltin ve aynı komutu yeniden çalıştırın'
  'Refreshing package lists...' 'Paket listeleri yenileniyor...'
  'apt-get update failed' 'apt-get update başarısız oldu'
  'network or repository problem' 'ağ ya da depo sorunu'
  'check /etc/apt/sources.list.d and connectivity' '/etc/apt/sources.list.d dizinini ve bağlantıyı kontrol edin'
  'network problem' 'ağ sorunu'
  'check connectivity / DNS' 'bağlantıyı / DNS'\''i kontrol edin'
  'invalid key data' 'geçersiz anahtar verisi'
  'retry later' 'daha sonra yeniden deneyin'
  'Server is not provisioned yet' 'Sunucu henüz kurulmadı'
  'Run: sudo ./setup.sh install' 'Çalıştırın: sudo ./setup.sh install'
  'see the usage above' 'yukarıdaki kullanıma bakın'
  'not a valid FQDN (use the bare domain, without http:// or paths)' 'geçerli bir FQDN değil (yalın alan adını kullanın, http:// ya da yol olmadan)'
  '--node and --proxy cannot be combined' '--node ve --proxy birlikte kullanılamaz'
  'a Node.js site proxies to its own application' 'bir Node.js sitesi kendi uygulamasına proxy yapar'
  'drop --proxy; choose the port with --port' '--proxy'\''yi çıkarın; portu --port ile seçin'
  'a number between 1024 and 65535' '1024 ile 65535 arasında bir sayı'
  'use https://host/owner/repo.git or git@host:owner/repo.git, without a user, password or token inside' 'https://host/owner/repo.git ya da git@host:owner/repo.git kullanın; içinde kullanıcı, parola ya da token olmadan'
  '--branch needs --git' '--branch için --git gerekir'
  '--port, --start, --script, --git and --branch belong to --node' '--port, --start, --script, --git ve --branch yalnızca --node ile kullanılır'
  '--ws-path is no longer needed: a proxy site passes WebSocket upgrades on every path' '--ws-path artık gerekmiyor: bir proxy sitesi WebSocket yükseltmelerini her yolda geçirir'
  'expected e.g. 8.3' 'örneğin 8.3 bekleniyor'
  '1..64 expected' '1..64 bekleniyor'
  'use e.g. 64M' 'örneğin 64M kullanın'
  '--wildcard and --no-ssl cannot be combined' '--wildcard ve --no-ssl birlikte kullanılamaz'
  'drop one of them' 'birini çıkarın'
  'it was installed with --mail-only: a domain gets its mail here and its site somewhere else' '--mail-only ile kuruldu: bir alan adının postası burada, sitesi başka yerde olur'
  'a site of that name would take the redirect'\''s place' 'o adla bir site yönlendirmenin yerini alırdı'
  'OpenLiteSpeed is not installed' 'OpenLiteSpeed kurulu değil'
  'run install first' 'önce install çalıştırın'
  'WordPress needs MariaDB' 'WordPress için MariaDB gerekir'
  'MariaDB is not installed' 'MariaDB kurulu değil'
  'run: setup.sh install' 'çalıştırın: setup.sh install'
  'choose one with --port' '--port ile bir port seçin'
  'choose another one with --port, or leave --port out to get a free one' '--port ile başka bir port seçin, ya da boş bir port verilmesi için --port'\''u çıkarın'
  'System user and directory layout' 'Sistem kullanıcısı ve dizin yapısı'
  'OpenLiteSpeed virtual host' 'OpenLiteSpeed sanal host'
  'Smoke test (HTTP)' 'Duman testi (HTTP)'
  'SSL certificate (Let'\''s Encrypt)' 'SSL sertifikası (Let'\''s Encrypt)'
  'MariaDB database' 'MariaDB veritabanı'
  'WordPress installation' 'WordPress kurulumu'
  'Log rotation, fail2ban and scheduled tasks' 'Log döndürme, fail2ban ve zamanlanmış görevler'
  'Housekeeping done' 'Düzenleme işleri tamam'
  'Node.js application (PM2)' 'Node.js uygulaması (PM2)'
  'Install it once, with the name it will send as: lomp install --with-mail --mail-hostname mail.example.com' 'Bir kez kurun, gönderirken kullanacağı adla: lomp install --with-mail --mail-hostname mail.example.com'
  'Done' 'Tamam'
  'Using DNS-01 validation with the stored Cloudflare API token' 'Kayıtlı Cloudflare API token'\''ı ile DNS-01 doğrulaması kullanılıyor'
  'HTTP-01 through the Cloudflare proxy may fail; DNS-01 is recommended (setup.sh install --cf-api-token <token>). Trying HTTP-01 anyway...' 'Cloudflare proxy'\''si üzerinden HTTP-01 başarısız olabilir; DNS-01 önerilir (setup.sh install --cf-api-token <token>). Yine de HTTP-01 deneniyor...'
  'check /etc/group' '/etc/group dosyasını kontrol edin'
  'name collision with an unrelated account' 'ilgisiz bir hesapla ad çakışması'
  'remove/rename that account or choose another domain' 'o hesabı kaldırın/yeniden adlandırın ya da başka bir alan adı seçin'
  'check /etc/passwd' '/etc/passwd dosyasını kontrol edin'
  'OpenLiteSpeed is not installed on this server' 'Bu sunucuda OpenLiteSpeed kurulu değil'
  'run '\''lompstack install'\'' first, then retry' 'önce '\''lompstack install'\'' çalıştırın, sonra yeniden deneyin'
  'Mode' 'Mod'
  'Next' 'Sıradaki adım'
  'Document root' 'Belge kökü'
  'System user' 'Sistem kullanıcısı'
  'Database' 'Veritabanı'
  'DB user' 'DB kullanıcısı'
  'DB password' 'DB parolası'
  'DB host' 'DB sunucusu'
  'Usage: setup.sh remove <domain> [--keep-db] [--keep-files] [--keep-ssl]' 'Kullanım: setup.sh remove <domain> [--keep-db] [--keep-files] [--keep-ssl]'
  'Removal cancelled' 'Kaldırma iptal edildi'
  're-run with --yes to skip the question' 'soruyu atlamak için --yes ile yeniden çalıştırın'
  'Continue?' 'Devam edilsin mi?'
  'Scheduled tasks' 'Zamanlanmış görevler'
  'cron entries cleaned' 'cron kayıtları temizlendi'
  'OpenLiteSpeed configuration' 'OpenLiteSpeed yapılandırması'
  'Node.js application' 'Node.js uygulaması'
  'Safety backup' 'Güvenlik yedeği'
  'safety backup written' 'güvenlik yedeği yazıldı'
  'safety backup FAILED (continuing because you confirmed the removal)' 'güvenlik yedeği BAŞARISIZ (kaldırmayı onayladığınız için devam ediliyor)'
  'home directory missing; nothing to back up' 'home dizini yok; yedeklenecek bir şey yok'
  'Mail' 'Posta'
  'mailboxes, mail, DKIM key and certificate removed' 'posta kutuları, postalar, DKIM anahtarı ve sertifika kaldırıldı'
  'this site had no mail' 'bu sitenin postası yoktu'
  'database kept (--keep-db)' 'veritabanı korundu (--keep-db)'
  'Certificate' 'Sertifika'
  'certificate kept (--keep-ssl)' 'sertifika korundu (--keep-ssl)'
  'certificate removed' 'sertifika kaldırıldı'
  'Files and system user' 'Dosyalar ve sistem kullanıcısı'
  'files, logs and user kept (--keep-files)' 'dosyalar, loglar ve kullanıcı korundu (--keep-files)'
  'files and user removed' 'dosyalar ve kullanıcı kaldırıldı'
  'State and housekeeping' 'Durum ve düzenleme işleri'
  # ---- with values, longest first
  'nothing listens on 127.0.0.1:{1} after 30 s (PM2 status: {2}); the application must listen on process.env.PORT - see: setup.sh app logs {3}' '30 saniye sonra 127.0.0.1:{1} adresini dinleyen yok (PM2 durumu: {2}); uygulama process.env.PORT portunu dinlemeli - bakın: setup.sh app logs {3}'
  'create one with: setup.sh add app.example.com --node   (a proxy site can take one over: setup.sh app set {1} --start "npm start")' 'şununla oluşturun: setup.sh add app.example.com --node   (bir proxy sitesi de devralabilir: setup.sh app set {1} --start "npm start")'
  'create one with: setup.sh add app.example.com --node, or publish an app under a path: setup.sh proxy add {1} /api/ 127.0.0.1:3001' 'şununla oluşturun: setup.sh add app.example.com --node, ya da bir uygulamayı bir yol altında yayınlayın: setup.sh proxy add {1} /api/ 127.0.0.1:3001'
  'nothing but the record exists of {1} - a restore that was refused left it - so the record is put away and nothing else is touched' '{1} için kayıttan başka bir şey yok - reddedilen bir geri yükleme bıraktı - bu yüzden kayıt kaldırılır, başka hiçbir şeye dokunulmaz'
  'a link or '\''..'\'' there could aim a root chmod/chown anywhere; inspect it with: ls -la '\''{1}'\'', use a real directory, then re-run' 'oradaki bir bağlantı ya da '\''..'\'' root'\''un chmod/chown işlemini başka yere yöneltebilir; şununla inceleyin: ls -la '\''{1}'\'', gerçek bir dizin kullanın, sonra yeniden çalıştırın'
  'waiting for code: {1}. Put the application into {2}/app (owned by {3}) or deploy it from git, then run: setup.sh app deploy {4}' 'kod bekleniyor: {1}. Uygulamayı {2}/app içine koyun (sahibi {3} olmalı) ya da git'\''ten deploy edin, sonra çalıştırın: setup.sh app deploy {4}'
  'git clone of {1} failed (status {2}); a private repository needs the site'\''s deploy key: setup.sh app deploy-key {3}' '{1} için git clone başarısız oldu (durum {2}); özel bir depo için sitenin deploy anahtarı gerekir: setup.sh app deploy-key {3}'
  'Port {1} is already used by {2}; the application of {3} stays stopped (setup.sh app set {4} --port <free port>)' '{1} portunu zaten {2} kullanıyor; {3} uygulaması durdurulmuş kalıyor (setup.sh app set {4} --port <boş port>)'
  '{1}/app already holds files but is not a git checkout; move them away before the first deploy from {2}' '{1}/app içinde dosyalar var ama bir git kopyası değil; {2} deposundan ilk deploy'\''dan önce onları başka yere taşıyın'
  'Every mailbox of {1} and all of its mail is deleted too, and the safety backup does NOT include it' '{1} alan adının tüm posta kutuları ve postaları da silinir; güvenlik yedeği bunları İÇERMEZ'
  'worker {1} of {2} does not stay up (PM2 status: {3}, {4} restart(s)); see: setup.sh app logs {5} --process {6}' '{2} sitesinin {1} worker'\''ı ayakta kalmıyor (PM2 durumu: {3}, {4} yeniden başlatma); bakın: setup.sh app logs {5} --process {6}'
  'lomp mail domain add {1} --mailbox info   (to host sites here as well: lomp install --role web)' 'lomp mail domain add {1} --mailbox info   (burada site de barındırmak için: lomp install --role web)'
  'The record of {1} is put away ({2}/archive/domains/); {3} and the site it belongs to are as they were' '{1} kaydı kaldırıldı ({2}/archive/domains/); {3} ve ait olduğu site olduğu gibi duruyor'
  'the mail of {1} is a mail domain of its own here and stays as it is (setup.sh mail domain del {2})' '{1} postası burada ayrı bir posta alan adıdır ve olduğu gibi kalır (setup.sh mail domain del {2})'
  'Required tools missing: {1} (a real run installs them; some dry-run details may be skipped)' 'Gerekli araçlar eksik: {1} (gerçek çalıştırma bunları kurar; bazı dry-run ayrıntıları atlanabilir)'
  'put the code into {1}/app (copied as root? setup.sh fix-owner {2}), then: setup.sh app deploy {3}' 'kodu {1}/app içine koyun (root olarak mı kopyaladınız? setup.sh fix-owner {2}), sonra: setup.sh app deploy {3}'
  'the scheduled job {1} of {2} is not valid and stays out of cron (setup.sh app worker {3} list)' '{2} sitesinin {1} zamanlanmış işi geçerli değil ve cron'\''a eklenmedi (setup.sh app worker {3} list)'
  'DB_HOST, DB_PORT, DB_SOCKET, DB_NAME, DB_USER, DB_PASSWORD and DATABASE_URL set for {1}' '{1} için DB_HOST, DB_PORT, DB_SOCKET, DB_NAME, DB_USER, DB_PASSWORD ve DATABASE_URL ayarlandı'
  'The site is up, but its mail is not: run '\''lomp mail enable {1}'\'' once the cause is fixed' 'Site ayakta ama postası değil: neden giderilince '\''lomp mail enable {1}'\'' çalıştırın'
  '--wildcard needs DNS-01 with a Cloudflare API token ({1} missing); certificate skipped' '--wildcard için Cloudflare API token'\''ı ile DNS-01 gerekir ({1} yok); sertifika atlandı'
  'the scheduled job {1} of {2} is not valid; it gets no script (setup.sh app worker {3} list)' '{2} sitesinin {1} zamanlanmış işi geçerli değil; betiği yazılmadı (setup.sh app worker {3} list)'
  'could not restore the TCP login of the database user (setup.sh app env {1} import-db)' 'veritabanı kullanıcısının TCP girişi geri yüklenemedi (setup.sh app env {1} import-db)'
  'The application receives the full path, prefix included: serve its routes under {1}.' 'Uygulamaya yolun tamamı gider, önek dahil: rotalarını {1} altında sunun.'
  'to keep the mail, turn it off instead and leave the site: setup.sh mail disable {1}' 'postayı korumak için siteyi bırakıp postayı kapatın: setup.sh mail disable {1}'
  'At your DNS provider, the records for {1} can go too (MX, mail.{2}, SPF, DKIM, _dmarc)' 'DNS sağlayıcınızda {1} kayıtları da silinebilir (MX, mail.{2}, SPF, DKIM, _dmarc)'
  'Until your application listens on {1}, the site answers 502/503. That is expected.' 'Uygulamanız {1} adresini dinleyene kadar site 502/503 yanıtı verir. Bu beklenen bir durumdur.'
  '[dry-run] would install the dependencies and build once {1}/package.json is there' '[dry-run] {1}/package.json geldiğinde bağımlılıklar kurulup derleme yapılacaktı'
  'Certificate skipped. Point the A/AAAA records to {1} and run: setup.sh renew-ssl {2}' 'Sertifika atlandı. A/AAAA kayıtlarını {1} adresine yönlendirin ve çalıştırın: setup.sh renew-ssl {2}'
  'the filter produced more than one document (a comma where a pipe belongs?): {1}' 'filtre birden fazla belge üretti (pipe yerine virgül mü?): {1}'
  'for a private repository add the site first, then: setup.sh app deploy-key {1}' 'özel bir depo için önce siteyi ekleyin, sonra: setup.sh app deploy-key {1}'
  '{1} also sends requests to 127.0.0.1:{2}; they fail once this application is gone' '{1} de 127.0.0.1:{2} adresine istek gönderiyor; bu uygulama gidince başarısız olurlar'
  'Nothing answers on {1} yet; {2}{3} returns 503 until the application listens there' '{1} adresinde henüz yanıt veren yok; uygulama orayı dinleyene kadar {2}{3} 503 döner'
  '{1} is on record as running as {2}, and that account'\''s home is {3}: another site'\''s' '{1} kayıtlarda {2} kullanıcısıyla çalışıyor görünüyor ve o hesabın home dizini {3}: başka bir sitenin'
  'for a private repository: setup.sh app deploy-key {1}, then use the SSH URL' 'özel bir depo için: setup.sh app deploy-key {1}, sonra SSH URL'\''sini kullanın'
  'logs: setup.sh app logs {1} --process NAME (jobs: {2}/.pm2/logs/NAME-job.log)' 'loglar: setup.sh app logs {1} --process AD (işler: {2}/.pm2/logs/AD-job.log)'
  'OpenLiteSpeed did not reload; permalinks work after: systemctl restart {1}' 'OpenLiteSpeed yeniden yüklenmedi; kalıcı bağlantılar şundan sonra çalışır: systemctl restart {1}'
  '{1} still redirects to {2}, which is no longer here: setup.sh redirect del {3}' '{1} hâlâ {2} adresine yönlendiriyor, o da artık burada değil: setup.sh redirect del {3}'
  'could not work out which processes to restart (setup.sh app status {1})' 'hangi süreçlerin yeniden başlatılacağı belirlenemedi (setup.sh app status {1})'
  'The site stays on HTTP. Fix the problem and run: setup.sh renew-ssl {1}' 'Site HTTP'\''de kalıyor. Sorunu giderin ve çalıştırın: setup.sh renew-ssl {1}'
  'A previous OpenLiteSpeed instance still holds port {1} ({2}); stopping it' 'Önceki bir OpenLiteSpeed örneği hâlâ {1} portunu tutuyor ({2}); durduruluyor'
  'Another lompstack command is running; waiting for it (up to {1} s)...' 'Başka bir lompstack komutu çalışıyor; bitmesi bekleniyor (en fazla {1} sn)...'
  'This server is set up for mail only, so {1} cannot be added as a site' 'Bu sunucu yalnızca posta için kurulu; bu yüzden {1} site olarak eklenemez'
  'the project uses {1}, which needs corepack (npm install -g corepack)' 'proje {1} kullanıyor; bunun için corepack gerekir (npm install -g corepack)'
  'could not check out {1} again; {2}/app stays on the commit that failed' '{1} yeniden alınamadı; {2}/app başarısız olan commit'\''te kalıyor'
  'choose the port to run the app on: setup.sh app set {1} --port 3000' 'uygulamanın çalışacağı portu seçin: setup.sh app set {1} --port 3000'
  'use '\''setup.sh remove {1}'\'' first, or '\''renew-ssl'\'' / '\''db'\'' to change it' 'önce '\''setup.sh remove {1}'\'' kullanın, ya da değiştirmek için '\''renew-ssl'\'' / '\''db'\'''
  'fix it, then run: setup.sh app deploy {1}   (output: {2}/deploy.log)' 'düzeltin, sonra çalıştırın: setup.sh app deploy {1}   (çıktı: {2}/deploy.log)'
  '{1} no longer deploys from {2}; the checkout in {3}/app stays as it is' '{1} artık {2} deposundan deploy etmiyor; {3}/app içindeki kopya olduğu gibi kalıyor'
  '{1}/{2} does not exist yet; the worker cannot start before it does' '{1}/{2} henüz yok; o oluşmadan worker başlayamaz'
  'Running job {1} of {2} as {3}; its output goes to {4}/.pm2/logs/{5}-job.log' '{2} sitesinin {1} işi {3} kullanıcısıyla çalıştırılıyor; çıktısı {4}/.pm2/logs/{5}-job.log dosyasına gider'
  'could not tell the default branch of {1}; name it with --branch' '{1} deposunun varsayılan dalı belirlenemedi; --branch ile adını verin'
  'the mail of {1} does not belong to the site and was left alone' '{1} postası siteye ait değil, dokunulmadı'
  '[dry-run] would create an ed25519 deploy key for {1} in {2}/.ssh' '[dry-run] {1} için {2}/.ssh içinde bir ed25519 deploy anahtarı oluşturulacaktı'
  'not requested (once DNS points here: setup.sh renew-ssl {1})' 'istenmedi (DNS buraya yönlenince: setup.sh renew-ssl {1})'
  'a safety backup (files + database) is written to {1}/{2}/ first' 'önce {1}/{2}/ içine bir güvenlik yedeği (dosyalar + veritabanı) yazılır'
  'Node.js or PM2 is missing: installing Node.js {1} with PM2 {2}' 'Node.js ya da PM2 eksik: Node.js {1}, PM2 {2} ile kuruluyor'
  'pm2 could not start the application (setup.sh app logs {1})' 'pm2 uygulamayı başlatamadı (setup.sh app logs {1})'
  'Another change to the application of {1} is still running' '{1} uygulamasında başka bir değişiklik hâlâ sürüyor'
  'Directories ready: {1}/{public_html,logs,private,backups}' 'Dizinler hazır: {1}/{public_html,logs,private,backups}'
  'This server does not run mail yet, so {1} did not get any' 'Bu sunucuda henüz posta çalışmıyor; bu yüzden {1} posta almadı'
  'The build failed; putting {1} back and building it again' 'Derleme başarısız oldu; {1} geri alınıp yeniden derleniyor'
  'not writing a cron entry that cron could not parse ({1})' 'cron'\''un ayrıştıramayacağı bir cron satırı yazılmıyor ({1})'
  'Port {1} is already used by {2}; worker {3} of {4} stays stopped' '{1} portunu zaten {2} kullanıyor; {4} sitesinin {3} worker'\''ı durdurulmuş kalıyor'
  '{1} is missing, so there is no configuration to add {2} to' '{1} yok; bu yüzden {2} eklenecek bir yapılandırma da yok'
  'its Node.js application and {1} are stopped and removed' 'Node.js uygulaması ve {1} durdurulup kaldırılır'
  '(state archived in {1}/archive/domains/, backup in {2}/{3}/)' '(durum {1}/archive/domains/ altında arşivlendi, yedek {2}/{3}/ içinde)'
  'worker {1} removed from {2} (its logs stay in {3}/.pm2/logs)' '{1} worker'\''ı {2} sitesinden kaldırıldı (logları {3}/.pm2/logs içinde kalır)'
  'could not write the job scripts into {1}/.pm2/jobs as {2}' 'iş betikleri {1}/.pm2/jobs içine {2} kullanıcısıyla yazılamadı'
  'Node.js {1} with PM2; the application will listen on {2}' 'PM2 ile Node.js {1}; uygulama {2} adresini dinleyecek'
  '{1} is a scheduled job: it has no process to restart' '{1} zamanlanmış bir iş: yeniden başlatılacak bir süreci yok'
  'vhost removed and archived under {1}/archive/vhosts/' 'vhost kaldırıldı ve {1}/archive/vhosts/ altına arşivlendi'
  '{1} is a long-running worker, not a scheduled job' '{1} zamanlanmış bir iş değil, sürekli çalışan bir worker'
  'git could not check out the fetched {1} (status {2})' 'git, çekilen {1} sürümünü alamadı (durum {2})'
  'remove it first: setup.sh app worker {1} remove {2}' 'önce kaldırın: setup.sh app worker {1} remove {2}'
  'Use the apex domain and --www instead of www.{1}' 'www.{1} yerine yalın alan adını ve --www kullanın'
  '[dry-run] would create user {1} (home {2}, nologin)' '[dry-run] {1} kullanıcısı oluşturulacaktı (home {2}, nologin)'
  'could not point {1}/app at {2} (git config failed)' '{1}/app, {2} deposuna yönlendirilemedi (git config başarısız)'
  'setup.sh redirect del {1}   (then add the site)' 'setup.sh redirect del {1}   (sonra siteyi ekleyin)'
  'HTTPS smoke test failed ({1}); check {2}/error.log' 'HTTPS duman testi başarısız oldu ({1}); {2}/error.log dosyasına bakın'
  'a directory inside {1}, written relative to it' '{1} içinde bir dizin, ona göreli yazılır'
  'stopped; start it with: setup.sh app start {1}' 'durduruldu; başlatmak için: setup.sh app start {1}'
  'git fetch of branch {1} from {2} failed (status {3})' '{2} deposundan {1} dalı için git fetch başarısız oldu (durum {3})'
  'check {1}/error.log and the LSAPI processor ({2})' '{1}/error.log dosyasına ve LSAPI işlemcisine ({2}) bakın'
  'run it now with: setup.sh app worker {1} run {2}' 'şimdi çalıştırmak için: setup.sh app worker {1} run {2}'
  'the web process is {1}, {2} worker(s) run under {3}' 'web süreci {1}, {3} altında {2} worker çalışıyor'
  '[dry-run] would stop, disable and delete {1}' '[dry-run] {1} durdurulup devre dışı bırakılacak ve silinecekti'
  'dependencies of {1} could not be installed: {2}' '{1} bağımlılıkları kurulamadı: {2}'
  '{1} proxies to {2}, which is not on this server' '{1}, bu sunucuda olmayan {2} adresine proxy yapıyor'
  '{1} is proxied by Cloudflare (orange cloud).' '{1} Cloudflare üzerinden proxy'\''leniyor (turuncu bulut).'
  'Application running on 127.0.0.1:{1} under {2}' 'Uygulama {2} altında 127.0.0.1:{1} adresinde çalışıyor'
  'The site is up, its application is not: {1}' 'Site ayakta, uygulaması değil: {1}'
  'The public deploy key of {1} cannot be read' '{1} sitesinin açık deploy anahtarı okunamıyor'
  'DNS for {1} does not point to this server: {2}' '{1} DNS'\''i bu sunucuya yönlenmiyor: {2}'
  '{1} (uploaded as root? setup.sh fix-owner {2})' '{1} (root olarak mı yüklediniz? setup.sh fix-owner {2})'
  'admin credentials: setup.sh credentials {1}' 'yönetici giriş bilgileri: setup.sh credentials {1}'
  '[dry-run] would put the record of {1} away' '[dry-run] {1} kaydı kaldırılacaktı'
  'Could not write the script of job {1} as {2}' '{1} işinin betiği {2} kullanıcısıyla yazılamadı'
  'System user {1} already exists with home {2}' '{1} sistem kullanıcısı zaten var, home dizini {2}'
  'vhost + listener maps (archived), {1}, {2}, {3}' 'vhost + listener eşlemeleri (arşivlenir), {1}, {2}, {3}'
  'the mail tables could not be rebuilt: {1}' 'posta tabloları yeniden oluşturulamadı: {1}'
  'not active (run: setup.sh renew-ssl {1})' 'etkin değil (çalıştırın: setup.sh renew-ssl {1})'
  '127.0.0.1:{1} (given to the app as PORT)' '127.0.0.1:{1} (uygulamaya PORT olarak verilir)'
  '{1} variable(s) (setup.sh app env {2} list)' '{1} değişken (setup.sh app env {2} list)'
  'job {1} of {2}: {3} (log: {4}/.pm2/logs/{5}-job.log)' '{2} sitesinin {1} işi: {3} (log: {4}/.pm2/logs/{5}-job.log)'
  '[dry-run] would run job {1} of {2} now, as {3}' '[dry-run] {2} sitesinin {1} işi şimdi {3} kullanıcısıyla çalıştırılacaktı'
  'invalid jq filter or corrupted JSON: {1}' 'geçersiz jq filtresi ya da bozuk JSON: {1}'
  'OpenLiteSpeed reloaded: {1} had changed' 'OpenLiteSpeed yeniden yüklendi: {1} değişmişti'
  '[dry-run] would fetch {1}{2} into {3}/app as {4}' '[dry-run] {1}{2}, {4} kullanıcısıyla {3}/app içine çekilecekti'
  'there is no package.json in {1}/app yet' '{1}/app içinde henüz package.json yok'
  'check {1}/logs/error.log and {2}/error.log' '{1}/logs/error.log ve {2}/error.log dosyalarına bakın'
  '[dry-run] would run as {1} in {2}: {3} build' '[dry-run] {1} kullanıcısıyla {2} içinde çalıştırılacaktı: {3} build'
  '{1}, cpu {2}%, memory {3} MB, up {4}, restarts {5}' '{1}, cpu %{2}, bellek {3} MB, çalışma süresi {4}, yeniden başlatma {5}'
  'Certificate could not be obtained: {1}' 'Sertifika alınamadı: {1}'
  '{1}: the application is not running: {2}' '{1}: uygulama çalışmıyor: {2}'
  'The application of {1} is not running' '{1} uygulaması çalışmıyor'
  'could not write {1}/.pm2/lomp.env as {2}' '{1}/.pm2/lomp.env, {2} kullanıcısıyla yazılamadı'
  '{1} only redirects to {2} on this server' '{1} bu sunucuda yalnızca {2} adresine yönlendiriyor'
  '[dry-run] would enable and start {1}' '[dry-run] {1} etkinleştirilip başlatılacaktı'
  '{1} did not restart (journalctl -u {2})' '{1} yeniden başlamadı (journalctl -u {2})'
  'manifest missing ({1}/manifest.json)' 'manifest yok ({1}/manifest.json)'
  '{1} gets a PM2 application on port {2}' '{1}, {2} portunda bir PM2 uygulaması alıyor'
  'Port {1} cannot be used for worker {2}' '{1} portu {2} worker'\''ı için kullanılamaz'
  'lock {1} is held by another process' '{1} kilidini başka bir süreç tutuyor'
  'The first deploy from {1} failed: {2}' '{1} deposundan ilk deploy başarısız oldu: {2}'
  'Unknown option for app deploy: {1}' 'app deploy için bilinmeyen seçenek: {1}'
  'Unknown option for worker add: {1}' 'worker add için bilinmeyen seçenek: {1}'
  '{1} did not start (journalctl -u {2})' '{1} başlamadı (journalctl -u {2})'
  'Unknown option for proxy list: {1}' 'proxy list için bilinmeyen seçenek: {1}'
  'Unsupported operating system: {1} {2}' 'Desteklenmeyen işletim sistemi: {1} {2}'
  'Could not download signing key {1}' '{1} imza anahtarı indirilemedi'
  'The web process of {1} is stopped' '{1} sitesinin web süreci durdurulmuş'
  'Could not let {1} log in over TCP' '{1} kullanıcısının TCP üzerinden girişi açılamadı'
  'Preflight checks for {1} (mode: {2})' '{1} için ön kontroller (mod: {2})'
  '[dry-run] would run as {1} in {2}: {3}' '[dry-run] {1} kullanıcısıyla {2} içinde çalıştırılacaktı: {3}'
  'Unknown option for app list: {1}' 'app list için bilinmeyen seçenek: {1}'
  'Unknown option for app logs: {1}' 'app logs için bilinmeyen seçenek: {1}'
  'create it first: setup.sh db {1}' 'önce oluşturun: setup.sh db {1}'
  'fix the filter; {1} is as it was' 'filtreyi düzeltin; {1} olduğu gibi duruyor'
  '[dry-run] would create group {1}' '[dry-run] {1} grubu oluşturulacaktı'
  '{1} (memory {2}, upload {3}, workers {4})' '{1} (bellek {2}, yükleme {3}, worker {4})'
  '{1} runs no Node.js application' '{1} bir Node.js uygulaması çalıştırmıyor'
  'worker {1} of {2} is not running: {3}' '{2} sitesinin {1} worker'\''ı çalışmıyor: {3}'
  'Unknown option for app set: {1}' 'app set için bilinmeyen seçenek: {1}'
  '{1} already has a worker named {2}' '{1} sitesinde {2} adında bir worker zaten var'
  'check the ownership of {1}/.pm2' '{1}/.pm2 sahipliğini kontrol edin'
  'there is no package.json in {1}' '{1} içinde package.json yok'
  ''\''{1} build'\'' failed with status {2}' ''\''{1} build'\'' {2} durum koduyla başarısız oldu'
  'Could not prepare {1}/.pm2 as {2}' '{1}/.pm2, {2} kullanıcısıyla hazırlanamadı'
  'Job {1} of {2} ended with status {3}' '{2} sitesinin {1} işi {3} durum koduyla bitti'
  'Path {1} cannot be proxied on {2}' '{1} yolu {2} sitesinde proxy yapılamaz'
  'Installing required tools: {1}' 'Gerekli araçlar kuruluyor: {1}'
  'Could not set up directory {1}' '{1} dizini hazırlanamadı'
  'Preflight OK (user {1}, home {2})' 'Ön kontroller tamam (kullanıcı {1}, home {2})'
  'Unknown option for remove: {1}' 'remove için bilinmeyen seçenek: {1}'
  'building {1} failed as well: {2}' '{1} derlemesi de başarısız oldu: {2}'
  'Could not create {1}/.ssh as {2}' '{1}/.ssh, {2} kullanıcısıyla oluşturulamadı'
  'could not create {1}/.pm2 as {2}' '{1}/.pm2, {2} kullanıcısıyla oluşturulamadı'
  'could not delete UFW rule {1}' '{1} UFW kuralı silinemedi'
  'No free port between {1} and {2}' '{1} ile {2} arasında boş port yok'
  'OpenLiteSpeed reloaded ({1})' 'OpenLiteSpeed yeniden yüklendi ({1})'
  'Unknown option for app {1}: {2}' 'app {1} için bilinmeyen seçenek: {2}'
  'Port {1} cannot be used for {2}' '{1} portu {2} için kullanılamaz'
  'gpg --dearmor failed for {1}' '{1} için gpg --dearmor başarısız oldu'
  'Invalid --proxy target '\''{1}'\''' 'Geçersiz --proxy hedefi '\''{1}'\'''
  'Invalid --php-children '\''{1}'\''' 'Geçersiz --php-children '\''{1}'\'''
  'PHP is not executing for {1}' '{1} için PHP çalışmıyor'
  'files {1} and logs {2} DELETED' '{1} dosyaları ve {2} logları SİLİNİR'
  '{1}: active, starts at boot' '{1}: etkin, açılışta başlar'
  '{1} has no process named '\''{2}'\''' '{1} sitesinde '\''{2}'\'' adında bir süreç yok'
  'Invalid variable name '\''{1}'\''' 'Geçersiz değişken adı '\''{1}'\'''
  'Unknown worker action '\''{1}'\''' 'Bilinmeyen worker işlemi '\''{1}'\'''
  '{1}/app/{2} does not exist yet' '{1}/app/{2} henüz yok'
  'Rolling back {1} step(s)...' '{1} adım geri alınıyor...'
  'State update failed for {1}' '{1} için durum güncellemesi başarısız oldu'
  'Unknown option for add: {1}' 'add için bilinmeyen seçenek: {1}'
  'Site answers on http://{1}/' 'Site http://{1}/ adresinde yanıt veriyor'
  'Put the record of {1} away?' '{1} kaydı kaldırılsın mı?'
  'Site {1} is not registered' '{1} sitesi kayıtlı değil'
  'check the ownership of {1}' '{1} sahipliğini kontrol edin'
  'Deploy key created for {1}' '{1} için deploy anahtarı oluşturuldu'
  '{1} has no worker named '\''{2}'\''' '{1} sitesinde '\''{2}'\'' adında bir worker yok'
  'see {1}/.pm2/logs/{2}-job.log' 'bakın: {1}/.pm2/logs/{2}-job.log'
  'Unknown proxy action '\''{1}'\''' 'Bilinmeyen proxy işlemi '\''{1}'\'''
  '{1}://{2}{3} now goes to {4} (was {5})' '{1}://{2}{3} artık {4} adresine gidiyor (önceki: {5})'
  'HTTPS active: https://{1}/' 'HTTPS etkin: https://{1}/'
  'PM2 service prepared; {1}' 'PM2 servisi hazırlandı; {1}'
  'Invalid domain name '\''{1}'\''' 'Geçersiz alan adı '\''{1}'\'''
  'Worker {1} of {2} is stopped' '{2} sitesinin {1} worker'\''ı durdurulmuş'
  'Nothing of {1} is running' '{1} sitesinde çalışan hiçbir şey yok'
  'ssh-keygen failed for {1}' '{1} için ssh-keygen başarısız oldu'
  'Invalid worker name '\''{1}'\''' 'Geçersiz worker adı '\''{1}'\'''
  ''\''{1}'\'' failed with status {2}' ''\''{1}'\'' {2} durum koduyla başarısız oldu'
  '{1} has no path proxy on {2}' '{2} sitesinde {1} için yol yönlendirmesi yok'
  'rollback step failed: {1}' 'geri alma adımı başarısız oldu: {1}'
  'Invalid PHP version '\''{1}'\''' 'Geçersiz PHP sürümü '\''{1}'\'''
  'Smoke test failed for {1}' '{1} için duman testi başarısız oldu'
  'Unknown app action '\''{1}'\''' 'Bilinmeyen app işlemi '\''{1}'\'''
  'Unknown env action '\''{1}'\''' 'Bilinmeyen env işlemi '\''{1}'\'''
  '--cwd {1} leads outside {2}' '--cwd {1}, {2} dışına çıkıyor'
  'running on 127.0.0.1:{1}' '127.0.0.1:{1} adresinde çalışıyor'
  '{1}{2} is no longer proxied' '{1}{2} artık proxy yapılmıyor'
  'Installing packages: {1}' 'Paketler kuruluyor: {1}'
  '{1}/app, run by PM2 ({2}): {3}' '{1}/app, PM2 çalıştırır ({2}): {3}'
  '{1} stopped and removed' '{1} durduruldu ve kaldırıldı'
  'Invalid --timeout '\''{1}'\''' 'Geçersiz --timeout '\''{1}'\'''
  'could not write {1} as {2}' '{1}, {2} kullanıcısıyla yazılamadı'
  'Site {1} already exists' '{1} sitesi zaten var'
  'Backup created: {1} ({2})' 'Yedek oluşturuldu: {1} ({2})'
  'worker {1} of {2}: online' '{2} sitesinin {1} worker'\''ı: çalışıyor'
  'Invalid --script '\''{1}'\''' 'Geçersiz --script '\''{1}'\'''
  'Invalid --memory '\''{1}'\''' 'Geçersiz --memory '\''{1}'\'''
  'Refusing to set up {1}' '{1} kurulmayacak'
  'Invalid --branch '\''{1}'\''' 'Geçersiz --branch '\''{1}'\'''
  'Invalid --upload '\''{1}'\''' 'Geçersiz --upload '\''{1}'\'''
  'System user {1} exists' '{1} sistem kullanıcısı var'
  'localhost (socket {1})' 'localhost (soket {1})'
  'Invalid --start '\''{1}'\''' 'Geçersiz --start '\''{1}'\'''
  'Could not install {1}' '{1} kurulamadı'
  'This will remove {1}' '{1} kaldırılacak'
  'Invalid branch '\''{1}'\''' 'Geçersiz dal '\''{1}'\'''
  'Deploy of {1} failed' '{1} deploy'\''u başarısız oldu'
  'Invalid --cron '\''{1}'\''' 'Geçersiz --cron '\''{1}'\'''
  'Invalid target '\''{1}'\''' 'Geçersiz hedef '\''{1}'\'''
  'Invalid --port '\''{1}'\''' 'Geçersiz --port '\''{1}'\'''
  '{1} has no database' '{1} sitesinin veritabanı yok'
  'Invalid --cwd '\''{1}'\''' 'Geçersiz --cwd '\''{1}'\'''
  'groupadd {1} failed' 'groupadd {1} başarısız oldu'
  'Backing up {1} -> {2}' '{1} yedekleniyor -> {2}'
  'Fetching {1} from {2}' '{2} deposundan {1} çekiliyor'
  'As {1} in {2}: {3} build' '{1} kullanıcısıyla {2} içinde: {3} build'
  'removed from {1}: {2}' '{1} sitesinden kaldırıldı: {2}'
  'Invalid path '\''{1}'\''' 'Geçersiz yol '\''{1}'\'''
  'useradd {1} failed' 'useradd {1} başarısız oldu'
  'userdel {1} failed' 'userdel {1} başarısız oldu'
  'Site {1} is ready' '{1} sitesi hazır'
  '{1} needs a value' '{1} bir değer ister'
  '{1} {2} of {3}: stopped' '{3} sitesinin {1} {2}: durduruldu'
  'registered in {1}' '{1} içinde kayıtlı'
  'Invalid -n '\''{1}'\''' 'Geçersiz -n '\''{1}'\'''
  'job {1} of {2} done' '{2} sitesinin {1} işi tamamlandı'
  '{1}://{2}{3} goes to {4}' '{1}://{2}{3}, {4} adresine gidiyor'
  '{1} is a {2} site' '{1} bir {2} sitesi'
  '{1} is locked' '{1} kilitli'
  'rollback: {1}' 'geri alma: {1}'
  'As {1} in {2}: {3}' '{1} kullanıcısıyla {2} içinde: {3}'
  '{1} set for {2}' '{2} için {1} ayarlandı'
  'Mail for {1}' '{1} için posta'
  'Removed {1}' '{1} kaldırıldı'
  'Cloning {1}' '{1} klonlanıyor'
  'Back on {1}' '{1} sürümüne dönüldü'
  'inspect {1}' '{1} dosyasını inceleyin'
  # ---- rename and redirect (lib/rename.sh)
  '[dry-run] would record that {1} redirects to {2}' '[dry-run] {1} adresinin {2} adresine yönlendiği kaydedilecekti'
  'Two names are needed: the one that redirects and where to' 'İki ad gerekli: yönlenecek olan ve nereye yönleneceği'
  'Unknown option for redirect add: {1}' 'redirect add için bilinmeyen seçenek: {1}'
  'Unknown option for redirect del: {1}' 'redirect del için bilinmeyen seçenek: {1}'
  'Unknown redirect command: {1}' 'Bilinmeyen redirect komutu: {1}'
  'the target is a domain name, without http:// or paths' 'hedef bir alan adıdır; http:// ya da yol olmadan yazın'
  'Use the bare name and --www instead of {1}' '{1} yerine yalın adı ve --www kullanın'
  '{1} cannot redirect to itself' '{1} kendisine yönlendirilemez'
  '{1} is a site of this server' '{1} bu sunucunun bir sitesi'
  'a redirect answers for the whole name, and the site does that now' 'yönlendirme adın tamamı için yanıt verir; şu an bunu site yapıyor'
  'to move the site to {1} and leave a redirect behind: setup.sh rename {2} {3}' 'siteyi {1} adına taşıyıp geride yönlendirme bırakmak için: setup.sh rename {2} {3}'
  '{1} is itself only a redirect' '{1} kendisi yalnızca bir yönlendirme'
  'it sends its visitors on to {1}' 'ziyaretçilerini {1} adresine gönderiyor'
  'redirect {1} to that name instead' '{1} adını doğrudan o ada yönlendirin'
  '[dry-run] would add the virtual host that sends {1} on to {2}' '[dry-run] {1} adını {2} adresine gönderen sanal konak eklenecekti'
  'No certificate for {1}: {2}' '{1} için sertifika yok: {2}'
  'its DNS does not point to this server ({1})' 'DNS kaydı bu sunucuya yönlenmiyor ({1})'
  'It redirects over HTTP only until then. Once its DNS points here: setup.sh redirect add {1} {2}' 'O zamana kadar yalnızca HTTP üzerinden yönlendirir. DNS kaydı buraya yönlenince: setup.sh redirect add {1} {2}'
  '{1} does not answer with a redirect yet ({2})' '{1} henüz yönlendirmeyle yanıt vermiyor ({2})'
  '{1} and www.{2} now go to {3} (HTTPS too)' '{1} ve www.{2} artık {3} adresine gidiyor (HTTPS de)'
  '{1} and www.{2} now go to {3} (HTTP only)' '{1} ve www.{2} artık {3} adresine gidiyor (yalnızca HTTP)'
  '{1} now go to {2} (HTTPS too)' '{1} artık {2} adresine gidiyor (HTTPS de)'
  '{1} now go to {2} (HTTP only)' '{1} artık {2} adresine gidiyor (yalnızca HTTP)'
  'Which redirect?' 'Hangi yönlendirme?'
  'No redirect called {1}' '{1} adında bir yönlendirme yok'
  'Stop sending {1} on to {2}?' '{1} adının {2} adresine yönlendirilmesi durdurulsun mu?'
  'Nothing was changed' 'Hiçbir şey değiştirilmedi'
  '{1} no longer redirects; this server answers it like any name it does not know' '{1} artık yönlendirmiyor; bu sunucu onu tanımadığı herhangi bir ad gibi yanıtlıyor'
  'Two names are needed: the site and its new name' 'İki ad gerekli: site ve yeni adı'
  'Unknown option for rename: {1}' 'rename için bilinmeyen seçenek: {1}'
  'Use the bare name instead of {1}' '{1} yerine yalın adı kullanın'
  'whether www.<name> is served is a setting the site keeps' 'www.<ad> sunulup sunulmayacağı sitenin koruduğu bir ayardır'
  '{1} is called that already' '{1} zaten bu adı taşıyor'
  '{1} cannot be renamed to {2}' '{1}, {2} olarak yeniden adlandırılamıyor'
  '{1} is a site of this server already' '{1} zaten bu sunucunun bir sitesi'
  '{1} only redirects to {2} here (setup.sh redirect del {3})' '{1} burada yalnızca {2} adresine yönlendiriyor (setup.sh redirect del {3})'
  '{1} is in the way: something of that name was here before' '{1} yolu dolu: o adla daha önce burada bir şey vardı'
  'the home of {1} is not the directory {2}' '{1} sitesinin ev dizini {2} değil'
  'the site runs as {1}:{2}, not as the user lomp named after it ({3})' 'site {1}:{2} olarak çalışıyor; lomp'\''un ona verdiği kullanıcıyla ({3}) değil'
  'a Linux user called {1} exists already' '{1} adında bir Linux kullanıcısı zaten var'
  'a Linux group called {1} exists already' '{1} adında bir Linux grubu zaten var'
  'Rename cancelled' 'Yeniden adlandırma iptal edildi'
  '[dry-run] nothing was changed' '[dry-run] hiçbir şey değiştirilmedi'
  'This will rename the site {1} to {2}' '{1} sitesi {2} olarak yeniden adlandırılacak'
  'Renamed {1} to {2}' '{1}, {2} olarak yeniden adlandırıldı'
  'files    {1} becomes {2} (moved, not copied); the Linux user {3} keeps its name' 'dosyalar {1}, {2} olur (taşınır, kopyalanmaz); Linux kullanıcısı {3} adını korur'
  'files    {1} becomes {2} (moved, not copied); the Linux user {3} becomes {4}' 'dosyalar {1}, {2} olur (taşınır, kopyalanmaz); Linux kullanıcısı {3}, {4} olur'
  'database {1} keeps its name, its user and its password' 'veritabanı {1} adını, kullanıcısını ve şifresini korur'
  'database none' 'veritabanı yok'
  'HTTPS    a new certificate for {1}' 'HTTPS    {1} için yeni bir sertifika'
  'HTTPS    no certificate is requested for {1} now' 'HTTPS    {1} için şimdi sertifika istenmiyor'
  '{1}  is no domain name, so nothing ever asked this server for it: nothing stays behind under it' '{1}  bir alan adı değil, yani bu sunucuya o adla hiç gelinmedi: o adla geride bir şey kalmaz'
  '{1}  stays as a redirect: every request goes on to {2} with a 301, under the certificate it has' '{1}  yönlendirme olarak kalır: her istek 301 ile {2} adresine gider, mevcut sertifikasıyla'
  '{1}  stays as a redirect: every request goes on to {2} with a 301' '{1}  yönlendirme olarak kalır: her istek 301 ile {2} adresine gider'
  '{1}  is no longer answered here, and its certificate is deleted (--no-redirect)' '{1}  artık burada yanıtlanmaz ve sertifikası silinir (--no-redirect)'
  'WordPress the addresses in its database are rewritten to {1}' 'WordPress veritabanındaki adresler {1} olarak yeniden yazılır'
  'WordPress its database is left as it is (--no-search-replace)' 'WordPress veritabanı olduğu gibi bırakılır (--no-search-replace)'
  'Node.js  its PM2 service is set up again under the new user: dependencies are installed again, the application is built and started' 'Node.js  PM2 servisi yeni kullanıcıyla yeniden kurulur: bağımlılıklar yeniden yüklenir, uygulama derlenir ve başlatılır'
  'mail     every mailbox moves to @{1} with its mail and its password; each address at @{2} becomes an alias of it' 'posta    her posta kutusu postaları ve şifresiyle @{1} alanına taşınır; @{2} alanındaki her adres onun takma adı olur'
  '         (people sign in with their new address from then on; --keep-mail leaves the mail where it is)' '         (bundan sonra herkes yeni adresiyle giriş yapar; --keep-mail postayı yerinde bırakır)'
  'mail     stays at @{1}: every mailbox, alias and key as it is, {2} becoming a mail domain of its own' 'posta    @{1} alanında kalır: her posta kutusu, takma ad ve anahtar olduğu gibi; {2} kendi başına bir posta alanı olur'
  '         ({1} starts without mail: setup.sh mail enable {2})' '         ({1} postasız başlar: setup.sh mail enable {2})'
  'a safety backup is written to {1} first; the site is away for about a minute, its application until it is built' 'önce {1} altına bir güvenlik yedeği yazılır; site yaklaşık bir dakika, uygulaması ise derlenene kadar kapalı kalır'
  'a safety backup is written to {1} first; the site is away for about a minute' 'önce {1} altına bir güvenlik yedeği yazılır; site yaklaşık bir dakika kapalı kalır'
  'The DNS of {1} does not point to this server yet: {2}' '{1} alan adının DNS kaydı henüz bu sunucuya yönlenmiyor: {2}'
  'It gets no certificate until it does, so it answers over HTTP only - and a site that expects HTTPS (WordPress does) will not work properly until then.' 'Yönlenene kadar sertifika alamaz, yani yalnızca HTTP üzerinden yanıt verir - HTTPS bekleyen bir site de (WordPress bekler) o zamana kadar düzgün çalışmaz.'
  'It gets no certificate until it does, so it answers over HTTP only.' 'Yönlenene kadar sertifika alamaz, yani yalnızca HTTP üzerinden yanıt verir.'
  'Better: point {1} and www.{2} here first, then rename. Afterwards it would be: setup.sh renew-ssl {3}' 'Daha iyisi: önce {1} ve www.{2} adlarını buraya yönlendirin, sonra yeniden adlandırın. Sonradan yapılacaksa: setup.sh renew-ssl {3}'
  'Better: point {1} here first, then rename. Afterwards it would be: setup.sh renew-ssl {2}' 'Daha iyisi: önce {1} adını buraya yönlendirin, sonra yeniden adlandırın. Sonradan yapılacaksa: setup.sh renew-ssl {2}'
  'Safety backup of {1}' '{1} için güvenlik yedeği'
  'The safety backup failed, so nothing was changed' 'Güvenlik yedeği alınamadı, bu yüzden hiçbir şey değiştirilmedi'
  'free some space under {1}, or see the log' '{1} altında yer açın ya da loga bakın'
  'safety backup written: {1}' 'güvenlik yedeği yazıldı: {1}'
  'Taking {1} off the air' '{1} yayından kaldırılıyor'
  'Processes of {1} are still running' '{1} kullanıcısının süreçleri hâlâ çalışıyor'
  'they did not stop when asked' 'istendiğinde durmadılar'
  'virtual host removed, nothing runs as {1}' 'sanal konak kaldırıldı, {1} olarak çalışan bir şey yok'
  'Moving the site to {1}' 'Site {1} adına taşınıyor'
  'home {1}, user {2}' 'ev dizini {1}, kullanıcı {2}'
  'Could not rename the group {1} to {2}' '{1} grubu {2} olarak yeniden adlandırılamadı'
  'Could not rename the user {1} to {2}' '{1} kullanıcısı {2} olarak yeniden adlandırılamadı'
  'something still runs as {1}' '{1} olarak hâlâ bir şey çalışıyor'
  'Could not point the user {1} at {2}' '{1} kullanıcısı {2} dizinine yönlendirilemedi'
  'Could not move the logs of {1}' '{1} sitesinin logları taşınamadı'
  'Could not move the state of {1}' '{1} sitesinin durum kaydı taşınamadı'
  'Could not rewrite the state of {1}' '{1} sitesinin durum kaydı yeniden yazılamadı'
  'Could not move {1} to {2}' '{1}, {2} konumuna taşınamadı'
  'see the log' 'loga bakın'
  'OpenLiteSpeed virtual host for {1}' '{1} için OpenLiteSpeed sanal konağı'
  '{1} does not answer' '{1} yanıt vermiyor'
  'check {1}; the site is put back under {2}' '{1} dosyasına bakın; site {2} adına geri alınıyor'
  'the site answers on http://{1}/' 'site http://{1}/ adresinde yanıt veriyor'
  'The mail of {1} could not be given a record of its own; its mailboxes still work: setup.sh mail domain add {2}' '{1} postasına kendi kaydı verilemedi; posta kutuları çalışmaya devam ediyor: setup.sh mail domain add {2}'
  'The old name {1}' 'Eski ad {1}'
  '{1} now sends every request on to {2}, over HTTPS too' '{1} artık her isteği {2} adresine gönderiyor, HTTPS üzerinden de'
  '{1} now sends every request on to {2}' '{1} artık her isteği {2} adresine gönderiyor'
  'The redirect from {1} could not be set up; later: setup.sh redirect add {2} {3}' '{1} için yönlendirme kurulamadı; sonra: setup.sh redirect add {2} {3}'
  'nothing is left under {1}: it was no name anything could ask for' '{1} adıyla geride bir şey kalmadı: kimsenin soracağı bir ad değildi'
  '{1} is no longer answered here' '{1} artık burada yanıtlanmıyor'
  'The redirect from {1} still leads to {2}; later: setup.sh redirect add {3} {4}' '{1} yönlendirmesi hâlâ {2} adresine gidiyor; sonra: setup.sh redirect add {3} {4}'
  'The application of {1} did not come up; later: setup.sh app deploy {2}' '{1} uygulaması ayağa kalkmadı; sonra: setup.sh app deploy {2}'
  'Certificate for {1}' '{1} için sertifika'
  'The certificate step ended early; later: setup.sh renew-ssl {1}' 'Sertifika adımı erken bitti; sonra: setup.sh renew-ssl {1}'
  'no certificate requested (setup.sh renew-ssl {1})' 'sertifika istenmedi (setup.sh renew-ssl {1})'
  'Mailboxes to @{1}' 'Posta kutuları @{1} alanına'
  '{1} stays a mailbox at {2}: {3}' '{1}, {2} alanında posta kutusu olarak kalıyor: {3}'
  '{1} exists already' '{1} zaten var'
  '{1} is in the way' '{1} yolu dolu'
  'mail could not be switched on for {1}' '{1} için posta açılamadı'
  'The mail tables could not be rebuilt ({1}): setup.sh mail status' 'Posta tabloları yeniden oluşturulamadı ({1}): setup.sh mail status'
  'The webmail of {1} could not be set up; later: setup.sh mail webmail on {2}' '{1} için webmail kurulamadı; sonra: setup.sh mail webmail on {2}'
  'WordPress addresses, scheduled tasks and logs' 'WordPress adresleri, zamanlanmış görevler ve loglar'
  'WordPress database left as it is (--no-search-replace)' 'WordPress veritabanı olduğu gibi bırakıldı (--no-search-replace)'
  '[dry-run] would rewrite {1} to {2} in the WordPress database' '[dry-run] WordPress veritabanında {1}, {2} olarak yeniden yazılacaktı'
  'wp-cli could not be installed, so the WordPress database still says {1}' 'wp-cli kurulamadı, bu yüzden WordPress veritabanı hâlâ {1} diyor'
  '(no redirects - add one with: setup.sh redirect add old-name.com example.com)' '(yönlendirme yok - eklemek için: setup.sh redirect add old-name.com example.com)'
  'it is on record as running as {1}, and that account'\''s home is {2}: another site'\''s (setup.sh remove {3} puts such a record away)' 'kayıtta {1} olarak çalıştığı yazıyor, o hesabın ev dizini ise {2}: başka bir sitenin (setup.sh remove {3} böyle bir kaydı kaldırır)'
  'wp-cli could not be installed, so the WordPress database was not looked at: it may give another name than {1} as its address' 'wp-cli kurulamadı, bu yüzden WordPress veritabanına bakılmadı: adres olarak {1} dışında bir ad veriyor olabilir'
  'Later: wp option get home - and if that is another name: wp search-replace '\''//that-name'\'' '\''//{1}'\'' --all-tables-with-prefix --skip-columns=guid   (as {2}, in {3}/public_html)' 'Sonra: wp option get home - başka bir ad çıkarsa: wp search-replace '\''//o-ad'\'' '\''//{1}'\'' --all-tables-with-prefix --skip-columns=guid   ({2} olarak, {3}/public_html içinde)'
  'WordPress did not say which address it has, so no address in its database was rewritten: {1} itself never was one' 'WordPress hangi adresi kullandığını söylemedi, bu yüzden veritabanındaki hiçbir adres yeniden yazılmadı: {1} zaten hiç adres olmadı'
  'If it answers under another name than {1}: wp search-replace '\''//that-name'\'' '\''//{2}'\'' --all-tables-with-prefix --skip-columns=guid   (as {3}, in {4}/public_html)' '{1} dışında bir adla yanıt veriyorsa: wp search-replace '\''//o-ad'\'' '\''//{2}'\'' --all-tables-with-prefix --skip-columns=guid   ({3} olarak, {4}/public_html içinde)'
  'no password line for {1}' '{1} için şifre satırı yok'
  'could not make {1}' '{1} oluşturulamadı'
  'could not move {1}' '{1} taşınamadı'
  'the mail of {1} is switched off' '{1} postası kapalı'
  'redirect del <from> [--keep-ssl]' 'redirect del <kimden> [--keep-ssl]'
  'Later: wp search-replace '\''//{1}'\'' '\''//{2}'\'' --all-tables-with-prefix --skip-columns=guid   (as {3}, in {4}/public_html)' 'Sonra: wp search-replace '\''//{1}'\'' '\''//{2}'\'' --all-tables-with-prefix --skip-columns=guid   ({3} olarak, {4}/public_html içinde)'
  'Not every address in the WordPress database could be rewritten (see {1})' 'WordPress veritabanındaki adreslerin hepsi yeniden yazılamadı (bkz. {1})'
  'Again: wp search-replace '\''{1}'\'' '\''{2}'\'' --all-tables-with-prefix --skip-columns=guid   (as {3}, in {4}/public_html)' 'Yeniden: wp search-replace '\''{1}'\'' '\''{2}'\'' --all-tables-with-prefix --skip-columns=guid   ({3} olarak, {4}/public_html içinde)'
  'WordPress: the addresses in its database now say {1}' 'WordPress: veritabanındaki adresler artık {1} diyor'
  'WordPress: its database gives {1} as its address already' 'WordPress: veritabanı adres olarak zaten {1} veriyor'
  'WordPress: its database said {1}; the addresses in it now say {2}' 'WordPress: veritabanı {1} diyordu; içindeki adresler artık {2} diyor'
  'WordPress does not give {1} as its address, although its database was rewritten from {2}' 'WordPress, veritabanı {2} adından yeniden yazıldığı hâlde adres olarak {1} vermiyor'
  'The name is then set outside the database: look for WP_HOME and WP_SITEURL in {1}/public_html/wp-config.php' 'Ad o hâlde veritabanı dışında ayarlanmış: {1}/public_html/wp-config.php içinde WP_HOME ve WP_SITEURL satırlarına bakın'
  '[dry-run] would empty the page cache {1}' '[dry-run] sayfa önbelleği {1} boşaltılacaktı'
  'page cache emptied: no page from before the addresses changed is served any more' 'sayfa önbelleği boşaltıldı: adresler değişmeden önceki hiçbir sayfa artık sunulmuyor'
  'The page cache {1} could not be emptied: pages cached before the addresses changed may still be served' 'Sayfa önbelleği {1} boşaltılamadı: adresler değişmeden önce önbelleğe alınan sayfalar hâlâ sunulabilir'
  'Purge it from WordPress (LiteSpeed Cache > Purge All), or empty that directory' 'WordPress içinden temizleyin (LiteSpeed Cache > Purge All) ya da o dizini boşaltın'
  'Address' 'Adres'
  'Files' 'Dosyalar'
  'Old name' 'Eski ad'
  'Backups' 'Yedekler'
  '{1}/public_html (user {2})' '{1}/public_html (kullanıcı {2})'
  '{1} (unchanged; setup.sh credentials {2})' '{1} (değişmedi; setup.sh credentials {2})'
  'no longer answered' 'artık yanıtlanmıyor'
  '{1} (no domain name: nothing is left under it)' '{1} (alan adı değil: o adla bir şey kalmadı)'
  '{1}/ (the one from before the rename: {2})' '{1}/ (yeniden adlandırmadan önceki: {2})'
  'No certificate yet: point the DNS of {1} here, then run: setup.sh renew-ssl {2}' 'Henüz sertifika yok: {1} alan adının DNS kaydını buraya yönlendirin, sonra çalıştırın: setup.sh renew-ssl {2}'
  'Keep the DNS of {1} pointing here for as long as the redirect should work.' 'Yönlendirmenin çalışmasını istediğiniz sürece {1} alan adının DNS kaydı buraya yönlenmeli.'
  'Mail: now at @{1} - {2}. Same passwords; the user name to sign in with is the new address.' 'Posta: artık @{1} alanında - {2}. Şifreler aynı; giriş için kullanıcı adı yeni adrestir.'
  'Mail to the old addresses at @{1} still arrives, as aliases, and may still be sent from. Keep the MX of {2} pointing here.' '@{1} alanındaki eski adreslere gelen posta takma ad olarak ulaşmaya devam eder; o adreslerle gönderim de yapılabilir. {2} alan adının MX kaydı buraya yönlenmeye devam etmeli.'
  'For mail from outside to reach @{1} directly, its DNS needs the records: setup.sh mail dns {2}' 'Dışarıdan gelen postanın @{1} alanına doğrudan ulaşması için DNS kayıtları gerekir: setup.sh mail dns {2}'
  'The mailboxes could not be moved to @{1}; they are at @{2} and work as before' 'Posta kutuları @{1} alanına taşınamadı; @{2} alanında duruyorlar ve eskisi gibi çalışıyorlar'
  'Mail: the mailboxes at @{1} work as before; {2} is a mail domain of its own now (setup.sh mail domain list).' 'Posta: @{1} alanındaki posta kutuları eskisi gibi çalışıyor; {2} artık kendi başına bir posta alanı (setup.sh mail domain list).'
  'Mail for {1}, if it should have any: setup.sh mail enable {2} --mailbox info' '{1} için posta istenirse: setup.sh mail enable {2} --mailbox info'
  'A variable of the application still names {1}: setup.sh app env {2} list' 'Uygulamanın bir değişkeni hâlâ {1} adını içeriyor: setup.sh app env {2} list'
  'These files still name {1} (an address, or the old path {2}); have a look at them:' 'Bu dosyalar hâlâ {1} adını içeriyor (bir adres ya da eski yol {2}); bir göz atın:'
  'These files still name {1}; have a look at them:' 'Bu dosyalar hâlâ {1} adını içeriyor; bir göz atın:'
)
