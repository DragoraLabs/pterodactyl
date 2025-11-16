#!/bin/bash
# ==================================================
#  PTERODACTYL PANEL‑ONLY (HTTP on 8080)
#  No Wings | No SSL | India‑IST
#  Debian 11/12 | Ubuntu 22.04/24.04
# ==================================================

set -euo pipefail

# Colors
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

clear
echo -e "${GREEN}PTERODACTYL PANEL‑ONLY (HTTP on 8080)${NC}\n"

# === Input ===
read -p "Panel FQDN (e.g. panel.example.com): " FQDN
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

# === System Update ===
log "Updating system..."
apt update && apt upgrade -y

# === Dependencies ===
log "Installing PHP, Nginx, MariaDB, Redis, Composer..."
apt install -y curl wget gnupg2 software-properties-common lsb-release ca-certificates

# PHP version
if lsb_release -rs | grep -q "11\|22.04"; then
    apt install -y php8.1 php8.1-{cli,fpm,curl,mbstring,xml,bcmath,zip,gd,mysql}
else
    add-apt-repository ppa:ondrej/php -y
    apt update
    apt install -y php8.3 php8.3-{cli,fpm,curl,mbstring,xml,bcmath,zip,gd,mysql}
fi

apt install -y nginx mariadb-server mariadb-client redis-server unzip git tar

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
FLUSH PRIVILEGES;
SQL

# === Composer ===
log "Installing Composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# === Panel download ===
log "Downloading Pterodactyl Panel..."
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage bootstrap/cache

# === .env ===
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

# === Nginx (HTTP on 8080) ===
log "Configuring Nginx to listen on 8080..."
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
        fastcgi_pass unix:/run/php/php$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')-fpm.sock;
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
if command -v ufw >/dev/null; then
    ufw allow $PANEL_PORT
    ufw reload
elif command -v iptables >/dev/null; then
    iptables -I INPUT -p tcp --dport $PANEL_PORT -j ACCEPT
fi

# === Final Output ===
clear
success "PTERODACTYL PANEL (HTTP on 8080) INSTALLED!"
echo
echo "=========================================="
echo "   LOGIN DETAILS (SAVE THIS!)"
echo "=========================================="
echo "URL: http://$FQDN:$PANEL_PORT"
echo "Username: $ADMIN_USER"
echo "Email: $ADMIN_EMAIL"
echo "Password: $ADMIN_PASS"
echo
echo "Port 8080 is open. No SSL (add later with Certbot)."
echo "=========================================="
