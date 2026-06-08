#!/bin/bash
set -euo pipefail

# ============================================================
# USER PARAMETERS — will be prompted at runtime if left empty
# ============================================================
ZABBIX_DB_NAME=""
ZABBIX_DB_USER=""
ZABBIX_DB_PASS=""
WEB_SERVER_IP=""       # monitored server IP — allowed to reach port 10051
SSH_PORT=""            # default: 55022

# Ubuntu version for Zabbix repo (e.g. ubuntu24.04, ubuntu26.04)
UBUNTU_CODEVER="ubuntu26.04"
ZABBIX_VERSION="7.4"

# ============================================================
# DERIVED
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"

# ============================================================
# HELPERS
# ============================================================
info()  { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }

require_configs() {
    local missing=0
    for f in sysctl-hardening.conf zabbix-jail.local; do
        [[ -f "${CONFIG_DIR}/${f}" ]] || { warn "Missing: config/${f}"; missing=1; }
    done
    [[ $missing -eq 0 ]] || die "Missing config files. See README.md."
}

set_param() {
    local file="$1" regex="$2" replacement="$3"
    if grep -qE "$regex" "$file"; then
        sed -i -E "s|${regex}|${replacement}|" "$file"
    else
        warn "Pattern not found in $file: $regex — skipping"
    fi
}

# ============================================================
# PROMPTS
# ============================================================
prompt_params() {
    echo ""
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║       Zabbix Server Setup — Config       ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""

    if [[ -z "$ZABBIX_DB_NAME" ]]; then
        read -rp "  Zabbix DB name     [zabbix]: " ZABBIX_DB_NAME
        ZABBIX_DB_NAME="${ZABBIX_DB_NAME:-zabbix}"
    fi

    if [[ -z "$ZABBIX_DB_USER" ]]; then
        read -rp "  Zabbix DB user     [zabbix]: " ZABBIX_DB_USER
        ZABBIX_DB_USER="${ZABBIX_DB_USER:-zabbix}"
    fi

    if [[ -z "$ZABBIX_DB_PASS" ]]; then
        while true; do
            read -rsp "  Zabbix DB password: " ZABBIX_DB_PASS; echo
            [[ -n "$ZABBIX_DB_PASS" ]] && break
            warn "Password cannot be empty."
        done
    fi

    if [[ -z "$WEB_SERVER_IP" ]]; then
        while true; do
            read -rp "  Monitored web server IP: " WEB_SERVER_IP
            [[ -n "$WEB_SERVER_IP" ]] && break
            warn "IP cannot be empty."
        done
    fi

    if [[ -z "$SSH_PORT" ]]; then
        read -rp "  SSH port           [55022]: " SSH_PORT
        SSH_PORT="${SSH_PORT:-55022}"
    fi

    echo ""
    info "Config summary:"
    echo "    DB name      : $ZABBIX_DB_NAME"
    echo "    DB user      : $ZABBIX_DB_USER"
    echo "    Web server IP: $WEB_SERVER_IP"
    echo "    SSH port     : $SSH_PORT"
    echo ""
    read -rp "  Proceed? [Y/n]: " confirm
    [[ "${confirm,,}" == "n" ]] && die "Aborted by user."
}

# ============================================================
# 1. SSH KEY GENERATION
# ============================================================
generate_ssh_key() {
    info "Generating SSH key pair for root..."

    local key_dir="/root/.ssh"
    local key_path="${key_dir}/zabbix_server_id_ed25519"

    mkdir -p "$key_dir"
    chmod 700 "$key_dir"

    if [[ -f "$key_path" ]]; then
        warn "Key already exists at ${key_path} — skipping generation."
    else
        ssh-keygen -t ed25519 -f "$key_path" -N "" -C "zabbix-server-root" -q
        ok "SSH key generated: ${key_path}"
    fi

    local pubkey
    pubkey=$(cat "${key_path}.pub")

    echo ""
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║                  ACTION REQUIRED — SSH KEY                  ║"
    echo "  ╠══════════════════════════════════════════════════════════════╣"
    echo "  ║                                                              ║"
    echo "  ║  Add this public key to the monitored web server:           ║"
    echo "  ║  /root/.ssh/authorized_keys                                 ║"
    echo "  ║                                                              ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  PUBLIC KEY:"
    echo "  $pubkey"
    echo ""
    echo "  Run this on the web server to add it:"
    echo "  echo '$pubkey' >> /root/.ssh/authorized_keys"
    echo ""
    echo "  PRIVATE KEY path on this server: ${key_path}"
    echo "  Connect using:"
    echo "  ssh -i ${key_path} -p ${SSH_PORT} root@${WEB_SERVER_IP}"
    echo ""

    read -rp "  Press Enter to continue after you have noted the key info..."
}

# ============================================================
# 2. PACKAGES
# ============================================================
install_packages() {
    info "Updating system and installing base packages..."
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq \
        curl wget vim ufw net-tools unzip \
        unattended-upgrades auditd fail2ban \
        apache2 mariadb-server \
        php php-mysql php-gd php-bcmath php-mbstring \
        php-xml php-ldap php-snmp php-curl php-zip \
        libapache2-mod-php

    info "Installing Zabbix ${ZABBIX_VERSION} repository..."
    local deb="zabbix-release_latest_${ZABBIX_VERSION}+${UBUNTU_CODEVER}_all.deb"
    local url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/${deb}"
    wget -q -O "/tmp/${deb}" "$url" \
        || die "Failed to download Zabbix repo package from: $url"
    dpkg -i "/tmp/${deb}"
    rm -f "/tmp/${deb}"

    apt-get update -qq
    apt-get install -y -qq \
        zabbix-server-mysql \
        zabbix-frontend-php \
        zabbix-apache-conf \
        zabbix-sql-scripts \
        zabbix-agent2

    ok "Packages installed."
}

# ============================================================
# 3. MARIADB — SECURE + ZABBIX DB
# ============================================================
configure_mariadb() {
    info "Securing MariaDB and creating Zabbix database..."

    mysql -u root << EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;
FLUSH PRIVILEGES;
EOF

    mysql -u root << EOF
CREATE DATABASE IF NOT EXISTS \`${ZABBIX_DB_NAME}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${ZABBIX_DB_USER}'@'localhost'
    IDENTIFIED BY '${ZABBIX_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${ZABBIX_DB_NAME}\`.* TO '${ZABBIX_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

    ok "MariaDB secured. DB '${ZABBIX_DB_NAME}' and user '${ZABBIX_DB_USER}' created."
}

# ============================================================
# 4. ZABBIX SCHEMA IMPORT
# ============================================================
import_zabbix_schema() {
    info "Importing Zabbix DB schema (this may take a minute)..."

    local table_count
    table_count=$(mysql -u root -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${ZABBIX_DB_NAME}';" \
        -s -N 2>/dev/null || echo 0)

    if [[ "$table_count" -gt 0 ]]; then
        warn "Zabbix DB already has tables — skipping schema import."
        return
    fi

    zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz \
        | mysql -u"${ZABBIX_DB_USER}" -p"${ZABBIX_DB_PASS}" "${ZABBIX_DB_NAME}" \
        || die "Schema import failed."

    ok "Zabbix schema imported."
}

# ============================================================
# 5. ZABBIX SERVER CONFIG
# ============================================================
configure_zabbix_server() {
    info "Configuring Zabbix server..."
    local conf="/etc/zabbix/zabbix_server.conf"
    cp -n "$conf" "${conf}.bak"

    set_param "$conf" \
        '^[#[:space:]]*DBPassword[[:space:]]*=.*' \
        "DBPassword=${ZABBIX_DB_PASS}"

    ok "Zabbix server config updated."
}

# ============================================================
# 6. SERVICES
# ============================================================
configure_services() {
    info "Enabling and starting services..."
    systemctl enable --now zabbix-server zabbix-agent2 apache2 mariadb

    info "Disabling unneeded services..."
    for svc in avahi-daemon cups bluetooth snapd; do
        systemctl disable --now "$svc" 2>/dev/null || true
    done
    apt-get purge -y -qq snapd 2>/dev/null || true

    ok "Services configured."
}

# ============================================================
# 7. KERNEL HARDENING
# ============================================================
kernel_hardening() {
    info "Applying kernel hardening via sysctl..."
    cp "${CONFIG_DIR}/sysctl-hardening.conf" /etc/sysctl.d/99-hardening.conf
    sysctl -p /etc/sysctl.d/99-hardening.conf > /dev/null
    ok "Kernel hardening applied."
}

# ============================================================
# 8. AUTO UPDATES
# ============================================================
configure_auto_updates() {
    info "Configuring unattended-upgrades..."
    echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true \
        | debconf-set-selections
    dpkg-reconfigure -f noninteractive unattended-upgrades

    local conf="/etc/apt/apt.conf.d/50unattended-upgrades"
    set_param "$conf" \
        '^[[:space:]]*//?[[:space:]]*Unattended-Upgrade::Automatic-Reboot[[:space:]].*' \
        'Unattended-Upgrade::Automatic-Reboot "false";'
    set_param "$conf" \
        '^[[:space:]]*//?[[:space:]]*Unattended-Upgrade::Automatic-Reboot-WithUsers[[:space:]].*' \
        'Unattended-Upgrade::Automatic-Reboot-WithUsers "false";'
    set_param "$conf" \
        '^[[:space:]]*//?[[:space:]]*Unattended-Upgrade::Remove-Unused-Dependencies[[:space:]].*' \
        'Unattended-Upgrade::Remove-Unused-Dependencies "true";'

    ok "Auto-updates configured (no automatic reboots)."
}

# ============================================================
# 9. SSH HARDENING
# ============================================================
harden_ssh() {
    info "Hardening SSH..."
    local sshd="/etc/ssh/sshd_config"
    cp -n "$sshd" "${sshd}.bak"

    ssh_set() {
        local key="$1" val="$2"
        if grep -qE "^[#[:space:]]*${key}[[:space:]]" "$sshd"; then
            sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$sshd"
        else
            echo "${key} ${val}" >> "$sshd"
        fi
    }

    ssh_set Port                            "$SSH_PORT"
    ssh_set LoginGraceTime                  "2m"
    ssh_set PermitRootLogin                 "prohibit-password"
    ssh_set MaxAuthTries                    "5"
    ssh_set MaxSessions                     "4"
    ssh_set StrictModes                     "yes"
    ssh_set PubkeyAuthentication            "yes"
    ssh_set PermitEmptyPasswords            "no"
    ssh_set PasswordAuthentication          "no"
    ssh_set ChallengeResponseAuthentication "no"
    ssh_set UsePAM                          "no"
    ssh_set ClientAliveInterval             "2400"
    ssh_set ClientAliveCountMax             "1"

    local ci="/etc/ssh/sshd_config.d/50-cloud-init.conf"
    if [[ -f "$ci" ]]; then
        set_param "$ci" \
            '^[#[:space:]]*PasswordAuthentication[[:space:]].*' \
            'PasswordAuthentication no'
    fi

    systemctl restart ssh
    ok "SSH hardened on port $SSH_PORT."
    warn "Verify SSH access on port $SSH_PORT in a new terminal before closing this session!"
}

# ============================================================
# 10. PHP HARDENING
# ============================================================
harden_php() {
    info "Hardening PHP..."
    local ini
    ini=$(find /etc/php -name "php.ini" -path "*/apache2/*" | head -1)
    [[ -z "$ini" ]] && die "php.ini not found."
    cp -n "$ini" "${ini}.bak"

    php_set() {
        local key="$1" val="$2"
        if grep -qE "^[;[:space:]]*${key}[[:space:]]*=" "$ini"; then
            sed -i -E "s|^[;[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$ini"
        else
            echo "${key} = ${val}" >> "$ini"
        fi
    }

    # disable_functions kept minimal — Zabbix frontend needs broader PHP access than WordPress
    php_set expose_php              "Off"
    php_set session.use_strict_mode "1"
    php_set session.cookie_httponly "1"
    php_set session.cookie_secure   "1"
    php_set session.cookie_samesite "Lax"
    php_set allow_url_include       "Off"

    ok "PHP hardened ($ini)."
}

# ============================================================
# 11. APACHE HARDENING
# ============================================================
harden_apache() {
    info "Hardening Apache..."
    local sec="/etc/apache2/conf-available/security.conf"
    set_param "$sec" '^[#[:space:]]*ServerTokens[[:space:]].*'    'ServerTokens Prod'
    set_param "$sec" '^[#[:space:]]*ServerSignature[[:space:]].*' 'ServerSignature Off'
    set_param "$sec" '^[#[:space:]]*TraceEnable[[:space:]].*'     'TraceEnable Off'

    cat > /etc/apache2/conf-available/zabbix-hardening.conf << 'EOF'
<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"
    Header always set Cross-Origin-Resource-Policy "same-origin"
    Header always unset X-Powered-By
</IfModule>
EOF

    a2enmod proxy proxy_http proxy_fcgi ssl headers
    a2enconf zabbix-hardening
    apache2ctl configtest && systemctl reload apache2
    ok "Apache hardened."
}

# ============================================================
# 12. FAIL2BAN
# ============================================================
configure_fail2ban() {
    info "Deploying fail2ban config from config/zabbix-jail.local..."
    local jail_local="/etc/fail2ban/jail.local"

    [[ -f "$jail_local" ]] && cp "$jail_local" "${jail_local}.bak"

    sed "s|{{SSH_PORT}}|${SSH_PORT}|g" \
        "${CONFIG_DIR}/zabbix-jail.local" > "$jail_local"

    systemctl enable --now fail2ban
    fail2ban-client reload
    ok "fail2ban configured (SSH port: ${SSH_PORT})."
}

# ============================================================
# 13. UFW FIREWALL
# ============================================================
configure_ufw() {
    info "Configuring UFW firewall..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT"/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow from "$WEB_SERVER_IP" to any port 10051 proto tcp
    ufw --force enable
    ok "UFW enabled. Port 10051 open for ${WEB_SERVER_IP}."
}

# ============================================================
# MAIN
# ============================================================
main() {
    require_root
    require_configs
    prompt_params
    generate_ssh_key

    install_packages
    configure_mariadb
    import_zabbix_schema
    configure_zabbix_server
    configure_services
    kernel_hardening
    configure_auto_updates
    harden_ssh
    harden_php
    harden_apache
    configure_fail2ban
    configure_ufw

    echo ""
    echo "============================================================"
    ok "Zabbix server setup complete."
    echo "  Zabbix DB    : ${ZABBIX_DB_NAME}"
    echo "  Zabbix user  : ${ZABBIX_DB_USER}"
    echo "  Web server IP: ${WEB_SERVER_IP}"
    echo "  SSH port     : ${SSH_PORT}"
    echo "  SSH key      : /root/.ssh/zabbix_server_id_ed25519"
    echo ""
    warn "Still TODO:"
    echo "  1. Add SSL: certbot --apache"
    echo "  2. Finish Zabbix web setup: http://<this-server>/zabbix"
    echo "  3. Add monitored host in Zabbix UI:"
    echo "     Configuration > Hosts > IP: ${WEB_SERVER_IP}, Port: 10050"
    echo "  4. Verify SSH on new port before closing this session:"
    echo "     ssh -p ${SSH_PORT} root@<this-server>"
    echo "============================================================"
}

main "$@"
