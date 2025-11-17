#!/bin/bash
# UNIVERSAL Pterodactyl Installer (Panel + Wings)
# Debian 11/12, Ubuntu 20.04/22.04/24.04
set -euo pipefail
IFS=$'\n\t'

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && err "Run this script as root (sudo)."

clear
echo -e "${GREEN}Pterodactyl Universal Installer${NC}"

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

 1) Install Pterodactyl Panel
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
echo -e "${GREEN}PANEL INSTALLER STARTING...${NC}"

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
sed -i '/ondrej\/php/d' /etc/apt/sources.list

apt-get update -y
apt-get install -y ca-certificates curl wget tar unzip git lsb-release gnupg2 software-properties-common

###############################################
# PHP INSTALL
###############################################
echo
echo "Choose PHP version:"
echo "1) 8.1"
echo "2) 8.2 (recommended)"
echo "3) 8.3"
read -p "Select [2]: " PV
PV=${PV:-2}
[[ "$PV" == "1" ]] && PHP_VER="8.1"
[[ "$PV" == "2" ]] && PHP_VER="8.2"
[[ "$PV" == "3" ]] && PHP_VER="8.3"

curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury.gpg
echo "deb [signed-by=/usr/share/keyrings/sury.gpg] https://packages.sury.org/php/ $CODENAME main" > /etc/apt/sources.list.d/php.list
apt-get update -y

apt-get install -y php$PHP_VER php$PHP_VER-fpm php$PHP_VER-cli php$PHP_VER-mysql php$PHP_VER-xml \
php$PHP_VER-curl php$PHP_VER-gd php$PHP_VER-zip php$PHP_VER-bcmath php$PHP_VER-mbstring

systemctl enable --now php$PHP_VER-fpm

###############################################
# WEB STACK
###############################################
apt-get install -y nginx mariadb-server redis-server
systemctl enable --now nginx mariadb redis-server

###############################################
# DATABASE
###############################################
mysql -u root <<SQL
DROP DATABASE IF EXISTS pterodactyl;
CREATE DATABASE pterodactyl CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

###############################################
# PANEL DOWNLOAD
###############################################
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -sLo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz && rm panel.tar.gz
cp .env.example .env

###############################################
# ENV CONFIG
###############################################
sed -i "s|APP_URL=.*|APP_URL=https://$FQDN|" .env
sed -i "s|APP_TIMEZONE=.*|APP_TIMEZONE=$TIMEZONE|" .env

sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env

###############################################
# SSL CERTS
###############################################
mkdir -p /etc/certs
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
 -subj "/CN=$FQDN/O=Pterodactyl" \
 -keyout /etc/certs/privkey.pem \
 -out /etc/certs/fullchain.pem

###############################################
# COMPOSER + MIGRATIONS
###############################################
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction

yes yes | php artisan key:generate --force
php artisan migrate --seed --force

php artisan p:user:make \
 --email "$ADMIN_EMAIL" \
 --username "$ADMIN_USER" \
 --name-first "$ADMIN_FIRST" \
 --name-last "$ADMIN_LAST" \
 --password "$ADMIN_PASS" \
 --admin 1 --no-interaction || true

###############################################
# NGINX CONFIG
###############################################
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name $FQDN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $FQDN;

    root /var/www/pterodactyl/public;
    index index.php;

    ssl_certificate /etc/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/privkey.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php$PHP_VER-fpm.sock;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t && systemctl restart nginx

clear
ok "Panel Installed Successfully!"
echo "Admin: $ADMIN_USER"
echo "Email: $ADMIN_EMAIL"
echo "Password: $ADMIN_PASS"

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
apt-get install -y curl wget tar unzip

###############################################
# SSL CERTS
###############################################
mkdir -p /etc/certs
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
 -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
 -keyout /etc/certs/privkey.pem \
 -out /etc/certs/fullchain.pem

###############################################
# INSTALL WINGS
###############################################
mkdir -p /etc/pterodactyl /var/lib/pterodactyl /var/lib/pterodactyl/volumes

log "Downloading Wings..."
curl -L https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 \
 -o /usr/local/bin/wings || err "Download failed"

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
    cert: /etc/certs/fullchain.pem
    key: /etc/certs/privkey.pem
  upload_limit: 100

system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: $WINGS_BIND_PORT

allowed_mounts: []

remote: "https://$NODE_FQDN"
EOF

###############################################
# SYSTEMD SERVICE
###############################################
cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=network.target

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
read -p "Press Enter to return..."
menu
}

###############################################
# START MENU
###############################################
menu
