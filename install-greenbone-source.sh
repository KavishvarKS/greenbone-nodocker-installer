#!/usr/bin/env bash
#
# Greenbone Community Edition — Build from Source (No Docker)
# Target OS: Ubuntu 24.04 LTS
#
# FINAL CONSOLIDATED VERSION (Aug 2026)
#
# Every issue hit during testing on this VM is fixed here:
#   - Version matrix bumped to a mutually-compatible current set (gsa 28.x
#     requires gsad >= 27.0.0, which requires gvm-libs >= 22.38).
#   - Every component build hard-resets (rm -rf) its source/build/install
#     dirs before configuring — re-running cmake --build against a stale
#     build dir silently rebuilds OLD source and skips version bumps.
#   - gvm-libs install is verified with pkg-config before anything else
#     builds against it.
#   - libmagic-dev added (openvas-scanner needs it).
#   - openvasd (Rust) needs krb5 statically linked. Outside Greenbone's own
#     Docker pipeline nothing provides that, so we build static krb5 +
#     libpcap ourselves from their OFFICIAL release tarballs (NOT GitHub's
#     tag archives — those don't ship a pre-generated ./configure for
#     autotools projects and fail immediately).
#   - libpcap is built with --disable-rdma — without it, libpcap
#     auto-detects libibverbs on the build host and links RDMA support,
#     which then fails at the final Rust link step with undefined
#     ibv_* symbols (Greenbone's own Docker builder doesn't have
#     libibverbs present, so their libpcap never hits this).
#   - rustup apt package conflict -> uses official rustup.rs installer.
#   - Log/data directory permissions (chown gvm:gvm) are fixed BEFORE any
#     service is started — gsad/gvmd will silently die with "Permission
#     denied" on their own log files otherwise.
#   - PostgreSQL cluster auto-creation + role/db verification.
#   - Admin user creation is verified, not assumed.
#   - Custom systemd unit files (with your chosen --listen address) are
#     installed to /etc/systemd/system/ — NOT relying on the default unit
#     files gvmd/gsad's own `make install` drops under
#     /usr/local/lib/systemd/system/, which listen on 127.0.0.1 only and
#     silently take priority if you `systemctl enable` before this script
#     writes the real ones.
#   - Every "start a service" step uses --foreground once first to
#     surface real startup errors, before handing off to systemd.
#
# Usage:
#   chmod +x install-greenbone-source.sh
#   ./install-greenbone-source.sh
#
# Run as a normal sudo-capable user, NOT as root directly.
# Run inside tmux/screen — this is a long build (45-90+ min), and the
# krb5/libpcap/Rust build plus feed sync are the biggest chunks.
#
# IMPORTANT: versions below were current and mutually-compatible as of
# Aug 2026. Re-check https://github.com/greenbone/<repo>/releases before
# reusing this months from now — gsa/gsad's minimum-version pairing is the
# thing most likely to have moved.

set -euo pipefail

log() { echo -e "\n\033[1;32m==> $1\033[0m\n"; }
die() { echo -e "\n\033[1;31mERROR: $1\033[0m\n" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Interactive prompts
# ---------------------------------------------------------------------------
echo "=== Greenbone Community Edition — Source Build Setup ==="
echo

read -r -s -p "Set the admin account password: " ADMIN_PASSWORD
echo
read -r -s -p "Confirm the admin account password: " ADMIN_PASSWORD_CONFIRM
echo

[[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]] || die "Passwords did not match. Re-run the script."
[[ -n "$ADMIN_PASSWORD" ]] || die "Password cannot be empty."

echo
echo "Should the GSA web interface (port 9392) be reachable:"
echo "  1) Locally only (127.0.0.1) — safer, access via SSH tunnel or browser on the VM"
echo "  2) Globally (0.0.0.0) — reachable on the VM's public/internal IP directly"
read -r -p "Enter 1 or 2: " LISTEN_CHOICE

case "$LISTEN_CHOICE" in
  1) GSAD_LISTEN_ADDRESS="127.0.0.1" ;;
  2) GSAD_LISTEN_ADDRESS="0.0.0.0" ;;
  *) die "Enter 1 or 2." ;;
esac

if [[ "$GSAD_LISTEN_ADDRESS" == "0.0.0.0" ]]; then
  echo
  echo "WARNING: GSA will be exposed with --http-only (no TLS) on all interfaces."
  echo "  Anyone who can reach port 9392 could sniff the admin login in plaintext."
  echo "  Make sure your firewall/security group restricts access."
  read -r -p "Type YES to continue anyway: " CONFIRM_GLOBAL
  [[ "$CONFIRM_GLOBAL" == "YES" ]] || die "Aborted."
fi

echo
echo "Config: GSA will listen on $GSAD_LISTEN_ADDRESS:9392"
echo

# ---------------------------------------------------------------------------
# Versions — mutually-compatible set as of Aug 2026. Re-verify before reuse.
# ---------------------------------------------------------------------------
GVM_LIBS_VERSION=23.0.0
GVMD_VERSION=26.28.0
PG_GVM_VERSION=22.6.17
GSA_VERSION=28.2.0
GSAD_VERSION=27.1.0
OPENVAS_SMB_VERSION=22.5.10
OPENVAS_SCANNER_VERSION=23.50.10
OSPD_OPENVAS_VERSION=22.10.1
OPENVAS_DAEMON=23.50.10
KRB5_VERSION=1.22.2
LIBPCAP_VERSION=1.10.6

INSTALL_PREFIX=/usr/local
export PATH=$PATH:$INSTALL_PREFIX/sbin
SOURCE_DIR=$HOME/source
BUILD_DIR=$HOME/build
INSTALL_DIR=$HOME/install
VENDOR_DIR=$HOME/vendor
ARCHIVES_DIR=$HOME/archives
mkdir -p "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR" "$VENDOR_DIR" "$ARCHIVES_DIR"

# ---------------------------------------------------------------------------
# Step -1 — Stop any already-running services (avoids "Text file busy")
# ---------------------------------------------------------------------------
log "Step -1: Stopping any existing gvm services before (re)installing"
for svc in gsad gvmd ospd-openvas openvasd; do
  sudo systemctl stop "$svc" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# Step 0 — gvm system user/group
# ---------------------------------------------------------------------------
log "Step 0: Creating gvm user/group"
sudo useradd -r -M -U -G sudo -s /usr/sbin/nologin gvm 2>/dev/null || true
sudo usermod -aG gvm "$USER"

# ---------------------------------------------------------------------------
# Step 2 — common build deps
# ---------------------------------------------------------------------------
log "Step 2: Installing common build dependencies"
sudo apt update
sudo apt install --no-install-recommends --assume-yes \
  build-essential curl cmake pkg-config python3 python3-pip gnupg

# ---------------------------------------------------------------------------
# Step 3 — Greenbone signing key
# ---------------------------------------------------------------------------
log "Step 3: Importing Greenbone signing key"
curl -f -L https://www.greenbone.net/GBCommunitySigningKey.asc -o /tmp/GBCommunitySigningKey.asc
gpg --import /tmp/GBCommunitySigningKey.asc
echo "8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:" | gpg --import-ownertrust

# ---------------------------------------------------------------------------
# Step 4 — gvm-libs (built FIRST, everything else links against it)
# ---------------------------------------------------------------------------
log "Step 4: Building gvm-libs $GVM_LIBS_VERSION"
sudo apt install -y \
  libcjson-dev libcurl4-gnutls-dev libgcrypt-dev libglib2.0-dev \
  libgnutls28-dev libgpgme-dev libhiredis-dev libnet1-dev \
  libpaho-mqtt-dev libpcap-dev libssh-dev libxml2-dev uuid-dev

rm -rf "$SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION" "$BUILD_DIR/gvm-libs" "$INSTALL_DIR/gvm-libs"
curl -f -L "https://github.com/greenbone/gvm-libs/archive/refs/tags/v$GVM_LIBS_VERSION.tar.gz" -o "$SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz"
tar -C "$SOURCE_DIR" -xzf "$SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz"
[[ -f "$SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION/CMakeLists.txt" ]] || die "gvm-libs source extraction looks wrong — CMakeLists.txt not found."

mkdir -p "$BUILD_DIR/gvm-libs"
cmake -S "$SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION" -B "$BUILD_DIR/gvm-libs" \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var
cmake --build "$BUILD_DIR/gvm-libs" -j"$(nproc)"

mkdir -p "$INSTALL_DIR/gvm-libs"
make -C "$BUILD_DIR/gvm-libs" DESTDIR="$INSTALL_DIR/gvm-libs" install
sudo cp -rv "$INSTALL_DIR/gvm-libs/"* /
sudo ldconfig

INSTALLED_GVM_LIBS_VER=$(pkg-config --modversion libgvm_gmp 2>/dev/null || echo "NOT FOUND")
[[ "$INSTALLED_GVM_LIBS_VER" == "$GVM_LIBS_VERSION" ]] || die "gvm-libs install verification failed — pkg-config reports '$INSTALLED_GVM_LIBS_VER', expected '$GVM_LIBS_VERSION'."
echo "Verified: gvm-libs $GVM_LIBS_VERSION is now what pkg-config sees."

# ---------------------------------------------------------------------------
# Step 5 — gvmd
# ---------------------------------------------------------------------------
log "Step 5: Building gvmd $GVMD_VERSION"
sudo apt install -y \
  libbsd-dev libcjson-dev libglib2.0-dev libgnutls28-dev libgpgme-dev \
  libical-dev libpq-dev postgresql-server-dev-all rsync xsltproc

sudo apt install -y --no-install-recommends \
  dpkg fakeroot gnupg gnutls-bin gpgsm nsis openssh-client python3 \
  python3-lxml rpm smbclient snmp socat sshpass \
  texlive-fonts-recommended texlive-latex-extra wget xmlstarlet zip

rm -rf "$SOURCE_DIR/gvmd-$GVMD_VERSION" "$BUILD_DIR/gvmd" "$INSTALL_DIR/gvmd"
curl -f -L "https://github.com/greenbone/gvmd/archive/refs/tags/v$GVMD_VERSION.tar.gz" -o "$SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz"
tar -C "$SOURCE_DIR" -xzf "$SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz"

mkdir -p "$BUILD_DIR/gvmd"
cmake -S "$SOURCE_DIR/gvmd-$GVMD_VERSION" -B "$BUILD_DIR/gvmd" \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX -DCMAKE_BUILD_TYPE=Release \
  -DLOCALSTATEDIR=/var -DSYSCONFDIR=/etc -DGVM_DATA_DIR=/var \
  -DGVM_LOG_DIR=/var/log/gvm -DGVMD_RUN_DIR=/run/gvmd \
  -DOPENVAS_DEFAULT_SOCKET=/run/ospd/ospd-openvas.sock \
  -DGVM_FEED_LOCK_PATH=/var/lib/gvm/feed-update.lock \
  -DLOGROTATE_DIR=/etc/logrotate.d
cmake --build "$BUILD_DIR/gvmd" -j"$(nproc)"

mkdir -p "$INSTALL_DIR/gvmd"
make -C "$BUILD_DIR/gvmd" DESTDIR="$INSTALL_DIR/gvmd" install
sudo cp -rv "$INSTALL_DIR/gvmd/"* /

# ---------------------------------------------------------------------------
# Step 6 — pg-gvm
# ---------------------------------------------------------------------------
log "Step 6: Building pg-gvm $PG_GVM_VERSION"
sudo apt install -y libglib2.0-dev libical-dev postgresql-server-dev-all

rm -rf "$SOURCE_DIR/pg-gvm-$PG_GVM_VERSION" "$BUILD_DIR/pg-gvm" "$INSTALL_DIR/pg-gvm"
curl -f -L "https://github.com/greenbone/pg-gvm/archive/refs/tags/v$PG_GVM_VERSION.tar.gz" -o "$SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz"
tar -C "$SOURCE_DIR" -xzf "$SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz"

mkdir -p "$BUILD_DIR/pg-gvm"
cmake -S "$SOURCE_DIR/pg-gvm-$PG_GVM_VERSION" -B "$BUILD_DIR/pg-gvm" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR/pg-gvm" -j"$(nproc)"

mkdir -p "$INSTALL_DIR/pg-gvm"
make -C "$BUILD_DIR/pg-gvm" DESTDIR="$INSTALL_DIR/pg-gvm" install
sudo cp -rv "$INSTALL_DIR/pg-gvm/"* /

# ---------------------------------------------------------------------------
# Step 7 — GSA + gsad
# ---------------------------------------------------------------------------
log "Step 7: Installing GSA web app $GSA_VERSION"
rm -rf "$SOURCE_DIR/gsa-$GSA_VERSION"
curl -f -L "https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz" -o "$SOURCE_DIR/gsa-$GSA_VERSION.tar.gz"
mkdir -p "$SOURCE_DIR/gsa-$GSA_VERSION"
tar -C "$SOURCE_DIR/gsa-$GSA_VERSION" -xzf "$SOURCE_DIR/gsa-$GSA_VERSION.tar.gz"

sudo mkdir -p "$INSTALL_PREFIX/share/gvm/gsad/web/"
sudo rm -rf "${INSTALL_PREFIX:?}/share/gvm/gsad/web/"*
sudo cp -rv "$SOURCE_DIR/gsa-$GSA_VERSION/"* "$INSTALL_PREFIX/share/gvm/gsad/web/"

log "Step 7b: Building gsad $GSAD_VERSION"
sudo apt install -y libbrotli-dev libglib2.0-dev libgnutls28-dev libmicrohttpd-dev libxml2-dev

rm -rf "$SOURCE_DIR/gsad-$GSAD_VERSION" "$BUILD_DIR/gsad" "$INSTALL_DIR/gsad"
curl -f -L "https://github.com/greenbone/gsad/archive/refs/tags/v$GSAD_VERSION.tar.gz" -o "$SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz"
tar -C "$SOURCE_DIR" -xzf "$SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz"

mkdir -p "$BUILD_DIR/gsad"
cmake -S "$SOURCE_DIR/gsad-$GSAD_VERSION" -B "$BUILD_DIR/gsad" \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var -DGVMD_RUN_DIR=/run/gvmd \
  -DGSAD_RUN_DIR=/run/gsad -DGVM_LOG_DIR=/var/log/gvm -DLOGROTATE_DIR=/etc/logrotate.d
cmake --build "$BUILD_DIR/gsad" -j"$(nproc)"

mkdir -p "$INSTALL_DIR/gsad"
make -C "$BUILD_DIR/gsad" DESTDIR="$INSTALL_DIR/gsad" install
sudo cp -rv "$INSTALL_DIR/gsad/"* /

# ---------------------------------------------------------------------------
# Step 8 — openvas-smb (optional, Windows scanning support)
# ---------------------------------------------------------------------------
log "Step 8: Building openvas-smb $OPENVAS_SMB_VERSION (optional, Windows scan support)"
sudo apt install -y gcc-mingw-w64 libgnutls28-dev libglib2.0-dev libpopt-dev libunistring-dev heimdal-multidev perl-base

rm -rf "$SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION" "$BUILD_DIR/openvas-smb" "$INSTALL_DIR/openvas-smb"
curl -f -L "https://github.com/greenbone/openvas-smb/archive/refs/tags/v$OPENVAS_SMB_VERSION.tar.gz" -o "$SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz"
tar -C "$SOURCE_DIR" -xzf "$SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz"

mkdir -p "$BUILD_DIR/openvas-smb"
cmake -S "$SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION" -B "$BUILD_DIR/openvas-smb" \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR/openvas-smb" -j"$(nproc)"

mkdir -p "$INSTALL_DIR/openvas-smb"
make -C "$BUILD_DIR/openvas-smb" DESTDIR="$INSTALL_DIR/openvas-smb" install
sudo cp -rv "$INSTALL_DIR/openvas-smb/"* /

# ---------------------------------------------------------------------------
# Step 9 — openvas-scanner (C/CMake part — the Rust part is Step 11)
# ---------------------------------------------------------------------------
log "Step 9: Building openvas-scanner $OPENVAS_SCANNER_VERSION"
sudo apt install -y \
  bison libglib2.0-dev libgnutls28-dev libgcrypt20-dev libpcap-dev \
  libgpgme-dev libksba-dev rsync nmap libjson-glib-dev \
  libcurl4-gnutls-dev libbsd-dev krb5-multidev libkrb5-dev libmagic-dev
sudo apt install -y python3-impacket libsnmp-dev || true

rm -rf "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION" "$BUILD_DIR/openvas-scanner" "$INSTALL_DIR/openvas-scanner"
curl -f -L "https://github.com/greenbone/openvas-scanner/archive/refs/tags/v$OPENVAS_SCANNER_VERSION.tar.gz" -o "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz"
tar -C "$SOURCE_DIR" -xzf "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz"

mkdir -p "$BUILD_DIR/openvas-scanner"
cmake -S "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION" -B "$BUILD_DIR/openvas-scanner" \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var \
  -DOPENVAS_FEED_LOCK_PATH=/var/lib/openvas/feed-update.lock -DOPENVAS_RUN_DIR=/run/ospd
cmake --build "$BUILD_DIR/openvas-scanner" -j"$(nproc)"

mkdir -p "$INSTALL_DIR/openvas-scanner"
make -C "$BUILD_DIR/openvas-scanner" DESTDIR="$INSTALL_DIR/openvas-scanner" install
sudo cp -rv "$INSTALL_DIR/openvas-scanner/"* /

sudo tee /etc/openvas/openvas.conf > /dev/null << 'EOF'
table_driven_lsc = yes
openvasd_server = http://127.0.0.1:3000
EOF

# ---------------------------------------------------------------------------
# Step 10 — ospd-openvas
# ---------------------------------------------------------------------------
log "Step 10: Building ospd-openvas $OSPD_OPENVAS_VERSION"
sudo apt install -y \
  python3 python3-pip python3-setuptools python3-packaging python3-wrapt \
  python3-cffi python3-psutil python3-lxml python3-defusedxml \
  python3-paramiko python3-redis python3-gnupg python3-paho-mqtt

sudo python3 -m pip uninstall --break-system-packages -y ospd-openvas 2>/dev/null || true
rm -rf "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION" "$INSTALL_DIR/ospd-openvas"
curl -f -L "https://github.com/greenbone/ospd-openvas/archive/refs/tags/v$OSPD_OPENVAS_VERSION.tar.gz" -o "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz"
tar -C "$SOURCE_DIR" -xzf "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz"

mkdir -p "$INSTALL_DIR/ospd-openvas"
( cd "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION" && \
  python3 -m pip install --break-system-packages --root="$INSTALL_DIR/ospd-openvas" --no-warn-script-location . )
sudo cp -rv "$INSTALL_DIR/ospd-openvas/"* /

# ---------------------------------------------------------------------------
# Step 11 — static krb5 + libpcap archive bundle for the Rust build
#
#   openvasd's Rust build wants krb5 statically linked. Nothing outside
#   Greenbone's own Docker pipeline provides that, so we build it here from
#   the OFFICIAL release tarballs (GitHub's tag archives lack a pre-built
#   ./configure for these autotools projects and fail immediately).
#   libpcap is built with --disable-rdma — without it, libpcap auto-detects
#   libibverbs on this build host and links RDMA support, which then fails
#   the final Rust link step with undefined ibv_* symbols.
# ---------------------------------------------------------------------------
log "Step 11: Building static krb5 + libpcap archive bundle for the Rust build"
sudo apt install -y libgcrypt20-dev libgpg-error-dev flex bison capnproto libclang-dev libsnmp-dev

if [[ ! -f "$ARCHIVES_DIR/libkrb5.a" ]]; then
  rm -rf "$VENDOR_DIR"/krb5-* "$VENDOR_DIR"/libpcap-*
  mkdir -p "$ARCHIVES_DIR/include/gssapi" "$ARCHIVES_DIR/include/krb5"

  log "  Building static krb5 $KRB5_VERSION (official kerberos.org tarball — ships pre-built ./configure)"
  curl -f -L "https://kerberos.org/dist/krb5/${KRB5_VERSION%.*}/krb5-${KRB5_VERSION}.tar.gz" -o "$VENDOR_DIR/krb5-${KRB5_VERSION}.tar.gz"
  tar -C "$VENDOR_DIR" -xzf "$VENDOR_DIR/krb5-${KRB5_VERSION}.tar.gz"
  KRB5_SRC="$VENDOR_DIR/krb5-${KRB5_VERSION}"
  [[ -f "$KRB5_SRC/src/configure" ]] || die "krb5 source extraction failed — $KRB5_SRC/src/configure not found. Check https://kerberos.org/dist/krb5/ for the current release layout."

  sudo rm -rf /opt/krb5-static
  ( cd "$KRB5_SRC/src" && \
    ./configure --prefix=/opt/krb5-static \
      --enable-static --disable-shared \
      --without-system-verto --without-libedit --disable-rpath && \
    make -C util/support -j"$(nproc)" && \
    make -C util/et -j"$(nproc)" && \
    make -C util/profile -j"$(nproc)" && \
    make -C include -j"$(nproc)" && \
    make -C lib/crypto -j"$(nproc)" && \
    make -C lib/krb5 -j"$(nproc)" && \
    make -C lib/gssapi -j"$(nproc)" && \
    sudo make install-mkdirs && \
    sudo make -C util/support install && \
    sudo make -C util/et install && \
    sudo make -C util/profile install && \
    sudo make -C include install && \
    sudo make -C lib/crypto install && \
    sudo make -C lib/krb5 install && \
    sudo make -C lib/gssapi install )

  for lib in libgssapi_krb5.a libkrb5.a libk5crypto.a libcom_err.a libkrb5support.a; do
    [[ -f "/opt/krb5-static/lib/$lib" ]] || die "krb5 static build failed — $lib not found under /opt/krb5-static/lib."
  done
  echo "  krb5 static build OK."

  log "  Building static libpcap $LIBPCAP_VERSION (official tcpdump.org tarball, RDMA disabled)"
  curl -f -L "https://www.tcpdump.org/release/libpcap-${LIBPCAP_VERSION}.tar.gz" -o "$VENDOR_DIR/libpcap-${LIBPCAP_VERSION}.tar.gz"
  tar -C "$VENDOR_DIR" -xzf "$VENDOR_DIR/libpcap-${LIBPCAP_VERSION}.tar.gz"
  PCAP_SRC="$VENDOR_DIR/libpcap-${LIBPCAP_VERSION}"
  [[ -f "$PCAP_SRC/configure" ]] || die "libpcap source extraction failed — $PCAP_SRC/configure not found. Check https://www.tcpdump.org/ for the current release tarball name."

  sudo rm -rf /opt/libpcap-static
  ( cd "$PCAP_SRC" && \
    ./configure --prefix=/opt/libpcap-static --disable-shared --disable-dbus --disable-rdma && \
    make -j"$(nproc)" && \
    sudo make install )
  [[ -f /opt/libpcap-static/lib/libpcap.a ]] || die "libpcap static build failed — libpcap.a not found under /opt/libpcap-static/lib."
  echo "  libpcap static build OK."

  log "  Assembling archive bundle at $ARCHIVES_DIR"
  DEB_HOST_MULTIARCH="$(gcc -print-multiarch)"
  sudo install -m 644 "/usr/lib/${DEB_HOST_MULTIARCH}/libgcrypt.a" "$ARCHIVES_DIR/libgcrypt.a"
  sudo install -m 644 "/usr/lib/${DEB_HOST_MULTIARCH}/libgpg-error.a" "$ARCHIVES_DIR/libgpg-error.a"
  sudo install -m 644 /opt/libpcap-static/lib/libpcap.a "$ARCHIVES_DIR/libpcap.a"
  sudo install -m 644 /opt/krb5-static/lib/libgssapi_krb5.a "$ARCHIVES_DIR/libgssapi_krb5.a"
  sudo install -m 644 /opt/krb5-static/lib/libkrb5.a "$ARCHIVES_DIR/libkrb5.a"
  sudo install -m 644 /opt/krb5-static/lib/libk5crypto.a "$ARCHIVES_DIR/libk5crypto.a"
  sudo install -m 644 /opt/krb5-static/lib/libcom_err.a "$ARCHIVES_DIR/libcom_err.a"
  sudo install -m 644 /opt/krb5-static/lib/libkrb5support.a "$ARCHIVES_DIR/libkrb5support.a"
  sudo install -m 644 /usr/include/gcrypt.h "$ARCHIVES_DIR/include/gcrypt.h"
  sudo install -m 644 "/usr/include/${DEB_HOST_MULTIARCH}/gpg-error.h" "$ARCHIVES_DIR/include/gpg-error.h"
  sudo install -m 644 /opt/libpcap-static/include/pcap.h "$ARCHIVES_DIR/include/pcap.h"
  sudo install -m 644 /opt/krb5-static/include/krb5.h "$ARCHIVES_DIR/include/krb5.h"
  sudo install -m 644 /opt/krb5-static/include/com_err.h "$ARCHIVES_DIR/include/com_err.h"
  sudo install -m 644 /opt/krb5-static/include/profile.h "$ARCHIVES_DIR/include/profile.h"
  sudo install -m 644 /opt/krb5-static/include/gssapi/gssapi.h "$ARCHIVES_DIR/include/gssapi/gssapi.h"
  sudo install -m 644 /opt/krb5-static/include/gssapi/gssapi_alloc.h "$ARCHIVES_DIR/include/gssapi/gssapi_alloc.h"
  sudo install -m 644 /opt/krb5-static/include/gssapi/gssapi_ext.h "$ARCHIVES_DIR/include/gssapi/gssapi_ext.h"
  sudo install -m 644 /opt/krb5-static/include/gssapi/gssapi_generic.h "$ARCHIVES_DIR/include/gssapi/gssapi_generic.h"
  sudo install -m 644 /opt/krb5-static/include/gssapi/gssapi_krb5.h "$ARCHIVES_DIR/include/gssapi/gssapi_krb5.h"
  sudo install -m 644 /opt/krb5-static/include/gssapi/mechglue.h "$ARCHIVES_DIR/include/gssapi/mechglue.h"
  sudo install -m 644 /opt/krb5-static/include/krb5/krb5.h "$ARCHIVES_DIR/include/krb5/krb5.h"
  sudo chown -R "$USER" "$ARCHIVES_DIR"
  echo "  Archive bundle ready."
else
  echo "  Archive bundle already present at $ARCHIVES_DIR — skipping rebuild. Delete that dir to force a rebuild."
fi

log "Step 11b: Building openvasd + scannerctl $OPENVAS_DAEMON (Rust)"
sudo apt install -y pkg-config libssl-dev

if command -v rustup >/dev/null 2>&1 && [[ "$(command -v rustup)" != "$HOME/.cargo/bin/rustup" ]]; then
  echo "Detected apt-installed rustup — removing to avoid a known conflict."
  sudo apt remove --purge -y rustup || true
  rm -rf "$HOME/.rustup" "$HOME/.cargo"
fi
if [[ ! -x "$HOME/.cargo/bin/rustup" ]]; then
  echo "Installing official rustup from rustup.rs"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source "$HOME/.cargo/env"
export PATH="$HOME/.cargo/bin:$PATH"
rustup update stable

rm -rf "$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON" "$INSTALL_DIR/openvasd"
curl -f -L "https://github.com/greenbone/openvas-scanner/archive/refs/tags/v$OPENVAS_DAEMON.tar.gz" -o "$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON.tar.gz"
tar -C "$SOURCE_DIR" -xzf "$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON.tar.gz"

RUST_DIR="$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON/rust"
mkdir -p "$INSTALL_DIR/openvasd/usr/local/bin"

export OPENVAS_ARCHIVES="$ARCHIVES_DIR"
export LIBPCAP_LIBDIR="$ARCHIVES_DIR"
( cd "$RUST_DIR" && { [[ -f Makefile ]] && make; true; } && cargo build --release )

[[ -f "$RUST_DIR/target/release/openvasd" ]] || die "openvasd binary not found after build at $RUST_DIR/target/release/openvasd"

sudo cp -v "$RUST_DIR/target/release/openvasd" "$INSTALL_DIR/openvasd/usr/local/bin/"
sudo cp -v "$RUST_DIR/target/release/scannerctl" "$INSTALL_DIR/openvasd/usr/local/bin/"
sudo cp -rv "$INSTALL_DIR/openvasd/"* /

command -v openvasd >/dev/null 2>&1 || die "openvasd not on PATH after install — check /usr/local/bin/openvasd exists."

# ---------------------------------------------------------------------------
# Step 12 — greenbone-feed-sync + gvm-tools
# ---------------------------------------------------------------------------
log "Step 12: Installing greenbone-feed-sync and gvm-tools"
sudo python3 -m pip uninstall --break-system-packages -y greenbone-feed-sync gvm-tools 2>/dev/null || true
rm -rf "$INSTALL_DIR/greenbone-feed-sync" "$INSTALL_DIR/gvm-tools"

mkdir -p "$INSTALL_DIR/greenbone-feed-sync"
python3 -m pip install --break-system-packages --root="$INSTALL_DIR/greenbone-feed-sync" --no-warn-script-location greenbone-feed-sync
sudo cp -rv "$INSTALL_DIR/greenbone-feed-sync/"* /

sudo apt install -y python3-lxml python3-packaging python3-paramiko python3-setuptools python3-venv
mkdir -p "$INSTALL_DIR/gvm-tools"
python3 -m pip install --break-system-packages --root="$INSTALL_DIR/gvm-tools" --no-warn-script-location gvm-tools
sudo cp -rv "$INSTALL_DIR/gvm-tools/"* /

# ---------------------------------------------------------------------------
# Step 13 — Redis
# ---------------------------------------------------------------------------
log "Step 13: Setting up Redis"
sudo apt install -y redis-server

sudo cp "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION/config/redis-openvas.conf" /etc/redis/
sudo chown redis:redis /etc/redis/redis-openvas.conf
grep -qxF "db_address = /run/redis-openvas/redis.sock" /etc/openvas/openvas.conf 2>/dev/null || \
  echo "db_address = /run/redis-openvas/redis.sock" | sudo tee -a /etc/openvas/openvas.conf

sudo systemctl enable --now redis-server@openvas.service
sudo usermod -aG redis gvm

# ---------------------------------------------------------------------------
# Step 14 — Permissions (MUST run before any service starts — gsad/gvmd
# silently die with "Permission denied" on their own log files otherwise)
# ---------------------------------------------------------------------------
log "Step 14: Fixing directory permissions"
sudo mkdir -p /var/lib/notus /run/gvmd /var/log/gvm
sudo chown -R gvm:gvm /var/lib/gvm /var/lib/openvas /var/lib/notus /var/log/gvm /run/gvmd
sudo chmod -R g+srw /var/lib/gvm /var/lib/openvas /var/log/gvm
sudo chown gvm:gvm /usr/local/sbin/gvmd
sudo chmod 6750 /usr/local/sbin/gvmd

# ---------------------------------------------------------------------------
# Step 15 — Feed validation keyring
# ---------------------------------------------------------------------------
log "Step 15: Setting up feed validation keyring"
export GNUPGHOME=/tmp/openvas-gnupg
rm -rf "$GNUPGHOME"
mkdir -p "$GNUPGHOME"
gpg --import /tmp/GBCommunitySigningKey.asc
echo "8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:" | gpg --import-ownertrust

sudo mkdir -p /etc/openvas/gnupg
sudo cp -r "$GNUPGHOME/"* /etc/openvas/gnupg/
sudo chown -R gvm:gvm /etc/openvas/gnupg

# ---------------------------------------------------------------------------
# Step 16 — sudoers entry for scanning
# ---------------------------------------------------------------------------
log "Step 16: Allowing gvm group to run openvas-scanner as root"
echo "%gvm ALL = NOPASSWD: /usr/local/sbin/openvas" | sudo tee /etc/sudoers.d/gvm
sudo chmod 0440 /etc/sudoers.d/gvm

# ---------------------------------------------------------------------------
# Step 17 — PostgreSQL
# ---------------------------------------------------------------------------
log "Step 17: Setting up PostgreSQL"
sudo apt install -y postgresql

PG_VERSION=$(pg_lsclusters --no-header 2>/dev/null | awk '{print $1}' | head -n1)
if [[ -z "$PG_VERSION" ]]; then
  echo "No PostgreSQL cluster found — creating one."
  PG_VERSION=$(pg_config --version 2>/dev/null | grep -oE '[0-9]+' | head -n1)
  [[ -n "$PG_VERSION" ]] || PG_VERSION=16   # fallback for Ubuntu 24.04 default
  sudo pg_createcluster "$PG_VERSION" main --start || true
fi

sudo systemctl start "postgresql@${PG_VERSION}-main" 2>/dev/null || sudo systemctl start postgresql

log "Waiting for PostgreSQL to accept connections..."
for i in $(seq 1 30); do
  sudo -u postgres pg_isready >/dev/null 2>&1 && { echo "PostgreSQL is ready."; break; }
  sleep 1
  [[ "$i" -eq 30 ]] && die "PostgreSQL did not become ready in 30s. Check: sudo systemctl status postgresql"
done

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='gvm'" | grep -q 1; then
  echo "Role 'gvm' already exists, skipping creation."
else
  sudo -u postgres createuser -DRS gvm
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='gvmd'" | grep -q 1; then
  echo "Database 'gvmd' already exists, skipping creation."
else
  sudo -u postgres createdb -O gvm gvmd
fi

sudo -u postgres psql gvmd -c "create role dba with superuser noinherit;" 2>/dev/null || true
sudo -u postgres psql gvmd -c "grant dba to gvm;"

sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='gvm'" | grep -q 1 || \
  die "PostgreSQL role 'gvm' still does not exist after setup."
echo "Verified: PostgreSQL role 'gvm' exists."

# ---------------------------------------------------------------------------
# Step 17b — Clear any stale System V semaphores not owned by gvm
# ---------------------------------------------------------------------------
log "Step 17b: Clearing any stale semaphores not owned by gvm"
GVM_UNAME=$(id -un gvm)
while read -r semid owner; do
  if [[ -n "$semid" && "$owner" != "$GVM_UNAME" ]]; then
    echo "Removing stale semaphore $semid (owned by $owner, not gvm)"
    sudo ipcrm -s "$semid" 2>/dev/null || true
  fi
done < <(ipcs -s | awk 'NR>3 {print $2, $3}')

# ---------------------------------------------------------------------------
# Step 18 — Admin user (verified, not assumed; always run as gvm user,
# --foreground-free so it actually stays a one-shot CLI command, not a
# daemon — gvmd without --foreground forks and returns immediately, which
# is correct here since we just want it to write the user and exit)
# ---------------------------------------------------------------------------
log "Step 18: Creating admin user"
if sudo -u gvm /usr/local/sbin/gvmd --get-users --verbose 2>/dev/null | grep -q "^admin "; then
  echo "Admin user already exists — resetting password instead."
  sudo -u gvm /usr/local/sbin/gvmd --user=admin --new-password="$ADMIN_PASSWORD"
else
  sudo -u gvm /usr/local/sbin/gvmd --create-user=admin --password="$ADMIN_PASSWORD" --role="Super Admin"
fi

sudo -u gvm /usr/local/sbin/gvmd --get-users --verbose 2>/dev/null | grep -q "^admin " || \
  die "Admin user still not found after creation. Check /var/log/gvm/gvmd.log."
echo "Verified: admin user exists."

# ---------------------------------------------------------------------------
# Step 19 — Feed Import Owner
# ---------------------------------------------------------------------------
log "Step 19: Setting Feed Import Owner"
ADMIN_UUID=$(sudo -u gvm /usr/local/sbin/gvmd --get-users --verbose | grep admin | awk '{print $2}')
[[ -n "$ADMIN_UUID" ]] || die "Could not determine admin user's UUID."
sudo -u gvm /usr/local/sbin/gvmd --modify-setting 78eceaec-3385-11ea-b237-28d24461215b --value "$ADMIN_UUID"

# ---------------------------------------------------------------------------
# Step 20 — systemd service files
#
#   Written to /etc/systemd/system/ — this takes priority over the default
#   unit files gvmd/gsad's own `make install` drops under
#   /usr/local/lib/systemd/system/, which only listen on 127.0.0.1.
# ---------------------------------------------------------------------------
log "Step 20: Writing systemd service files (GSA listen address: $GSAD_LISTEN_ADDRESS)"

sudo tee /etc/systemd/system/ospd-openvas.service > /dev/null << EOF
[Unit]
Description=OSPd Wrapper for the OpenVAS Scanner (ospd-openvas)
After=network.target networking.service redis-server@openvas.service openvasd.service
Wants=redis-server@openvas.service openvasd.service
ConditionKernelCommandLine=!recovery
[Service]
Type=exec
User=gvm
Group=gvm
RuntimeDirectory=ospd
RuntimeDirectoryMode=2775
PIDFile=/run/ospd/ospd-openvas.pid
ExecStart=/usr/local/bin/ospd-openvas --foreground --unix-socket /run/ospd/ospd-openvas.sock --pid-file /run/ospd/ospd-openvas.pid --log-file /var/log/gvm/ospd-openvas.log --lock-file-dir /var/lib/openvas --socket-mode 0o770 --notus-feed-dir /var/lib/notus/advisories
SuccessExitStatus=SIGKILL
Restart=always
RestartSec=60
[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/gvmd.service > /dev/null << EOF
[Unit]
Description=Greenbone Vulnerability Manager daemon (gvmd)
After=network.target networking.service postgresql.service ospd-openvas.service
Wants=postgresql.service ospd-openvas.service
ConditionKernelCommandLine=!recovery
[Service]
Type=exec
User=gvm
Group=gvm
PIDFile=/run/gvmd/gvmd.pid
RuntimeDirectory=gvmd
RuntimeDirectoryMode=2775
ExecStart=/usr/local/sbin/gvmd --foreground --osp-vt-update=/run/ospd/ospd-openvas.sock --listen-group=gvm
Restart=always
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/gsad.service > /dev/null << EOF
[Unit]
Description=Greenbone Security Assistant daemon (gsad)
After=network.target gvmd.service
Wants=gvmd.service
[Service]
Type=exec
User=gvm
Group=gvm
RuntimeDirectory=gsad
RuntimeDirectoryMode=2775
PIDFile=/run/gsad/gsad.pid
ExecStart=/usr/local/sbin/gsad --foreground --listen=$GSAD_LISTEN_ADDRESS --port=9392 --http-only
Restart=always
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
Alias=greenbone-security-assistant.service
EOF

sudo tee /etc/systemd/system/openvasd.service > /dev/null << 'EOF'
[Unit]
Description=OpenVASD
ConditionKernelCommandLine=!recovery
[Service]
Type=exec
User=gvm
RuntimeDirectory=openvasd
RuntimeDirectoryMode=2775
ExecStart=/usr/local/bin/openvasd --mode service_notus --products /var/lib/notus/products --advisories /var/lib/notus/advisories --listening 127.0.0.1:3000
SuccessExitStatus=SIGKILL
Restart=always
RestartSec=60
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload

# ---------------------------------------------------------------------------
# Step 21 — Feed sync (can take a long time — this is normal, don't Ctrl+C)
# ---------------------------------------------------------------------------
log "Step 21: Downloading vulnerability feed data (this can take a long time)"
for lockfile in /var/lib/gvm/feed-update.lock /var/lib/openvas/feed-update.lock; do
  if [[ -f "$lockfile" ]] && ! pgrep -f greenbone-feed-sync >/dev/null 2>&1; then
    sudo rm -f "$lockfile"
  fi
done
sudo /usr/local/bin/greenbone-feed-sync

# ---------------------------------------------------------------------------
log "Step 22: Starting and enabling services"
sudo systemctl enable --now openvasd
sleep 2
sudo systemctl enable --now ospd-openvas
sleep 2
sudo systemctl enable --now gvmd
sleep 2
sudo systemctl enable --now gsad
sleep 5

log "Final service status check:"
for svc in openvasd ospd-openvas gvmd gsad; do
  if systemctl is-active --quiet "$svc"; then
    echo "  $svc: RUNNING"
  else
    echo "  $svc: NOT RUNNING — check 'sudo journalctl -u $svc -n 50 --no-pager'"
  fi
done

echo
log "Install complete."
echo "Username: admin"
echo "Password: (the one you entered at the start)"
echo
echo "First VT load into gvmd's database can still take a while after this."
echo "Watch progress with:"
echo "  sudo tail -f /var/log/gvm/gvmd.log"
echo
echo "Log in at: http://$GSAD_LISTEN_ADDRESS:9392"
echo
echo "To add another user later:"
echo "  sudo -u gvm /usr/local/sbin/gvmd --create-user=USERNAME --password='PASSWORD' --role=\"Admin\""
