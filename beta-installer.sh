#!/bin/bash
# Pterodactyl Panel Installer - Fixed 2025 version
# Supports Ubuntu 22.04 / 24.04 (and Debian 11/12 with limitations)
# Now uses PHP 8.3 + listens on port 8080
set -euo pipefail
IFS=$'\n\t'

# Colors
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# require root
[[ $EUID -ne 0 ]] && err "Run this script as root (sudo)."

clear
echo -e "${GREEN}Pterodactyl Panel Installer (2025 - PHP 8.3 - Port 8080)${NC}"
echo

# Detect OS
. /etc/os-release 2>/dev/null || err "/etc/os-release not found."
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-unknown}"
CODENAME="${VERSION_CODENAME:-$(lsb_release -sc 2>/dev/null || echo 'unknown')}"

log "Detected: ${OS_NAME:-$OS_ID} $OS_VER (codename: $CODENAME)"

# ── User input ───────────────────────────────────────────────────────────────
read -rp "Panel Domain (FQDN, e.g. panel.example.com): " FQDN
[[ -z "$FQDN" ]] && err "FQDN is required!"

read -rp "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

read -rp "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -rp "Admin Password (leave blank = random): " ADMIN_PASS
echo
[[ -z "$ADMIN_PASS" ]] && ADMIN_PASS="$(openssl rand -base64 15)" && warn "Generated password: $ADMIN_PASS"

read -rp "Admin First Name [Admin]: " ADMIN_FIRST; ADMIN_FIRST=${ADMIN_FIRST:-Admin}
read -rp "Admin Last Name [User]: " ADMIN_LAST;   ADMIN_LAST=${ADMIN_LAST:-User}

DB_NAME="pterodactyl"
DB_USER="pterodactyl"
DB_PASS="$(openssl rand -hex 16)"

log "Summary: Domain=$FQDN | User=$ADMIN_USER | Email=$ADMIN_EMAIL"
read -rp "Press Enter to continue..." dummy

# ── Cleanup old/broken repos ─────────────────────────────────────────────────
log "Cleaning old/broken PHP repositories..."
rm -f /etc/apt/sources.list.d/*ondrej* /etc/apt/sources.list.d/*sury* 2>/dev/null || true
sed -i '/ondrej\/php/d;/packages.sury.org/d' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || true
apt-get update -qq || true
ok "Cleanup done."

# ── Prerequisites ────────────────────────────────────────────────────────────
log "Installing base packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl wget gnupg lsb-release software-properties-common \
    unzip git tar build-essential openssl apt-transport-https \
    nginx mariadb-server redis-server || err "Prerequisites failed"
ok "Base packages installed."

systemctl enable --now mariadb nginx redis-server 2>/dev/null || true

# ── PHP 8.3 (Ondřej Surý PPA) ────────────────────────────────────────────────
log "Installing PHP 8.3 from Ondřej Surý PPA..."

add-apt-repository -y ppa:ondrej/php 2>/dev/null || true
apt-get update -qq || err "Failed to update after adding Ondřej PPA"

if ! apt-get install -y php8.3 php8.3-{fpm,cli,mbstring,xml,curl,zip,gd,bcmath,mysql,common,tokenizer,intl} php8.3-readline; then
    err "PHP 8.3 installation failed!\nTry: sudo apt update && sudo apt install php8.3 php8.3-fpm"
fi

ok "PHP 8.3 installed."
systemctl enable --now php8.3-fpm || true

# ── Database setup ───────────────────────────────────────────────────────────
log "Creating MariaDB database + user..."
mysql -u root <<SQL || err "MariaDB setup failed"
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
ok "Database ready."

# ── Download Panel ───────────────────────────────────────────────────────────
log "Downloading latest Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

curl -sLo panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" \
    || err "Download failed"

tar -xzf panel.tar.gz
rm -f panel.tar.gz

chmod -R 755 storage bootstrap/cache
cp .env.example .env
chown -R www-data:www-data /var/www/pterodactyl
ok "Panel downloaded."

# ── Configure .env ───────────────────────────────────────────────────────────
log "Configuring .env..."

sed -i "s|^APP_URL=.*|APP_URL=https://${FQDN}|" .env
sed -i "s|^APP_TIMEZONE=.*|APP_TIMEZONE=Asia/Kolkata|" .env   # ← change if needed

sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" .env
sed -i "s|^DB_PORT=.*|DB_PORT=3306|" .env
sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env

sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env
sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env
sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env

sed -i "s|^REDIS_HOST=.*|REDIS_HOST=127.0.0.1|" .env

sed -i "s|^MAIL_FROM_ADDRESS=.*|MAIL_FROM_ADDRESS=noreply@${FQDN}|" .env
sed -i "s|^MAIL_FROM_NAME=.*|MAIL_FROM_NAME=\"Pterodactyl Panel\"|" .env

ok ".env configured."

# ── Composer & Laravel setup ─────────────────────────────────────────────────
log "Installing Composer & dependencies..."

curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer || err "Composer install failed"

export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-dev --optimize-autoloader --no-interaction || err "Composer dependencies failed"

log "Running artisan commands..."
php artisan key:generate --force
php artisan config:clear
php artisan cache:clear
php artisan migrate --seed --force || err "Migrations failed!"

log "Creating admin account..."
php artisan p:user:make \
    --email "${ADMIN_EMAIL}" \
    --username "${ADMIN_USER}" \
    --name-first "${ADMIN_FIRST}" \
    --name-last "${ADMIN_LAST}" \
    --admin=1 \
    --password "${ADMIN_PASS}" \
    --no-interaction || warn "Admin creation failed - run manually later"

ok "Artisan setup completed."

# ── Nginx config - PORT 8080 (http only for now) ─────────────────────────────
log "Creating Nginx config (listening on port 8080)..."

NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"

cat > "${NGINX_CONF}" <<'EOF'
server {
    listen 8080;
    server_name _;

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl-access.log;
    error_log  /var/log/nginx/pterodactyl-error.log warn;

    client_max_body_size 100M;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# Enable & clean default
rm -f /etc/nginx/sites-enabled/default
ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/pterodactyl.conf

nginx -t && systemctl restart nginx || err "Nginx config/restart failed!"

# ── Final summary ────────────────────────────────────────────────────────────
clear
ok "PTERODACTYL PANEL INSTALL FINISHED!"
cat <<EOF

Panel address:    http://${FQDN}:8080
Admin username:   ${ADMIN_USER}
Admin email:      ${ADMIN_EMAIL}
Admin password:   ${ADMIN_PASS}

Database user:    ${DB_USER}
Database password:${DB_PASS}

Next steps (strongly recommended):
  1. Install real SSL (Cloudflare / Let's Encrypt)
  2. Change Nginx port back to 443 + add SSL
  3. Configure email (SMTP) in .env
  4. Set up Wings daemon on game nodes

Good luck & have fun! 🚀
EOF
