#!/bin/bash
# UNIVERSAL LINUX PTERODACTYL PANEL INSTALLER
# Supports: Debian, Ubuntu, CentOS, Rocky, AlmaLinux, Fedora, Arch, OpenSUSE

set -euo pipefail

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

clear
echo -e "${GREEN}PTERODACTYL PANEL (Universal Linux Installer)${NC}\n"


# === Detect OS ===
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        error "Unsupported OS: Cannot detect /etc/os-release"
    fi
}

install_php() {
    case "$OS" in
        debian|ubuntu)
            log "Installing PHP 8.1 for Debian/Ubuntu..."
            apt update
            apt install -y software-properties-common gnupg
            add-apt-repository ppa:ondrej/php -y || true
            apt update
            apt install -y php8.1 php8.1-{cli,fpm,curl,mbstring,xml,bcmath,zip,gd,mysql}
        ;;
        centos|rhel|rocky|almalinux)
            log "Installing PHP 8.1 for RHEL-based systems..."
            dnf install -y epel-release
            dnf install -y https://rpms.remirepo.net/enterprise/remi-release-8.rpm
            dnf module reset php -y
            dnf module enable php:remi-8.1 -y
            dnf install -y php php-cli php-fpm php-curl php-mbstring php-xml php-gd php-bcmath php-zip php-mysqlnd
        ;;
        fedora)
            log "Installing PHP 8.1 for Fedora..."
            dnf install -y php php-cli php-fpm php-curl php-mbstring php-xml php-gd php-bcmath php-zip php-mysqlnd
        ;;
        arch)
            log "Installing PHP for Arch..."
            pacman -Sy --noconfirm php php-fpm php-gd php-curl php-zip php-intl php-mcrypt mariadb nginx redis unzip git
        ;;
        opensuse*)
            log "Installing PHP 8.1 for openSUSE..."
            zypper refresh
            zypper install -y php8 php8-fpm php8-mysql php8-curl php8-zip php8-mbstring php8-bcmath php8-gd php8-xml
        ;;
        *)
            error "Unsupported OS: $OS"
        ;;
    esac
}

install_dependencies() {
    case "$OS" in
        debian|ubuntu)
            apt install -y nginx mariadb-server mariadb-client redis-server unzip git tar curl wget ca-certificates
        ;;
        centos|rhel|rocky|almalinux|fedora)
            dnf install -y nginx mariadb-server redis unzip git tar curl wget
            systemctl enable --now mariadb
        ;;
        arch)
            pacman -Sy --noconfirm nginx mariadb redis unzip git tar curl wget
        ;;
        opensuse*)
            zypper install -y nginx mariadb redis unzip git tar curl wget
        ;;
    esac
}

detect_os
log "Detected OS: $OS $VER"

# === USER INPUT ===
read -p "Panel FQDN: " FQDN
read -p "Email: " EMAIL
read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}
read -p "Admin Email: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}
read -s -p "Admin Password (blank=random): " ADMIN_PASS
echo
[[ -z "$ADMIN_PASS" ]] && ADMIN_PASS=$(openssl rand -base64 18) && warn "Random password generated!"

DB_PASS=$(openssl rand -base64 32)
PANEL_PORT=8080
TIMEZONE="Asia/Kolkata"

echo -e "\nStarting installer..."

install_php
install_dependencies

# === SQL Setup ===
systemctl start mariadb || true

mysql <<SQL
DROP DATABASE IF EXISTS pterodactyl;
CREATE DATABASE pterodactyl;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# === Composer ===
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# === PANEL INSTALL ===
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage bootstrap/cache
cp .env.example .env

# === ENV ===
sed -i "s|APP_URL=.*|APP_URL=http://$FQDN:$PANEL_PORT|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env
sed -i "s|APP_TIMEZONE=.*|APP_TIMEZONE=$TIMEZONE|" .env

composer install --no-dev --optimize-autoloader
php artisan key:generate --force
php artisan migrate --seed --force
php artisan p:user:make --email "$ADMIN_EMAIL" --username "$ADMIN_USER" --admin 1 --password "$ADMIN_PASS" --no-interaction

# === SSL (Self-signed) ===
mkdir -p /etc/letsencrypt/live/$FQDN
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/CN=$FQDN" \
    -keyout /etc/letsencrypt/live/$FQDN/privkey.pem \
    -out /etc/letsencrypt/live/$FQDN/fullchain.pem

# === NGINX ===
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

cat > /etc/nginx/conf.d/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name $FQDN;
    return 301 https://\$server_name\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $FQDN;
    root /var/www/pterodactyl/public;

    ssl_certificate /etc/letsencrypt/live/$FQDN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FQDN/privkey.pem;

    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php-fpm.sock;
        include fastcgi.conf;
    }
}
EOF

systemctl restart nginx

# === Done ===
clear
success "INSTALLATION COMPLETE!"
echo "Panel URL: https://$FQDN"
echo "User: $ADMIN_USER"
echo "Email: $ADMIN_EMAIL"
echo "Password: $ADMIN_PASS"
echo "Self-signed SSL installed."
