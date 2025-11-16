#!/bin/bash
# ==================================================
#  PTERODACTYL PANEL UNIVERSAL INSTALLER (INDIA)
#  Panel on 8080 | HTTPS Redirect | Self‑Signed SSL
#  No Wings | DB Reset | All Linux Distros
#  Time: November 16, 2025 | IST
# ==================================================

set -euo pipefail

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

clear
echo -e "${GREEN}PTERODACTYL UNIVERSAL PANEL INSTALLER (INDIA - IST)${NC}\n"

# === Detect OS ===
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    error "Unsupported OS"
fi
log "Detected: $OS $VER"

# === Input ===
read -p "Panel FQDN (e.g. node.gamerhost.qzz.io): " FQDN
[[ -z "$FQDN" ]] && error "FQDN required!"

read -p "Email (alerts): " EMAIL
[[ -z "$EMAIL" ]] && error "Email required!"

read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

read -s -p "Admin Password (blank = random): " ADMIN_PASS
echo
[[ -z "$ADMIN_PASS" ]] && ADMIN_PASS=$(openssl rand -base64 18) && warn "Random password!"

DB_PASS=$(openssl rand -base64 32)
PANEL_PORT=8080
TIMEZONE="Asia/Kolkata"

echo -e "\nStarting install...\n"

# === Debian 11 Backports Fix ===
if [[ "$OS" == "debian" && "$VER" == "11" ]]; then
    rm -f /etc/apt/sources.list.d/*backports* 2>/dev/null
    sed -i '/bullseye-backports/d' /etc/apt/sources.list
    echo "deb http://archive.debian.org/debian bullseye-backports main contrib non-free" > /etc/apt/sources.list.d/bullseye-backports.list
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
fi

# === PHP 8.1 ===
case "$OS" in
    debian|ubuntu)
        apt update
        apt install -y software-properties-common gnupg ca-certificates
        if [[ "$OS" == "debian" && "$VER" == "11" ]]; then
            apt install -y -t bullseye-backports php8.1 php8.1-{cli,fpm,curl,mbstring,xml,bcmath,zip,gd,mysql}
        else
            add-apt-repository ppa:ondrej/php -y
            apt update
            apt install -y php8.1 php8.1-{cli,fpm,curl,mbstring,xml,bcmath,zip,gd,mysql}
        fi
        PHP_FPM_SOCK="/run/php/php8.1-fpm.sock"
        ;;
    centos|rhel|rocky|almalinux)
        dnf install -y epel-release
        dnf install -y https://rpms.remirepo.net/enterprise/remi-release-8.rpm
        dnf module reset php -y
        dnf module enable php:remi-8.1 -y
        dnf install -y php php-cli php-fpm php-{curl,mbstring,xml,gd,bcmath,zip,mysqlnd}
        PHP_FPM_SOCK="/var/run/php-fpm/www.sock"
        ;;
    fedora) dnf install -y php php-cli php-fpm php-{curl,mbstring,xml,gd,bcmath,zip,mysqlnd}; PHP_FPM_SOCK="/var/run/php-fpm/www.sock" ;;
    arch) pacman -Sy --noconfirm php php-fpm php-{gd,curl,zip,intl}; PHP_FPM_SOCK="/run/php-fpm/php-fpm.sock" ;;
    opensuse*) zypper install -y php8 php8-fpm php8-{mysql,curl,zip,mbstring,bcmath,gd,xml}; PHP_FPM_SOCK="/var/run/php-fpm.sock" ;;
    *) error "OS not supported" ;;
esac

# === Dependencies ===
case "$OS" in
    debian|ubuntu) apt install -y nginx mariadb-server redis-server unzip git tar curl wget ;;
    centos|rhel|rocky|almalinux|fedora) dnf install -y nginx mariadb-server redis unzip git tar curl wget; systemctl enable --now mariadb ;;
    arch) pacman -Sy --noconfirm nginx mariadb redis unzip git tar curl wget ;;
    opensuse*) zypper install -y nginx mariadb redis unzip git tar curl wget ;;
esac

# === DB Reset ===
log "Resetting database..."
systemctl start mariadb 2>/dev/null || true
mysql <<SQL
DROP DATABASE IF EXISTS pterodactyl;
CREATE DATABASE pterodactyl;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# === Composer & Panel ===
log "Installing Composer & Panel..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
mkdir -p /var/www/pterodactyl && cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage bootstrap/cache
cp .env.example .env

sed -i \
  -e "s|APP_URL=.*|APP_URL=http://$FQDN:$PANEL_PORT|" \
  -e "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" \
  -e "s|APP_TIMEZONE=.*|APP_TIMEZONE=$TIMEZONE|" \
  .env

chown -R www-data:www-data /var/www/pterodactyl 2>/dev/null || chown -R nginx:nginx /var/www/pterodactyl || true

composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force
php artisan migrate --seed --force
php artisan p:user:make --email "$ADMIN_EMAIL" --username "$ADMIN_USER" --admin 1 --password "$ADMIN_PASS" --no-interaction

# === SSL (Self‑Signed) ===
log "Generating SSL cert..."
mkdir -p /etc/letsencrypt/live/$FQDN
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/C=IN/ST=NA/L=NA/O=GameHost/CN=$FQDN" \
    -keyout /etc/letsencrypt/live/$FQDN/privkey.pem \
    -out /etc/letsencrypt/live/$FQDN/fullchain.pem

# === Nginx Config ===
log "Setting up Nginx..."
rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true

cat > /etc/nginx/conf.d/pterodactyl.conf <<NGINX
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
    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;
    ssl_certificate /etc/letsencrypt/live/$FQDN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FQDN/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Frame-Options DENY;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:$PHP_FPM_SOCK;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }
    location ~ /\.ht { deny all; }
}
NGINX

# Panel on 8080
cat > /etc/nginx/conf.d/pterodactyl-8080.conf <<PROXY
server {
    listen $PANEL_PORT;
    server_name $FQDN;
    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
PROXY

nginx -t && systemctl restart nginx

# === Firewall ===
ufw allow 80,443,8080 2>/dev/null || true

# === Final ===
clear
success "PTERODACTYL PANEL INSTALLED!"
echo "URL: http://$FQDN:$PANEL_PORT"
echo "HTTPS: https://$FQDN"
echo "User: $ADMIN_USER | Pass: $ADMIN_PASS"
echo "Real SSL: certbot --nginx -d $FQDN"
