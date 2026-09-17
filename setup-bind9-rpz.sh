#!/bin/bash
#
# setup-bind9-rpz.sh
# Provisioning BIND9 + RPZ blocklist Trust Positif (Komdigi) di fresh machine.
# Target: Debian 12/13 (trixie) fresh install, akses root.
#
# Jalankan: chmod +x setup-bind9-rpz.sh && ./setup-bind9-rpz.sh
#

set -euo pipefail

# ============================================================
# EDIT BAGIAN INI SEBELUM MENJALANKAN
# ============================================================

# Subnet client yang boleh pakai resolver ini (allow-recursion).
# WAJIB diganti. Jangan pakai "any" -> jadi open resolver, rawan
# disalahgunakan untuk DNS amplification attack.
CLIENT_ACL='162.4.63.0/24; 172.16.100.0/29; 127.0.0.1;'

# Domain tujuan redirect untuk domain yang diblokir.
# WAJIB sudah punya A record valid di DNS publik sebelum script ini jalan.
BLOCK_TARGET="blocked.rambowifi.com."

# Sumber blocklist Komdigi
SRC_URL="https://trustpositif.komdigi.go.id/assets/db/domains_isp"

# Jadwal cron update mingguan (default: Senin 03:00)
CRON_SCHEDULE="0 3 * * 1"

# Aktifkan statistics-channels di 127.0.0.1:8053 (untuk cek cache hit/miss)
ENABLE_STATS_CHANNEL=1

# Aktifkan logging khusus RPZ ke /var/log/named/rpz.log
ENABLE_RPZ_LOG=1

# ============================================================
# JANGAN EDIT DI BAWAH INI KECUALI PAHAM
# ============================================================

ZONE_NAME="rpz.trustpositif"
BINDDIR="/var/cache/bind"
WORKDIR="${BINDDIR}/rpz-update"

# File domains_isp yang WAJIB sudah di-download manual (lihat README) ke
# direktori yang sama dengan script ini, sebelum script dijalankan.
SEED_FILE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/domains_isp"

msg()  { echo -e "\n=== $1 ==="; }
fail() { echo "GAGAL: $1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "script harus dijalankan sebagai root"

# ---------- 1. Pre-flight check ----------
msg "1/9 Pre-flight check"

if [ ! -f "$SEED_FILE" ]; then
    fail "file domains_isp tidak ditemukan di $SEED_FILE

Download dulu sebelum menjalankan script ini:
    wget https://trustpositif.komdigi.go.id/assets/db/domains_isp -O ${SEED_FILE}

Baru jalankan ulang: sudo ./$(basename "$0")"
fi

SEED_SIZE=$(stat -c%s "$SEED_FILE")
if [ "$SEED_SIZE" -lt 100000000 ]; then
    fail "file $SEED_FILE cuma ${SEED_SIZE} byte — kemungkinan download terputus atau bukan file yang benar (harusnya ~200MB). Download ulang lalu coba lagi."
fi
if head -c 200 "$SEED_FILE" | grep -qi "<html"; then
    fail "file $SEED_FILE berisi HTML, bukan domain list. Download ulang, cek URL-nya."
fi
echo "File domains_isp ditemukan: ${SEED_SIZE} byte, $(wc -l < "$SEED_FILE") baris"

TARGET_HOST="${BLOCK_TARGET%.}"
if ! getent hosts "$TARGET_HOST" >/dev/null 2>&1; then
    echo "PERINGATAN: $TARGET_HOST belum resolve dari server ini."
    echo "Semua domain terblokir akan gagal resolve sampai A record-nya ada."
    read -rp "Lanjutkan? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || exit 1
fi

TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM_GB" -lt 12 ]; then
    echo "PERINGATAN: RAM terdeteksi ${TOTAL_RAM_GB}GB."
    echo "Zone ~9.5 juta domain butuh sekitar 6.5GB RSS. Minimal 12GB disarankan."
    read -rp "Lanjutkan? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || exit 1
fi

# ---------- 2. Install paket ----------
# Catatan: resolver lama (unbound/dnsmasq/systemd-resolved) SENGAJA belum
# dimatikan di titik ini. apt-get butuh resolusi DNS untuk deb.debian.org,
# dan kalau resolver dimatikan sekarang sementara /etc/resolv.conf masih
# mengarah ke 127.0.0.1, apt akan gagal total. Resolver lama baru dimatikan
# nanti tepat sebelum named dinyalakan (lihat step 8).
msg "2/9 Install BIND9"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y bind9 bind9-utils bind9-dnsutils curl

# ---------- 3. Siapkan direktori ----------
msg "3/9 Siapkan direktori kerja"

mkdir -p "$WORKDIR"
chown -R bind:bind "$BINDDIR"

if [ "$ENABLE_RPZ_LOG" -eq 1 ]; then
    mkdir -p /var/log/named
    chown bind:bind /var/log/named
fi

# ---------- 4. Install script update ----------
msg "4/9 Install script update RPZ"

cat > "${WORKDIR}/update-rpz.sh" << UPDATESCRIPT
#!/bin/bash
set -euo pipefail

WORKDIR="${WORKDIR}"
LIVEDIR="${BINDDIR}"
SRC_URL="${SRC_URL}"
TARGET="${BLOCK_TARGET}"
ZONE_NAME="${ZONE_NAME}"
LOG="/var/log/rpz-update.log"

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$1" >> "\$LOG"; }

cd "\$WORKDIR"
log "=== Mulai update RPZ ==="

# 1. Download ke file temp — skip kalau file sudah ada (mis. dari seed file
#    pertama kali, lihat setup-bind9-rpz.sh). Cron mingguan selalu mulai
#    bersih (file .new di-rename ke .prev di akhir run), jadi ini tidak
#    pernah membuat cron skip download beneran.
if [ -f domains_isp.new ]; then
    log "domains_isp.new sudah ada (pre-seeded), skip curl download"
else
    if ! curl -sS -o domains_isp.new -L "\$SRC_URL"; then
        log "GAGAL: curl error, update dibatalkan, zone lama tetap dipakai"
        exit 1
    fi
fi

# 2. Sanity check
SIZE=\$(stat -c%s domains_isp.new)
if [ "\$SIZE" -lt 100000000 ]; then
    log "GAGAL: hasil download cuma \${SIZE} byte, terlalu kecil. Dibatalkan."
    exit 1
fi
if head -c 200 domains_isp.new | grep -qi "<html"; then
    log "GAGAL: hasil download berisi HTML, bukan domain list. Dibatalkan."
    exit 1
fi

LINES=\$(wc -l < domains_isp.new)
log "Download OK: \${SIZE} byte, \${LINES} baris"

# 3. Convert ke format RPZ zone
SERIAL=\$(date +%Y%m%d%H)
{
cat <<EOF
\\\$TTL 60
@ SOA localhost. admin.localhost. (\$SERIAL 1h 15m 30d 1h)
  NS localhost.
EOF
awk -v target="\$TARGET" 'NF && \$1 !~ /^#/ {
    gsub(/^[ \t]+|[ \t]+\$/, "", \$1)
    print \$1 " CNAME " target
}' domains_isp.new | sort -u
} > db.rpz.new

ZONE_LINES=\$(wc -l < db.rpz.new)

# 4. Compile ke raw format (load jauh lebih cepat saat named start)
if ! named-compilezone -f text -F raw -o db.rpz.raw.new "\$ZONE_NAME" db.rpz.new > compile.log 2>&1; then
    log "GAGAL: named-compilezone error. Detail:"
    cat compile.log >> "\$LOG"
    exit 1
fi

# 5. Validasi zone hasil compile
if ! named-checkzone -f raw "\$ZONE_NAME" db.rpz.raw.new > checkzone.log 2>&1; then
    log "GAGAL: named-checkzone error. Detail:"
    cat checkzone.log >> "\$LOG"
    exit 1
fi

# 6. Semua valid — swap ke production, simpan backup
chown bind:bind db.rpz.raw.new
if [ -f "\$LIVEDIR/db.rpz.trustpositif.raw" ]; then
    mv "\$LIVEDIR/db.rpz.trustpositif.raw" "\$LIVEDIR/db.rpz.trustpositif.raw.bak"
fi
mv db.rpz.raw.new "\$LIVEDIR/db.rpz.trustpositif.raw"
mv domains_isp.new domains_isp.prev
mv db.rpz.new db.rpz.prev

# 7. Reload zone
if rndc reload "\$ZONE_NAME" >> "\$LOG" 2>&1; then
    log "SUKSES: zone direload — \${ZONE_LINES} baris zone dari \${LINES} domain"
else
    log "PERINGATAN: file sudah di-swap tapi rndc reload gagal, cek manual"
fi

log "=== Selesai ==="
UPDATESCRIPT

chmod +x "${WORKDIR}/update-rpz.sh"

# ---------- 5. Generate zone pertama kali ----------
msg "5/9 Generate zone RPZ dari file yang sudah di-download (butuh beberapa menit)"

# Pakai seed file yang sudah dicek di step 1 — bukan file asli yang
# dipindah, supaya kalau perlu diulang, seed file masih ada.
cp "$SEED_FILE" "${WORKDIR}/domains_isp.new"

"${WORKDIR}/update-rpz.sh" || true

if [ ! -f "${BINDDIR}/db.rpz.trustpositif.raw" ]; then
    echo "--- isi /var/log/rpz-update.log ---"
    cat /var/log/rpz-update.log 2>/dev/null || true
    fail "zone RPZ gagal dibuat, cek log di atas"
fi

chown bind:bind "${BINDDIR}/db.rpz.trustpositif.raw"

# ---------- 6. Tulis konfigurasi BIND ----------
msg "6/9 Tulis konfigurasi BIND9"

for f in /etc/bind/named.conf.options /etc/bind/named.conf.local; do
    [ -f "$f" ] && cp "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
done

{
cat << EOF
acl trusted-clients {
    ${CLIENT_ACL}
};

options {
    directory "${BINDDIR}";

    listen-on { any; };
    allow-recursion { trusted-clients; };
    allow-query { trusted-clients; };
    allow-transfer { none; };

    dnssec-validation auto;

    statistics-file "${BINDDIR}/stats";
    zone-statistics yes;

    response-policy {
        zone "${ZONE_NAME}";
    };
};
EOF

if [ "$ENABLE_STATS_CHANNEL" -eq 1 ]; then
cat << 'EOF'

statistics-channels {
    inet 127.0.0.1 port 8053 allow { 127.0.0.1; };
};
EOF
fi

if [ "$ENABLE_RPZ_LOG" -eq 1 ]; then
cat << 'EOF'

logging {
    channel rpz_log {
        file "/var/log/named/rpz.log" versions 3 size 20m;
        severity info;
        print-time yes;
    };
    category rpz { rpz_log; };
};
EOF
fi
} > /etc/bind/named.conf.options

cat > /etc/bind/named.conf.local << EOF
//
// Zone RPZ Trust Positif — di-generate oleh setup-bind9-rpz.sh
//

zone "${ZONE_NAME}" {
    type master;
    file "${BINDDIR}/db.rpz.trustpositif.raw";
    masterfile-format raw;
    allow-query { none; };
};
EOF

touch "${BINDDIR}/stats"
chown bind:bind "${BINDDIR}/stats"
chmod 664 "${BINDDIR}/stats"

# ---------- 8. Validasi, stop resolver lain, start named ----------
msg "8/9 Validasi konfigurasi"

named-checkconf || fail "named-checkconf error — resolver lama tidak diganggu, service tidak di-restart"
named-checkzone -f raw "$ZONE_NAME" "${BINDDIR}/db.rpz.trustpositif.raw" \
    || fail "zone RPZ tidak valid — resolver lama tidak diganggu"

echo "Konfigurasi valid."

# Baru di titik ini resolver lama dimatikan — semua proses yang butuh DNS
# (apt install, download blocklist) sudah selesai di atas. Kalau di-stop
# lebih awal (sebelum apt-get update misalnya) dan /etc/resolv.conf masih
# mengarah ke 127.0.0.1, apt akan gagal resolve deb.debian.org.
echo "Menghentikan resolver lain (kalau ada) sebelum named naik..."
for svc in unbound dnsmasq systemd-resolved; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "Menemukan $svc aktif di port 53 — menghentikan."
        systemctl stop "$svc"
        systemctl disable "$svc" || true
    fi
done

echo "Menjalankan named..."
systemctl restart named
systemctl enable named

sleep 5
systemctl is-active --quiet named || fail "named gagal start, cek: journalctl -u named -n 50"

# ---------- 9. Pasang cron ----------
msg "9/9 Pasang cron update mingguan"

cat > /etc/cron.d/rpz-update << EOF
${CRON_SCHEDULE} root ${WORKDIR}/update-rpz.sh
EOF
chmod 644 /etc/cron.d/rpz-update

# ---------- Verifikasi ----------
msg "Verifikasi"

echo "--- zone status ---"
rndc zonestatus "$ZONE_NAME" || true

echo
echo "--- resolusi normal ---"
dig @127.0.0.1 google.com +short || true

echo
echo "--- memory ---"
free -h
ps -o pid,rss,cmd -C named || true

cat << EOF

============================================================
SELESAI.

Tes blocking (ganti dengan domain dari blocklist):
    dig @127.0.0.1 <domain-terblokir>
  -> harus CNAME ke ${BLOCK_TARGET}

Cek statistik cache:
    curl -s http://127.0.0.1:8053/json/v1 | python3 -m json.tool | head -50

Pantau RPZ hit:
    tail -f /var/log/named/rpz.log

Update manual:
    ${WORKDIR}/update-rpz.sh && cat /var/log/rpz-update.log

Rollback zone ke versi sebelumnya:
    cp ${BINDDIR}/db.rpz.trustpositif.raw.bak ${BINDDIR}/db.rpz.trustpositif.raw
    chown bind:bind ${BINDDIR}/db.rpz.trustpositif.raw
    rndc reload ${ZONE_NAME}

CATATAN:
- Unit systemd-nya "named", bukan "bind9". "systemctl enable bind9" akan
  ditolak karena bind9.service cuma linked alias.
- Kalau nanti mau tambah zone slave trustpositifkominfo dari Komdigi,
  IP publik server ini harus didaftarkan dulu di
  https://integrasipenapisan.komdigi.go.id
============================================================
EOF
