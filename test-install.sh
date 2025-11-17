#!/bin/bash
# ============================================
#  Pterodactyl Installer + Wings + Menu
#  Supports Debian 11/12 and Ubuntu 20–24
# ============================================

set -euo pipefail
IFS=$'\n\t'

# Colors
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# Require root
if [ "$EUID" -ne 0 ]; then
  err "Run this script as root (sudo)."
fi

###############################################
#                 MENU                        #
###############################################

clear
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}      Pterodactyl Auto Installer Menu       ${NC}"
echo -e "${GREEN}============================================${NC}"
echo
echo "1) Install Pterodactyl Panel"
echo "2) Install Wings (Node)"
echo "3) System Information"
echo "0) Exit"
echo

read -p "Choose an option: " MENU_CHOICE

###############################################
#                SYSTEM INFO                  #
###############################################

if [[ "$MENU_CHOICE" == "3" ]]; then
  echo -e "${BLUE}System Info:${NC}"
  echo "-----------------------"
  echo "OS: $(lsb_release -d | awk -F: '{print $2}')"
  echo "Kernel: $(uname -r)"
  echo "CPU: $(lscpu | grep 'Model name' | awk -F: '{print $2}')"
  echo "RAM: $(free -h | awk '/Mem/ {print $2}')"
  echo "Disk: $(df -h / | awk '/\// {print $2}')"
  echo "-----------------------"
  exit 0
fi

###############################################
#                WINGS PLACEHOLDER            #
###############################################

if [[ "$MENU_CHOICE" == "2" ]]; then
  echo -e "${YELLOW}Wings installer will be added soon...${NC}"
  exit 0
fi

###############################################
#        PANEL INSTALLER STARTS HERE          #
###############################################

if [[ "$MENU_CHOICE" != "1" ]]; then
  echo "Invalid option!"
  exit 1
fi

clear
echo -e "${GREEN}Pterodactyl Panel Installer (Fixed)${NC}"
echo

# Detect OS
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="$ID"
  OS_NAME="$NAME"
  OS_VER="$VERSION_ID"
  CODENAME="$(lsb_release -sc 2>/dev/null || true)"
else
  err "/etc/os-release not found, cannot detect OS."
fi
log "Detected OS: $OS_NAME $OS_VER (codename: ${CODENAME:-unknown})"

# Prevent unbound variable errors
FQDN=""
ADMIN_EMAIL=""
ADMIN_USER=""
ADMIN_PASS=""
ADMIN_FIRST=""
ADMIN_LAST=""

# Ask questions interactively
read -p "Panel Domain (FQDN, e.g. panel.example.com): " FQDN
[[ -z "$FQDN" ]] && err "FQDN required."

read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "Admin Password (leave blank for random): " ADMIN_PASS
echo
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS="$(openssl rand -base64 12)"
  warn "Random admin password generated: $ADMIN_PASS"
fi

read -p "Admin First Name [Admin]: " ADMIN_FIRST
ADMIN_FIRST=${ADMIN_FIRST:-Admin}

read -p "Admin Last Name [User]: " ADMIN_LAST
ADMIN_LAST=${ADMIN_LAST:-User}

# Defaults
TIMEZONE="Asia/Kolkata"
DB_NAME="pterodactyl"
DB_USER="pterodactyl"
DB_PASS="$(openssl rand -hex 16)"

log "Working with: Domain=$FQDN | Admin=$ADMIN_USER | Email=$ADMIN_EMAIL"
read -p "Press Enter to continue..."

# Cleanup Ondrej PPA
log "Cleaning old ondrej PHP PPA..."
find /etc/apt/sources.list.d -name '*ondrej*' -delete 2>/dev/null || true
sed -i '/ondrej\/php/d' /etc/apt/sources.list || true
apt-get update -y || true
ok "Cleaned."

# Install prerequisites
log "Installing prerequisites..."
apt-get install -y ca-certificates curl wget tar unzip git lsb-release gnupg2 software-properties-common
ok "Base packages installed."

# PHP selection
echo
echo "Choose PHP version:"
echo "  1) 8.1"
echo "  2) 8.2 (recommended)"
echo "  3) 8.3"
read -p "Select (1/2/3) [2]: " PHP_CHOICE
PHP_CHOICE=${PHP_CHOICE:-2}

case "$PHP_CHOICE" in
  1) PHP_VER="8.1" ;;
  2) PHP_VER="8.2" ;;
  3) PHP_VER="8.3" ;;
  *) PHP_VER="8.2" ;;
esac

# Install PHP
log "Installing PHP $PHP_VER..."
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ ${CODENAME} main" \
 > /etc/apt/sources.list.d/sury-php.list
apt-get update -y
apt-get install -y php${PHP_VER} php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-mbstring php${PHP_VER}-xml php${PHP_VER}-curl php${PHP_VER}-zip php${PHP_VER}-gd php${PHP_VER}-bcmath php${PHP_VER}-mysql
systemctl enable --now php${PHP_VER}-fpm
ok "PHP installed."

# Install web stack
log "Installing NGINX, MariaDB, Redis..."
apt-get install -y nginx mariadb-server redis-server
systemctl enable --now nginx mariadb redis-server

# MySQL
log "Creating MySQL database..."
mysql -u root <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# Download panel
log "Downloading Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -sL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
rm panel.tar.gz
cp .env.example .env

# .env function
set_env() {
  key="$1"; val="$2"
  if grep -q "^$key=" .env; then
    sed -i "s|^$key=.*|$key=$val|" .env
  else
    echo "$key=$val" >> .env
  fi
}

# .env values
log "Configuring .env..."
set_env APP_URL "https://$FQDN"
set_env APP_TIMEZONE "$TIMEZONE"
set_env APP_ENVIRONMENT_ONLY false

set_env DB_HOST 127.0.0.1
set_env DB_PORT 3306
set_env DB_DATABASE "$DB_NAME"
set_env DB_USERNAME "$DB_USER"
set_env DB_PASSWORD "$DB_PASS"

set_env CACHE_DRIVER redis
set_env SESSION_DRIVER redis
set_env QUEUE_CONNECTION redis
set_env REDIS_HOST 127.0.0.1

# generate temporary key
TMP_APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"
set_env APP_KEY "$TMP_APP_KEY"

chown -R www-data:www-data /var/www/pterodactyl

# composer
log "Installing Composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
export COMPOSER_ALLOW_SUPERUSER=1

composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction
php artisan key:generate --force
php artisan migrate --seed --force

# Admin user
php artisan p:user:make \
  --email "$ADMIN_EMAIL" \
  --username "$ADMIN_USER" \
  --name-first "$ADMIN_FIRST" \
  --name-last "$ADMIN_LAST" \
  --password "$ADMIN_PASS" \
  --admin 1 --no-interaction || true

# SSL
mkdir -p /etc/certs/certs
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
 -subj "/CN=$FQDN/O=Pterodactyl" \
 -keyout /etc/certs/certs/privkey.pem \
 -out /etc/certs/certs/fullchain.pem

# NGINX
NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $FQDN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $FQDN;

    root /var/www/pterodactyl/public;
    index index.php;

    ssl_certificate /etc/certs/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/certs/privkey.pem;

    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t
systemctl restart nginx

# DONE
clear
ok "Pterodactyl Installed Successfully!"

echo "========================================="
echo " Panel URL: https://$FQDN"
echo " Admin Username: $ADMIN_USER"
echo " Admin Email: $ADMIN_EMAIL"
echo " Admin Password: $ADMIN_PASS"
echo " DB User: $DB_USER"
echo " DB Pass: $DB_PASS"
echo "========================================="
echo
echo -e "${YELLOW}If using Cloudflare:${NC}"
echo " Service Type = URL"
echo " URL = https://localhost:443"
echo " TLS → No TLS Verify = ON"
echo "========================================="
