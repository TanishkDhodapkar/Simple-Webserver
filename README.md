# server-hardening

Automated Ubuntu server hardening and WordPress deployment.

## What it does

- System packages + unattended security updates
- Kernel hardening (sysctl)
- SSH hardening (custom port, key-only auth)
- MySQL secure installation + site DB/user creation
- PHP hardening (disable dangerous functions, session security, etc.)
- WordPress deployment + wp-config.php generation
- ModSecurity WAF (enabled, not just detection mode)
- Apache vhost with HTTP→HTTPS redirect, TLS config, upload PHP block
- fail2ban with Apache + SSH jails
- UFW firewall (SSH port, 80, 443 only)

## Directory structure

```
server-hardening/
├── setup.sh                  # Main script — edit variables at the top
└── config/
    ├── jail.local            # fail2ban jails ({{SSH_PORT}} substituted at runtime)
    ├── sysctl-hardening.conf # Kernel parameters → /etc/sysctl.d/99-hardening.conf
    ├── web1.conf             # Apache vhost template ({{SITE_DOMAIN}}, {{DOC_ROOT}}, {{ADMIN_EMAIL}} substituted)
    └── wp-htaccess           # WordPress .htaccess with security headers
```

## Usage

### 1. Set your parameters

Edit the variables at the top of `setup.sh`:

```bash
DB_NAME="web1db"
DB_USER="web1user"
DB_PASS="your_strong_password_here"
SITE_DOMAIN="yoursite.com"
DOC_ROOT="/var/www/web1"
ADMIN_EMAIL="admin@yoursite.com"
SSH_PORT="55022"
```

> **Do not commit real passwords.** Set `DB_PASS` on the server directly, or use an `.env` file (already in `.gitignore`).

### 2. Clone on the server and run

```bash
git clone https://github.com/youruser/server-hardening.git
cd server-hardening
chmod +x setup.sh
sudo ./setup.sh
```

The script must be run from the repo root — it locates `config/` relative to its own path.

### 3. After the script completes

| Task | Command |
|---|---|
| SSL via Let's Encrypt | `certbot --apache -d yoursite.com` |
| SSL via custom cert | Place `.crt`, `.key`, `.ca-bundle` in `/etc/ssl/` |
| Finish WordPress install | Visit `https://yoursite.com/wp-admin/install.php` |
| Tune CSP header | Edit `config/wp-htaccess`, re-run or copy manually |

### Verify SSH before closing your session

The script restarts SSH on the custom port. Before closing your current terminal, confirm access in a new one:

```bash
ssh -p 55022 user@yourserver
```

## Config file placeholders

Config files use placeholders that `setup.sh` substitutes at deploy time. You never hardcode server-specific values in config files.

| Placeholder | Replaced with |
|---|---|
| `{{SITE_DOMAIN}}` | `SITE_DOMAIN` variable |
| `{{DOC_ROOT}}` | `DOC_ROOT` variable |
| `{{ADMIN_EMAIL}}` | `ADMIN_EMAIL` variable |
| `{{SSH_PORT}}` | `SSH_PORT` variable (in `jail.local` only) |

## Re-running

The script is safe to re-run:

- WordPress download skipped if `DOC_ROOT` already exists
- Config files backed up with `.bak` before overwriting
- MySQL uses `CREATE IF NOT EXISTS` for DB and user
- UFW is reset before re-applying rules
