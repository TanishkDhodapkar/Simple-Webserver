\# server-hardening



Automated Ubuntu server hardening and WordPress deployment script.



\## What it does



\- System packages + unattended security updates

\- Kernel hardening (sysctl)

\- SSH hardening (custom port, key-only auth)

\- MySQL secure installation + site DB/user creation

\- PHP hardening (disable dangerous functions, session security, etc.)

\- WordPress deployment + wp-config.php generation

\- ModSecurity WAF (enabled, not just detection mode)

\- Apache vhost with HTTP→HTTPS redirect, TLS config, upload PHP block

\- fail2ban with Apache + SSH jails

\- UFW firewall (SSH port, 80, 443 only)



\## Directory structure



```

server-hardening/

├── setup.sh                  # Main script — edit variables at the top

└── config/

&#x20;   ├── jail.local            # fail2ban jail config ({{SSH\_PORT}} is substituted at runtime)

&#x20;   ├── sysctl-hardening.conf # Kernel parameters → /etc/sysctl.d/99-hardening.conf

&#x20;   ├── web1.conf             # Apache vhost template ({{SITE\_DOMAIN}}, {{DOC\_ROOT}}, {{ADMIN\_EMAIL}} substituted)

&#x20;   └── wp-htaccess           # WordPress .htaccess with security headers

```



\## Usage



\### 1. Set your parameters



Edit the variables at the top of `setup.sh`:



```bash

DB\_NAME="web1db"

DB\_USER="web1user"

DB\_PASS="your\_strong\_password\_here"

SITE\_DOMAIN="yoursite.com"

DOC\_ROOT="/var/www/web1"

ADMIN\_EMAIL="admin@yoursite.com"

SSH\_PORT="55022"

```



\*\*Do not commit real passwords.\*\* Set `DB\_PASS` on the server directly, or use an `.env` file (already in `.gitignore`).



\### 2. Clone on the server and run



```bash

git clone https://github.com/youruser/server-hardening.git

cd server-hardening

chmod +x setup.sh

sudo ./setup.sh

```



The script must be run from the repo root — it locates `config/` relative to its own path.



\### 3. After the script completes



| Task | Command |

|---|---|

| SSL (Let's Encrypt) | `certbot --apache -d yoursite.com` |

| SSL (custom cert) | Place `.crt`, `.key`, `.ca-bundle` in `/etc/ssl/` |

| Finish WordPress install | Visit `https://yoursite.com/wp-admin/install.php` |

| Tune CSP header | Edit `config/wp-htaccess`, re-run or copy manually |



\### Verify SSH before closing your session



The script restarts SSH on the custom port. Before closing your current terminal:



```bash

\# In a new terminal, verify access on the new port

ssh -p 55022 user@yourserver

```



\## Config file placeholders



The script substitutes these at deploy time — you edit the config files with placeholders, not hardcoded values:



| Placeholder | Replaced with |

|---|---|

| `{{SITE\_DOMAIN}}` | `SITE\_DOMAIN` variable |

| `{{DOC\_ROOT}}` | `DOC\_ROOT` variable |

| `{{ADMIN\_EMAIL}}` | `ADMIN\_EMAIL` variable |

| `{{SSH\_PORT}}` | `SSH\_PORT` variable (in `jail.local`) |



\## Re-running



The script is safe to re-run. Key idempotency behaviors:



\- WordPress download skipped if `DOC\_ROOT` already exists

\- Config files backed up with `.bak` suffix before overwriting

\- MySQL `CREATE IF NOT EXISTS` used for DB and user

\- UFW reset before re-applying rules

