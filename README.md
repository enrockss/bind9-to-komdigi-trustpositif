# BIND9 RPZ — Blocklist Trust Positif (Komdigi)

Script provisioning untuk setup BIND9 sebagai DNS resolver dengan RPZ
(Response Policy Zone) blocklist dari Trust Positif Kementerian
Komunikasi dan Digital RI. Sekali jalan di fresh machine, langsung jadi
resolver dengan blocking + redirect + update mingguan otomatis.

## Apa yang dilakukan script ini

- Install BIND9 dan tools terkait
- Stop resolver lain yang mungkin konflik di port 53 (unbound, dnsmasq, systemd-resolved)
- Download blocklist domain dari Komdigi (`domains_isp`, ~9.5 juta domain)
- Convert ke format RPZ zone, compile ke **raw format** (load jauh lebih cepat dibanding text)
- Konfigurasi `named.conf.options` dan `named.conf.local` — ACL client, response-policy, statistics-channels, logging RPZ
- Pasang cron mingguan untuk update blocklist otomatis, dengan validasi berlapis sebelum swap ke production
- Validasi config sebelum restart service (tidak akan matikan resolver kalau config-nya rusak)

## Requirement

- Debian 12/13 (bookworm/trixie), akses root
- Minimal 12GB RAM (zone ~9.5 juta domain butuh sekitar 6.5GB RSS saat loaded)
- Koneksi internet untuk download blocklist (~200MB)
- Domain block page (mis. `blocked.namamu.com`) sudah punya A record valid **sebelum** dijalankan

## Cara pakai

1. Edit variabel di bagian atas `setup-bind9-rpz.sh`:

   ```bash
   CLIENT_ACL='<subnet-client-kamu>; 127.0.0.1;'
   BLOCK_TARGET="<domain-block-page-kamu>."
   ```

   Nilai default di script ini cuma contoh — **wajib diganti** sebelum dijalankan.

2. Download dan jalankan sebagai root:

   ```bash
   wget https://raw.githubusercontent.com/enrockss/bind9-to-komdigi-trustpositif/refs/heads/main/setup-bind9-rpz.sh
   chmod +x setup-bind9-rpz.sh
   nano setup-bind9-rpz.sh    # edit CLIENT_ACL dan BLOCK_TARGET dulu, lalu save
   sudo ./setup-bind9-rpz.sh
   ```

   Penting: pakai URL **raw** (`raw.githubusercontent.com`), bukan link
   halaman file di GitHub (`github.com/.../blob/...`) — kalau salah, yang
   kedownload adalah halaman HTML, bukan script-nya.

3. Script berhenti otomatis di tahap mana pun kalau ada error (config invalid, zone gagal compile, dll) — aman ditinggal, tidak akan restart service dengan config rusak.

Waktu proses total sekitar 10-15 menit, tergantung kecepatan koneksi dan spek server.

## Setelah selesai

Tes resolusi normal:
```bash
dig @127.0.0.1 google.com +short
```

Tes blocking (ganti dengan domain dari blocklist):
```bash
dig @127.0.0.1 <domain-terblokir>
```
Harus keluar `CNAME` ke domain block target, lalu `A` record-nya.

Cek statistik cache/query:
```bash
curl -s http://127.0.0.1:8053/json/v1 | python3 -m json.tool | head -50
```

Pantau RPZ hit real-time:
```bash
tail -f /var/log/named/rpz.log
```

Update manual (di luar jadwal cron):
```bash
/var/cache/bind/rpz-update/update-rpz.sh
cat /var/log/rpz-update.log
```

Rollback ke zone sebelumnya kalau update terbaru bermasalah:
```bash
cp /var/cache/bind/db.rpz.trustpositif.raw.bak /var/cache/bind/db.rpz.trustpositif.raw
chown bind:bind /var/cache/bind/db.rpz.trustpositif.raw
rndc reload rpz.trustpositif
```

## Catatan penting

- **Nama unit systemd adalah `named`, bukan `bind9`.** Di Debian, `bind9.service` cuma linked alias — `systemctl enable bind9` akan ditolak. Pakai `systemctl status named` / `systemctl restart named`.
- **HTTPS blocking menampilkan cert warning**, bukan redirect mulus. Browser connect ke IP block target tapi sertifikat TLS-nya untuk domain block page, sementara SNI tetap nama domain asli yang diblokir — jadi muncul `ERR_CERT_COMMON_NAME_INVALID`. Ini keterbatasan struktural DNS-based blocking di HTTPS, bukan bug. User teknis bisa klik "lanjutkan" untuk tetap sampai ke halaman block.
- **Domain HSTS-preloaded** (situs besar yang terdaftar di [hstspreload.org](https://hstspreload.org)) akan **hard-block tanpa opsi lanjut** — browser menolak total, bukan sekadar warning.
- **AppArmor**: kalau BIND9 di sistem kamu dikekang AppArmor (defaultnya bervariasi), pastikan semua file zone ada di `/var/cache/bind/` atau path lain yang di-allow profile `usr.sbin.named`. Kalau tidak, akan ada error permission yang membingungkan meski permission Unix-nya benar.
- Server yang dipakai untuk develop script ini pakai statistics-channels di `127.0.0.1:8053` **tanpa autentikasi** — sengaja dibatasi ke localhost saja. Jangan expose ke jaringan luas tanpa reverse proxy + auth di depannya.

## Zone slave tambahan: `trustpositifkominfo` (opsional, belum di-otomasi)

Komdigi juga menyediakan zone RPZ kedua (`trustpositifkominfo`) via AXFR/IXFR
langsung dari server mereka — beda mekanisme dari flat file `domains_isp`
di atas. Belum dimasukkan ke script ini karena:

- IP publik server **harus didaftarkan dulu** dan di-approve di
  [integrasipenapisan.komdigi.go.id](https://integrasipenapisan.komdigi.go.id)
  (proses approval maks 1×24 jam)
- Zone ini besar (~19 juta record, ~400MB per transfer) dan pada saat
  ditest, master Komdigi melakukan full re-transfer setiap beberapa menit,
  dengan zone berstatus `not loaded`/`SERVFAIL` selama proses transfer
  berlangsung — masih menunggu klarifikasi dari helpdesk Komdigi soal
  perilaku ini sebelum dianggap aman untuk production.

Kontak helpdesk resmi: Telegram `@rpzhelpdesk`, WhatsApp +62 882 1053 8691,
email `helpdeskrpz@aduankonten.id`.

## Tidak termasuk di script ini

- Setup SNMP/LibreNMS monitoring (nama user SNMP daemon dan path sudoers beda-beda antar distro, lebih aman dikonfigurasi manual)
- Zone slave `trustpositifkominfo` (lihat bagian di atas)
