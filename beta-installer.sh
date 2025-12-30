#!/bin/bash
# UNIVERSAL Pterodactyl Installer (Panel + Wings) - 2025 Fixed Version
# With port 8080 + HTTPS + two separate self-signed certificates
set -euo pipefail
IFS=$'\n\t'

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && err "Run this script as root (sudo)."

clear
echo -e "${GREEN}Pterodactyl Universal Installer - Port 8080 + HTTPS${NC}"

# Detect OS
. /etc/os-release
CODENAME="$(lsb_release -sc 2>/dev/null || echo "")"
log "Detected: $NAME $VERSION_ID ($CODENAME)"

###############################################
# MENU
###############################################
menu() {
echo -e "
${GREEN}Select Option:${NC}

 1) Install Pterodactyl Panel (port 8080 + HTTPS)
 2) Install Wings (Node)
 3) System Info
 4) Exit
"
read -p "Choose [1-4]: " CHOICE
case $CHOICE in
  1) install_panel ;;
  2) install_wings ;;
  3) system_info ;;
  4) exit 0 ;;
  *) menu ;;
esac
}

###############################################
# SYSTEM INFO
###############################################
system_info() {
echo
echo -e "${GREEN}System Information${NC}"
echo "OS: $PRETTY_NAME"
echo "Kernel: $(uname -r)"
echo "CPU: $(lscpu | grep 'Model name' | sed 's/Model name:\s*//')"
echo "$(df -h /)"
echo
read -p "Press Enter to return to menu..."
menu
}

###############################################
# PANEL INSTALLER
###############################################
install_panel() {

clear
echo -e "${GREEN}PANEL INSTALLER (port 8080 + HTTPS)${NC}"

read -p "Panel Domain (FQDN): " FQDN
[[ -z "$FQDN" ]] && err "Domain required."

read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "Admin Password (blank = random): " ADMIN_PASS
echo
[[ -z "$ADMIN_PASS" ]] && ADMIN_PASS="$(openssl rand -base64 12)"

read -p "Admin First Name [Admin]: " ADMIN_FIRST
ADMIN_FIRST=${ADMIN_FIRST:-Admin}

read -p "Admin Last Name [User]: " ADMIN_LAST
ADMIN_LAST=${ADMIN_LAST:-User}

DB_PASS="$(openssl rand -hex 16)"
TIMEZONE="Asia/Kolkata"

log "Cleaning old PHP repositories..."
find /etc/apt/sources.list.d -name '*ondrej*' -delete 2>/dev/null || true
find /etc/apt/sources.list.d -name '*sury*' -delete 2>/dev/null || true
sed -i '/ondrej\/php/d;/sury.org/d' /etc/apt/sources.list

apt-get update -y || true
apt-get install -y ca-certificates curl wget tar unzip git lsb-release gnupg2 software-properties-common

# PHP (Ondřej PPA - most reliable in 2025)
log "Adding Ondřej Surý PPA..."
add-apt-repository ppa:ondrej/php -y || LC_ALL=C.UTF-8 add-apt-repository ppa:ondrej/php -y
apt-get update -y

echo "Choose PHP version:"
echo "1) 8.2   2) 8.3 (recommended)"
read -p "Select [2]: " PV
PV=${PV:-2}
[[ "$PV" == "1" ]] && PHP_VER="8.2" || PHP_VER="8.3"

apt-get install -y php$PHP_VER php$PHP_VER-fpm php$PHP_VER-cli php$PHP_VER-mysql php$PHP_VER-xml \
php$PHP_VER-curl php$PHP_VER-gd php$PHP_VER-zip php$PHP_VER-bcmath php$PHP_VER-mbstring php$PHP_VER-intl

systemctl enable --now php$PHP_VER-fpm

# Web stack
apt-get install -y nginx mariadb-server redis-server
systemctl enable --now nginx mariadb redis-server

# Database
mysql -u root <<SQL
DROP DATABASE IF EXISTS pterodactyl;
CREATE DATABASE pterodactyl CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# Panel download
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -sLo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz && rm panel.tar.gz
cp .env.example .env
chown -R www-data:www-data .

# .env basics
sed -i "s|^APP_URL=.*|APP_URL=https://$FQDN:8080|" .env
sed -i "s|^APP_TIMEZONE=.*|APP_TIMEZONE=$TIMEZONE|" .env
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env
sed -i "s|^DB_USERNAME=.*|DB_USERNAME=pterodactyl|" .env
sed -i "s|^DB_DATABASE=.*|DB_DATABASE=pterodactyl|" .env
sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env
sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env
sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env

# Composer + setup
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-dev --optimize-autoloader --no-interaction

php artisan key:generate --force
php artisan migrate --seed --force

php artisan p:user:make \
 --email "$ADMIN_EMAIL" \
 --username "$ADMIN_USER" \
 --name-first "$ADMIN_FIRST" \
 --name-last "$ADMIN_LAST" \
 --password "$ADMIN_PASS" \
 --admin 1 --no-interaction || true

###############################################
# SSL CERTS - PANEL (with real domain)
###############################################
mkdir -p /etc/certs/panel
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
 -subj "/C=NA/ST=NA/L=NA/O=Pterodactyl/CN=$FQDN" \
 -keyout /etc/certs/panel/privkey.pem \
 -out /etc/certs/panel/fullchain.pem || true

chmod 644 /etc/certs/panel/fullchain.pem
chmod 600 /etc/certs/panel/privkey.pem

###############################################
# NGINX CONFIG - HTTPS on port 8080
###############################################
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 8080 ssl http2;
    listen [::]:8080 ssl http2;

    server_name $FQDN _;  # both specific domain and catch-all

    root /var/www/pterodactyl/public;
    index index.php;

    ssl_certificate     /etc/certs/panel/fullchain.pem;
    ssl_certificate_key /etc/certs/panel/privkey.pem;

    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php$PHP_VER-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
    }

    location ~ /\.ht { deny all; }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf

nginx -t && systemctl restart nginx || {
    warn "Nginx configuration failed - check logs:"
    tail -n 20 /var/log/nginx/error.log
}

clear
ok "Panel Installed Successfully!"
echo "URL:          https://$FQDN:8080"
echo "Admin:        $ADMIN_USER / $ADMIN_EMAIL"
echo "Password:     $ADMIN_PASS"
echo "Self-signed certificate: /etc/certs/panel/"
echo
echo "Cloudflare Tunnel suggestion: HTTP → http://localhost:8080"
echo "(or HTTPS → https://localhost:8080 with Full SSL mode)"
read -p "Press Enter to return..."
menu
}

###############################################
# WINGS INSTALLER
###############################################
install_wings() {

clear
echo -e "${GREEN}WINGS INSTALLER STARTING...${NC}"

read -p "Node FQDN (example: node.example.com): " NODE_FQDN
[[ -z "$NODE_FQDN" ]] && err "FQDN required."

read -p "Wings Port [8080]: " WINGS_PORT
WINGS_PORT=${WINGS_PORT:-8080}

read -p "SFTP Bind Port [2022]: " WINGS_BIND_PORT
WINGS_BIND_PORT=${WINGS_BIND_PORT:-2022}

read -p "UUID: " NODE_UUID
read -p "Token ID: " NODE_TOKEN_ID
read -p "Token: " NODE_TOKEN

log "Installing dependencies..."
apt-get install -y curl wget tar unzip docker.io || err "Dependencies failed"
systemctl enable --now docker

###############################################
# SSL CERTS - WINGS (separate certificate)
###############################################
mkdir -p /etc/certs/wings
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
 -subj "/C=NA/ST=NA/L=NA/O=Pterodactyl Wings/CN=$NODE_FQDN" \
 -keyout /etc/certs/wings/privkey.pem \
 -out /etc/certs/wings/fullchain.pem || true

chmod 644 /etc/certs/wings/fullchain.pem
chmod 600 /etc/certs/wings/privkey.pem

###############################################
# INSTALL WINGS
###############################################
mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes

log "Downloading Wings..."
curl -L https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 \
 -o /usr/local/bin/wings || err "Wings download failed"

chmod +x /usr/local/bin/wings

###############################################
# CONFIG YAML
###############################################
cat > /etc/pterodactyl/config.yml <<EOF
debug: false
uuid: "$NODE_UUID"
token_id: "$NODE_TOKEN_ID"
token: "$NODE_TOKEN"

api:
  host: 0.0.0.0
  port: $WINGS_PORT
  ssl:
    enabled: true
    cert: /etc/certs/wings/fullchain.pem
    key: /etc/certs/wings/privkey.pem
  upload_limit: 100

system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: $WINGS_BIND_PORT

allowed_mounts: []

remote: "https://$NODE_FQDN:8080"   # adjust if panel port different
EOF

###############################################
# SYSTEMD SERVICE
###############################################
cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=network.target docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/var/lib/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wings

ok "Wings Node Installed!"
echo "Certificate: /etc/certs/wings/"
echo "API: https://$NODE_FQDN:$WINGS_PORT (SSL enabled)"
read -p "Press Enter to return..."
menu
}

###############################################
# START MENU
###############################################
menu
