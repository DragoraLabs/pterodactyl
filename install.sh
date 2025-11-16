#!/bin/bash
# ==================================================
#  PTERODACTYL PANEL‑ONLY (HTTP on 8080 + Self‑Signed SSL)
#  Debian 11 (Bullseye) – PHP 8.1 from backports
#  No Wings | No Certbot
# ==================================================

set -euo pipefail

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

clear
echo -e "${GREEN}PTERODACTYL PANEL‑ONLY (HTTP on 8080 + Self‑Signed SSL)${NC}\n"

# === Input ===
read -p "Panel FQDN (e.g. node.gamerhost.qzz.io): " FQDN
[[ -z "$FQDN" ]] && error "FQDN required!"

read -p "Email (for alerts): " EMAIL
[[ -z "$EMAIL" ]] && error "Email required!"

read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

read -s -p "Admin Password (blank = random): " ADMIN_PASS
echo
[[ -z "$ADMIN_PASS" ]] && ADMIN_PASS=$(openssl rand -base64 18) && warn "Random password generated!"

DB_PASS=$(openssl rand -base64 32)
TIMEZONE="Asia/Kolkata"
PANEL_PORT=8080

echo -e "\n${BLUE}Starting with:${NC}"
echo "   FQDN: $FQDN | Port: $PANEL_PORT | Admin: $ADMIN_USER"
read -p "Press Enter to begin..."

# === Prep ===
log "Creating /var/www/pterodactyl..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

# === Enable backports (PHP 8.1) ===
log "Enabling Debian backports for PHP 8.1..."
cat > /etc/apt/sources.list.d/backports.list <<EOF
deb http://deb.debian.org/debian bullseye-backports main
EOF
apt update

# === System Update + Dependencies ===
log "Updating system & installing packages..."
apt -y upgrade
apt -y install \
    curl wget gnupg2 ca-certificates lsb-release \
    nginx mariadb-server mariadb-client redis-server unzip git tar \
    php8.1 php8.1-{cli,fpm,curl,mbstring,xml,bcmath,zip,gd,mysql} \
    -t bullseye-backports

# === MariaDB ===
log "Setting up database..."
systemctl start mariadb
mysql <<SQL
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
CREATE DATABASE pterodactyl;
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH Privileges;
SQL

# === Composer ===
log "Installing Composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# === Panel download ===
log "Downloading Pterodactyl Panel..."
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage bootstrap/cache

# === .env (HTTP only) ===
cat > .env <<ENV
APP_URL=http://$FQDN:$PANEL_PORT
APP_TIMEZONE=$TIMEZONE
APP_SERVICE_AUTHOR=noreply@$FQDN
DB_PASSWORD=$DB_PASS
CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_DRIVER=redis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379
MAIL_FROM_ADDRESS=noreply@$FQDN
MAIL_FROM_NAME="Pterodactyl Panel"
ENV

cp .env.example .env
chown -R www-data:www-data /var/www/pterodactyl

# === Install Panel ===
log "Running Composer & migrations..."
composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force
php artisan migrate --seed --force
php artisan p:user:make \
    --email "$ADMIN_EMAIL" \
    --username "$ADMIN_USER" \
    --admin 1 \
    --password "$ADMIN_PASS" \
    --no-interaction

# === Self‑Signed SSL (for Nginx) ===
log "Generating self‑signed certificate..."
mkdir -p /etc/ssl/pterodactyl
openssl req \
  -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=$FQDN" \
  -keyout /etc/ssl/pterodactyl/privkey.pem \
  -out /etc/ssl/pterodactyl/fullchain.pem

# === Nginx (HTTP on 8080 + HTTPS on 8443 optional) ===
log "Configuring Nginx (HTTP on 8080)..."
cat > /etc/nginx/sites-available/pterodactyl <<NGINX
server {
    listen $PANEL_PORT;
    server_name $FQDN;

    root /var/www/pterodactyl/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# === Firewall (only 8080) ===
log "Opening port 8080..."
ufw allow $PANEL_PORT || true
ufw reload || true

# === Final Output ===
clear
success "PTERODACTYL PANEL (HTTP on 8080) + SELF‑SIGNED SSL INSTALLED!"
echo
echo "=========================================="
echo "   LOGIN DETAILS (SAVE THIS!)"
echo "=========================================="
echo "URL: http://$FQDN:$PANEL_PORT"
echo "Username: $ADMIN_USER"
echo "Email: $ADMIN_EMAIL"
echo "Password: $ADMIN_PASS"
echo
echo "Self‑signed certs (if you want HTTPS later):"
echo "   /etc/ssl/pterodactyl/fullchain.pem"
echo "   /etc/ssl/pterodactyl/privkey.pem"
echo
echo "Add HTTPS on 8443 later with:"
echo "   nano /etc/nginx/sites-available/pterodactyl"
echo "   (add listen 8443 ssl; + ssl_certificate lines)"
echo "=========================================="
