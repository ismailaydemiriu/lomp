#!/usr/bin/env bash
# lib/menu.sh - user interface: the command reference and the interactive menu shown
#               when the command is run with no arguments on a terminal. The menu is a
#               launcher: every entry runs the ordinary command as a child process, so
#               each action takes the lock, starts from clean state and cannot take the
#               menu down when it fails.

lib_usage() {
  # a usage text is no single message lib/lang.sh could look up: its Turkish is here
  if [[ "${LIB_LANG:-en}" == "tr" ]]; then
    cat <<'USAGE_EOF'
lomp - LOMP yığını: Linux + OpenLiteSpeed + MariaDB + PHP (LSPHP), Redis ve TLS ile.
       Ubuntu 22.04 / 24.04 için üretim VPS kurulumu ve site yönetimi.

KULLANIM
  sudo lomp                             # argümansız: etkileşimli menü
  sudo lomp <command>                   # kurulumdan sonra: kısa ad, her yerde çalışır
  sudo ./setup.sh <command> [arguments] [global flags]
  sudo ./setup.sh domain.com            # şunun kısaltması: add domain.com

KOMUTLAR
  install [opts]                Sunucuyu kurar (tekrar çalıştırmak güvenlidir)
      --php 8.3                 Varsayılan LSPHP sürümü
      --timezone Europe/Istanbul
      --admin-port 7080         WebAdmin portu (OpenLiteSpeed varsayılanı; boş her port olur)
      --admin-access MODE       WebAdmin erişimi: tunnel (varsayılan) | ip | open
      --admin-ip 1.2.3.4        SİZİN adresiniz (sunucunun değil); --admin-access ip demektir
                                Mevcut SSH oturumundan alınması için "auto" yazın
      --email admin@x.com       Varsayılan e-posta (Let's Encrypt / bildirimler)
      --ssh-port 2222           SSH portunu değiştirir (önce UFW'de açılır)
      --non-interactive         Hiç soru sormaz, varsayılanları kullanır
      --with-node [--node 24]   Node.js (NodeSource) + PM2; kurulu ana sürüm korunur
      --with-python             python3-venv + pip (her uygulamaya ayrı venv)
      --with-netdata            localhost'a (+ yönetici IP'sine) bağlı Netdata
      --with-mail [--mail-hostname mail.example.com]
                                Bu sunucudaki siteler için posta sunucusu (Postfix, Dovecot,
                                Rspamd); kendi adı, bir A kaydı ve bir PTR kaydı gerekir
      --mail-only [--mail-hostname mail.example.com]
                                Yalnızca posta için sunucu: aynı posta sunucusu; web yığını
                                yalnızca webmail gerektirdiği için kurulur. Alan adları site
                                değil posta alır ("mail domain add"). --role web bunu geri alır
      --cloudflare              Cloudflare proxy'lerine güvenir (gerçek istemci IP'si)
      --cf-api-token TOKEN      Cloudflare API token'ını saklar (DNS-01 / fail2ban); "-" onu
                                stdin'den okur, böylece süreç listesinde görünmez
      --mariadb 11.4            MariaDB'yi resmi depodan kurar
      --redis-persist           Redis kalıcılığını açar (varsayılan: yalnızca önbellek)
      --backup-schedule "daily 03:00"
      --auto-reboot             unattended-upgrades'in yeniden başlatmasına izin verir
      --skip-upgrade            Kurulum sırasında apt upgrade adımını atlar
  add <domain> [opts]           Site oluşturur (kullanıcı, dizinler, sanal konak, SSL)
      --email a@b.c  --no-ssl  --www  --www-primary  --php 8.3
      --memory 256M  --upload 64M  --php-children N
      --proxy 127.0.0.1:3000  --static  --wordpress  --cloudflare  --no-db
      --wildcard  --staging  --hsts-preload
      --mail [--mailbox info] [--mail-quota 2G]
                                Siteyi oluştururken ona kendi postasını verir
      --wp-title "Title" --wp-admin admin --wp-email a@b.c --wp-locale en_US
      --node [--port N] [--start "npm start" | --script dist/main.js] [--git URL [--branch B]]
                                Node.js sitesi: PM2 uygulamayı sitenin kullanıcısı olarak
                                çalıştırır, OpenLiteSpeed ona proxy olur (3000'den itibaren
                                boş bir port); --git ile uygulama hemen yayına alınır
                                --no-db verilmedikçe her site kendi veritabanını ve
                                MariaDB kullanıcısını alır.
  wordpress <domain>            En güncel WordPress'in dosyalarını (wordpress.org/latest.zip)
                                var olan bir PHP sitesinin public_html dizinine, sitenin kendi
                                kullanıcısı olarak koyar; kurulum tarayıcıda tamamlanır ve
                                yazdığı wp-config.php bir dakika içinde 0640'a çekilir
                                ("add --wordpress" ise tamamını kurar)
  db <domain>                   Sitenin MariaDB veritabanını oluşturur (veya gösterir)
  db list                       Her sitenin veritabanı, kullanıcısı ve boyutu (şifreler yok)
  db passwd <domain>            Sitenin veritabanı kullanıcısına yeni, rastgele bir şifre
  proxy list [<domain>]         Her sitenin yol proxy'leri ve uygulamalarının yanıt verip vermediği
  proxy add <domain> <path> <host:port>
                                Var olan bir sitenin bir yolu altında bir uygulama yayınlar,
                                her modda: proxy add example.com /api/ 127.0.0.1:3001
  proxy remove <domain> <path>  O yola proxy yapmayı bırakır
  app list                      Node.js uygulamaları: durum, CPU, bellek, yeniden başlatma
                                sayısı (--json)
  app status <domain>
  app start|stop|restart <domain> [--process NAME]
  app logs <domain> [--process NAME] [--out|--error] [-n LINES]
  app worker <domain> list | remove NAME | run NAME
  app worker <domain> add NAME --start CMD [--cwd DIR] [--port N] [--memory 256M]
  app worker <domain> add NAME --cron "*/5 * * * *" --start CMD [--timeout 1h]
                                Worker'lar (kuyruk tüketicileri, botlar) uygulamanın yanında, onun
                                PM2'si altında çalışır; --cron ile işi cron başlatır, aynı anda
                                tek çalıştırma olur
  app deploy <domain> [--git URL [--branch B]]
                                git'ten çeker (ilk seferde: clone), bağımlılıklar değiştiyse
                                kurar, bellek sınırıyla derler, yeniden başlatır
  app deploy-key <domain>       Özel depo için sitenin salt okunur anahtarını oluşturur/yazdırır
  app set <domain> [--port N] [--start CMD | --script FILE] [--memory 512M|none] [--no-git]
  app env <domain> list [--show] | set NAME | unset NAME... | import-db
                                Değerler stdin'den veya gizli bir istemden gelir, komut satırından
                                asla gelmez; import-db DB_* ve DATABASE_URL ekler
  mail domain add <domain> [--mailbox info] [--quota 2G]
                                Bu sunucunun sitesi olmayan bir alan adı için posta (web
                                sitesi başka yerdedir veya yoktur): Linux kullanıcısı da sanal konak da yok
  mail domain add <domain> --to <you@example.com> [--address info,sales] [--catch-all]
                                Aynısı, kendi posta kutusu olmadan: adresleri var olan bir
                                posta kutusuna teslim edilir - birkaç alan adı için tek gelen
                                kutusu - ve o posta kutusu onların adına gönderebilir
  mail domain list              Postası olan her alan adı: site mi, yalnızca posta mı; posta
                                kutuları, takma adlar
  mail domain del <domain> [--dns-cleanup] [--no-backup]
                                Posta alan adını ve tüm postasını son bir yedekten sonra kaldırır
  mail enable <domain> [--mailbox info] [--quota 2G]
                                Siteye kendi postasını verir: DKIM anahtarı, mail.<domain> için
                                sertifika ve eklenecek DNS kayıtları
                                (--to, --address ve --catch-all burada da çalışır)
  mail disable <domain> [--delete-data]
  mail box add|passwd|quota|list|del|kick <user@domain>
                                Şifreler stdin'den veya gizli bir istemden gelir, komut satırından
                                asla gelmez; "kick" posta kutusunun açık oturumlarını sonlandırır
  mail alias add|del|list <alias@domain> [target,...]
                                Başka bir yere giden adres; buradaki bir posta kutusuna gidiyorsa
                                o kutu onun adına da gönderebilir. Takma ad olarak "@<domain>" bir
                                catch-all olur: alan adının kendi satırı olmayan her adresi
  mail dns <domain> [--check] [--json]   DNS'e ne yazılacağı ve orada olup olmadığı
  mail dns <domain> --apply [--replace-mx]
                                O kayıtları saklanan token ile Cloudflare'e yazar.
                                Yabancı bir MX veya ikinci bir SPF kaydı bildirilir, asla üzerine
                                yazılmaz; yalnızca lompstack'in yazdığı kayıtlar kaldırılır
  mail status|test|queue        Posta yığını: ne çalışıyor, ters DNS, giden 25 numaralı port
  mail cert [domain]            Gelmemiş bir sertifikayı yeniden ister
  mail regenerate               Her posta yapılandırma dosyasını yeniden yazar ve yığını
                                yeniden başlatır
  mail webmail on|off <domain>  webmail.<domain> adresinde webmail. Webmaili olan her alan adı
                                tek bir Roundcube'u ve tek bir PHP sürecini paylaşır; yirmincisi
                                bir sanal konağa mal olur, başka bir şeye değil
  webmail status                Ne çalışıyor ve hangi alan adları için (herkes kendi şifresini
                                orada, Ayarlar (Settings) altında değiştirir)
  webmail update [version]      Daha yeni bir Roundcube alır (bu her gün kendiliğinden de olur)
  webmail forget <user@domain>|@<domain>|--gone
                                Artık olmayan bir posta kutusu için webmail tarafında kalanları
                                kaldırır (adres defteri, kimlikler, ayarlar). Bir posta kutusu
                                silinince bu kendiliğinden olur; komut, lomp bunu yapmaya
                                başlamadan önce veya veritabanı kapalıyken silinen kutular içindir.
                                --gone böyle adreslerin hepsidir: onları listeler (doctor ilk
                                birkaçını söyler) ve kaldırmadan önce sorar
  webmail uninstall | purge     Kaldırır; "purge" veritabanını da siler
  mail dkim status <domain>     Bu alan adının hangi anahtarla imzaladığı
  mail dkim rotate <domain> [--abort]
                                İkinci bir anahtar üretir ve kaydını yayınlar; kayıt DNS'te görününce
                                imzalama kendiliğinden ona geçer, eski anahtar ise gönderilmiş
                                postalar doğrulanabilsin diye bir hafta saklanır
  mail backup <domain> [--keep N]     Yalnızca posta: posta kutuları, takma adlar, DKIM anahtarı
  mail restore <domain> [--file A]    ve postanın kendisi; aynı posta kutularına, aynı şifreler
                                ve aynı anahtarla geri gelir. Boş olmayan bir posta kutusu için
                                önce sorulur: kopya oradakinin yerini alır. Bir betikte
                                yanıtlamak için --yes ekleyin
  mail relay set --host H [--port 587] --user U [--spf-include NAME] [--tls LEVEL] | relay off
                                25 numaralı portun kapalı olduğu yerde giden postayı başka bir
                                sunucu üzerinden gönderir; şifre stdin'den okunur
  remove <domain> [opts]        Site kaldırır (--keep-db --keep-files --keep-ssl; diğer adı: delete)
  rename <old> <new> [opts]     Siteyi başka bir alan adına taşır: dosyalar, kullanıcı, loglar
                                ve ayarlar onunla gelir, veritabanı kalır, yeni ad sertifikasını
                                alır, WordPress'in adresleri yeniden yazılır ve eski ad her şeyi
                                301 ile yeni ada gönderir
                                (--no-redirect --no-ssl --no-search-replace)
  redirect add <from> <to>      Site olmayan, ziyaretçilerini yalnızca başka bir ada gönderen
                                bir ad (301, yol korunur; --www --no-ssl)
  redirect list | del <from>    Yönlendirmeler; biri için yanıt vermeyi bırakır (--keep-ssl)
  import <[user@]host> [opts]   Başka bir sunucudan SSH ile site getirir: sunduklarını listeler,
                                hangilerini istediğinizi sorar, burada henüz olmayan siteleri
                                ekler, dosyaları ve sitenin kendi dosyalarının gösterdiği
                                veritabanını (WordPress, ya da başka bir uygulamanın
                                config.php, .env ... dosyası) kopyalar ve
                                o dosyaları buradaki veritabanına yöneltir. Bu
                                sunucuda posta kuruluysa alan adının posta kutuları da gelir
                                (öteki sunucu lomp ya da CyberPanel ise şifreleriyle), takma
                                adları ve iletmeleri de; DNS'e dokunulmaz. Yeni site orada
                                çalıştığı PHP sürümünü alır (bu sunucunun verdiğinden büyük
                                memory_limit ya da yükleme boyutu da korunur), cron işleri burada sitenin
                                kullanıcısı olarak çalışır. Öteki sunucu yalnızca okunur
                                (--list --all --only a.com,b.com --no-create --no-mail
                                --only-mail --no-cron --port N --key FILE --password-file FILE
                                --path DIR --as DOMAIN --db NAME)
  import cron <domain> [--clear]  Aktarımla siteye gelen cron işleri; istenirse kaldırır
  list                          Site tablosu (--json)
  status                        Servisler, sürümler, kaynaklar, siteler (--json)
  doctor                        Derin sağlık kontrolü (--json, --quiet)
  credentials <domain>|--all    Saklanan kimlik bilgilerini gösterir (asla loglanmaz)
  fix-owner <domain>|--all      root olarak yüklemeden sonra (WinSCP, scp) sitenin dosyalarını
                                kendi kullanıcısına geri verir. Yalnızca başkasına ait olan
                                değişir; logs/ ve dosya izinleri aynı kalır. Yüklemeden sonra
                                bir dakika içinde kendiliğinden olur; komut beklemeden yapmak içindir
  fix-owner --auto on|off       Bunu durdurur (root sitede kendi dosyalarını tutar) veya başlatır
  optimize                      Sistemi yeniden ölçer ve yeniden ayarlar (fark gösterir)
  harden <domain>|--all         Bir sitedeki PHP shell'in yapabileceklerini sınırlar: PHP'den
                                süreç çalıştırma yok, open_basedir, yükleme dizinlerinde betik
                                yok, bu makinede yalnızca DNS, web, MariaDB, Redis ve kendi
                                uygulaması erişilebilir (site başına --allow-exec,
                                --allow-upload-php; "harden status"; --firewall on|off)
  scan <domain>|--all [--wide]  Sitenin PHP dosyalarında web shell'lerin yapı taşlarını arar
                                (çözülmüş veya istekten gelen verinin eval edilmesi, istekten
                                kurulan komutlar, paketlenmiş kod) ve bakılacak dosyaları
                                listeler. Hiçbir şeyi değiştirmez; --wide ayrıca her eval,
                                base64_decode ve exec kullanımını listeler
  php-cleanup [--php 8.3]       Bir "apt-get install lsphp83*" işlemini geri alır: onun, lomp'un kendi
                                PHP paketleri dışında eklediklerini siler (derleyici, hata
                                ayıklama sembolleri, kaynaklar, dağıtımın PHP'si). Listeyi
                                gösterir ve önce sorar
  backup <domain>|--all [opts]  --remote --encrypt --keep N --no-mail --dry-run
                                Postası olan bir alan adı, sitenin arşivinin yanında ikinci bir
                                arşiv alır, saklama süresi de ayrıdır: posta gigabaytla ölçülür
         --configure-remote     rsync/rclone hedefini yapılandırır
         --schedule "daily 03:00" [--encrypt] [--remote] [--keep N] [--no-mail]
                                Her siteyi otomatik yedekler ("weekly sun 04:00", "hourly" veya
                                bir cron ifadesi de olur); --schedule off bunu durdurur
  restore <domain> --file <archive>   [--no-db] [--no-files] [--no-mail] [--mail-file F]
                                Posta, yanındaki en yeni posta arşivinden gelir; posta kutusu
                                şifreleri ve DKIM anahtarı aynı kalır
  renew-ssl [domain] [opts]     --force --all --staging --wildcard
  renew-ssl --missing           Sertifikası olmayan her site için sertifika (DNS'i doğrudan veya
                                Cloudflare üzerinden buraya bakmalıdır); başarısız olan biri
                                diğerlerini durdurmaz
  ssl [status]                  Her sertifika, siteler ve posta: var mı, ne kadar süresi kaldı
                                ve kendiliğinden yenileniyor mu (certbot'u ne çalıştırıyor,
                                deploy hook, her yenileme dosyası). Hiçbir şeyi değiştirmez;
                                Cloudflare'in ne zaman Full (strict) olabileceğini de söyler
  ssl test                      Her yenilemenin provasını yapar (certbot renew --dry-run)
  ssl fix                       Otomatik yenilemeyi onarır: zamanlayıcı veya cron girdisi, hook
  update                        Güvenli paket güncellemesi + sıralı servis yeniden başlatmaları;
                                yeni bir lompstack'in değiştirdiklerini de uygular (zamanlanmış
                                görevler, site ev dizinleri, loglar)
  self-update [--from DIR]      En son lompstack'i çeker ve kurulu kopyayı yeniler; o da
                                değiştirdiklerini sunucuya uygular.
                                Hiçbir pakete dokunulmaz (onu update yapar).
  update-cf-ips                 Cloudflare IP aralıklarını yeniler
  firewall [status]             Web portları herkese mi yoksa yalnızca Cloudflare'e mi yanıt verir
  firewall --web-cloudflare-only   80/443'ü Cloudflare aralıkları dışında her şeye kapatır;
                                böylece kimse sunucunun adresini kullanarak korumayı atlatamaz.
                                Cloudflare token'ı gerekir: sertifikalar o zaman DNS-01 ile gelir
  firewall --web-open           Onları yeniden açar
  htaccess-check                Bir sitenin .htaccess dosyası değişince OpenLiteSpeed'i yeniden
                                yükler (cron her dakika çalıştırır; OpenLiteSpeed onu yalnızca
                                yüklenirken okur), root'un siteye yüklediklerini sitenin
                                kullanıcısına verir ve WordPress'in daha açık bıraktığı
                                wp-config.php dosyasını 0640'a çeker
  notify [opts]                 --email a@b.c [--smtp-host H --smtp-port P
                                --smtp-user U --smtp-pass P --smtp-from F]
                                --telegram-token T --telegram-chat ID
                                --webhook URL   --ssh-login on|off  --test  --show
  panel [open|status|close]     WebAdmin panelini açar. Yalın "panel", portu mevcut SSH
                                oturumunuzun adresi için 60 dakikalığına açar ve URL'yi,
                                kullanıcıyı ve şifreyi yazdırır; kendiliğinden yeniden
                                kapanır. Seçenekler: --ip auto|IP|any, --minutes N
                                (0 = açık kalır). "status" mevcut durumu ve SSH tünel
                                komutunu gösterir, "close" hemen kapatır. Dinamik IP'ler
                                için tasarlanmıştır.
  logs <domain> [--access|--error] [-n LINES]
  menu                          Etkileşimli menü (yalın "lomp" da bunu açar); Türkçe veya
                                İngilizce: bir kez sorulur, 28. madde bunu değiştirir
  help                          Bu metin

GENEL SEÇENEKLER
  --yes / -y        Onaylara evet yanıtı varsayılır
  --dry-run         Deneme: neyin değişeceğini gösterir; hiçbir şeyi değiştirmez
  --quiet / -q      Yalnızca uyarılar ve hatalar
  --verbose / -v    Komut çıktısını gösterir
  --no-color        Renkleri kapatır
  --json            Makinece okunabilir çıktı (status, doctor, list)
  --non-interactive Hiç sormaz (varsayılanlar kullanılır)
  --version         Betiğin ve hedef bileşenlerin sürümlerini gösterir

YOLLAR
  Siteler        /home/<domain>/{public_html,logs,private,backups}
  Durum          /root/.server-setup/   (0700; kimlik bilgileri burada durur)
  Log            /var/log/server_setup.log
  Yedekler       /var/backups/server-setup/
USAGE_EOF
    return 0
  fi
  cat <<'USAGE_EOF'
lomp - LOMP stack: Linux + OpenLiteSpeed + MariaDB + PHP (LSPHP), with Redis and TLS.
       Production VPS provisioning and site management for Ubuntu 22.04 / 24.04.

USAGE
  sudo lomp                             # no arguments: interactive menu
  sudo lomp <command>                   # after install: short name, works anywhere
  sudo ./setup.sh <command> [arguments] [global flags]
  sudo ./setup.sh domain.com            # shorthand for: add domain.com

COMMANDS
  install [opts]                Provision the server (idempotent, re-run safe)
      --php 8.3                 Default LSPHP version
      --timezone Europe/Istanbul
      --admin-port 7080         WebAdmin port (OpenLiteSpeed default; any free port works)
      --admin-access MODE       WebAdmin reachability: tunnel (default) | ip | open
      --admin-ip 1.2.3.4        YOUR address (not the server's); implies --admin-access ip
                                Use "auto" to take it from the current SSH session
      --email admin@x.com       Default e-mail (Let's Encrypt / notifications)
      --ssh-port 2222           Change SSH port (UFW is opened first)
      --non-interactive         Never ask questions, use defaults
      --with-node [--node 24]   Node.js (NodeSource) + PM2; an installed major is kept
      --with-python             python3-venv + pip (venv-per-app policy)
      --with-netdata            Netdata bound to localhost (+ admin IP)
      --with-mail [--mail-hostname mail.example.com]
                                Mail server (Postfix, Dovecot, Rspamd) for the sites of
                                this server; needs its own name, an A record and a PTR
      --mail-only [--mail-hostname mail.example.com]
                                A server for mail alone: the same mail server, and the web
                                stack only because the webmail needs one. Domains get mail
                                ("mail domain add"), not sites. --role web undoes it
      --cloudflare              Trust Cloudflare proxies (real client IP)
      --cf-api-token TOKEN      Store Cloudflare API token (DNS-01 / fail2ban); "-" reads it
                                from stdin so it stays out of the process list
      --mariadb 11.4            Install MariaDB from the official repository
      --redis-persist           Enable Redis persistence (default: cache only)
      --backup-schedule "daily 03:00"
      --auto-reboot             Allow unattended-upgrades to reboot
      --skip-upgrade            Skip apt upgrade during install
  add <domain> [opts]           Create a site (user, dirs, vhost, SSL)
      --email a@b.c  --no-ssl  --www  --www-primary  --php 8.3
      --memory 256M  --upload 64M  --php-children N
      --proxy 127.0.0.1:3000  --static  --wordpress  --cloudflare  --no-db
      --wildcard  --staging  --hsts-preload
      --mail [--mailbox info] [--mail-quota 2G]
                                Give the site its own mail while creating it
      --wp-title "Title" --wp-admin admin --wp-email a@b.c --wp-locale en_US
      --node [--port N] [--start "npm start" | --script dist/main.js] [--git URL [--branch B]]
                                Node.js site: PM2 runs the app as the site's user and
                                OpenLiteSpeed proxies to it (a free port from 3000 up);
                                with --git the application is deployed right away
                                Every site gets its own database and MariaDB user
                                unless --no-db is given.
  wordpress <domain>            Put the files of the latest WordPress (wordpress.org/latest.zip)
                                into the public_html of a PHP site that exists, as the site's
                                own user; the installation is finished in the browser, and
                                the wp-config.php it writes is closed to 0640 within a minute
                                ("add --wordpress" installs it whole instead)
  db <domain>                   Create (or show) the MariaDB database for a site
  db list                       Every site's database, user and size (no passwords)
  db passwd <domain>            A new random password for the site's database user
  proxy list [<domain>]         Path proxies of every site and whether their app answers
  proxy add <domain> <path> <host:port>
                                Publish an app under a path of an existing site, in any
                                mode: proxy add example.com /api/ 127.0.0.1:3001
  proxy remove <domain> <path>  Stop proxying that path
  app list                      Node.js applications: status, CPU, memory, restarts (--json)
  app status <domain>
  app start|stop|restart <domain> [--process NAME]
  app logs <domain> [--process NAME] [--out|--error] [-n LINES]
  app worker <domain> list | remove NAME | run NAME
  app worker <domain> add NAME --start CMD [--cwd DIR] [--port N] [--memory 256M]
  app worker <domain> add NAME --cron "*/5 * * * *" --start CMD [--timeout 1h]
                                Workers (queue consumers, bots) run next to the app under
                                its PM2; with --cron, cron starts a job, one run at a time
  app deploy <domain> [--git URL [--branch B]]
                                Pull from git (the first time: clone), install dependencies
                                when they changed, build with a memory limit, restart
  app deploy-key <domain>       Create or print the site's read-only key for a private repo
  app set <domain> [--port N] [--start CMD | --script FILE] [--memory 512M|none] [--no-git]
  app env <domain> list [--show] | set NAME | unset NAME... | import-db
                                Values come from stdin or a hidden prompt, never from
                                the command line; import-db adds DB_* and DATABASE_URL
  mail domain add <domain> [--mailbox info] [--quota 2G]
                                Mail for a domain that is no site of this server (its web
                                site is elsewhere, or it has none): no Linux user, no vhost
  mail domain add <domain> --to <you@example.com> [--address info,sales] [--catch-all]
                                The same without a mailbox of its own: its addresses are
                                delivered into a mailbox that exists - one inbox for several
                                domains - and that mailbox may send as them
  mail domain list              Every domain with mail: site or mail only, mailboxes, aliases
  mail domain del <domain> [--dns-cleanup] [--no-backup]
                                Remove a mail domain and all of its mail, after a last backup
  mail enable <domain> [--mailbox info] [--quota 2G]
                                Give a site its own mail: DKIM key, certificate for
                                mail.<domain>, and the DNS records to add
                                (--to, --address and --catch-all work here as well)
  mail disable <domain> [--delete-data]
  mail box add|passwd|quota|list|del|kick <user@domain>
                                Passwords come from stdin or a hidden prompt, never from
                                the command line; "kick" ends the open sessions of a mailbox
  mail alias add|del|list <alias@domain> [target,...]
                                An address that goes somewhere else; a mailbox here that it
                                goes to may also send as it. "@<domain>" as the alias is a
                                catch-all: every address of the domain with no line of its own
  mail dns <domain> [--check] [--json]   What to put in DNS, and whether it is there
  mail dns <domain> --apply [--replace-mx]
                                Write those records into Cloudflare with the stored token.
                                A foreign MX or a second SPF record is reported, never
                                overwritten; only records lompstack wrote are ever removed
  mail status|test|queue        The mail stack: what runs, reverse DNS, outgoing port 25
  mail cert [domain]            Ask again for a certificate that did not come
  mail regenerate               Rewrite every mail configuration file and restart the stack
  mail webmail on|off <domain>  A webmail at webmail.<domain>. Every domain that has one
                                shares a single Roundcube and a single PHP process, so the
                                twentieth costs a vhost and nothing else
  webmail status                What runs, and for which domains (people change their own
                                password in it, under Settings)
  webmail update [version]      Take a newer Roundcube (it also happens by itself, daily)
  webmail forget <user@domain>|@<domain>|--gone
                                Remove what the webmail still keeps for a mailbox that is gone
                                (address book, identities, settings). Deleting a mailbox does
                                this by itself; the command is for one that went before lomp
                                did, or while the database was down. --gone is every such
                                address at once: it lists them (doctor names the first few)
                                and asks before it removes them
  webmail uninstall | purge     Remove it; "purge" drops its database too
  mail dkim status <domain>     Which key this domain signs with
  mail dkim rotate <domain> [--abort]
                                Make a second key and publish its record; signing moves to it
                                by itself once DNS carries it, and the old key is kept a week
                                so that mail already sent still verifies
  mail backup <domain> [--keep N]     The mail on its own: mailboxes, aliases, the DKIM key
  mail restore <domain> [--file A]    and the mail itself, back into the same mailboxes
                                with the same passwords and the same key. A mailbox that is
                                not empty is asked about first: the copy replaces what is
                                there. Add --yes to answer it in a script
  mail relay set --host H [--port 587] --user U [--spf-include NAME] [--tls LEVEL] | relay off
                                Send outgoing mail through another server where port 25
                                is blocked; the password is read from stdin
  remove <domain> [opts]        Remove a site  (--keep-db --keep-files --keep-ssl; alias: delete)
  rename <old> <new> [opts]     Move a site to another domain name: files, user, logs and
                                settings follow, the database stays, the new name gets its
                                certificate, a WordPress has its addresses rewritten, and the
                                old name sends everything on with a 301
                                (--no-redirect --no-ssl --no-search-replace)
  redirect add <from> <to>      A name that is no site and only sends its visitors on to
                                another one (301, path kept; --www --no-ssl)
  redirect list | del <from>    The redirects; stop answering for one (--keep-ssl)
  import <[user@]host> [opts]   Bring sites from another server over SSH: lists what it serves,
                                asks which ones, adds the sites that are not here yet, copies
                                the files and the database the site's own files name (a
                                WordPress, or the config.php, .env ... of another application),
                                and points those files at the database here. The mailboxes of a domain
                                come with it when this server runs mail - with their passwords
                                where the other server is a lomp or a CyberPanel - and so do
                                its aliases and forwarders; DNS is not touched. A new site
                                gets the PHP version it ran there (and a memory_limit or upload
                                size above this server's own), and its cron jobs run here
                                as the site's user. The other server is only read (--list
                                --all --only a.com,b.com --no-create --no-mail --only-mail
                                --no-cron --port N --key FILE --password-file FILE --path DIR
                                --as DOMAIN --db NAME)
  import cron <domain> [--clear]  The cron jobs an import gave a site; remove them
  list                          Table of sites (--json)
  status                        Services, versions, resources, sites (--json)
  doctor                        Deep health check (--json, --quiet)
  credentials <domain>|--all    Show stored credentials (never logged)
  fix-owner <domain>|--all      Hand a site's files back to its own user after uploading as
                                root (WinSCP, scp). Only what is someone else's changes;
                                logs/ and the file modes stay as they are. It happens by itself
                                within a minute of an upload; the command is for right now
  fix-owner --auto on|off       Stop that (root keeps files of its own in a site), or start it
  optimize                      Re-measure the system and re-tune (shows a diff)
  harden <domain>|--all         Limit what a PHP shell in a site can do: no process execution
                                from PHP, open_basedir, no scripts in upload directories, and
                                only DNS, web, MariaDB, Redis and its own application reachable
                                on this machine (--allow-exec, --allow-upload-php per site;
                                "harden status"; --firewall on|off)
  scan <domain>|--all [--wide]  Look through a site's PHP files for what web shells are made of
                                (eval of decoded or request data, commands made of the request,
                                packed code) and list the files to open. Changes nothing;
                                --wide also lists every use of eval, base64_decode and exec
  php-cleanup [--php 8.3]       Undo an "apt-get install lsphp83*": purge what it added beyond
                                lomp's own PHP packages (compiler, debug symbols, sources,
                                the distribution's PHP). Shows the list and asks first
  backup <domain>|--all [opts]  --remote --encrypt --keep N --no-mail --dry-run
                                A domain with mail gets a second archive beside the site's,
                                with a retention of its own: mail is measured in gigabytes
         --configure-remote     Configure rsync/rclone destination
         --schedule "daily 03:00" [--encrypt] [--remote] [--keep N] [--no-mail]
                                Back up every site automatically ("weekly sun 04:00", "hourly"
                                or a cron expression work too); --schedule off stops it
  restore <domain> --file <archive>   [--no-db] [--no-files] [--no-mail] [--mail-file F]
                                The mail comes from the newest mail archive next to it, with
                                the same mailbox passwords and the same DKIM key
  renew-ssl [domain] [opts]     --force --all --staging --wildcard
  renew-ssl --missing           A certificate for every site that has none (its DNS must point
                                here, directly or through Cloudflare); one that fails does not
                                stop the others
  ssl [status]                  Every certificate, sites and mail: whether there is one, how
                                long it has, and whether it renews by itself (what runs
                                certbot, the deploy hook, each renewal file). Changes nothing;
                                it also says when Cloudflare can go to Full (strict)
  ssl test                      Rehearse every renewal (certbot renew --dry-run)
  ssl fix                       Put automatic renewal back: the timer or cron entry, the hook
  update                        Safe package update + ordered service restarts; also applies
                                what a newer lompstack changes (scheduled tasks, site homes, logs)
  self-update [--from DIR]      Pull the latest lompstack and refresh the installed
                                copy, which then applies what it changes on the server.
                                No package is touched (update does that).
  update-cf-ips                 Refresh Cloudflare IP ranges
  firewall [status]             Whether the web ports answer everyone or Cloudflare only
  firewall --web-cloudflare-only   Close 80/443 to everything but Cloudflare's ranges, so
                                nobody can walk around the edge by using the server's address.
                                Needs a Cloudflare token: certificates then come over DNS-01
  firewall --web-open           Open them again
  htaccess-check                Reload OpenLiteSpeed when a site's .htaccess has changed
                                (cron runs it every minute; OpenLiteSpeed reads it only on load),
                                hand what root uploaded into a site to the site's user, and
                                close to 0640 a wp-config.php WordPress left more open
  notify [opts]                 --email a@b.c [--smtp-host H --smtp-port P
                                --smtp-user U --smtp-pass P --smtp-from F]
                                --telegram-token T --telegram-chat ID
                                --webhook URL   --ssh-login on|off  --test  --show
  panel [open|status|close]     Open the WebAdmin panel. Bare "panel" opens the port
                                for the address of your current SSH session for 60
                                minutes and prints the URL, user and password; it
                                closes again on its own. Options: --ip auto|IP|any,
                                --minutes N (0 = stay open). "status" shows the
                                current state and the SSH tunnel command, "close"
                                shuts it immediately. Built for dynamic IPs.
  logs <domain> [--access|--error] [-n LINES]
  menu                          Interactive menu (also what a bare "lomp" opens); in
                                Turkish or English: asked once, item 28 changes it
  help                          This text

GLOBAL FLAGS
  --yes / -y        Assume yes for confirmations
  --dry-run         Show what would change; touch nothing
  --quiet / -q      Only warnings and errors
  --verbose / -v    Show command output
  --no-color        Disable colours
  --json            Machine-readable output (status, doctor, list)
  --non-interactive Never prompt (defaults are used)
  --version         Show script and target component versions

PATHS
  Sites          /home/<domain>/{public_html,logs,private,backups}
  State          /root/.server-setup/   (0700; credentials live here)
  Log            /var/log/server_setup.log
  Backups        /var/backups/server-setup/
USAGE_EOF
}

MENU_CMD=""   # how the user invoked us, for the prompts we echo back

_menu_cmd_name() { if [[ -x "$BIN_SHORT" ]]; then basename "$BIN_SHORT"; else basename "$BIN_LINK"; fi; }

_menu_rule() { printf '%s%s%s\n' "$C_DIM" "------------------------------------------------------------" "$C_RST"; }

# -----------------------------------------------------------------------------
#  Two languages
# -----------------------------------------------------------------------------
# The menu's texts are written in English where they are used, and MENU_TR at the end of this
# file holds the Turkish for each of them, keyed by the English text exactly as written. A
# text with no entry there is shown in English alone. MENU_LANG says what is shown:
#   tr  Turkish      en  English      both  English with the Turkish next to it
# It is the language chosen for the server (lib/lang.sh: asked once, at the first install or
# the first time the menu opens, changed with "Menu language"); LOMP_MENU_LANG overrides it for
# one run. The command reference is not translated; what the commands print is lib/lang.sh's.
MENU_LANG=""            # "" = not read yet
MENU_TXT="" MENU_ALT="" # what _menu_pair found: the text to show, and its other language

_menu_lang_load() {
  local v="${LOMP_MENU_LANG:-${LIB_LANG_SESSION:-}}"
  [[ -n "$v" ]] || v="$(lib_lang_stored)"
  case "$v" in tr|en|both) MENU_LANG="$v" ;; *) MENU_LANG="en" ;; esac
}

_menu_pair() {   # English text -> MENU_TXT, MENU_ALT
  local tr=""
  [[ -n "$MENU_LANG" ]] || _menu_lang_load
  MENU_TXT="$1"; MENU_ALT=""
  [[ -n "$1" ]] || return 0
  tr="${MENU_TR[$1]:-}"
  [[ -n "$tr" && "$tr" != "$1" ]] || return 0
  case "$MENU_LANG" in
    tr)   MENU_TXT="$tr" ;;
    both) MENU_ALT="$tr" ;;
  esac
  return 0
}

# A text on one line: "English / Türkçe" when both are shown.
_menu_t() {   # English text
  _menu_pair "$1"
  printf '%s%s' "$MENU_TXT" "${MENU_ALT:+ / $MENU_ALT}"
}

# The same for a text with values in it: the English text is a printf format.
_menu_tf() {   # format, value...
  local a="" b=""
  _menu_pair "$1"; shift
  # shellcheck disable=SC2059
  printf -v a "$MENU_TXT" "$@"
  if [[ -n "$MENU_ALT" ]]; then
    # shellcheck disable=SC2059
    printf -v b "$MENU_ALT" "$@"
    a+=" / ${b}"
  fi
  printf '%s' "$a"
}

# printf for whole lines: the English lines, then the Turkish ones.
_menu_printf() {   # format, value...
  local nl='\n'
  _menu_pair "$1"; shift
  # shellcheck disable=SC2059
  printf "$MENU_TXT" "$@"
  if [[ -n "$MENU_ALT" ]]; then
    # shellcheck disable=SC2059
    printf "${MENU_ALT#"$nl"}" "$@"
  fi
  return 0
}

# What follows a number in a list: the text, and its Turkish beside it or, when the two do
# not fit one line, below it.
_menu_label() {   # English text
  _menu_pair "$1"
  if [[ -z "$MENU_ALT" ]]; then printf '%s\n' "$MENU_TXT"
  elif (( ${#MENU_TXT} + ${#MENU_ALT} > 96 )); then printf '%s\n      %s%s%s\n' "$MENU_TXT" "$C_DIM" "$MENU_ALT" "$C_RST"
  else printf '%s %s/ %s%s\n' "$MENU_TXT" "$C_DIM" "$MENU_ALT" "$C_RST"; fi
}

# Lines of explanation: the Turkish block first, then the English one.
_menu_lines() {   # colour ("" for none), line...
  local c="$1" l="" any=0
  shift
  [[ -n "$MENU_LANG" ]] || _menu_lang_load
  if [[ "$MENU_LANG" != "en" ]]; then
    for l in "$@"; do
      if [[ -n "${MENU_TR[$l]:-}" ]]; then printf '  %s%s%s\n' "$c" "${MENU_TR[$l]}" "${c:+$C_RST}"; any=1; fi
    done
  fi
  if [[ "$MENU_LANG" != "tr" ]] || (( ! any )); then
    for l in "$@"; do printf '  %s%s%s\n' "$c" "$l" "${c:+$C_RST}"; done
  fi
  return 0
}

_menu_prompt() { printf '%s%s: %s' "$C_BLD" "$(_menu_t "$1")" "$C_RST"; }   # English text

_menu_language() {
  local what="" new=""
  [[ -n "$MENU_LANG" ]] || _menu_lang_load
  _menu_printf '\n  Turkish or English, for the menu and for what the commands print. Now: %s\n' "$MENU_LANG"
  printf '  1) Türkçe\n  2) English\n  3) English + Türkçe (menu; commands print Türkçe)\n'
  _menu_ask what "Choice"
  case "$what" in
    1) new="tr" ;;
    2) new="en" ;;
    3) new="both" ;;
    *) return 0 ;;
  esac
  # the commands this menu runs read it from where it is kept
  MENU_LANG="$new"; LIB_LANG_SESSION="$new"
  lib_lang_store "$new"
  return 0
}

_menu_pause() {
  local _ignored=""
  printf '\n%s%s%s' "$C_DIM" "$(_menu_t 'Press Enter to go back to the menu...')" "$C_RST"
  read -r _ignored || true
  printf '\n'
}

# Run an ordinary lompstack command as a child. Its failure is reported, not fatal:
# the menu keeps running so the operator can read the error and try something else.
_menu_run() {
  local rc=0
  printf '\n%s%s$ %s %s%s\n\n' "$C_BLD" "$C_CYN" "$MENU_CMD" "$*" "$C_RST"
  # Ctrl-C belongs to the child (stopping a followed log, say). The terminal sends it to the
  # menu as well, which used to end the whole menu. ':' rather than '' so the child, which
  # does not inherit a handler, still gets the default action and stops.
  trap ':' INT
  "$SCRIPT_PATH" "$@" </dev/tty || rc=$?
  trap - INT
  if (( rc == 130 )); then _menu_printf '\n%sStopped.%s\n' "$C_DIM" "$C_RST"
  elif (( rc != 0 )); then _menu_printf '\n%sThat command exited with status %s.%s\n' "$C_YEL" "$rc" "$C_RST"; fi
  _menu_pause
}

# The registered sites a menu entry offers, one per line: all of them, with "apps" those that
# run a Node.js application, with "php" those PHP runs in.
_menu_domains() {   # [apps|php]
  local d="" only="${1:-}"
  while read -r d; do
    [[ -n "$d" ]] || continue
    if [[ "$only" == "apps" ]] && ! lib_app_state_load "$d"; then continue; fi
    if [[ "$only" == "php" ]]; then
      case "$(lib_json_get "$(lib_domain_json "$d")" '.mode')" in php|wordpress|"") ;; *) continue ;; esac
    fi
    printf '%s\n' "$d"
  done < <(lib_domains_list)
  return 0
}

# Ask for a domain, offering those by number. Prints the choice.
_menu_pick_domain() {   # [apps|php]
  local -a doms=()
  local d="" i=1 choice="" only="${1:-}"
  mapfile -t doms < <(_menu_domains "$only")
  if ((${#doms[@]} == 0)); then
    if [[ "$only" == "apps" ]]; then _menu_printf '%sNo Node.js applications yet: add a site and choose "Node.js app".%s\n' "$C_YEL" "$C_RST" >&2
    elif [[ "$only" == "php" ]]; then _menu_printf '%sNo PHP sites yet: add a site and choose "PHP site".%s\n' "$C_YEL" "$C_RST" >&2
    else _menu_printf '%sNo sites have been added yet.%s\n' "$C_YEL" "$C_RST" >&2; fi
    return 1
  fi
  _menu_printf '\n%sWhich site?%s\n' "$C_BLD" "$C_RST" >&2
  for d in "${doms[@]}"; do printf '  %2d) %s\n' "$i" "$d" >&2; i=$((i + 1)); done
  printf '   0) %s\n' "$(_menu_t 'cancel')" >&2
  _menu_prompt "Number" >&2
  read -r choice </dev/tty || return 1
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  (( choice >= 1 && choice <= ${#doms[@]} )) || return 1
  printf '%s' "${doms[$((choice - 1))]}"
}

_menu_ask() {   # _menu_ask VAR "prompt" ["default"]
  local -n _out="$1"
  local prompt="$2" def="${3:-}" ans=""
  _menu_pair "$prompt"
  if [[ -n "$MENU_ALT" ]]; then
    if (( ${#MENU_TXT} + ${#MENU_ALT} > 96 )); then printf '%s%s%s\n' "$C_DIM" "$MENU_ALT" "$C_RST"
    else MENU_TXT+=" / ${MENU_ALT}"; fi
  fi
  printf '%s%s%s%s: ' "$C_BLD" "$MENU_TXT" "${def:+ [$def]}" "$C_RST"
  read -r ans </dev/tty || ans=""
  _out="${ans:-$def}"
}

# One compact line of context, so the whole menu still fits an 80x24 terminal.
_menu_header() {
  local sites=0 d="" svc="" label=""
  while read -r d; do [[ -n "$d" ]] && sites=$((sites + 1)); done < <(lib_domains_list)
  printf '\n %s%slompstack%s  %s  %s site(s) ' "$C_BLD" "$C_CYN" "$C_RST" "$(hostname -s 2>/dev/null || hostname)" "$sites"
  for svc in lsws:web mariadb:db redis-server:cache fail2ban:f2b; do
    label="${svc#*:}"; svc="${svc%%:*}"
    if lib_service_active "$svc"; then printf ' %s%s:up%s' "$C_GRN" "$label" "$C_RST"
    else printf ' %s%s:DOWN%s' "$C_RED" "$label" "$C_RST"; fi
  done
  printf '\n'
  _menu_rule
}

# Lines of explanation above a question or under a heading, for whoever has not been here in
# a while: dimmed (hint) or plain (note).
_menu_hint() { _menu_lines "$C_DIM" "$@"; }   # line...
_menu_note() { _menu_lines "" "$@"; }         # line...

_menu_group() { printf ' %s%s%s\n' "$C_BLD" "$(_menu_t "$1")" "$C_RST"; }
_menu_item()  { printf '  %s%2s%s) ' "$C_CYN" "$1" "$C_RST"; _menu_label "$2"; }
# One choice of a short numbered list that is asked about with "Choice".
_menu_opt()   { printf '  %s) ' "$1"; _menu_label "$2"; }

# =============================================================================
#  Menu shown before the server is provisioned
# =============================================================================
_menu_not_installed() {
  local choice="" email=""
  while true; do
    _menu_printf '\n %s%slompstack%s  this server is not provisioned yet\n' "$C_BLD" "$C_CYN" "$C_RST"
    _menu_rule
    _menu_item 1 "Install the server (OpenLiteSpeed, PHP, MariaDB, Redis, firewall)"
    _menu_item 2 "Show what the installation would do, changing nothing (dry run)"
    _menu_item 3 "Command reference"
    _menu_item 4 "Install a mail-only server (mail and webmail for your domains, no web sites)"
    _menu_item 5 "Language: Türkçe or English"
    _menu_item 0 "Exit"
    printf '\n'; _menu_prompt "Choice"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_ask email "E-mail for Let's Encrypt and alerts" "$DEFAULT_EMAIL"
         if [[ -n "$email" ]]; then _menu_run install --email "$email"; else _menu_run install; fi ;;
      2) _menu_run install --dry-run ;;
      3) lib_usage | ${PAGER:-less} 2>/dev/null || lib_usage; _menu_pause ;;
      4) _menu_install_mail_only ;;
      5) _menu_language ;;
      0|q|Q|"") return 0 ;;
      *) _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

# =============================================================================
#  Main menu
# =============================================================================
lib_menu_main() {
  MENU_CMD="$(_menu_cmd_name)"
  if ! [[ -t 0 && -t 1 ]] || (( OPT_NON_INTERACTIVE )); then
    lib_usage
    return 0
  fi
  lib_require_tools
  _menu_lang_load
  if ! lib_installed; then _menu_not_installed; return 0; fi
  # a server installed for mail alone has no site to list: its menu is the mail menu
  if lib_server_mail_only; then _menu_mail top; return 0; fi

  local choice="" domain="" answer=""
  while true; do
    _menu_header
    _menu_group "SITES"
    _menu_item  1 "List sites"
    _menu_item  2 "Add a site"
    _menu_item  3 "Site credentials"
    _menu_item  4 "Site logs"
    _menu_item  5 "Databases"
    _menu_item  6 "Node.js apps (PM2) and proxies (a domain or a path -> an app's port)"
    _menu_item  7 "Remove a site"
    _menu_item 26 "Rename a site (new domain name; the old one redirects to it)"
    _menu_item 27 "Redirects (a domain that only sends visitors on to another)"
    _menu_item 29 "Import sites from another server (files and databases, over SSH)"
    _menu_item 20 "Mail: domains, mailboxes, DNS"
    _menu_item 21 "Fix file ownership (after uploading as root)"
    _menu_item 23 "Harden sites against PHP shells"
    _menu_item 24 "Scan sites for PHP shells (eval, base64, exec)"
    _menu_item 25 "Download WordPress into a site (you finish the setup in the browser)"
    _menu_group "SERVER"
    _menu_item  8 "Status"
    _menu_item  9 "Health check"
    _menu_item 10 "Open WebAdmin panel"
    _menu_item 11 "Certificates (which exist, automatic renewal, a site's first one)"
    _menu_item 12 "Back up sites (now, or automatically)"
    _menu_item 13 "Restore a site"
    _menu_group "MAINTENANCE"
    _menu_item 14 "Update packages"
    _menu_item 15 "Update lompstack"
    _menu_item 16 "Re-tune to hardware"
    _menu_item 17 "Notifications"
    _menu_item 18 "Optional components (Node.js, Python, Netdata, Mail)"
    _menu_item 22 "Remove extra PHP packages (after apt install lsphp83*)"
    _menu_item 19 "Command reference"
    _menu_item 28 "Language: Türkçe or English"
    _menu_item  0 "Exit"
    printf '\n'; _menu_prompt "Choice"
    read -r choice </dev/tty || return 0

    case "$choice" in
      1) _menu_run list ;;
      2) _menu_add_site ;;
      3) domain="$(_menu_pick_domain)" && _menu_run credentials "$domain" || _menu_pause ;;
      4) domain="$(_menu_pick_domain)" && _menu_run logs "$domain" || _menu_pause ;;
      5) _menu_databases ;;
      6) _menu_apps ;;
      7) _menu_remove_site ;;
      26) _menu_rename_site ;;
      27) _menu_redirects ;;
      29) _menu_import ;;
      20) _menu_mail ;;
      21) _menu_fix_owner ;;
      23) _menu_harden ;;
      24) _menu_scan ;;
      25) _menu_wordpress ;;
      8) _menu_run status ;;
      9) _menu_run doctor ;;
      10) _menu_run panel ;;
      11) _menu_certificates ;;
      12) _menu_backup ;;
      13) _menu_restore ;;
      14) _menu_run update ;;
      15) _menu_run self-update ;;
      16) _menu_run optimize ;;
      22) _menu_run php-cleanup ;;
      17) _menu_run notify --show ;;
      18) _menu_runtimes ;;
      19) lib_usage | ${PAGER:-less} 2>/dev/null || lib_usage; _menu_pause ;;
      28) _menu_language ;;
      0|q|Q|"") printf '\n'; return 0 ;;
      *) _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

_menu_add_site() {
  local domain="" kind="" email="" www="" ssl="" proxy="" port="" start=""
  local -a args=()
  _menu_ask domain "Domain (without www, e.g. example.com)"
  [[ -n "$domain" ]] || return 0
  if ! lib_domain_valid "${domain,,}"; then
    _menu_printf '%s"%s" is not a valid domain name.%s\n' "$C_YEL" "$domain" "$C_RST"
    _menu_pause; return 0
  fi
  args=("$domain")

  _menu_printf '\n%sWhat kind of site?%s\n' "$C_BLD" "$C_RST"
  _menu_opt 1 "PHP site (default)"
  _menu_opt 2 "WordPress, installed and configured"
  _menu_opt 3 "Static files only"
  _menu_opt 4 "Node.js app that lomp keeps running (PM2: starts at boot, comes back after a crash)"
  _menu_opt 5 "Reverse proxy: the domain goes to a port where an app you start yourself listens"
  _menu_ask kind "Choice" "1"
  case "$kind" in
    2) args+=(--wordpress) ;;
    3) args+=(--static) ;;
    4) _menu_hint "Visitors reach the app through this site; the app itself listens on a local port." \
         "It must take that port from the PORT variable (process.env.PORT), not a fixed number." \
         "Afterwards: put the code into /home/<domain>/app, then menu 6 -> 3 (Deploy)."
       _menu_ask port "Port the app listens on (it gets it as PORT)" "$(lib_app_port_pick 2>/dev/null || true)"
       _menu_ask start "Start command (runs without a shell)" "npm start"
       args+=(--node)
       if [[ -n "$port" ]]; then args+=(--port "$port"); fi
       if [[ -n "$start" && "$start" != "npm start" ]]; then args+=(--start "$start"); fi ;;
    5) _menu_hint "Everything that asks for this domain is passed to the address below, on this server." \
         "lomp does not start that app: you do. While it is down the site answers 503." \
         "Only one path of a site (example.com/api/) instead: menu 6 -> 11 (Path proxies)."
       _menu_ask proxy "Where the app listens (host:port)" "127.0.0.1:3000"; args+=(--proxy "$proxy") ;;
    *) ;;
  esac

  _menu_ask www "$(_menu_tf 'Also serve www.%s? (y/n)' "$domain")" "y"
  [[ "${www,,}" == y* ]] && args+=(--www)

  # "n" by default: a site usually goes in before its DNS moves here. The certificate comes
  # later, from "Certificates" in this menu.
  _menu_ask ssl "Request a Let's Encrypt certificate now? DNS must already point here (y/n)" "n"
  [[ "${ssl,,}" == y* ]] || args+=(--no-ssl)

  _menu_ask email "Contact e-mail" "info@${domain,,}"
  [[ -n "$email" ]] && args+=(--email "$email")

  # only where this server actually runs mail; otherwise the question is an offer it cannot keep
  if lib_mail_installed; then
    local mail="" mailbox=""
    _menu_ask mail "$(_menu_tf 'Give this site its own mail (mailboxes at @%s)? (y/n)' "$domain")" "n"
    if [[ "${mail,,}" == y* ]]; then
      _menu_ask mailbox "First mailbox name (before the @)" "info"
      args+=(--mail)
      [[ -n "$mailbox" ]] && args+=(--mailbox "$mailbox")
    fi
  fi

  _menu_run add "${args[@]}"
}

# Like _menu_run, but the child's standard input is the given value instead of the terminal.
# Used for secrets: the value is piped in and never appears on a command line.
_menu_run_input() {   # value args...
  local value="$1" rc=0
  shift
  printf '\n%s%s$ %s %s%s\n\n' "$C_BLD" "$C_CYN" "$MENU_CMD" "$*" "$C_RST"
  trap ':' INT
  printf '%s' "$value" | "$SCRIPT_PATH" "$@" || rc=$?
  trap - INT
  if (( rc != 0 )); then _menu_printf '\n%sThat command exited with status %s.%s\n' "$C_YEL" "$rc" "$C_RST"; fi
  _menu_pause
}

_menu_databases() {
  local choice="" domain=""
  while true; do
    _menu_printf '\n %sDATABASES%s\n' "$C_BLD" "$C_RST"
    _menu_rule
    _menu_item 1 "List databases (sizes, no passwords)"
    _menu_item 2 "Create or show the database of a site"
    _menu_item 3 "Give a site's database a new random password"
    _menu_item 0 "Back"
    printf '\n'; _menu_prompt "Choice"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run db list ;;
      2) domain="$(_menu_pick_domain)" && _menu_run db "$domain" || _menu_pause ;;
      3) domain="$(_menu_pick_domain)" && _menu_run db passwd "$domain" || _menu_pause ;;
      0|q|Q|"") return 0 ;;
      *) _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

# A site added without a certificate is not asking for one, so "renew-ssl --all" passes it
# over. Item 2 is how such a site gets its first certificate once its DNS points here.
_menu_certificates() {
  local choice="" domain=""
  while true; do
    _menu_printf '\n %sCERTIFICATES%s   renewal is automatic; item 1 shows whether it is working\n' "$C_BLD" "$C_RST"
    _menu_rule
    _menu_item 1 "Check: which certificates exist, days left, is renewal automatic"
    _menu_item 2 "Get a certificate for a site (its DNS must point here)"
    _menu_item 3 "Renew every certificate now"
    _menu_item 4 "Rehearse the automatic renewal (replaces nothing)"
    _menu_item 5 "Switch automatic renewal back on (timer or cron, deploy hook)"
    _menu_item 6 "Get a certificate for every site that has none"
    _menu_item 0 "Back"
    printf '\n'; _menu_prompt "Choice"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run ssl status ;;
      2) domain="$(_menu_pick_domain)" && _menu_run renew-ssl "$domain" || _menu_pause ;;
      3) _menu_run renew-ssl --all ;;
      4) _menu_run ssl test ;;
      5) _menu_run ssl fix ;;
      6) _menu_run renew-ssl --missing ;;
      0|q|Q|"") return 0 ;;
      *) _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

_menu_apps() {
  local choice="" domain=""
  while true; do
    _menu_printf '\n %sNODE.JS APPS (PM2)%s   every site runs its own PM2 as its own user\n' "$C_BLD" "$C_RST"
    _menu_rule
    _menu_hint "How it works: the domain -> OpenLiteSpeed -> the app on its own local port (3000, 3001...)." \
      "PM2 keeps the app running: it starts at boot and comes back after a crash." \
      "A new app: 2 (add the site), copy the code into /home/<domain>/app, then 3 (deploy)." \
      "An app you start yourself, or one path of a site sent to a port: 2 (kind 5), or 11."
    _menu_item  1 "List applications"
    _menu_item  2 "Add a site (choose 'Node.js app')"
    _menu_item  3 "Deploy: install dependencies, build, restart"
    _menu_item  4 "Start"
    _menu_item  5 "Stop"
    _menu_item  6 "Restart"
    _menu_item  7 "Follow the logs"
    _menu_item  8 "Status of one application"
    _menu_item  9 "Environment variables"
    _menu_item 10 "Port, start command, memory limit"
    _menu_item 11 "Path proxies (example.com/api -> an app)"
    _menu_item 12 "Deploy from a Git repository (URL, branch)"
    _menu_item 13 "Deploy key for a private repository"
    _menu_item 14 "Workers and scheduled jobs (queues, bots, cron)"
    _menu_item  0 "Back"
    printf '\n'; _menu_prompt "Choice"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run app list ;;
      2) _menu_add_site ;;
      3) domain="$(_menu_pick_domain apps)" && _menu_run app deploy "$domain" || _menu_pause ;;
      4) domain="$(_menu_pick_domain apps)" && _menu_run app start "$domain" || _menu_pause ;;
      5) domain="$(_menu_pick_domain apps)" && _menu_run app stop "$domain" || _menu_pause ;;
      6) domain="$(_menu_pick_domain apps)" && _menu_run app restart "$domain" || _menu_pause ;;
      7) domain="$(_menu_pick_domain apps)" && _menu_run app logs "$domain" || _menu_pause ;;
      8) domain="$(_menu_pick_domain apps)" && _menu_run app status "$domain" || _menu_pause ;;
      9) domain="$(_menu_pick_domain apps)" && _menu_app_env "$domain" || _menu_pause ;;
      10) domain="$(_menu_pick_domain apps)" && _menu_app_set "$domain" || _menu_pause ;;
      11) _menu_proxies ;;
      12) domain="$(_menu_pick_domain apps)" && _menu_app_git "$domain" || _menu_pause ;;
      13) domain="$(_menu_pick_domain apps)" && _menu_run app deploy-key "$domain" || _menu_pause ;;
      14) domain="$(_menu_pick_domain apps)" && _menu_workers "$domain" || _menu_pause ;;
      0|q|Q|"") return 0 ;;
      *) _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

# A worker of the site, by number: jobs only with "job", long-running ones with "process".
_menu_pick_worker() {   # domain [process|job]
  local -a names=()
  local n="" i=1 choice=""
  while IFS= read -r n; do
    if [[ -n "$n" ]]; then names+=("$n"); fi
  done < <(jq -r --arg k "${2:-}" '.[] | select($k == "" or (($k == "job") == ((.cron // "") != ""))) | .name' <<<"$(lib_app_workers_json "$1")" || true)
  if ((${#names[@]} == 0)); then _menu_printf '%sThere is nothing to choose from here yet.%s\n' "$C_YEL" "$C_RST" >&2; return 1; fi
  _menu_printf '\n%sWhich one?%s\n' "$C_BLD" "$C_RST" >&2
  for n in "${names[@]}"; do printf '  %2d) %s\n' "$i" "$n" >&2; i=$((i + 1)); done
  printf '   0) %s\n' "$(_menu_t 'cancel')" >&2
  _menu_prompt "Number" >&2
  read -r choice </dev/tty || return 1
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  (( choice >= 1 && choice <= ${#names[@]} )) || return 1
  printf '%s' "${names[$((choice - 1))]}"
}

_menu_workers() {   # domain
  local domain="$1" choice="" name="" start="" cron="" port="" cwd=""
  local -a args=()
  while true; do
    _menu_printf '\n %sWORKERS AND JOBS OF %s%s   run as the site user, next to the application\n' "$C_BLD" "$domain" "$C_RST"
    _menu_rule
    _menu_item 1 "List"
    _menu_item 2 "Add a background worker (queue consumer, bot)"
    _menu_item 3 "Add a scheduled job (cron)"
    _menu_item 4 "Run a scheduled job now"
    _menu_item 5 "Follow the logs of one"
    _menu_item 6 "Restart a worker"
    _menu_item 7 "Stop one"
    _menu_item 8 "Start one"
    _menu_item 9 "Remove one"
    _menu_item 0 "Back"
    printf '\n'; _menu_prompt "Choice"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run app worker "$domain" list ;;
      2) _menu_ask name "Name (a-z, 0-9 and -)"
         _menu_ask start "Command, run without a shell (e.g. node worker.js)"
         _menu_ask cwd "Directory, inside the site's home" "app"
         _menu_ask port "Port, only if it listens on one"
         if [[ -n "$name" && -n "$start" ]]; then
           args=(app worker "$domain" add "$name" --start "$start" --cwd "${cwd:-app}")
           if [[ -n "$port" ]]; then args+=(--port "$port"); fi
           _menu_run "${args[@]}"
         else _menu_pause; fi ;;
      3) _menu_ask name "Name (a-z, 0-9 and -)"
         _menu_ask cron "Schedule: minute hour day month weekday" "*/5 * * * *"
         _menu_ask start "Command, run without a shell (e.g. npm run cleanup)"
         _menu_ask cwd "Directory, inside the site's home" "app"
         if [[ -n "$name" && -n "$start" && -n "$cron" ]]; then
           _menu_run app worker "$domain" add "$name" --cron "$cron" --start "$start" --cwd "${cwd:-app}"
         else _menu_pause; fi ;;
      4) name="$(_menu_pick_worker "$domain" job)" && _menu_run app worker "$domain" run "$name" || _menu_pause ;;
      5) name="$(_menu_pick_worker "$domain")" && _menu_run app logs "$domain" --process "$name" || _menu_pause ;;
      6) name="$(_menu_pick_worker "$domain" process)" && _menu_run app restart "$domain" --process "$name" || _menu_pause ;;
      7) name="$(_menu_pick_worker "$domain")" && _menu_run app stop "$domain" --process "$name" || _menu_pause ;;
      8) name="$(_menu_pick_worker "$domain")" && _menu_run app start "$domain" --process "$name" || _menu_pause ;;
      9) name="$(_menu_pick_worker "$domain")" && _menu_run app worker "$domain" remove "$name" || _menu_pause ;;
      0|q|Q|"") return 0 ;;
      *) _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

_menu_app_git() {   # domain
  local domain="$1" url="" branch=""
  lib_app_state_load "$domain" || return 0
  _menu_printf '\n%sA private repository needs the deploy key first (item 13).%s\n' "$C_DIM" "$C_RST"
  _menu_ask url "Repository URL (https://host/owner/repo.git or git@host:owner/repo.git)" "$APP_GIT_URL"
  if [[ -z "$url" ]]; then _menu_pause; return 0; fi
  _menu_ask branch "Branch (empty: the repository's default)" "$APP_GIT_BRANCH"
  if [[ -n "$branch" ]]; then _menu_run app deploy "$domain" --git "$url" --branch "$branch"
  else _menu_run app deploy "$domain" --git "$url"; fi
}

_menu_app_env() {   # domain
  local domain="$1" choice="" name="" value=""
  while true; do
    _menu_printf '\n %sENVIRONMENT OF %s%s   stored root-only, never logged\n' "$C_BLD" "$domain" "$C_RST"
    _menu_rule
    _menu_item 1 "List the names"
    _menu_item 2 "Set a variable (the value is typed hidden)"
    _menu_item 3 "Remove a variable"
    _menu_item 4 "Add this site's database login (DB_*, DATABASE_URL)"
    _menu_item 0 "Back"
    printf '\n'; _menu_prompt "Choice"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run app env "$domain" list ;;
      2) _menu_ask name "Name (A-Z, 0-9 and _)"
         if [[ -n "$name" ]]; then
           _menu_prompt "Value (hidden)"
           IFS= read -r -s value </dev/tty || value=""
           printf '\n'
           _menu_run_input "$value" app env "$domain" set "$name"
           value=""
         fi ;;
      3) _menu_ask name "Name to remove"
         if [[ -n "$name" ]]; then _menu_run app env "$domain" unset "$name"; fi ;;
      4) _menu_run app env "$domain" import-db ;;
      0|q|Q|"") return 0 ;;
      *) _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

_menu_app_set() {   # domain
  local domain="$1" port="" start="" mem="" current=""
  local -a args=()
  lib_app_state_load "$domain" || return 0
  current="${APP_SCRIPT:-$APP_START}"
  _menu_printf '\n%sPress Enter to keep a value.%s\n' "$C_DIM" "$C_RST"
  _menu_ask port "Port" "$APP_PORT"
  _menu_ask start "Start command, or a file such as dist/main.js" "$current"
  _menu_ask mem "Memory limit (e.g. 512M, or none)" "${APP_MEMORY:-none}"
  if [[ -n "$port" && "$port" != "$APP_PORT" ]]; then args+=(--port "$port"); fi
  if [[ -n "$start" && "$start" != "$current" ]]; then
    if [[ "$start" =~ ^[^[:space:]]+\.(c|m)?js$ ]]; then args+=(--script "$start"); else args+=(--start "$start"); fi
  fi
  if [[ -n "$mem" && "$mem" != "${APP_MEMORY:-none}" ]]; then args+=(--memory "$mem"); fi
  if ((${#args[@]} == 0)); then _menu_printf '%sNothing changed.%s\n' "$C_DIM" "$C_RST"; _menu_pause; return 0; fi
  _menu_run app set "$domain" "${args[@]}"
}

_menu_proxies() {
  local choice="" domain="" path="" target="" current=""
  while true; do
    _menu_printf '\n %sPATH PROXIES%s   example.com/api/... -> an application, the rest of the site stays\n' "$C_BLD" "$C_RST"
    _menu_rule
    _menu_hint "Sends one path of a site you already have to a port on this server," \
      "e.g. /api/ -> 127.0.0.1:3001. The app must be listening there; lomp does not start it." \
      "The app gets the full path: /api/users arrives as /api/users, not as /users." \
      "A whole domain to a port instead: main menu 2 (Add a site), kind 5."
    _menu_item 1 "List path proxies"
    _menu_item 2 "Add a path proxy"
    _menu_item 3 "Remove a path proxy"
    _menu_item 0 "Back"
    printf '\n'; _menu_prompt "Choice"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run proxy list ;;
      2) if domain="$(_menu_pick_domain)"; then
           _menu_ask path "Path of the site that goes to the app" "/api/"
           _menu_ask target "Where the app listens (host:port)" "127.0.0.1:$(lib_app_port_pick 2>/dev/null || printf '3001')"
           _menu_run proxy add "$domain" "$path" "$target"
         else _menu_pause; fi ;;
      3) if domain="$(_menu_pick_domain)"; then
           current="$(lib_proxy_state_lines "$domain")"
           if [[ -z "$current" ]]; then
             _menu_printf '%s%s has no path proxies.%s\n' "$C_YEL" "$domain" "$C_RST"; _menu_pause; continue
           fi
           _menu_printf '\n%sPath proxies of %s:%s\n' "$C_BLD" "$domain" "$C_RST"
           while read -r path target; do printf '  %s -> %s\n' "$path" "$target"; done <<<"$current"
           _menu_ask path "Path to remove (e.g. /api/)"
           if [[ -n "$path" ]]; then _menu_run proxy remove "$domain" "$path"; else _menu_pause; fi
         else _menu_pause; fi ;;
      0|q|Q|"") return 0 ;;
      *) _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

_menu_remove_site() {
  local domain="" keep=""
  local -a args=()
  domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
  args=("$domain")
  _menu_printf '\n%sRemoving %s deletes its files, database and certificate.%s\n%sA safety backup is taken first.%s\n' \
    "$C_YEL" "$domain" "$C_RST" "$C_DIM" "$C_RST"
  _menu_ask keep "Keep the database? (y/n)" "n"
  [[ "${keep,,}" == y* ]] && args+=(--keep-db)
  _menu_ask keep "Keep the files? (y/n)" "n"
  [[ "${keep,,}" == y* ]] && args+=(--keep-files)
  _menu_run remove "${args[@]}"
}

# A site under another domain name. The command says what it is about to do and asks once more.
_menu_rename_site() {
  local domain="" new="" keep=""
  local -a args=()
  domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
  printf '\n'; _menu_note "The site moves to the new name as it is: files, settings, database. Nothing is copied." \
    "Point the DNS of the new name to this server first, so that it gets its certificate right away." \
    "Its mailboxes move to the new domain too, and the old addresses keep working. A Node.js application is built again."
  _menu_ask new "$(_menu_tf 'New domain for %s (without www, e.g. example.net)' "$domain")"
  [[ -n "$new" ]] || return 0
  if ! lib_domain_valid "${new,,}"; then
    _menu_printf '%s"%s" is not a valid domain name.%s\n' "$C_YEL" "$new" "$C_RST"
    _menu_pause; return 0
  fi
  args=("$domain" "${new,,}")
  # not asked about a site whose name is no domain name: nothing can ask for such a name, so
  # the command leaves no redirect under it whatever the answer
  if lib_domain_valid "$domain"; then
    _menu_ask keep "$(_menu_tf 'Keep %s as a redirect (301) to %s? (y/n)' "$domain" "${new,,}")" "y"
    [[ "${keep,,}" == y* ]] || args+=(--no-redirect)
  fi
  _menu_run rename "${args[@]}"
}

# Names that are no site here and only send their visitors on to another one.
# Sites of another server. The command lists what is there and asks which ones; ssh asks for
# the password itself.
_menu_import() {
  local host="" port=""
  printf '\n'; _menu_note "Looks at what another server serves and asks which sites to bring here: their files, and the" \
    "database of a WordPress. A site that is not here yet is added first. The other server is only read." \
    "Its mailboxes come along when this server runs mail. You are asked for the SSH password once."
  _menu_ask host "The other server (user@address, e.g. root@203.0.113.10)"
  [[ -n "$host" ]] || return 0
  _menu_ask port "Its SSH port" "22"
  _menu_run import "$host" --port "$port"
}

_menu_redirects() {
  local what="" from="" to="" www=""
  local -a args=()
  printf '\n'
  _menu_opt 1 "List the redirects"
  _menu_opt 2 "Add one (or fetch the certificate of one whose DNS points here now)"
  _menu_opt 3 "Remove one"
  _menu_ask what "Choice" "1"
  case "$what" in
    2) _menu_ask from "Domain that redirects (without www, e.g. old-name.com)"
       [[ -n "$from" ]] || return 0
       _menu_ask to "Where to (a site here, or any other domain)"
       [[ -n "$to" ]] || return 0
       args=("$from" "$to")
       _menu_ask www "$(_menu_tf 'Also redirect www.%s? (y/n)' "$from")" "y"
       [[ "${www,,}" == y* ]] && args+=(--www)
       _menu_run redirect add "${args[@]}" ;;
    3) _menu_run redirect list
       _menu_ask from "Which one (its name, empty to cancel)"
       [[ -n "$from" ]] || return 0
       _menu_run redirect del "$from" ;;
    *) _menu_run redirect list ;;
  esac
}

# Files uploaded as root (WinSCP, scp) stay root's, and PHP, which runs as the site's own
# user, cannot change them. This hands them over, every site at once unless one is picked.
_menu_fix_owner() {
  local what="" domain="" auto="on"
  lib_domain_fix_owner_auto_enabled || auto="off"
  printf '\n'; _menu_note "Files uploaded as root go to their site's own user; what already is the site's stays as it is."
  if [[ "$auto" == "on" ]]; then _menu_note "It happens by itself within a minute of an upload; this does it right now."; fi
  _menu_opt 1 "Every site"
  _menu_opt 2 "One site"
  if [[ "$auto" == "on" ]]; then _menu_opt 3 "Stop doing it automatically (root keeps files of its own in a site)"
  else _menu_opt 3 "Do it automatically again, within a minute of an upload (now: off)"; fi
  _menu_ask what "Choice" "1"
  if [[ "$what" == "3" ]]; then
    if [[ "$auto" == "on" ]]; then _menu_run fix-owner --auto off; else _menu_run fix-owner --auto on; fi
  elif [[ "$what" == "2" ]]; then
    domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
    _menu_run fix-owner "$domain"
  else
    _menu_run fix-owner --all
  fi
}

# Every site at once, or one - and for one, whether it keeps process execution.
_menu_harden() {
  local what="" domain="" keep=""
  printf '\n'; _menu_note "PHP in a site can then start no process, read only its own files and run no script in an upload directory;" "its user reaches only DNS, the web server, MariaDB and Redis on this machine."
  _menu_opt 1 "Every site"
  _menu_opt 2 "One site"
  _menu_opt 3 "Show what is set"
  _menu_ask what "Choice" "1"
  case "$what" in
    3) _menu_run harden status ;;
    2) domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
       _menu_ask keep "Does this site need exec/proc_open (y/N)" "n"
       if [[ "${keep,,}" == y* ]]; then _menu_run harden "$domain" --allow-exec; else _menu_run harden "$domain"; fi ;;
    *) _menu_run harden --all ;;
  esac
}

# Every site at once, or one - and whether to list every use of the functions shells are made
# of, which on a WordPress site is a long list of honest plugins.
_menu_scan() {
  local what="" domain="" wide=""
  local -a args=()
  printf '\n'; _menu_note "Reads the PHP files for what web shells are made of and lists the files to open. It changes nothing."
  _menu_opt 1 "Every site"
  _menu_opt 2 "One site"
  _menu_ask what "Choice" "1"
  if [[ "$what" == "2" ]]; then
    domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
    args=("$domain")
  else
    args=(--all)
  fi
  _menu_ask wide "Also list every use of eval, base64_decode and exec? Plugins use them too (y/N)" "n"
  if [[ "${wide,,}" == y* ]]; then args+=(--wide); fi
  _menu_run scan "${args[@]}"
}

# WordPress's files into a site that is already there; "Add a site" with kind 2 installs it
# whole instead. The command asks before it puts them next to something.
_menu_wordpress() {
  local domain=""
  printf '\n'; _menu_note "The latest WordPress (wordpress.org/latest.zip) goes straight into the site's public_html, as the" \
    "site's own user. You finish the installation in the browser; the database login is printed for it."
  domain="$(_menu_pick_domain php)" || { _menu_pause; return 0; }
  _menu_run wordpress "$domain"
}

# The domains a mail menu entry offers, one per line: those whose mail is on, or with "all"
# every domain that has mail here at all - one whose mail was turned off included.
_menu_mail_domains() {   # [all]
  local d=""
  if [[ "${1:-}" != "all" ]]; then lib_mail_domains; return 0; fi
  while read -r d; do
    [[ -n "$d" ]] || continue
    if _mail_domain_listed "$d"; then printf '%s\n' "$d"; fi
  done < <(lib_mail_domains_known)
  return 0
}

# Ask for one of them, offered by number. Prints the choice.
_menu_pick_mail_domain() {   # [all]
  local -a doms=()
  local d="" i=1 choice=""
  mapfile -t doms < <(_menu_mail_domains "${1:-}")
  if ((${#doms[@]} == 0)); then
    _menu_printf '%sNo domain has mail yet: "Add a domain" gives one its mail.%s\n' "$C_YEL" "$C_RST" >&2
    return 1
  fi
  _menu_printf '\n%sWhich domain?%s\n' "$C_BLD" "$C_RST" >&2
  for d in "${doms[@]}"; do printf '  %2d) %s\n' "$i" "$d" >&2; i=$((i + 1)); done
  printf '   0) %s\n' "$(_menu_t 'cancel')" >&2
  _menu_prompt "Number" >&2
  read -r choice </dev/tty || return 1
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  (( choice >= 1 && choice <= ${#doms[@]} )) || return 1
  printf '%s' "${doms[$((choice - 1))]}"
}

# Mail for a domain. A site of this server gets its mail switched on; any other domain is
# added for its mail alone. Either way the mail goes into a mailbox of the domain's own, or
# into one that exists already - which is how one inbox comes to hold several domains.
_menu_mail_add_domain() {
  local domain="" how="" box="" quota="" to="" addrs="" first=""
  local -a args=()
  _menu_ask domain "Domain (without www, e.g. example.com)"
  [[ -n "$domain" ]] || return 0
  domain="${domain,,}"
  if ! lib_domain_valid "$domain"; then
    _menu_printf '%s"%s" is not a valid domain name.%s\n' "$C_YEL" "$domain" "$C_RST"
    _menu_pause; return 0
  fi
  if lib_domain_registered "$domain" && ! lib_mail_domain_standalone "$domain"; then
    args=(mail enable "$domain")
  else
    args=(mail domain add "$domain")
    if ! lib_server_mail_only; then
      _menu_printf '\n  %s is not a site of this server: it is added for its mail alone (no site, no Linux user).\n' "$domain"
    fi
  fi
  first="$(lib_mail_boxes | head -n 1 || true)"
  _menu_printf '\n%sWhere does the mail of %s go?%s\n' "$C_BLD" "$domain" "$C_RST"
  _menu_opt 1 "$(_menu_tf 'Into a mailbox of its own (info@%s, with a password of its own)' "$domain")"
  _menu_opt 2 "Into a mailbox that exists already - one inbox for several domains"
  _menu_ask how "Choice" "1"
  if [[ "$how" == "2" ]]; then
    if [[ -z "$first" ]]; then
      _menu_printf '%sThere is no mailbox on this server yet: the first domain needs one of its own.%s\n' "$C_YEL" "$C_RST"
      _menu_pause; return 0
    fi
    _menu_ask to "Deliver into which mailbox" "$first"
    [[ -n "$to" ]] || return 0
    _menu_ask addrs "$(_menu_tf 'Which addresses of %s? Names with commas (info,sales), or * for every address' "$domain")" "info"
    args+=(--to "$to")
    if [[ "$addrs" == "*" ]]; then args+=(--catch-all)
    elif [[ -n "$addrs" ]]; then args+=(--address "$addrs"); fi
  else
    _menu_ask box "Mailbox name (before the @), or a dash for none" "info"
    _menu_ask quota "Mailbox size" "2G"
    if [[ -n "$box" && "$box" != "-" ]]; then args+=(--mailbox "$box" --quota "$quota"); fi
  fi
  _menu_run "${args[@]}"
}

_menu_mail_webmail() {
  local what="" domain=""
  printf '\n'
  _menu_opt 1 "What runs, and for which domains"
  _menu_opt 2 "Switch it on for a domain (it answers at webmail.<domain>)"
  _menu_opt 3 "Switch it off for a domain"
  _menu_ask what "Choice" "1"
  if [[ "$what" == "2" ]]; then
    domain="$(_menu_pick_mail_domain)" || { _menu_pause; return 0; }
    _menu_run mail webmail on "$domain"
  elif [[ "$what" == "3" ]]; then
    domain="$(_menu_pick_mail_domain)" || { _menu_pause; return 0; }
    _menu_run mail webmail off "$domain"
  else
    _menu_run webmail status
  fi
}

# Turning mail off keeps every message and can be undone. Removing is for a mail domain only -
# a site's mail goes with the site - and takes a last backup before it deletes anything.
_menu_mail_off() {
  local domain="" what=""
  domain="$(_menu_pick_mail_domain all)" || { _menu_pause; return 0; }
  if ! lib_mail_domain_standalone "$domain"; then _menu_run mail disable "$domain"; return 0; fi
  printf '\n'
  _menu_opt 1 "Turn its mail off: no delivery and no login, every message stays, and it can be turned on again"
  _menu_opt 2 "Remove the domain with all of its mail (a last backup is taken first)"
  _menu_ask what "Choice" "1"
  if [[ "$what" == "2" ]]; then _menu_run mail domain del "$domain"
  else _menu_run mail disable "$domain"; fi
}

# Header of the mail menu when it is the server's own menu.
_menu_mail_header() {
  local n=0 d="" svc="" label=""
  while read -r d; do [[ -n "$d" ]] && n=$((n + 1)); done < <(lib_mail_domains)
  printf '\n %s%slompstack%s  %s  mail server, sends as %s  %s domain(s)\n ' "$C_BLD" "$C_CYN" "$C_RST" \
    "$(hostname -s 2>/dev/null || hostname)" "$(lib_mail_host)" "$n"
  for svc in postfix:smtp dovecot:imap rspamd:filter lsws:webmail mariadb:db fail2ban:f2b; do
    label="${svc#*:}"; svc="${svc%%:*}"
    if lib_service_active "$svc"; then printf ' %s%s:up%s' "$C_GRN" "$label" "$C_RST"
    else printf ' %s%s:DOWN%s' "$C_RED" "$label" "$C_RST"; fi
  done
  printf '\n'
  _menu_rule
}

# "top": this is the menu of a mail-only server, not a submenu of the sites' one.
_menu_mail() {   # [top]
  local top="${1:-}" choice="" domain="" box="" quota="" alias="" target=""
  while true; do
    if ! lib_mail_installed; then
      _menu_printf '\n  The mail server is not installed yet. Optional components (18) installs it.\n'
      _menu_pause
      return 0
    fi
    if [[ -n "$top" ]]; then _menu_mail_header
    else
      _menu_printf '\n %sMAIL%s   (this server sends as %s)\n' "$C_BLD" "$C_RST" "$(lib_mail_host)"
      _menu_rule
    fi
    _menu_item  1 "Domains that have mail here"
    _menu_item  2 "Add a domain (a mailbox of its own, or into one that exists)"
    _menu_item  3 "Mailboxes: who has one, its size, how full it is"
    _menu_item  4 "Add a mailbox"
    _menu_item  5 "Change a mailbox password"
    _menu_item  6 "Aliases: an address that is delivered into another mailbox"
    _menu_item  7 "What to put in DNS (and whether it is there)"
    _menu_item  8 "Can this server send? (reverse DNS, port 25)"
    _menu_item  9 "Webmail (on or off for a domain, or what runs)"
    _menu_item 10 "Turn mail off for a domain, or remove a mail domain"
    if [[ -n "$top" ]]; then
      _menu_item 11 "Server: status, health check, backups, updates"
      _menu_item 12 "Language: Türkçe or English"
      _menu_item  0 "Exit"
    else
      _menu_item  0 "Back"
    fi
    printf '\n'; _menu_prompt "Choice"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run mail domain list ;;
      2) _menu_mail_add_domain ;;
      3) _menu_run mail box list ;;
      4) domain="$(_menu_pick_mail_domain)" || { _menu_pause; continue; }
         _menu_ask box "Mailbox name (before the @)" "info"
         _menu_ask quota "Mailbox size" "2G"
         [[ -n "$box" ]] && _menu_run mail box add "${box}@${domain}" --quota "$quota" ;;
      5) _menu_ask box "Which address?"
         [[ -n "$box" ]] && _menu_run mail box passwd "$box" ;;
      6) _menu_ask alias "Alias address, or @domain for every address of a domain (empty to only list them)"
         if [[ -z "$alias" ]]; then _menu_run mail alias list
         else
           _menu_ask target "Where should it go? (an address, or several with commas)"
           [[ -n "$target" ]] && _menu_run mail alias add "$alias" "$target"
         fi ;;
      7) domain="$(_menu_pick_mail_domain)" || { _menu_pause; continue; }
         _menu_run mail dns "$domain" --check ;;
      8) _menu_run mail test ;;
      9) _menu_mail_webmail ;;
      10) _menu_mail_off ;;
      11) if [[ -n "$top" ]]; then _menu_mail_server
          else _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST"; fi ;;
      12) if [[ -n "$top" ]]; then _menu_language
          else _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST"; fi ;;
      0|q|Q|"") [[ -n "$top" ]] && printf '\n'; return 0 ;;
      *) _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

# What a mail-only server needs besides its mail: the same commands the sites' menu offers,
# without the ones that are about sites.
_menu_mail_server() {
  local choice=""
  while true; do
    _menu_printf '\n %sSERVER%s\n' "$C_BLD" "$C_RST"
    _menu_rule
    _menu_item  1 "Status"
    _menu_item  2 "Health check"
    _menu_item  3 "Back up the mail (now, or automatically)"
    _menu_item  4 "Restore a domain's mail from a backup"
    _menu_item  5 "Update packages"
    _menu_item  6 "Update lompstack"
    _menu_item  7 "Re-tune to hardware"
    _menu_item  8 "Notifications"
    _menu_item  9 "Open WebAdmin panel"
    _menu_item 10 "Command reference"
    _menu_item 11 "Certificates: which exist, is renewal automatic"
    _menu_item  0 "Back"
    printf '\n'; _menu_prompt "Choice"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_run status ;;
      2) _menu_run doctor ;;
      3) _menu_mail_backup ;;
      4) _menu_mail_restore ;;
      5) _menu_run update ;;
      6) _menu_run self-update ;;
      7) _menu_run optimize ;;
      8) _menu_run notify --show ;;
      9) _menu_run panel ;;
      10) lib_usage | ${PAGER:-less} 2>/dev/null || lib_usage; _menu_pause ;;
      11) _menu_run ssl status ;;
      0|q|Q|"") return 0 ;;
      *) _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

# A mail domain's backup is its mail: mailboxes with their password hashes, aliases, the DKIM
# key and every message, in one archive under BACKUP_ROOT/<domain>/.
_menu_mail_backup() {
  local what="" enc="" sched="" domain=""
  local -a args=()
  sched="$(lib_manifest_get '.backup.schedule' 2>/dev/null || true)"
  printf '\n'
  _menu_opt 1 "Every domain, now"
  _menu_opt 2 "One domain, now"
  _menu_opt 3 "$(_menu_tf 'Automatic backups (now: %s)' "${sched:-off}")"
  _menu_ask what "Choice" "1"
  if [[ "$what" == "3" ]]; then _menu_backup_schedule; return 0; fi
  if [[ "$what" == "2" ]]; then
    domain="$(_menu_pick_mail_domain all)" || { _menu_pause; return 0; }
    args=("$domain")
  else
    args=(--all)
  fi
  _menu_ask enc "Encrypt the archive? (y/n)" "n"
  [[ "${enc,,}" == y* ]] && args+=(--encrypt)
  _menu_run backup "${args[@]}"
}

# The domain is typed, not picked: on a new server - the case a restore exists for - it is not
# a domain of this server yet, and the restore is what makes it one.
_menu_mail_restore() {
  local domain="" file=""
  _menu_ask domain "Domain whose mail to restore"
  [[ -n "$domain" ]] || return 0
  domain="${domain,,}"
  if ! lib_domain_valid "$domain"; then
    _menu_printf '%s"%s" is not a valid domain name.%s\n' "$C_YEL" "$domain" "$C_RST"
    _menu_pause; return 0
  fi
  _menu_printf '\n%sMail archives of %s:%s\n' "$C_BLD" "$domain" "$C_RST"
  if ! find "${BACKUP_ROOT}/${domain}" -maxdepth 1 -name "${domain}-mail-*.tar.gz*" ! -name '*.sha256' -printf '  %p\n' 2>/dev/null | sort | tail -20 | grep .; then
    _menu_printf '  (none found under %s - copy the archive there, or give its path below)\n' "${BACKUP_ROOT}/${domain}"
  fi
  _menu_ask file "Full path of the archive (empty: the newest one above)"
  if [[ -n "$file" ]]; then _menu_run mail restore "$domain" --file "$file"
  else _menu_run mail restore "$domain"; fi
}

# A mail-only server from the menu: the two things it cannot be installed without are asked
# for here, everything else has a default.
_menu_install_mail_only() {
  local email="" mh=""
  local -a args=(install --mail-only)
  printf '\n'
  _menu_note "A server for mail alone: Postfix, Dovecot, Rspamd and a webmail. Your domains get their" \
    "mail here; their web sites stay where they are. It needs a name of its own, like" \
    "mail.example.com, with an A record pointing here and a PTR record your provider sets."
  printf '\n'
  _menu_ask mh "Name this server sends mail as" "$(hostname -f 2>/dev/null || true)"
  [[ -n "$mh" ]] || return 0
  _menu_ask email "E-mail for Let's Encrypt and alerts" "$DEFAULT_EMAIL"
  args+=(--mail-hostname "$mh")
  [[ -n "$email" ]] && args+=(--email "$email")
  _menu_run "${args[@]}"
}

# Optional components are never installed unless asked for, on the command line with
# --with-node / --with-python / --with-netdata / --with-mail, or from here.
_menu_runtimes() {
  local choice="" ver="" node_v="" py_v="" nd="" mail_v="" mail_host=""
  while true; do
    node_v="$(lib_manifest_get '.components.node')"
    py_v="$(lib_manifest_get '.components.python')"
    nd="$(lib_manifest_get '.components.netdata')"
    mail_v="$(lib_manifest_get '.components.mail.postfix')"
    mail_host="$(lib_mail_host)"
    _menu_printf '\n %sOPTIONAL COMPONENTS%s   (nothing here is installed by default)\n' "$C_BLD" "$C_RST"
    _menu_rule
    printf '  %s1%s) Node.js + PM2        %s\n' "$C_CYN" "$C_RST" \
      "$( [[ -n "$node_v" ]] && printf '%s%s %s%s' "$C_GRN" "$(_menu_t 'installed')" "$node_v" "$C_RST" || printf '%s%s%s' "$C_DIM" "$(_menu_t 'not installed')" "$C_RST")"
    printf '  %s2%s) Python venv + pip    %s\n' "$C_CYN" "$C_RST" \
      "$( [[ -n "$py_v" ]] && printf '%s%s %s%s' "$C_GRN" "$(_menu_t 'installed')" "$py_v" "$C_RST" || printf '%s%s%s' "$C_DIM" "$(_menu_t 'not installed')" "$C_RST")"
    printf '  %s3%s) Netdata monitoring   %s\n' "$C_CYN" "$C_RST" \
      "$( [[ "$nd" == "true" ]] && printf '%s%s%s' "$C_GRN" "$(_menu_t 'installed')" "$C_RST" || printf '%s%s%s' "$C_DIM" "$(_menu_t 'not installed')" "$C_RST")"
    printf '  %s4%s) Mail server          %s\n' "$C_CYN" "$C_RST" \
      "$( [[ -n "$mail_v" ]] && printf '%s%s%s' "$C_GRN" "$(_menu_tf 'installed, sends as %s' "$mail_host")" "$C_RST" || printf '%s%s%s' "$C_DIM" "$(_menu_t 'not installed')" "$C_RST")"
    printf '  %s0%s) %s\n' "$C_CYN" "$C_RST" "$(_menu_t 'Back')"
    printf '\n'; _menu_prompt "Choice"
    read -r choice </dev/tty || return 0
    case "$choice" in
      1) _menu_ask ver "Node.js major version" "$(lib_install_node_major_resolve)"
         _menu_run install --with-node --node "$ver" --skip-upgrade ;;
      2) _menu_run install --with-python --skip-upgrade ;;
      3) _menu_run install --with-netdata --skip-upgrade ;;
      4) if [[ -n "$mail_v" ]]; then
           _menu_run mail status
         else
           local mh=""
           printf '\n'
           _menu_note "The mail server needs a name of its own (mail.example.com), an A record" \
             "pointing here, and a PTR record your provider sets to the same name."
           _menu_ask mh "Name this server sends mail as" "$(hostname -f 2>/dev/null || true)"
           [[ -n "$mh" ]] && _menu_run install --with-mail --mail-hostname "$mh" --skip-upgrade
         fi ;;
      0|q|Q|"") return 0 ;;
      *) _menu_printf '%sPick a number from the list.%s\n' "$C_YEL" "$C_RST" ;;
    esac
  done
}

# Automatic backups: every site, each night or week, by cron. One archive per site holds its
# files, its database, its vhost and its state.
_menu_backup_schedule() {
  local how="" at="" day="" keep="" enc="" rem="" spec="" keep_def="$BACKUP_KEEP"
  local -a args=()
  _menu_printf '\n  Every site gets an archive of its own under %s/<domain>/:\n  files, database, vhost and state. Older archives are removed as new ones arrive.\n' "$BACKUP_ROOT"
  printf '\n'
  _menu_opt 1 "Every day"
  _menu_opt 2 "Once a week"
  _menu_opt 3 "Every hour"
  _menu_opt 4 "Turn automatic backups off"
  _menu_opt 0 "Back"
  _menu_ask how "Choice" "1"
  case "$how" in
    1) _menu_ask at "At what time (HH:MM, the server's clock)" "03:00"; spec="daily ${at}" ;;
    2) _menu_ask day "On which day (mon tue wed thu fri sat sun)" "sun"
       _menu_ask at "At what time (HH:MM, the server's clock)" "03:00"
       day="${day,,}"; spec="weekly ${day} ${at}" ;;
    3) spec="hourly"; keep_def="24" ;;
    4) _menu_run backup --schedule off; return 0 ;;
    *) return 0 ;;
  esac
  if [[ "$how" != "3" ]] && ! [[ "$at" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    _menu_printf '%s"%s" is not a time like 03:00.%s\n' "$C_YEL" "$at" "$C_RST"; _menu_pause; return 0
  fi
  if [[ "$how" == "2" ]] && ! [[ "$day" =~ ^(mon|tue|wed|thu|fri|sat|sun)$ ]]; then
    _menu_printf '%s"%s" is not one of mon tue wed thu fri sat sun.%s\n' "$C_YEL" "$day" "$C_RST"; _menu_pause; return 0
  fi
  _menu_ask keep "Archives to keep per site" "$keep_def"
  if ! [[ "$keep" =~ ^[1-9][0-9]*$ ]]; then
    _menu_printf '%s"%s" is not a number of archives.%s\n' "$C_YEL" "$keep" "$C_RST"; _menu_pause; return 0
  fi
  args=(--schedule "$spec" --keep "$keep")
  _menu_ask enc "Encrypt the archives? (y/n)" "n"
  [[ "${enc,,}" == y* ]] && args+=(--encrypt)
  if lib_backup_remote_load; then
    _menu_ask rem "$(_menu_tf 'Also upload each one to %s %s? (y/n)' "$BKR_TYPE" "$BKR_TARGET")" "y"
    [[ "${rem,,}" == y* ]] && args+=(--remote)
  else
    _menu_printf '%s  They stay on this server only: "%s backup --configure-remote" adds a second place.%s\n' "$C_DIM" "$MENU_CMD" "$C_RST"
  fi
  _menu_run backup "${args[@]}"
}

_menu_backup() {
  local what="" enc="" sched=""
  local -a args=()
  sched="$(lib_manifest_get '.backup.schedule' 2>/dev/null || true)"
  printf '\n'
  _menu_opt 1 "Every site, now"
  _menu_opt 2 "One site, now"
  _menu_opt 3 "$(_menu_tf 'Automatic backups (now: %s)' "${sched:-off}")"
  _menu_ask what "Choice" "1"
  if [[ "$what" == "3" ]]; then _menu_backup_schedule; return 0; fi
  if [[ "$what" == "2" ]]; then
    local domain=""
    domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
    args=("$domain")
  else
    args=(--all)
  fi
  _menu_ask enc "Encrypt the archive? (y/n)" "n"
  [[ "${enc,,}" == y* ]] && args+=(--encrypt)
  _menu_run backup "${args[@]}"
}

_menu_restore() {
  local domain="" file=""
  domain="$(_menu_pick_domain)" || { _menu_pause; return 0; }
  _menu_printf '\n%sAvailable archives for %s:%s\n' "$C_BLD" "$domain" "$C_RST"
  if ! find "${BACKUP_ROOT}/${domain}" -maxdepth 1 -name '*.tar.gz*' -printf '  %p\n' 2>/dev/null | sort | head -20; then
    _menu_printf '  (none found under %s)\n' "${BACKUP_ROOT}/${domain}"
  fi
  _menu_ask file "Full path of the archive to restore"
  [[ -n "$file" ]] || return 0
  _menu_run restore "$domain" --file "$file"
}

# =============================================================================
#  The menu's texts in Turkish
# =============================================================================
# MENU_TR-BEGIN  One line per text: the English exactly as it is written above (a printf format keeps
# its %s and \n, in the same order), and the Turkish for it. A text that is missing here is
# shown in English alone; tests/unit.sh fails when one is missing or has other placeholders.
declare -gA MENU_TR=()
MENU_TR['\n  Turkish or English, for the menu and for what the commands print. Now: %s\n']='\n  Menü ve komut çıktıları için Türkçe ya da İngilizce. Şu an: %s\n'
MENU_TR['Choice']='Seçim'
MENU_TR['Press Enter to go back to the menu...']='Menüye dönmek için Enter'\''a basın...'
MENU_TR['\n%sStopped.%s\n']='\n%sDurduruldu.%s\n'
MENU_TR['\n%sThat command exited with status %s.%s\n']='\n%sKomut %s durum koduyla bitti.%s\n'
MENU_TR['%sNo Node.js applications yet: add a site and choose "Node.js app".%s\n']='%sHenüz Node.js uygulaması yok: bir site ekleyin ve Node.js uygulaması türünü seçin.%s\n'
MENU_TR['%sNo PHP sites yet: add a site and choose "PHP site".%s\n']='%sHenüz PHP sitesi yok: bir site ekleyin ve PHP sitesi türünü seçin.%s\n'
MENU_TR['%sNo sites have been added yet.%s\n']='%sHenüz hiç site eklenmedi.%s\n'
MENU_TR['\n%sWhich site?%s\n']='\n%sHangi site?%s\n'
MENU_TR['cancel']='vazgeç'
MENU_TR['Number']='Numara'
MENU_TR['\n %s%slompstack%s  this server is not provisioned yet\n']='\n %s%slompstack%s  bu sunucu henüz kurulmadı\n'
MENU_TR['Install the server (OpenLiteSpeed, PHP, MariaDB, Redis, firewall)']='Sunucuyu kur (OpenLiteSpeed, PHP, MariaDB, Redis, güvenlik duvarı)'
MENU_TR['Show what the installation would do, changing nothing (dry run)']='Hiçbir şeyi değiştirmeden kurulumun ne yapacağını göster (deneme)'
MENU_TR['Command reference']='Komut kılavuzu'
MENU_TR['Install a mail-only server (mail and webmail for your domains, no web sites)']='Yalnızca posta için sunucu kur (alan adlarınız için posta ve webmail, web sitesi yok)'
MENU_TR['Language: Türkçe or English']='Dil: Türkçe ya da English'
MENU_TR['Exit']='Çıkış'
MENU_TR['E-mail for Let'\''s Encrypt and alerts']='Let'\''s Encrypt ve uyarılar için e-posta'
MENU_TR['%sPick a number from the list.%s\n']='%sListeden bir numara seçin.%s\n'
MENU_TR['SITES']='SİTELER'
MENU_TR['List sites']='Siteleri listele'
MENU_TR['Add a site']='Site ekle'
MENU_TR['Site credentials']='Site giriş bilgileri'
MENU_TR['Site logs']='Site logları'
MENU_TR['Databases']='Veritabanları'
MENU_TR['Node.js apps (PM2) and proxies (a domain or a path -> an app'\''s port)']='Node.js uygulamaları (PM2) ve proxy'\''ler (alan adı ya da yol -> uygulamanın portu)'
MENU_TR['Remove a site']='Site kaldır'
MENU_TR['Rename a site (new domain name; the old one redirects to it)']='Siteyi yeniden adlandır (yeni alan adı; eskisi ona yönlenir)'
MENU_TR['Redirects (a domain that only sends visitors on to another)']='Yönlendirmeler (ziyaretçiyi yalnızca başka bir alan adına gönderen alan adı)'
MENU_TR['Mail: domains, mailboxes, DNS']='Posta: alan adları, posta kutuları, DNS'
MENU_TR['Fix file ownership (after uploading as root)']='Dosya sahipliğini düzelt (root olarak yükledikten sonra)'
MENU_TR['Harden sites against PHP shells']='Siteleri PHP shell'\''lere karşı sıkılaştır'
MENU_TR['Scan sites for PHP shells (eval, base64, exec)']='Sitelerde PHP shell tara (eval, base64, exec)'
MENU_TR['Download WordPress into a site (you finish the setup in the browser)']='Bir siteye WordPress indir (kurulumu tarayıcıda siz bitirirsiniz)'
MENU_TR['SERVER']='SUNUCU'
MENU_TR['Status']='Durum'
MENU_TR['Health check']='Sağlık kontrolü'
MENU_TR['Open WebAdmin panel']='WebAdmin panelini aç'
MENU_TR['Certificates (which exist, automatic renewal, a site'\''s first one)']='Sertifikalar (hangileri var, otomatik yenileme, bir sitenin ilk sertifikası)'
MENU_TR['Back up sites (now, or automatically)']='Siteleri yedekle (şimdi ya da otomatik)'
MENU_TR['Restore a site']='Site geri yükle'
MENU_TR['MAINTENANCE']='BAKIM'
MENU_TR['Update packages']='Paketleri güncelle'
MENU_TR['Update lompstack']='lompstack'\''i güncelle'
MENU_TR['Re-tune to hardware']='Donanıma göre yeniden ayarla'
MENU_TR['Notifications']='Bildirimler'
MENU_TR['Optional components (Node.js, Python, Netdata, Mail)']='İsteğe bağlı bileşenler (Node.js, Python, Netdata, Posta)'
MENU_TR['Remove extra PHP packages (after apt install lsphp83*)']='Fazla PHP paketlerini kaldır (apt install lsphp83* sonrası)'
MENU_TR['Domain (without www, e.g. example.com)']='Alan adı (www olmadan, örn. example.com)'
MENU_TR['%s"%s" is not a valid domain name.%s\n']='%s"%s" geçerli bir alan adı değil.%s\n'
MENU_TR['\n%sWhat kind of site?%s\n']='\n%sNe tür bir site?%s\n'
MENU_TR['PHP site (default)']='PHP sitesi (varsayılan)'
MENU_TR['WordPress, installed and configured']='WordPress, kurulmuş ve ayarlanmış'
MENU_TR['Static files only']='Yalnızca statik dosyalar'
MENU_TR['Node.js app that lomp keeps running (PM2: starts at boot, comes back after a crash)']='lomp'\''un çalışır tuttuğu Node.js uygulaması (PM2: açılışta başlar, çökünce geri gelir)'
MENU_TR['Reverse proxy: the domain goes to a port where an app you start yourself listens']='Ters proxy: alan adı, sizin başlattığınız uygulamanın dinlediği porta gider'
MENU_TR['Visitors reach the app through this site; the app itself listens on a local port.']='Ziyaretçiler uygulamaya bu site üzerinden ulaşır; uygulamanın kendisi yerel bir portu dinler.'
MENU_TR['It must take that port from the PORT variable (process.env.PORT), not a fixed number.']='Uygulama o portu PORT değişkeninden almalıdır (process.env.PORT), sabit bir sayıdan değil.'
MENU_TR['Afterwards: put the code into /home/<domain>/app, then menu 6 -> 3 (Deploy).']='Sonrası: kodu /home/<domain>/app içine koyun, ardından menü 6 -> 3 (Deploy).'
MENU_TR['Port the app listens on (it gets it as PORT)']='Uygulamanın dinleyeceği port (PORT değişkeniyle verilir)'
MENU_TR['Start command (runs without a shell)']='Başlatma komutu (kabuk olmadan çalışır)'
MENU_TR['Everything that asks for this domain is passed to the address below, on this server.']='Bu alan adına gelen her istek, bu sunucudaki aşağıdaki adrese iletilir.'
MENU_TR['lomp does not start that app: you do. While it is down the site answers 503.']='O uygulamayı lomp başlatmaz, siz başlatırsınız. Uygulama kapalıyken site 503 yanıtı verir.'
MENU_TR['Only one path of a site (example.com/api/) instead: menu 6 -> 11 (Path proxies).']='Bir sitenin yalnızca tek bir yolu (example.com/api/) için: menü 6 -> 11 (Yol proxy'\''leri).'
MENU_TR['Where the app listens (host:port)']='Uygulamanın dinlediği adres (host:port)'
MENU_TR['Also serve www.%s? (y/n)']='www.%s adresi de sunulsun mu? (y/n)'
MENU_TR['Request a Let'\''s Encrypt certificate now? DNS must already point here (y/n)']='Şimdi Let'\''s Encrypt sertifikası istensin mi? DNS zaten buraya yönlenmiş olmalı (y/n)'
MENU_TR['Contact e-mail']='İletişim e-postası'
MENU_TR['Give this site its own mail (mailboxes at @%s)? (y/n)']='Bu sitenin kendi postası olsun mu (@%s posta kutuları)? (y/n)'
MENU_TR['First mailbox name (before the @)']='İlk posta kutusunun adı (@ işaretinden önceki kısım)'
MENU_TR['\n %sDATABASES%s\n']='\n %sVERİTABANLARI%s\n'
MENU_TR['List databases (sizes, no passwords)']='Veritabanlarını listele (boyutlar, şifreler hariç)'
MENU_TR['Create or show the database of a site']='Bir sitenin veritabanını oluştur ya da göster'
MENU_TR['Give a site'\''s database a new random password']='Bir sitenin veritabanına yeni rastgele şifre ver'
MENU_TR['Back']='Geri'
MENU_TR['\n %sCERTIFICATES%s   renewal is automatic; item 1 shows whether it is working\n']='\n %sSERTİFİKALAR%s   yenileme otomatiktir; 1. seçenek çalışıp çalışmadığını gösterir\n'
MENU_TR['Check: which certificates exist, days left, is renewal automatic']='Kontrol: hangi sertifikalar var, kalan gün, yenileme otomatik mi'
MENU_TR['Get a certificate for a site (its DNS must point here)']='Bir site için sertifika al (DNS'\''i buraya yönlenmiş olmalı)'
MENU_TR['Renew every certificate now']='Tüm sertifikaları şimdi yenile'
MENU_TR['Rehearse the automatic renewal (replaces nothing)']='Otomatik yenilemeyi dene (hiçbir şeyi değiştirmez)'
MENU_TR['Switch automatic renewal back on (timer or cron, deploy hook)']='Otomatik yenilemeyi yeniden aç (timer ya da cron, deploy hook)'
MENU_TR['Get a certificate for every site that has none']='Sertifikası olmayan her site için sertifika al'
MENU_TR['\n %sNODE.JS APPS (PM2)%s   every site runs its own PM2 as its own user\n']='\n %sNODE.JS UYGULAMALARI (PM2)%s   her site kendi PM2'\''sini kendi kullanıcısıyla çalıştırır\n'
MENU_TR['How it works: the domain -> OpenLiteSpeed -> the app on its own local port (3000, 3001...).']='Nasıl çalışır: alan adı -> OpenLiteSpeed -> kendi yerel portundaki uygulama (3000, 3001...).'
MENU_TR['PM2 keeps the app running: it starts at boot and comes back after a crash.']='PM2 uygulamayı ayakta tutar: açılışta başlatır, çökerse yeniden başlatır.'
MENU_TR['A new app: 2 (add the site), copy the code into /home/<domain>/app, then 3 (deploy).']='Yeni uygulama: 2 (siteyi ekle), kodu /home/<domain>/app içine kopyalayın, sonra 3 (deploy).'
MENU_TR['An app you start yourself, or one path of a site sent to a port: 2 (kind 5), or 11.']='Kendi başlattığınız bir uygulama ya da bir sitenin tek bir yolu için: 2 (tür 5) veya 11.'
MENU_TR['List applications']='Uygulamaları listele'
MENU_TR['Add a site (choose '\''Node.js app'\'')']='Site ekle (Node.js uygulaması türünü seçin)'
MENU_TR['Deploy: install dependencies, build, restart']='Deploy: bağımlılıkları kur, derle, yeniden başlat'
MENU_TR['Start']='Başlat'
MENU_TR['Stop']='Durdur'
MENU_TR['Restart']='Yeniden başlat'
MENU_TR['Follow the logs']='Logları izle'
MENU_TR['Status of one application']='Tek bir uygulamanın durumu'
MENU_TR['Environment variables']='Ortam değişkenleri'
MENU_TR['Port, start command, memory limit']='Port, başlatma komutu, bellek sınırı'
MENU_TR['Path proxies (example.com/api -> an app)']='Yol proxy'\''leri (example.com/api -> bir uygulama)'
MENU_TR['Deploy from a Git repository (URL, branch)']='Git deposundan deploy et (URL, dal)'
MENU_TR['Deploy key for a private repository']='Özel depo için deploy anahtarı'
MENU_TR['Workers and scheduled jobs (queues, bots, cron)']='Worker'\''lar ve zamanlanmış işler (kuyruklar, botlar, cron)'
MENU_TR['%sThere is nothing to choose from here yet.%s\n']='%sBurada henüz seçilecek bir şey yok.%s\n'
MENU_TR['\n%sWhich one?%s\n']='\n%sHangisi?%s\n'
MENU_TR['\n %sWORKERS AND JOBS OF %s%s   run as the site user, next to the application\n']='\n %sWORKER'\''LAR VE İŞLER: %s%s   site kullanıcısıyla, uygulamanın yanında çalışır\n'
MENU_TR['List']='Listele'
MENU_TR['Add a background worker (queue consumer, bot)']='Arka plan worker'\''ı ekle (kuyruk tüketicisi, bot)'
MENU_TR['Add a scheduled job (cron)']='Zamanlanmış iş ekle (cron)'
MENU_TR['Run a scheduled job now']='Zamanlanmış bir işi şimdi çalıştır'
MENU_TR['Follow the logs of one']='Birinin loglarını izle'
MENU_TR['Restart a worker']='Bir worker'\''ı yeniden başlat'
MENU_TR['Stop one']='Birini durdur'
MENU_TR['Start one']='Birini başlat'
MENU_TR['Remove one']='Birini kaldır'
MENU_TR['Name (a-z, 0-9 and -)']='Ad (a-z, 0-9 ve -)'
MENU_TR['Command, run without a shell (e.g. node worker.js)']='Komut, kabuk olmadan çalışır (örn. node worker.js)'
MENU_TR['Directory, inside the site'\''s home']='Dizin, sitenin ev dizini içinde'
MENU_TR['Port, only if it listens on one']='Port, yalnızca bir port dinliyorsa'
MENU_TR['Schedule: minute hour day month weekday']='Zamanlama: dakika saat gün ay haftanın-günü'
MENU_TR['Command, run without a shell (e.g. npm run cleanup)']='Komut, kabuk olmadan çalışır (örn. npm run cleanup)'
MENU_TR['\n%sA private repository needs the deploy key first (item 13).%s\n']='\n%sÖzel bir depo için önce deploy anahtarı gerekir (13. seçenek).%s\n'
MENU_TR['Repository URL (https://host/owner/repo.git or git@host:owner/repo.git)']='Depo URL'\''si (https://host/owner/repo.git ya da git@host:owner/repo.git)'
MENU_TR['Branch (empty: the repository'\''s default)']='Dal (boş: deponun varsayılanı)'
MENU_TR['\n %sENVIRONMENT OF %s%s   stored root-only, never logged\n']='\n %sORTAM DEĞİŞKENLERİ: %s%s   yalnızca root okuyabilir, loglara yazılmaz\n'
MENU_TR['List the names']='Adları listele'
MENU_TR['Set a variable (the value is typed hidden)']='Değişken ata (değer gizli yazılır)'
MENU_TR['Remove a variable']='Değişken kaldır'
MENU_TR['Add this site'\''s database login (DB_*, DATABASE_URL)']='Bu sitenin veritabanı giriş bilgilerini ekle (DB_*, DATABASE_URL)'
MENU_TR['Name (A-Z, 0-9 and _)']='Ad (A-Z, 0-9 ve _)'
MENU_TR['Value (hidden)']='Değer (gizli)'
MENU_TR['Name to remove']='Kaldırılacak ad'
MENU_TR['\n%sPress Enter to keep a value.%s\n']='\n%sBir değeri değiştirmeden bırakmak için Enter'\''a basın.%s\n'
MENU_TR['Port']='Port'
MENU_TR['Start command, or a file such as dist/main.js']='Başlatma komutu ya da dist/main.js gibi bir dosya'
MENU_TR['Memory limit (e.g. 512M, or none)']='Bellek sınırı (örn. 512M ya da none)'
MENU_TR['%sNothing changed.%s\n']='%sHiçbir şey değişmedi.%s\n'
MENU_TR['\n %sPATH PROXIES%s   example.com/api/... -> an application, the rest of the site stays\n']='\n %sYOL PROXY'\''LERİ%s   example.com/api/... -> bir uygulama, sitenin geri kalanı yerinde kalır\n'
MENU_TR['Sends one path of a site you already have to a port on this server,']='Var olan bir sitenin tek bir yolunu bu sunucudaki bir porta gönderir,'
MENU_TR['e.g. /api/ -> 127.0.0.1:3001. The app must be listening there; lomp does not start it.']='örn. /api/ -> 127.0.0.1:3001. Uygulama orada dinliyor olmalı; lomp onu başlatmaz.'
MENU_TR['The app gets the full path: /api/users arrives as /api/users, not as /users.']='Uygulamaya yolun tamamı gider: /api/users, /users olarak değil /api/users olarak gelir.'
MENU_TR['A whole domain to a port instead: main menu 2 (Add a site), kind 5.']='Bir alan adının tamamını bir porta göndermek için: ana menü 2 (Site ekle), tür 5.'
MENU_TR['List path proxies']='Yol proxy'\''lerini listele'
MENU_TR['Add a path proxy']='Yol proxy'\''si ekle'
MENU_TR['Remove a path proxy']='Yol proxy'\''si kaldır'
MENU_TR['Path of the site that goes to the app']='Sitenin uygulamaya gidecek yolu'
MENU_TR['%s%s has no path proxies.%s\n']='%s%s sitesinde yol proxy'\''si yok.%s\n'
MENU_TR['\n%sPath proxies of %s:%s\n']='\n%s%s sitesinin yol proxy'\''leri:%s\n'
MENU_TR['Path to remove (e.g. /api/)']='Kaldırılacak yol (örn. /api/)'
MENU_TR['\n%sRemoving %s deletes its files, database and certificate.%s\n%sA safety backup is taken first.%s\n']='\n%s%s kaldırılınca dosyaları, veritabanı ve sertifikası silinir.%s\n%sÖnce bir güvenlik yedeği alınır.%s\n'
MENU_TR['Keep the database? (y/n)']='Veritabanı kalsın mı? (y/n)'
MENU_TR['Keep the files? (y/n)']='Dosyalar kalsın mı? (y/n)'
MENU_TR['The site moves to the new name as it is: files, settings, database. Nothing is copied.']='Site olduğu gibi yeni ada taşınır: dosyalar, ayarlar, veritabanı. Hiçbir şey kopyalanmaz.'
MENU_TR['Point the DNS of the new name to this server first, so that it gets its certificate right away.']='Sertifikasını hemen alabilmesi için önce yeni adın DNS'\''ini bu sunucuya yönlendirin.'
MENU_TR['Its mailboxes move to the new domain too, and the old addresses keep working. A Node.js application is built again.']='Posta kutuları da yeni alan adına taşınır, eski adresler çalışmaya devam eder. Node.js uygulaması yeniden derlenir.'
MENU_TR['New domain for %s (without www, e.g. example.net)']='%s için yeni alan adı (www olmadan, örn. example.net)'
MENU_TR['Keep %s as a redirect (301) to %s? (y/n)']='%s, %s adresine yönlendirme (301) olarak kalsın mı? (y/n)'
MENU_TR['List the redirects']='Yönlendirmeleri listele'
MENU_TR['Add one (or fetch the certificate of one whose DNS points here now)']='Ekle (ya da DNS'\''i artık buraya yönlenen birinin sertifikasını al)'
MENU_TR['Domain that redirects (without www, e.g. old-name.com)']='Yönlendirilecek alan adı (www olmadan, örn. old-name.com)'
MENU_TR['Where to (a site here, or any other domain)']='Nereye (buradaki bir site ya da başka herhangi bir alan adı)'
MENU_TR['Also redirect www.%s? (y/n)']='www.%s de yönlendirilsin mi? (y/n)'
MENU_TR['Which one (its name, empty to cancel)']='Hangisi (adı; vazgeçmek için boş bırakın)'
MENU_TR['Files uploaded as root go to their site'\''s own user; what already is the site'\''s stays as it is.']='Root olarak yüklenen dosyalar sitenin kendi kullanıcısına geçer; zaten sitenin olanlar olduğu gibi kalır.'
MENU_TR['It happens by itself within a minute of an upload; this does it right now.']='Yüklemeden sonra bir dakika içinde kendiliğinden olur; bu seçenek hemen yapar.'
MENU_TR['Every site']='Tüm siteler'
MENU_TR['One site']='Tek site'
MENU_TR['Stop doing it automatically (root keeps files of its own in a site)']='Otomatik yapmayı bırak (root sitede kendi dosyalarını tutar)'
MENU_TR['Do it automatically again, within a minute of an upload (now: off)']='Yeniden otomatik yap, yüklemeden sonra bir dakika içinde (şu an: kapalı)'
MENU_TR['PHP in a site can then start no process, read only its own files and run no script in an upload directory;']='Bundan sonra sitedeki PHP süreç başlatamaz, yalnızca kendi dosyalarını okuyabilir ve yükleme dizininde betik çalıştıramaz;'
MENU_TR['its user reaches only DNS, the web server, MariaDB and Redis on this machine.']='kullanıcısı bu makinede yalnızca DNS, web sunucusu, MariaDB ve Redis'\''e ulaşır.'
MENU_TR['Show what is set']='Geçerli ayarları göster'
MENU_TR['Does this site need exec/proc_open (y/N)']='Bu sitenin exec/proc_open'\''a ihtiyacı var mı (y/N)'
MENU_TR['Reads the PHP files for what web shells are made of and lists the files to open. It changes nothing.']='PHP dosyalarında web shell'\''lerin yapı taşlarını arar ve açıp bakılacak dosyaları listeler. Hiçbir şeyi değiştirmez.'
MENU_TR['Also list every use of eval, base64_decode and exec? Plugins use them too (y/N)']='eval, base64_decode ve exec'\''in her kullanımı da listelensin mi? Eklentiler de bunları kullanır (y/N)'
MENU_TR['The latest WordPress (wordpress.org/latest.zip) goes straight into the site'\''s public_html, as the']='En güncel WordPress (wordpress.org/latest.zip) doğrudan sitenin public_html dizinine, sitenin kendi'
MENU_TR['site'\''s own user. You finish the installation in the browser; the database login is printed for it.']='kullanıcısıyla konur. Kurulumu tarayıcıda bitirirsiniz; veritabanı giriş bilgileri bunun için yazdırılır.'
MENU_TR['%sNo domain has mail yet: "Add a domain" gives one its mail.%s\n']='%sHenüz hiçbir alan adının postası yok: "Alan adı ekle" bir alan adına posta verir.%s\n'
MENU_TR['\n%sWhich domain?%s\n']='\n%sHangi alan adı?%s\n'
MENU_TR['\n  %s is not a site of this server: it is added for its mail alone (no site, no Linux user).\n']='\n  %s bu sunucunun bir sitesi değil: yalnızca postası için eklenir (site yok, Linux kullanıcısı yok).\n'
MENU_TR['\n%sWhere does the mail of %s go?%s\n']='\n%s%s postası nereye gitsin?%s\n'
MENU_TR['Into a mailbox of its own (info@%s, with a password of its own)']='Kendi posta kutusuna (info@%s, kendi şifresiyle)'
MENU_TR['Into a mailbox that exists already - one inbox for several domains']='Zaten var olan bir posta kutusuna - birkaç alan adı için tek gelen kutusu'
MENU_TR['%sThere is no mailbox on this server yet: the first domain needs one of its own.%s\n']='%sBu sunucuda henüz posta kutusu yok: ilk alan adının kendi kutusu olmalı.%s\n'
MENU_TR['Deliver into which mailbox']='Hangi posta kutusuna teslim edilsin'
MENU_TR['Which addresses of %s? Names with commas (info,sales), or * for every address']='%s alan adının hangi adresleri? Virgülle ayrılmış adlar (info,sales) ya da her adres için *'
MENU_TR['Mailbox name (before the @), or a dash for none']='Posta kutusu adı (@ işaretinden önceki kısım) ya da istemiyorsanız tire'
MENU_TR['Mailbox size']='Posta kutusu boyutu'
MENU_TR['What runs, and for which domains']='Ne çalışıyor ve hangi alan adları için'
MENU_TR['Switch it on for a domain (it answers at webmail.<domain>)']='Bir alan adı için aç (webmail.<domain> adresinde yanıt verir)'
MENU_TR['Switch it off for a domain']='Bir alan adı için kapat'
MENU_TR['Turn its mail off: no delivery and no login, every message stays, and it can be turned on again']='Postasını kapat: teslimat ve giriş olmaz, tüm iletiler kalır, yeniden açılabilir'
MENU_TR['Remove the domain with all of its mail (a last backup is taken first)']='Alan adını tüm postasıyla kaldır (önce son bir yedek alınır)'
MENU_TR['\n  The mail server is not installed yet. Optional components (18) installs it.\n']='\n  Posta sunucusu henüz kurulu değil. İsteğe bağlı bileşenler (18) onu kurar.\n'
MENU_TR['\n %sMAIL%s   (this server sends as %s)\n']='\n %sPOSTA%s   (bu sunucu %s adıyla gönderir)\n'
MENU_TR['Domains that have mail here']='Burada postası olan alan adları'
MENU_TR['Add a domain (a mailbox of its own, or into one that exists)']='Alan adı ekle (kendi posta kutusuyla ya da var olan birine)'
MENU_TR['Mailboxes: who has one, its size, how full it is']='Posta kutuları: kimin var, boyutu, ne kadar dolu'
MENU_TR['Add a mailbox']='Posta kutusu ekle'
MENU_TR['Change a mailbox password']='Posta kutusu şifresini değiştir'
MENU_TR['Aliases: an address that is delivered into another mailbox']='Takma adlar: başka bir posta kutusuna teslim edilen adres'
MENU_TR['What to put in DNS (and whether it is there)']='DNS'\''e ne yazılmalı (ve yazılmış mı)'
MENU_TR['Can this server send? (reverse DNS, port 25)']='Bu sunucu posta gönderebiliyor mu? (ters DNS, port 25)'
MENU_TR['Webmail (on or off for a domain, or what runs)']='Webmail (bir alan adı için aç/kapat ya da ne çalışıyor)'
MENU_TR['Turn mail off for a domain, or remove a mail domain']='Bir alan adının postasını kapat ya da posta alan adını kaldır'
MENU_TR['Server: status, health check, backups, updates']='Sunucu: durum, sağlık kontrolü, yedekler, güncellemeler'
MENU_TR['Mailbox name (before the @)']='Posta kutusu adı (@ işaretinden önceki kısım)'
MENU_TR['Which address?']='Hangi adres?'
MENU_TR['Alias address, or @domain for every address of a domain (empty to only list them)']='Takma ad adresi ya da bir alan adının her adresi için @alanadı (yalnızca listelemek için boş bırakın)'
MENU_TR['Where should it go? (an address, or several with commas)']='Nereye gitsin? (bir adres ya da virgülle birkaç adres)'
MENU_TR['\n %sSERVER%s\n']='\n %sSUNUCU%s\n'
MENU_TR['Back up the mail (now, or automatically)']='Postayı yedekle (şimdi ya da otomatik)'
MENU_TR['Restore a domain'\''s mail from a backup']='Bir alan adının postasını yedekten geri yükle'
MENU_TR['Certificates: which exist, is renewal automatic']='Sertifikalar: hangileri var, yenileme otomatik mi'
MENU_TR['Every domain, now']='Tüm alan adları, şimdi'
MENU_TR['One domain, now']='Tek alan adı, şimdi'
MENU_TR['Automatic backups (now: %s)']='Otomatik yedekler (şu an: %s)'
MENU_TR['Encrypt the archive? (y/n)']='Arşiv şifrelensin mi? (y/n)'
MENU_TR['Domain whose mail to restore']='Postası geri yüklenecek alan adı'
MENU_TR['\n%sMail archives of %s:%s\n']='\n%s%s posta arşivleri:%s\n'
MENU_TR['  (none found under %s - copy the archive there, or give its path below)\n']='  (%s altında arşiv bulunamadı - arşivi oraya kopyalayın ya da yolunu aşağıya yazın)\n'
MENU_TR['Full path of the archive (empty: the newest one above)']='Arşivin tam yolu (boş: yukarıdaki en yenisi)'
MENU_TR['A server for mail alone: Postfix, Dovecot, Rspamd and a webmail. Your domains get their']='Yalnızca posta için bir sunucu: Postfix, Dovecot, Rspamd ve bir webmail. Alan adlarınızın postası'
MENU_TR['mail here; their web sites stay where they are. It needs a name of its own, like']='buraya gelir; web siteleri oldukları yerde kalır. Sunucunun kendine ait bir ada ihtiyacı var, örneğin'
MENU_TR['mail.example.com, with an A record pointing here and a PTR record your provider sets.']='mail.example.com; buraya yönlenen bir A kaydı ve sağlayıcınızın ayarladığı bir PTR kaydıyla.'
MENU_TR['Name this server sends mail as']='Bu sunucunun posta gönderirken kullanacağı ad'
MENU_TR['\n %sOPTIONAL COMPONENTS%s   (nothing here is installed by default)\n']='\n %sİSTEĞE BAĞLI BİLEŞENLER%s   (buradaki hiçbir şey varsayılan olarak kurulmaz)\n'
MENU_TR['installed']='kurulu'
MENU_TR['not installed']='kurulu değil'
MENU_TR['installed, sends as %s']='kurulu, %s adıyla gönderir'
MENU_TR['Node.js major version']='Node.js ana sürümü'
MENU_TR['The mail server needs a name of its own (mail.example.com), an A record']='Posta sunucusunun kendine ait bir adı (mail.example.com), buraya yönlenen bir A kaydı'
MENU_TR['pointing here, and a PTR record your provider sets to the same name.']='ve sağlayıcınızın aynı ada ayarladığı bir PTR kaydı olmalıdır.'
MENU_TR['\n  Every site gets an archive of its own under %s/<domain>/:\n  files, database, vhost and state. Older archives are removed as new ones arrive.\n']='\n  Her sitenin %s/<domain>/ altında kendi arşivi olur:\n  dosyalar, veritabanı, vhost ve durum. Yeni arşivler geldikçe eskileri silinir.\n'
MENU_TR['Every day']='Her gün'
MENU_TR['Once a week']='Haftada bir'
MENU_TR['Every hour']='Her saat'
MENU_TR['Turn automatic backups off']='Otomatik yedekleri kapat'
MENU_TR['At what time (HH:MM, the server'\''s clock)']='Saat kaçta (SS:DD, sunucunun saati)'
MENU_TR['On which day (mon tue wed thu fri sat sun)']='Hangi gün (mon tue wed thu fri sat sun)'
MENU_TR['%s"%s" is not a time like 03:00.%s\n']='%s"%s" 03:00 gibi bir saat değil.%s\n'
MENU_TR['%s"%s" is not one of mon tue wed thu fri sat sun.%s\n']='%s"%s" mon tue wed thu fri sat sun günlerinden biri değil.%s\n'
MENU_TR['Archives to keep per site']='Site başına saklanacak arşiv sayısı'
MENU_TR['%s"%s" is not a number of archives.%s\n']='%s"%s" geçerli bir arşiv sayısı değil.%s\n'
MENU_TR['Encrypt the archives? (y/n)']='Arşivler şifrelensin mi? (y/n)'
MENU_TR['Also upload each one to %s %s? (y/n)']='Her biri %s %s hedefine de yüklensin mi? (y/n)'
MENU_TR['%s  They stay on this server only: "%s backup --configure-remote" adds a second place.%s\n']='%s  Yalnızca bu sunucuda kalırlar: "%s backup --configure-remote" ikinci bir yer ekler.%s\n'
MENU_TR['Every site, now']='Tüm siteler, şimdi'
MENU_TR['One site, now']='Tek site, şimdi'
MENU_TR['\n%sAvailable archives for %s:%s\n']='\n%s%s için mevcut arşivler:%s\n'
MENU_TR['  (none found under %s)\n']='  (%s altında arşiv bulunamadı)\n'
MENU_TR['Full path of the archive to restore']='Geri yüklenecek arşivin tam yolu'
MENU_TR['Import sites from another server (files and databases, over SSH)']='Başka bir sunucudan site aktar (dosyalar ve veritabanları, SSH ile)'
MENU_TR['Looks at what another server serves and asks which sites to bring here: their files, and the']='Başka bir sunucunun yayınladığı sitelere bakar ve hangilerinin buraya getirileceğini sorar: dosyaları ve'
MENU_TR['database of a WordPress. A site that is not here yet is added first. The other server is only read.']='WordPress veritabanı. Burada henüz olmayan site önce eklenir. Diğer sunucu yalnızca okunur.'
MENU_TR['Its mailboxes come along when this server runs mail. You are asked for the SSH password once.']='Bu sunucuda posta kuruluysa posta kutuları da gelir. SSH şifresi bir kez sorulur.'
MENU_TR['The other server (user@address, e.g. root@203.0.113.10)']='Diğer sunucu (kullanıcı@adres, örn. root@203.0.113.10)'
MENU_TR['Its SSH port']='SSH portu'
# MENU_TR-END
