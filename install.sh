#!/bin/bash
# PTERODACTYL PANEL INSTALLER FIXED (Debian/Ubuntu)
# ==================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# Require root
if [ "$EUID" -ne 0 ]; then
  err "Run as root (sudo)."
fi

clear
echo -e "${GREEN}PTERODACTYL PANEL INSTALLER FIXED${NC}\n"

# ---------- Detect OS ----------
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="$ID"
  OS_NAME="$NAME"
  OS_VER="$VERSION_ID"
  CODENAME="$(lsb_release -sc 2>/dev/null || true)"
else
  err "Cannot detect OS. /etc/os-release missing."
fi

case "$OS_ID" in
  debian|ubuntu) ;;
  *) err "Unsupported OS: $OS_NAME ($OS_ID)."; ;;
esac

log "Detected: $OS_NAME $OS_VER (codename: ${CODENAME:-unknown})"

# ---------- User input ----------
read -p "Panel Domain (FQDN, e.g., node.example.com): " FQDN
[[ -z "$FQDN" ]] && err "FQDN required."

read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "Admin Password (blank=random): " ADMIN_PASS
echo
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS="$(openssl rand -base64 18)"
  warn "Random admin password generated: $ADMIN_PASS"
fi

DB_PASS="$(openssl rand -base64 32)"
TIMEZONE="Asia/Kolkata"

echo
log "Starting with: FQDN=$FQDN | Admin=$ADMIN_USER"
read -p "Press Enter to continue..."

# ---------- Remove old PHP PPAs ----------
log "Removing old Ondrej residues..."
rm -f /etc/apt/sources.list.d/ondrej-php*.list || true
sed -i '/ondrej\/php/d' /etc/apt/sources.list 2>/dev/null || true
apt-get update -y
ok "Old Ondrej PHP PPAs removed."

# ---------- Add Sury PHP repo on Debian ----------
if [[ "$OS_ID" == "debian" ]]; then
  log "Adding Sury PHP repository for Debian..."
  apt-get install -y lsb-release ca-certificates apt-transport-https software-properties-common gnupg2 curl
  curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/sury-php.list
  apt-get update -y
  ok "Sury PHP repository added."
fi

# ---------- Install dependencies ----------
log "Installing base dependencies..."
apt-get install -y ca-certificates curl wget lsb-release gnupg2 unzip git tar build-essential openssl software-properties-common mariadb-server mariadb-client nginx redis-server || true
systemctl enable --now mariadb
ok "Dependencies installed."

# ---------- Install PHP 8.1 ----------
if [[ "$OS_ID" == "debian" ]]; then
  log "Installing PHP 8.1 (Debian)..."
  apt-get install -y php8.1 php8.1-fpm php8.1-cli php8.1-mbstring php8.1-xml php8.1-curl php8.1-zip php8.1-gd php8.1-bcmath php8.1-mysql
else
  log "Installing PHP 8.1 (Ubuntu)..."
  add-apt-repository -y ppa:ondrej/php
  apt-get update -y
  apt-get install -y php8.1 php8.1-fpm php8.1-cli php8.1-mbstring php8.1-xml php8.1-curl php8.1-zip php8.1-gd php8.1-bcmath php8.1-mysql
fi
ok "PHP 8.1 installed."

# ---------- Create database ----------
log "Creating MySQL database and user..."
mysql <<SQL || err "MySQL commands failed"
DROP DATABASE IF EXISTS pterodactyl;
CREATE DATABASE pterodactyl;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
ok "Database created. Password: $DB_PASS"

# ---------- Download panel ----------
log "Downloading Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -sL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage bootstrap/cache
cp .env.example .env || true

# ---------- Configure .env ----------
log "Updating .env..."
sed -i "s|DB_DATABASE=.*|DB_DATABASE=pterodactyl|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env
sed -i "s|APP_URL=.*|APP_URL=https://$FQDN|" .env
sed -i "s|APP_TIMEZONE=.*|APP_TIMEZONE=$TIMEZONE|" .env
grep -q '^MAIL_FROM_ADDRESS' .env || echo "MAIL_FROM_ADDRESS=noreply@$FQDN" >> .env
grep -q '^MAIL_FROM_NAME' .env || echo "MAIL_FROM_NAME=\"Pterodactyl Panel\"" >> .env
chown -R www-data:www-data /var/www/pterodactyl

# ---------- SSL ----------
log "Creating SSL certificate..."
mkdir -p /etc/certs/certs
cd /etc/certs/certs
openssl req \
  -new \
  -newkey rsa:4096 \
  -days 3650 \
  -nodes \
  -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
  -keyout privkey.pem \
  -out fullchain.pem
ok "SSL certificate created."

# ---------- Nginx config ----------
log "Setting up Nginx..."
rm -f /etc/nginx/sites-enabled/default
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

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate /etc/certs/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/certs/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_intercept_errors off;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t && systemctl restart nginx || warn "Nginx reload failed."

# ---------- Composer & Laravel ----------
log "Installing PHP dependencies..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
cd /var/www/pterodactyl
composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force
php artisan config:clear
php artisan cache:clear
php artisan migrate --seed --force

# ---------- Create admin user ----------
log "Creating admin user..."
php artisan p:user:make --email "$ADMIN_EMAIL" --username "$ADMIN_USER" --name_first "Admin" --name_last "User" --admin 1 --password "$ADMIN_PASS" --no-interaction

clear
ok "PTERODACTYL PANEL INSTALL COMPLETE"
echo "=========================================="
echo "Panel HTTPS: https://$FQDN"
echo "Admin username: $ADMIN_USER"
echo "Admin email: $ADMIN_EMAIL"
echo "Admin password: $ADMIN_PASS"
echo "DB password (pterodactyl user): $DB_PASS"
echo "SSL cert: /etc/certs/certs"
echo "=========================================="
exit 0
