#!/bin/bash
set -euo pipefail
 
# ============================================================
# USER PARAMETERS — edit these before running
# ============================================================
DB_NAME="web1db"
DB_USER="web1user"
DB_PASS="CHANGE_ME_STRONG_PASSWORD"
SITE_DOMAIN="website1.com"
DOC_ROOT="/var/www/web1"
ADMIN_EMAIL="admin@website1.com"
SSH_PORT="55022"
 
# Vhost mode: will be asked interactively at runtime if left empty.
# Set to "http" or "https" here to skip the prompt.
VHOST_MODE=""
 
# Zabbix agent: set ZABBIX_SERVER_IP to enable agent install.
# Leave empty to skip.
ZABBIX_SERVER_IP=""
ZABBIX_AGENT_HOSTNAME="web1"
ZABBIX_VERSION="7.4"
UBUNTU_CODEVER="ubuntu26.04"
 
# ============================================================
# DERIVED
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
SITE_CONF="/etc/apache2/sites-available/${SITE_DOMAIN}.conf"
 
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
    for f in jail.local sysctl-hardening.conf web1-http.conf web1-https.conf wp-htaccess; do
        [[ -f "${CONFIG_DIR}/${f}" ]] || { warn "Missing config file: config/${f}"; missing=1; }
    done
    [[ $missing -eq 0 ]] || die "Missing config files. See README.md."
}
 
# In-place sed: replace a matching line (including commented variants).
# Usage: set_param FILE REGEX REPLACEMENT
set_param() {
    local file="$1" regex="$2" replacement="$3"
    if grep -qE "$regex" "$file"; then
        sed -i -E "s|${regex}|${replacement}|" "$file"
    else
        warn "Pattern not found in $file: $regex — skipping"
    fi
}
 
# ============================================================
# 1. PACKAGES
# ============================================================
install_packages() {
    info "Updating system and installing packages..."
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq \
        curl wget vim ufw net-tools unzip \
        unattended-upgrades auditd \
        apache2 mysql-server \
        php libapache2-mod-php php-mysql \
        libapache2-mod-security2 modsecurity-crs \
        fail2ban
    ok "Packages installed."
}
 
# ============================================================
# 2. SERVICES
# ============================================================
configure_services() {
    info "Enabling required services..."
    systemctl enable --now apache2 mysql ssh
 
    info "Disabling unneeded services..."
    for svc in avahi-daemon cups bluetooth; do
        systemctl disable --now "$svc" 2>/dev/null || true
    done
    ok "Services configured."
}
 
# ============================================================
# 3. KERNEL HARDENING
# ============================================================
kernel_hardening() {
    info "Applying kernel hardening via sysctl..."
    cp "${CONFIG_DIR}/sysctl-hardening.conf" /etc/sysctl.d/99-hardening.conf
    sysctl -p /etc/sysctl.d/99-hardening.conf > /dev/null
    ok "Kernel hardening applied."
}
 
# ============================================================
# 4. AUTO UPDATES
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
# 5. AUDITD RULES
# ============================================================
configure_auditd() {
    info "Configuring auditd rules..."
    cat > /etc/audit/rules.d/hardening.rules << 'EOF'
-a always,exit -F path=/etc/passwd  -F perm=wa -F auid>=1000 -F auid!=unset -k identity
-a always,exit -F path=/etc/shadow  -F perm=wa -F auid>=1000 -F auid!=unset -k identity
-a always,exit -F path=/etc/sudoers -F perm=wa -F auid>=1000 -F auid!=unset -k sudoers
EOF
    augenrules --load > /dev/null 2>&1 || auditctl -R /etc/audit/rules.d/hardening.rules
    systemctl enable --now auditd
    ok "Auditd configured."
}
 
# ============================================================
# 6. SSH HARDENING
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
    warn "Make sure port $SSH_PORT is open and your key is deployed before closing this session!"
}
 
# ============================================================
# 7. MYSQL HARDENING
# ============================================================
harden_mysql() {
    info "Hardening MySQL..."
    mysql -u root << EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket;
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
 
    mysql -u root << EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
    ok "MySQL hardened. DB '${DB_NAME}' and user '${DB_USER}' created."
}
 
# ============================================================
# 8. PHP HARDENING
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
 
    php_set expose_php              "Off"
    php_set disable_functions       "exec,passthru,shell_exec,system,popen,proc_open,proc_close,proc_get_status,proc_nice"
    php_set open_basedir            "${DOC_ROOT}/:/tmp/"
    php_set session.use_strict_mode "1"
    php_set session.cookie_httponly "1"
    php_set session.cookie_secure   "1"
    php_set session.cookie_samesite "Lax"
    php_set allow_url_fopen         "On"
    php_set allow_url_include       "Off"
    php_set max_execution_time      "300"
    php_set max_input_time          "600"
    php_set memory_limit            "512M"
    php_set upload_max_filesize     "24M"
    php_set post_max_size           "16M"
 
    ok "PHP hardened ($ini)."
}
 
# ============================================================
# 9. WORDPRESS SETUP
# ============================================================
setup_wordpress() {
    info "Deploying WordPress to ${DOC_ROOT}..."
    mkdir -p "$(dirname "$DOC_ROOT")"
 
    if [[ -d "$DOC_ROOT" ]]; then
        warn "${DOC_ROOT} already exists — skipping WordPress download."
    else
        wget -qO- https://wordpress.org/latest.tar.gz | tar -xzf - -C /var/www/
        mv /var/www/wordpress "$DOC_ROOT"
    fi
 
    chown -R www-data:www-data "$DOC_ROOT"
    find "$DOC_ROOT" -type d -exec chmod 755 {} +
    find "$DOC_ROOT" -type f -exec chmod 644 {} +
 
    cp "${DOC_ROOT}/wp-config-sample.php" "${DOC_ROOT}/wp-config.php"
    local wp_config="${DOC_ROOT}/wp-config.php"
 
    # DB credentials
    sed -i \
        -e "s/database_name_here/${DB_NAME}/" \
        -e "s/username_here/${DB_USER}/" \
        -e "s/password_here/${DB_PASS}/" \
        "$wp_config"
 
    # Fetch real salts from the WordPress API and replace the 8 placeholder
    # define() lines (AUTH_KEY through NONCE_SALT) in wp-config.php.
    info "Fetching WordPress salts..."
    local salts
    salts=$(curl -sf https://api.wordpress.org/secret-key/1.1/salt/) \
        || die "Failed to fetch WordPress salts — check network connectivity."
 
    # Use Python for the regex replacement — sed can't reliably handle multiline blocks.
    # Write the script to a temp file to avoid quoting issues.
    local py_script
    py_script=$(mktemp /tmp/wp_salts_XXXXXX.py)
    cat > "$py_script" << 'PYINLINE'
import re, sys
salts     = sys.argv[1]
wp_config = sys.argv[2]
with open(wp_config) as fh:
    c = fh.read()
c = re.sub(
    r"define\( 'AUTH_KEY'.*?define\( 'NONCE_SALT',\s*'[^']*'\s*\);",
    salts.strip(),
    c, flags=re.DOTALL
)
with open(wp_config, 'w') as fh:
    fh.write(c)
PYINLINE
    python3 "$py_script" "$salts" "$wp_config"
    rm -f "$py_script"
 
    chown root:www-data "$wp_config"
    chmod 640 "$wp_config"
 
    ok "WordPress deployed (DB credentials and salts configured)."
}
 
# ============================================================
# 10. MODSECURITY
# ============================================================
configure_modsecurity() {
    info "Enabling ModSecurity..."
    local msc="/etc/modsecurity/modsecurity.conf-recommended"
    local msc_active="/etc/modsecurity/modsecurity.conf"
 
    [[ -f "$msc_active" ]] || cp "$msc" "$msc_active"
    set_param "$msc_active" \
        '^SecRuleEngine[[:space:]].*' \
        'SecRuleEngine On'
 
    ok "ModSecurity enabled."
}
 
# ============================================================
# 11. .HTACCESS  (copied from config/wp-htaccess)
# ============================================================
write_htaccess() {
    info "Writing .htaccess from config/wp-htaccess..."
    cp "${CONFIG_DIR}/wp-htaccess" "${DOC_ROOT}/.htaccess"
    chown www-data:www-data "${DOC_ROOT}/.htaccess"
    chmod 644 "${DOC_ROOT}/.htaccess"
    ok ".htaccess deployed."
}
 
# ============================================================
# 12. APACHE VHOST
# ============================================================
prompt_vhost_mode() {
    # If already set via variable, validate and return
    if [[ -n "$VHOST_MODE" ]]; then
        [[ "$VHOST_MODE" == "http" || "$VHOST_MODE" == "https" ]] \
            || die "VHOST_MODE must be 'http' or 'https', got: $VHOST_MODE"
        return
    fi
 
    echo ""
    echo "  ┌─────────────────────────────────────┐"
    echo "  │   Select VirtualHost configuration  │"
    echo "  │                                     │"
    echo "  │   1) HTTP only  (port 80)           │"
    echo "  │   2) HTTPS      (port 443 + TLS)    │"
    echo "  └─────────────────────────────────────┘"
    while true; do
        read -rp "  Enter choice [1/2]: " choice
        case "$choice" in
            1) VHOST_MODE="http";  break ;;
            2) VHOST_MODE="https"; break ;;
            *) echo "  Please enter 1 or 2." ;;
        esac
    done
    echo ""
}
 
configure_apache() {
    prompt_vhost_mode
    info "Configuring Apache (mode: ${VHOST_MODE})..."
 
    # Harden catch-all default site
    local def_conf="/etc/apache2/sites-available/000-default.conf"
    if [[ -f "$def_conf" ]] && ! grep -q "Require all denied" "$def_conf"; then
        cat >> "$def_conf" << 'EOF'
<VirtualHost *:80>
    <Location />
        Require all denied
    </Location>
</VirtualHost>
EOF
    fi
 
    local template="${CONFIG_DIR}/web1-${VHOST_MODE}.conf"
    [[ -f "$template" ]] || die "Vhost template not found: $template"
 
    sed \
        -e "s|{{SITE_DOMAIN}}|${SITE_DOMAIN}|g" \
        -e "s|{{DOC_ROOT}}|${DOC_ROOT}|g" \
        -e "s|{{ADMIN_EMAIL}}|${ADMIN_EMAIL}|g" \
        "$template" > "$SITE_CONF"
 
    local mods="rewrite headers expires http2 proxy_fcgi setenvif unique_id security2 socache_shmcb"
    [[ "$VHOST_MODE" == "https" ]] && mods="$mods ssl"
    # shellcheck disable=SC2086
    a2enmod $mods
    a2dismod autoindex status userdir info 2>/dev/null || true
 
    a2ensite "$(basename "$SITE_CONF")"
    a2dissite 000-default.conf 2>/dev/null || true
 
    apache2ctl configtest && systemctl restart apache2
    ok "Apache configured (${VHOST_MODE})."
}
 
# ============================================================
# 13. APACHE HARDENING
# ============================================================
harden_apache() {
    info "Hardening Apache..."
    local sec="/etc/apache2/conf-available/security.conf"
    set_param "$sec" '^[#[:space:]]*ServerTokens[[:space:]].*'   'ServerTokens Prod'
    set_param "$sec" '^[#[:space:]]*ServerSignature[[:space:]].*' 'ServerSignature Off'
    set_param "$sec" '^[#[:space:]]*TraceEnable[[:space:]].*'     'TraceEnable Off'
    systemctl reload apache2
    ok "Apache hardened (ServerTokens, ServerSignature, TraceEnable)."
}
 
# ============================================================
# 14. FAIL2BAN  (copied from config/jail.local)
# ============================================================
configure_fail2ban() {
    info "Deploying fail2ban config from config/jail.local..."
    local jail_local="/etc/fail2ban/jail.local"
 
    [[ -f "$jail_local" ]] && cp "$jail_local" "${jail_local}.bak"
 
    # Substitute SSH port placeholder then write
    sed "s|{{SSH_PORT}}|${SSH_PORT}|g" \
        "${CONFIG_DIR}/jail.local" > "$jail_local"
 
    systemctl enable --now fail2ban
    fail2ban-client reload
    ok "fail2ban configured (SSH port: ${SSH_PORT})."
}
 
# ============================================================
# 15. UFW FIREWALL
# ============================================================
configure_ufw() {
    info "Configuring UFW firewall..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT"/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    ok "UFW enabled. Allowed ports: $SSH_PORT (SSH), 80, 443."
}
 
 
# ============================================================
# 16. ZABBIX AGENT2  (optional — skipped if ZABBIX_SERVER_IP is empty)
# ============================================================
install_zabbix_agent() {
    if [[ -z "$ZABBIX_SERVER_IP" ]]; then
        warn "ZABBIX_SERVER_IP not set — skipping Zabbix agent install."
        return
    fi
 
    info "Installing Zabbix agent2 (server: ${ZABBIX_SERVER_IP})..."
 
    local deb="zabbix-release_latest_${ZABBIX_VERSION}+${UBUNTU_CODEVER}_all.deb"
    local url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/${deb}"
    wget -q -O "/tmp/${deb}" "$url" || die "Failed to download Zabbix repo package."
    dpkg -i "/tmp/${deb}"
    rm -f "/tmp/${deb}"
    apt-get update -qq
    apt-get install -y -qq zabbix-agent2
 
    local conf="/etc/zabbix/zabbix_agent2.conf"
    cp -n "$conf" "${conf}.bak"
 
    set_param "$conf" '^[#[:space:]]*Server[[:space:]]*=.*'       "Server=${ZABBIX_SERVER_IP}"
    set_param "$conf" '^[#[:space:]]*ServerActive[[:space:]]*=.*' "ServerActive=${ZABBIX_SERVER_IP}"
    set_param "$conf" '^[#[:space:]]*Hostname[[:space:]]*=.*'     "Hostname=${ZABBIX_AGENT_HOSTNAME}"
 
    systemctl enable --now zabbix-agent2
 
    # Allow Zabbix server to reach agent port 10050
    ufw allow from "$ZABBIX_SERVER_IP" to any port 10050 proto tcp
 
    ss -tlnp | grep -q 10050 \
        && ok "zabbix-agent2 running. Port 10050 open for ${ZABBIX_SERVER_IP}." \
        || warn "Port 10050 not detected — check: systemctl status zabbix-agent2"
}
 
# ============================================================
# MAIN
# ============================================================
main() {
    require_root
    require_configs
 
    install_packages
    configure_services
    kernel_hardening
    configure_auto_updates
    configure_auditd
    harden_ssh
    harden_mysql
    harden_php
    setup_wordpress
    configure_modsecurity
    write_htaccess
    configure_apache
    harden_apache
    configure_fail2ban
    install_zabbix_agent
    configure_ufw
 
    echo ""
    echo "============================================================"
    ok "Setup complete."
    echo "  Site domain  : ${SITE_DOMAIN}"
    echo "  Document root: ${DOC_ROOT}"
    echo "  DB name      : ${DB_NAME}"
    echo "  DB user      : ${DB_USER}"
    echo "  SSH port     : ${SSH_PORT}"
    echo ""
    echo "  Vhost mode   : ${VHOST_MODE}"
    [[ -n "$ZABBIX_SERVER_IP" ]] && echo "  Zabbix server: ${ZABBIX_SERVER_IP} (agent: ${ZABBIX_AGENT_HOSTNAME})"
    echo ""
    warn "Still TODO (manual steps):"
    if [[ "$VHOST_MODE" == "https" ]]; then
        echo "  1. Place SSL cert/key in /etc/ssl/certs/ and /etc/ssl/private/"
        echo "     — or run: certbot --apache -d ${SITE_DOMAIN}"
    fi
    echo "  2. Complete WordPress setup: https://${SITE_DOMAIN}/wp-admin/install.php"
    echo "  3. Tune CSP header in config/wp-htaccess after testing your site"
    [[ -n "$ZABBIX_SERVER_IP" ]] && echo "  4. Add this host in Zabbix UI: Configuration > Hosts > IP: <this server> Port: 10050"
    echo "============================================================"
}
 
main "$@"
