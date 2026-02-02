#!/bin/bash
################################################################################
# Asterisk 22 – Rocky10 SAFE INSTALL
# WebRTC + OPUS + SRTP + FFmpeg + BCG729 (Fallback to asterisk-g72x)
################################################################################

set +e  # Continue script execution even if some commands fail

# Configuration paths
ASTERISK_BIN="/usr/sbin/asterisk"
ASTERISK_SRC="/usr/src/asterisk-22"
ASTERISK_MODULES="/usr/lib/asterisk/modules"
ERROR_LOG="/tmp/asterisk_install_errors.log"

# Color codes for terminal output
BLUE="\e[34m"; GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; RESET="\e[0m"
log(){ echo -e "${BLUE}[INFO]${RESET} $1"; }
ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
fail(){ echo -e "${RED}[ERR]${RESET} $1"; }

# Trap for error logging
trap 'echo "Error at line $LINENO" >> "$ERROR_LOG"' ERR

################################################################################
# CHECK EXISTING INSTALLATION AND ASK USER
################################################################################
log "Checking for existing Asterisk installation..."

REBUILD="yes"
USE_EXISTING_BUILD="no"
BUILD_G729_FALLBACK="ask"

if [ -x "$ASTERISK_BIN" ]; then
    # Show current version if Asterisk is already installed
    log "Existing Asterisk installation found:"
    $ASTERISK_BIN -x "core show version" 2>/dev/null | head -n1 || true
    
    echo ""
    echo "================================================================================"
    echo "EXISTING ASTERISK INSTALLATION DETECTED"
    echo "================================================================================"
    echo ""
    
    # Ask about reusing existing Asterisk build
    while true; do
        read -p "Do you want to rebuild Asterisk again? [y/N]: " REUSE
        REUSE=${REUSE:-N}
        
        case $REUSE in
            [Nn]* )
                REBUILD="no"
                USE_EXISTING_BUILD="yes"
                log "Will reuse existing Asterisk installation"
                break
                ;;
            [Yy]* )
                REBUILD="yes"
                USE_EXISTING_BUILD="no"
                log "Will rebuild Asterisk from source"
                break
                ;;
            * )
                echo "Please answer yes (y) or no (n)"
                ;;
        esac
    done
    
    # Check for existing G.729 modules
    if [ -f "$ASTERISK_MODULES/res_g729.so" ] || \
       [ -f "$ASTERISK_MODULES/codec_g729.so" ]; then
        echo ""
        log "Existing G.729 codec modules found:"
        [ -f "$ASTERISK_MODULES/res_g729.so" ] && echo "  • res_g729.so"
        [ -f "$ASTERISK_MODULES/codec_g729.so" ] && echo "  • codec_g729.so"
        
        while true; do
            read -p "Do you want to rebuild G.729 support? [y/N]: " REBUILD_G729
            REBUILD_G729=${REBUILD_G729:-N}
            
            case $REBUILD_G729 in
                [Yy]* )
                    BUILD_G729_FALLBACK="yes"
                    log "Will rebuild G.729 support"
                    break
                    ;;
                [Nn]* )
                    BUILD_G729_FALLBACK="no"
                    log "Will use existing G.729 modules"
                    break
                    ;;
                * )
                    echo "Please answer yes (y) or no (n)"
                    ;;
            esac
        done
    else
        BUILD_G729_FALLBACK="yes"
    fi
else
    log "No existing Asterisk installation found"
    REBUILD="yes"
    BUILD_G729_FALLBACK="yes"
fi

echo ""

################################################################################
# DATABASE CREDENTIALS CONFIGURATION
################################################################################
# Secure default password - change in production!
DEFAULT_PASS="Pass1word!234"

log "Configuring database credentials..."
read -p "MariaDB root password (if needed) [$DEFAULT_PASS]: " DB_ROOT_PASS
DB_ROOT_PASS=${DB_ROOT_PASS:-$DEFAULT_PASS}

read -p "Asterisk database username [asteriskuser]: " DB_USER
DB_USER=${DB_USER:-asteriskuser}

read -p "Asterisk database password [$DEFAULT_PASS]: " DB_PASS
DB_PASS=${DB_PASS:-$DEFAULT_PASS}

################################################################################
# REPOSITORY CONFIGURATION
################################################################################
log "Configuring required repositories..."

# Install EPEL and enable CodeReady Builder (CRB) repository
dnf install -y epel-release dnf-plugins-core
dnf config-manager --set-enabled crb

# Add RPM Fusion for ffmpeg (required for MP3 support)
if ! rpm -q rpmfusion-free-release &>/dev/null; then
    log "Adding RPM Fusion repository..."
    dnf install -y \
    https://download1.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm
fi

################################################################################
# INSTALL DEPENDENCIES
################################################################################
log "Installing system dependencies..."

dnf install -y \
wget git net-tools gcc gcc-c++ make cmake \
openssl-devel libuuid-devel jansson-devel libxml2-devel \
sqlite-devel libedit-devel libxslt-devel unixODBC-devel \
mariadb-server mariadb-devel mariadb-connector-odbc \
opus-devel libogg-devel libvorbis-devel \
libsrtp-devel ffmpeg-free ffmpeg-free-devel

# Additional dependencies for G.729 if needed
if [[ "$BUILD_G729_FALLBACK" == "yes" ]]; then
    log "Installing additional dependencies for G.729 codec..."
    dnf install -y autoconf automake libtool
fi

# Start and enable MariaDB service
systemctl enable --now mariadb
ok "All dependencies installed successfully"

################################################################################
# SECURE MARIADB ROOT AUTHENTICATION
################################################################################
log "Configuring MariaDB root authentication..."

# Check current authentication plugin for root user
ROOT_PLUGIN=$(sudo mysql -Nse \
"SELECT plugin FROM mysql.user WHERE User='root' AND Host='localhost';" 2>/dev/null || true)

if [[ "$ROOT_PLUGIN" == "mysql_native_password" ]]; then
    ok "MariaDB root password already configured"
else
    log "Configuring MariaDB root password authentication..."
    sudo mysql <<EOF
ALTER USER 'root'@'localhost'
IDENTIFIED VIA mysql_native_password
USING PASSWORD('$DB_ROOT_PASS');
FLUSH PRIVILEGES;
EOF
    ok "MariaDB root authentication configured"
fi

################################################################################
# CREATE ASTERISK DATABASE AND USER
################################################################################
log "Creating Asterisk database and user..."

sudo mysql -u root -p"$DB_ROOT_PASS" <<EOF
CREATE DATABASE IF NOT EXISTS asterisk;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON asterisk.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
ok "Database and user created successfully"

################################################################################
# DOWNLOAD AND BUILD ASTERISK 22 (IF REQUESTED)
################################################################################
if [[ "$REBUILD" == "yes" ]]; then
    log "Downloading and building Asterisk 22..."
    
    # Create and enter source directory
    cd /usr/src || exit 1
    rm -rf asterisk-22
    
    # Download latest Asterisk 22
    wget -q https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22-current.tar.gz
    tar xzf asterisk-22-current.tar.gz
    mv asterisk-22*/ asterisk-22
    cd asterisk-22 || exit 1
    
    # Install prerequisites and MP3 decoder
    contrib/scripts/install_prereq install
    contrib/scripts/get_mp3_source.sh
    
    # Configure with essential modules
    ./configure \
        --with-pjproject-bundled \
        --with-res_odbc \
        --with-unixodbc \
        --with-ssl \
        --with-srtp
    
    make menuselect.makeopts
    
    # Configure modules selection
    # Note: res_g729 is disabled - will use asterisk-g72x fallback
    menuselect/menuselect \
        --enable codec_opus \
        --enable codec_ulaw \
        --enable codec_alaw \
        --enable format_mp3 \
        --enable chan_pjsip \
        --enable res_pjsip \
        --enable res_rtp_asterisk \
        --enable app_confbridge \
        --disable chan_iax2 \
        --disable chan_dahdi \
        menuselect.makeopts
    
    # Compile and install
    make -j$(nproc)
    make install
    make samples
    ldconfig  # Update library cache
    
    ok "Asterisk 22 built and installed successfully"
else
    log "Skipping Asterisk rebuild - using existing installation"
fi

################################################################################
# G.729 CODEC HANDLING (FALLBACK TO ASTERISK-G72X) - CONDITIONAL
################################################################################
if [[ "$BUILD_G729_FALLBACK" == "yes" ]]; then
    log "Building G.729 codec support..."
    
    # Check if standard res_g729 module exists
    if [ -f "$ASTERISK_MODULES/res_g729.so" ]; then
        ok "Standard res_g729 module already exists"
    else
        log "Building Bcg729 + asterisk-g72x..."
        
        # 1️⃣ Build and install Bcg729 library
        log "Building Bcg729 library..."
        cd "$ASTERISK_SRC" || exit 1
        
        # Check if bcg729 already exists
        if [ -d "bcg729" ]; then
            log "Existing bcg729 directory found"
            read -p "Rebuild bcg729? [y/N]: " REBUILD_BCG729
            REBUILD_BCG729=${REBUILD_BCG729:-N}
            
            if [[ $REBUILD_BCG729 =~ ^[Yy]$ ]]; then
                rm -rf bcg729
                git clone https://github.com/BelledonneCommunications/bcg729.git
            fi
        else
            git clone https://github.com/BelledonneCommunications/bcg729.git
        fi
        
        cd bcg729 || exit 1
        mkdir -p build
        cd build || exit 1
        
        cmake -DCMAKE_POSITION_INDEPENDENT_CODE=ON .. || fail "Bcg729 cmake failed"
        make -j$(nproc) || fail "Bcg729 compilation failed"
        make install || fail "Bcg729 installation failed"
        
        # 2️⃣ Build and install asterisk-g72x (G.729 implementation)
        log "Building asterisk-g72x..."
        cd "$ASTERISK_SRC" || exit 1
        
        # Check if asterisk-g72x already exists
        if [ -d "asterisk-g72x" ]; then
            log "Existing asterisk-g72x directory found"
            read -p "Rebuild asterisk-g72x? [y/N]: " REBUILD_G72X
            REBUILD_G72X=${REBUILD_G72X:-N}
            
            if [[ $REBUILD_G72X =~ ^[Yy]$ ]]; then
                rm -rf asterisk-g72x
                git clone https://github.com/arkadijs/asterisk-g72x.git
            fi
        else
            git clone https://github.com/arkadijs/asterisk-g72x.git
        fi
        
        cd asterisk-g72x || exit 1
        
        # Prepare build environment
        make clean || true
        ./autogen.sh || fail "asterisk-g72x autogen failed"
        
        # Configure with Bcg729 support
        ./configure \
          --with-bcg729 \
          --with-bcg729-prefix=/usr/local \
          CFLAGS="-I$ASTERISK_SRC/include" \
          LDFLAGS="-L/usr/local/lib" || fail "asterisk-g72x configure failed"
        
        make -j$(nproc) || fail "asterisk-g72x compilation failed"
        make install || fail "asterisk-g72x installation failed"
        
        ok "G.729 codec support installed via asterisk-g72x"
    fi
else
    log "Skipping G.729 codec build - using existing modules"
fi

################################################################################
# CREATE ASTERISK USER AND SET PERMISSIONS
################################################################################
log "Configuring Asterisk user and permissions..."

# Create asterisk user if it doesn't exist
id asterisk &>/dev/null || useradd -r -s /sbin/nologin asterisk

# Create necessary directories
mkdir -p /var/run/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk

# Check if directories already have correct permissions
log "Setting ownership for Asterisk directories..."
chown -R asterisk:asterisk \
  /etc/asterisk \
  /var/lib/asterisk \
  /var/log/asterisk \
  /var/spool/asterisk \
  /usr/lib/asterisk \
  /var/run/asterisk 2>/dev/null || true

################################################################################
# CONFIGURE SYSTEMD SERVICE (ALWAYS UPDATE)
################################################################################
log "Configuring Asterisk systemd service..."

cat >/etc/systemd/system/asterisk.service <<EOF
[Unit]
Description=Asterisk PBX
After=network.target mariadb.service
Wants=mariadb.service

[Service]
Type=simple
User=asterisk
Group=asterisk
ExecStart=/usr/sbin/asterisk -f -C /etc/asterisk/asterisk.conf -U asterisk
ExecReload=/usr/sbin/asterisk -rx "core reload"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable asterisk

################################################################################
# FIX RUN DIRECTORY PERMISSIONS
################################################################################
log "Configuring Asterisk run directory..."

AST_RUN_DIR="/var/run/asterisk"
mkdir -p "$AST_RUN_DIR"
chown -R asterisk:asterisk "$AST_RUN_DIR"
chmod 775 "$AST_RUN_DIR"

# Ensure run directory is configured in asterisk.conf
ASTERISK_CONF="/etc/asterisk/asterisk.conf"
if [ -f "$ASTERISK_CONF" ]; then
    if ! grep -q "^astrundir = $AST_RUN_DIR" "$ASTERISK_CONF"; then
        log "Setting run directory in $ASTERISK_CONF"
        sed -i "/^\[directories\]/a astrundir = $AST_RUN_DIR" "$ASTERISK_CONF"
    fi
else
    # Create minimal asterisk.conf if it doesn't exist
    cat > "$ASTERISK_CONF" <<EOF
[directories]
astrundir = $AST_RUN_DIR
EOF
fi

################################################################################
# CONFIGURE ODBC FOR DATABASE CONNECTIVITY
################################################################################
log "Configuring ODBC database connectivity..."

# Check if ODBC configurations already exist
if [ -f "/etc/asterisk/res_odbc.conf" ]; then
    log "Existing res_odbc.conf found"
    read -p "Overwrite ODBC configuration? [y/N]: " OVERWRITE_ODBC
    OVERWRITE_ODBC=${OVERWRITE_ODBC:-N}
else
    OVERWRITE_ODBC="yes"
fi

if [[ $OVERWRITE_ODBC =~ ^[Yy]$ ]]; then
    # Asterisk ODBC configuration
    cat >/etc/asterisk/res_odbc.conf <<EOF
[asterisk]
enabled => yes
dsn => asterisk
username => $DB_USER
password => $DB_PASS
pre-connect => yes
EOF
    ok "ODBC configuration updated"
fi

if [ -f "/etc/odbc.ini" ]; then
    log "Existing odbc.ini found"
    read -p "Overwrite system ODBC configuration? [y/N]: " OVERWRITE_SYSTEM_ODBC
    OVERWRITE_SYSTEM_ODBC=${OVERWRITE_SYSTEM_ODBC:-N}
else
    OVERWRITE_SYSTEM_ODBC="yes"
fi

if [[ $OVERWRITE_SYSTEM_ODBC =~ ^[Yy]$ ]]; then
    # System ODBC configuration
    cat >/etc/odbc.ini <<EOF
[asterisk]
Driver = MariaDB
Server = localhost
Database = asterisk
User = $DB_USER
Password = $DB_PASS
Port = 3306
EOF
    ok "System ODBC configuration updated"
fi

################################################################################
# CONFIGURE FIREWALL FOR ASTERISK PORTS
################################################################################
log "Configuring firewall rules..."

if command -v firewall-cmd &>/dev/null; then
    # Check existing firewall rules
    EXISTING_RULES=$(firewall-cmd --list-all 2>/dev/null)
    
    # Ask before adding firewall rules
    echo ""
    echo "Firewall configuration:"
    echo "  • SIP: 5060/udp and 5060/tcp"
    echo "  • RTP: 10000-20000/udp"
    echo "  • HTTPS: 443/tcp"
    echo ""
    
    read -p "Configure firewall rules? [Y/n]: " CONFIGURE_FIREWALL
    CONFIGURE_FIREWALL=${CONFIGURE_FIREWALL:-Y}
    
    if [[ $CONFIGURE_FIREWALL =~ ^[Yy]$ ]]; then
        firewall-cmd --permanent --add-port=5060/udp --description="SIP"
        firewall-cmd --permanent --add-port=5060/tcp --description="SIP TLS"
        firewall-cmd --permanent --add-port=10000-20000/udp --description="RTP Media"
        firewall-cmd --permanent --add-service=https --description="Web Interface"
        firewall-cmd --reload
        ok "Firewall configured"
    else
        warn "Firewall configuration skipped"
    fi
else
    warn "firewalld not found - ensure ports 5060/udp and 10000-20000/udp are open"
fi

################################################################################
# SELINUX CONFIGURATION (IF APPLICABLE)
################################################################################
if command -v getenforce &>/dev/null; then
    SELINUX_STATUS=$(getenforce)
    if [[ "$SELINUX_STATUS" != "Disabled" ]]; then
        warn "SELinux is enabled - configuring for Asterisk..."
        
        echo ""
        echo "SELinux configuration options:"
        echo "  1. Set permissive mode (temporary, reverts on reboot)"
        echo "  2. Set permissive mode permanently"
        echo "  3. Skip SELinux configuration (not recommended)"
        echo ""
        
        read -p "Choose SELinux option [1/2/3]: " SELINUX_OPTION
        SELINUX_OPTION=${SELINUX_OPTION:-1}
        
        case $SELINUX_OPTION in
            1)
                setenforce 0
                ok "SELinux set to permissive mode (temporary)"
                ;;
            2)
                sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
                setenforce 0
                ok "SELinux set to permissive mode permanently"
                warn "Requires reboot to take full effect"
                ;;
            3)
                warn "SELinux configuration skipped"
                warn "Asterisk may not function properly with SELinux enforcing"
                ;;
            *)
                setenforce 0
                ok "SELinux set to permissive mode (temporary)"
                ;;
        esac
    fi
fi

################################################################################
# START ASTERISK AND VERIFY INSTALLATION
################################################################################
log "Starting Asterisk service..."

# Check if Asterisk is already running
if systemctl is-active --quiet asterisk; then
    log "Asterisk is already running, restarting..."
    systemctl restart asterisk
else
    systemctl start asterisk
fi

# Wait for service to start
sleep 5

if systemctl is-active --quiet asterisk; then
    ok "Asterisk service is running"
    
    # Display version information
    echo ""
    log "Asterisk version:"
    sudo -u asterisk asterisk -rx "core show version" 2>/dev/null || true
    
    # Display loaded codecs
    echo ""
    log "Loaded codecs:"
    sudo -u asterisk asterisk -rx "core show codecs" 2>/dev/null || true
    
    # Display loaded modules
    echo ""
    log "G.729 modules status:"
    if [ -f "$ASTERISK_MODULES/res_g729.so" ]; then
        echo "  ✓ res_g729.so (standard)"
    fi
    if [ -f "$ASTERISK_MODULES/codec_g729.so" ]; then
        echo "  ✓ codec_g729.so (asterisk-g72x)"
    fi
    
else
    fail "Asterisk failed to start. Check logs: journalctl -u asterisk"
    exit 1
fi

################################################################################
# INSTALLATION COMPLETE
################################################################################
echo ""
ok "╔══════════════════════════════════════════════════════════════╗"
ok "║           ASTERISK INSTALLATION COMPLETE                     ║"
ok "╚══════════════════════════════════════════════════════════════╝"
echo ""

log "Testing ODBC connection..."
isql -v asterisk $DB_USER $DB_PASS <<< "quit" && ok "ODBC connection successful" || fail "ODBC connection failed"

log "Installation summary:"
echo "  • Asterisk: $([ "$REBUILD" == "yes" ] && echo "Rebuilt" || echo "Existing installation reused")"
echo "  • G.729 codec: $([ "$BUILD_G729_FALLBACK" == "yes" ] && echo "Built" || echo "Existing modules used")"
echo "  • Database: asterisk (user: $DB_USER)"
echo "  • SIP Port: 5060/udp"
echo "  • RTP Range: 10000-20000/udp"
echo ""

log "Management commands:"
echo "  • Connect to CLI: sudo -u asterisk asterisk -r"
echo "  • Check status: systemctl status asterisk"
echo "  • View logs: journalctl -u asterisk -f"
echo ""

log "Next steps:"
echo "  1. Configure /etc/asterisk/pjsip.conf for SIP endpoints"
echo "  2. Configure /etc/asterisk/extensions.conf for dialplan"
echo "  3. Import database schema: mysql -u root -p asterisk < SQL files"
echo ""

warn "Security recommendations:"
echo "  • Change default passwords in production"
echo "  • Configure TLS for SIP connections"
echo "  • Set up proper firewall rules"
echo "  • Configure SELinux policies if enabled"
echo ""

# Cleanup
if [[ "$REBUILD" == "yes" ]]; then
    rm -f /usr/src/asterisk-22-current.tar.gz 2>/dev/null || true
fi

log "Error log saved to: $ERROR_LOG"
exit 0
