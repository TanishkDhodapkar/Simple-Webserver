# Webserver With Zabbix
Automated Ubuntu server hardening and deployment scripts for WordPress and Zabbix.

## Scripts

| Script | Purpose |
|---|---|
| `setup.sh` | WordPress server — hardening + WordPress deployment + optional Zabbix agent |
| `zabbix-setup.sh` | Zabbix monitoring server — full install + hardening |

---

## Directory structure

```
server-hardening/
├── setup.sh
├── zabbix-setup.sh
└── config/
    ├── sysctl-hardening.conf    # Kernel parameters (used by both scripts)
    ├── jail.local               # fail2ban jails for WordPress server
    ├── zabbix-jail.local        # fail2ban jails for Zabbix server
    ├── web1-http.conf           # Apache vhost template — HTTP only
    ├── web1-https.conf          # Apache vhost template — HTTPS + TLS
    └── wp-htaccess              # WordPress .htaccess with security headers
```

---

## setup.sh — WordPress server

### What it does

- System packages + unattended security updates (no auto-reboot)
- Kernel hardening via sysctl
- SSH hardening - custom port, key-only auth, strict timeouts
- MySQL secure install + site DB/user creation
- PHP hardening - disable dangerous functions, session security
- WordPress deployment + wp-config.php with DB credentials and fresh salts
- ModSecurity WAF in enforcement mode
- Apache vhost - HTTP or HTTPS (prompted at runtime)
- Apache hardening - ServerTokens, ServerSignature, TraceEnable
- fail2ban with SSH + Apache jails
- UFW firewall - SSH port, 80, 443 only
- Zabbix agent2 install and config (optional - skipped if ZABBIX_SERVER_IP is empty)

### Parameters

Edit variables at the top of `setup.sh` before running, or leave them as-is to be prompted:

```bash
DB_NAME="web1db"
DB_USER="web1user"
DB_PASS="CHANGE_ME_STRONG_PASSWORD"
SITE_DOMAIN="yoursite.com"
DOC_ROOT="/var/www/web1"
ADMIN_EMAIL="admin@yoursite.com"
SSH_PORT="55022"

# "http" or "https" — leave empty to be prompted at runtime
VHOST_MODE=""

# Set to Zabbix server IP to enable agent install, leave empty to skip
ZABBIX_SERVER_IP=""
ZABBIX_AGENT_HOSTNAME="web1"
```


### Vhost selection

If `VHOST_MODE` is empty, the script prompts at runtime:

```
  ┌─────────────────────────────────────┐
  │   Select VirtualHost configuration  │
  │                                     │
  │   1) HTTP only  (port 80)           │
  │   2) HTTPS      (port 443 + TLS)    │
  └─────────────────────────────────────┘
  Enter choice [1/2]:
```

Set `VHOST_MODE="http"` or `VHOST_MODE="https"` to skip the prompt.

### Zabbix agent (optional)

If `ZABBIX_SERVER_IP` is set, the script installs and configures `zabbix-agent2` automatically:

- Installs from the Zabbix repo
- Sets `Server`, `ServerActive`, and `Hostname` in `zabbix_agent2.conf`
- Starts and enables the service
- Opens UFW port 10050 from the Zabbix server IP only

If `ZABBIX_SERVER_IP` is left empty, this step is skipped entirely.

### Run

```bash
git clone https://github.com/TanishkDhodapkar/WebserverWithZabbix
cd WebserverWithZabbix
chmod +x setup.sh
sudo ./setup.sh
```

The script must run from the repo root - it locates `config/` relative to itself.

### After the script completes

| Task | Command |
|---|---|
| SSL via Let's Encrypt | `certbot --apache -d yoursite.com` |
| SSL via custom cert | Place `.crt`, `.key`, `.ca-bundle` in `/etc/ssl/` |
| Finish WordPress install | Visit `https://yoursite.com/wp-admin/install.php` |
| Tune CSP header | Edit `config/wp-htaccess`, re-run or copy manually |
| Add host in Zabbix UI | Configuration > Hosts > IP: this server, Port: 10050 |

> **Before closing your session, verify SSH access on the new port:**
> ```bash
> ssh -p 55022 user@yourserver
> ```

---

## zabbix-setup.sh — Zabbix monitoring server

### What it does

- Installs Zabbix server, frontend, agent2, and SQL scripts
- MariaDB secure install + Zabbix DB/user creation + schema import
- SSH key pair generated for connecting to monitored hosts
- SSH hardening, kernel hardening, PHP hardening, Apache hardening, Zabbix security response headers, UFW firewall and fail2ban
- SSH port, 80, 443, and port 10051 from monitored server IP only
- Unattended-upgrades with no auto-reboot
- snapd disabled and removed

### All parameters are prompted at runtime

When you run the script, you will be asked for:

| Prompt | Default | Notes |
|---|---|---|
| Zabbix DB name | `zabbix` | |
| Zabbix DB user | `zabbix` | |
| Zabbix DB password | — | Required, no default |
| Monitored web server IP | — | Required — used for UFW port 10051 rule |
| SSH port | `55022` | |

A summary is shown before anything runs, with a confirmation prompt.

### SSH key generation

The script generates an `ed25519` key pair at `/root/.ssh/zabbix_server_id_ed25519`.

After generation, the script pauses and displays:

- The **public key** to add to `/root/.ssh/authorized_keys` on the monitored server
- The exact command to add it remotely
- The SSH command to connect using the private key

```
echo 'ssh-ed25519 AAAA...' >> /root/.ssh/authorized_keys

ssh -i /root/.ssh/zabbix_server_id_ed25519 -p 55022 root@<WEB_SERVER_IP>
```

### Run

```bash
git clone https://github.com/TanishkDhodapkar/WebserverWithZabbix
cd WebserverWithZabbix
chmod +x zabbix-setup.sh
sudo ./zabbix-setup.sh
```

### After the script completes

| Task | Command / URL |
|---|---|
| Add SSL | `certbot --apache` |
| Finish Zabbix web setup | `http://<this-server>/zabbix` |
| Add monitored host in UI | Configuration > Hosts > IP: web server IP, Port: 10050 |
| Verify SSH on new port | `ssh -p <SSH_PORT> root@<this-server>` |

---

## Config file placeholders

Config files use placeholders substituted by the scripts at deploy time.

| Placeholder | Used in | Replaced with |
|---|---|---|
| `{{SITE_DOMAIN}}` | `web1-http.conf`, `web1-https.conf` | `SITE_DOMAIN` |
| `{{DOC_ROOT}}` | `web1-http.conf`, `web1-https.conf` | `DOC_ROOT` |
| `{{ADMIN_EMAIL}}` | `web1-http.conf`, `web1-https.conf` | `ADMIN_EMAIL` |
| `{{SSH_PORT}}` | `jail.local`, `zabbix-jail.local` | `SSH_PORT` |

---

## Re-running

Both scripts are safe to re-run:

- WordPress download skipped if `DOC_ROOT` already exists
- Zabbix schema import skipped if tables already exist in the DB
- SSH key generation skipped if key file already exists
- Config files backed up with `.bak` before overwriting
- MySQL/MariaDB use `CREATE IF NOT EXISTS`
- UFW reset before re-applying rules
