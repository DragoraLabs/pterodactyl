#!/bin/bash
# PTERODACTYL PANEL INSTALLER (Debian/Ubuntu only)
# - Supports: Debian 10/11/12 and Ubuntu 18.04/20.04/22.04/24.04
# - Removes accidental ondrej residues, adds bullseye archive if needed
# - Installs PHP 8.1 properly (Sury for Debian, PPA for Ubuntu)
# - Auto-detects PHP-FPM socket
# - Minimal panel-only install (no Wings)
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
echo -e "${GREEN}PTERODACTYL PANEL INSTALLER (Debian/Ubuntu)${NC}\n"

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
  *) err "Unsupported OS: $OS_NAME ($OS_ID). This installer supports Debian/Ubuntu only."; ;;
esac

log "Detected: $OS_NAME $OS_VER (codename: ${CODENAME:-unknown})"

# ---------- User input ----------
read -p "Panel FQDN (e.g. node.example.com): " FQDN
[[ -z "$FQDN" ]] && err "FQDN required."

read -p "Email (for alerts): " EMAIL
[[ -z "$EMAIL" ]] && err "Email required."

read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

read -s -p "Admin Password (blank=random): " ADMIN_PASS
echo
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS="$(openssl rand -base64 18)"
  warn "Random password generated."
fi

DB_PASS="$(openssl rand -base64 32)"
TIMEZONE="Asia/Kolkata"
PANEL_PORT=8080

echo
log "Starting with: FQDN=$FQDN | Admin=$ADMIN_USER | Port=$PANEL_PORT"
read -p "Press Enter to continue..."


# ---------- Remove ondrej residues (user requested) ----------
log "Removing any ondrej (PPA) residues..."
rm -f /etc/apt/sources.list.d/ondrej-php*.list || true
rm -f /etc/apt/sources.list.d/*ondrej*.list || true
sed -i '/ondrej\/php/d' /etc/apt/sources.list 2>/dev/null || true
sed -i '/ppa.launchpad.net\/ondrej/d' /etc/apt/sources.list.d/* 2>/dev/null || true
apt-get update -y || true
ok "Removed ondrej residues (if any)."


# ---------- Debian bullseye-archive handling ----------
if [[ "$OS_ID" == "debian" && "$CODENAME" == "bullseye" ]]; then
  log "Adding archived bullseye-backports (Debian 11) and disabling Check-Valid-Until..."
  cat > /etc/apt/sources.list.d/bullseye-backports.list <<EOF
deb http://archive.debian.org/debian bullseye-backports main contrib non-free
EOF
  echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
  apt-get update -y
  ok "Bullseye archive backports added."
fi

# ---------- Install base deps ----------
log "Installing common prerequisites..."
if [[ "$OS_ID" == "ubuntu" ]]; then
  apt-get update -y
fi
apt-get install -y ca-certificates curl wget lsb-release gnupg2 unzip git tar build-essential openssl || true
ok "Prerequisites installed."


# ---------- Install PHP 8.1 (Sury for Debian, PPA for Ubuntu) ----------
install_php_debian() {
  log "Installing PHP 8.1 on Debian via packages.sury.org..."
  # add Sury GPG key and repo (works on Debian & Debian-based)
  curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/sury-php.list
  apt-get update -y
  apt-get install -y php8.1 php8.1-fpm php8.1-cli php8.1-mbstring php8.1-xml \
    php8.1-curl php8.1-zip php8.1-gd php8.1-bcmath php8.1-mysql || \
    err "Failed to install PHP 8.1 packages on Debian."
  ok "PHP 8.1 installed (Debian)."
}

install_php_ubuntu() {
  log "Installing PHP 8.1 on Ubuntu via Ondřej PPA..."
  apt-get update -y
  apt-get install -y software-properties-common
  add-apt-repository -y ppa:ondrej/php
  apt-get update -y
  apt-get install -y php8.1 php8.1-fpm php8.1-cli php8.1-mbstring php8.1-xml \
    php8.1-curl php8.1-zip php8.1-gd php8.1-bcmath php8.1-mysql || \
    err "Failed to install PHP 8.1 packages on Ubuntu."
  ok "PHP 8.1 installed (Ubuntu)."
}

case "$OS_ID" in
  debian)
    install_php_debian
    ;;
  ubuntu)
    install_php_ubuntu
    ;;
esac


# ---------- Install Nginx, MariaDB, Redis ----------
log "Installing Nginx, MariaDB, Redis..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx mariadb-server mariadb-client redis-server || \
  err "Failed to install Nginx/MariaDB/Redis."
ok "Nginx, MariaDB, Redis installed."

# Start MariaDB
systemctl enable --now mariadb || true

# ---------- Create DB and user ----------
log "Creating MySQL database and user..."
mysql <<SQL || err "MySQL commands failed."
DROP DATABASE IF EXISTS pterodactyl;
CREATE DATABASE pterodactyl;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
ok "Database created."

# ---------- Composer ----------
log "Installing Composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer || err "Composer install failed."
ok "Composer installed."

# ---------- Panel download & setup ----------
log "Downloading Panel (latest release tarball)..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -sL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz || err "Failed to download panel tarball."
tar -xzf panel.tar.gz
chmod -R 755 storage bootstrap/cache || true
cp .env.example .env || true

# Put minimal env values (we will override key parts)
log "Writing minimal .env adjustments..."
sed -i "s|APP_URL=.*|APP_URL=http://$FQDN:$PANEL_PORT|" .env || true
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env || true
sed -i "s|APP_TIMEZONE=.*|APP_TIMEZONE=$TIMEZONE|" .env || true
# Set mail from if missing
grep -q '^MAIL_FROM_ADDRESS' .env || echo "MAIL_FROM_ADDRESS=noreply@$FQDN" >> .env
grep -q '^MAIL_FROM_NAME' .env || echo "MAIL_FROM_NAME=\"Pterodactyl Panel\"" >> .env

chown -R www-data:www-data /var/www/pterodactyl || true

# ---------- Composer install & migrations ----------
log "Installing PHP dependencies (composer). This may take a while..."
composer install --no-dev --optimize-autoloader --no-interaction || err "Composer install failed."

log "Generating app key and running migrations..."
php artisan key:generate --force
php artisan migrate --seed --force

log "Creating admin user..."
php artisan p:user:make --email "$ADMIN_EMAIL" --username "$ADMIN_USER" --admin 1 --password "$ADMIN_PASS" --no-interaction

ok "Panel database and admin user set up."

# ---------- PHP-FPM socket autodetect ----------
log "Detecting PHP-FPM socket..."
PHP_FPM_SOCK=""
# typical sockets
for s in /run/php/php*-fpm.sock /var/run/php/php*-fpm.sock; do
  if compgen -G "$s" > /dev/null; then
    PHP_FPM_SOCK="$(compgen -G "$s" | head -n1)"
    break
  fi
done

# fallback to tcp if no socket
if [[ -z "$PHP_FPM_SOCK" ]]; then
  # check for service names
  if systemctl is-active --quiet php8.1-fpm 2>/dev/null; then
    PHP_FPM_SOCK="unix:/run/php/php8.1-fpm.sock"
  else
    PHP_FPM_SOCK="127.0.0.1:9000"
  fi
fi
log "Using PHP-FPM socket: $PHP_FPM_SOCK"

# ---------- Self-signed cert (placeholder) ----------
log "Generating self-signed cert (3650 days)..."
mkdir -p /etc/letsencrypt/live/"$FQDN"
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/CN=$FQDN/O=Pterodactyl" \
  -keyout /etc/letsencrypt/live/"$FQDN"/privkey.pem \
  -out /etc/letsencrypt/live/"$FQDN"/fullchain.pem
ok "Self-signed cert created."

# ---------- Nginx config ----------
log "Writing Nginx configuration..."
NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
cat > "$NGINX_CONF" <<EOF
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

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    sendfile off;

    ssl_certificate /etc/letsencrypt/live/$FQDN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FQDN/privkey.pem;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass $PHP_FPM_SOCK;
        fastcgi_index index.php;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf
# remove default if present
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default || true

nginx -t && systemctl restart nginx || warn "Nginx config/test failed; check logs."

# ---------- Reverse proxy for panel on port 8080 (optional) ----------
log "Adding reverse-proxy config for Panel on port $PANEL_PORT -> internal (if needed)..."
cat > /etc/nginx/sites-available/pterodactyl-8080.conf <<EOF
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
EOF
ln -sf /etc/nginx/sites-available/pterodactyl-8080.conf /etc/nginx/sites-enabled/

systemctl reload nginx || true

# ---------- Firewall (attempt UFW) ----------
if command -v ufw >/dev/null 2>&1; then
  log "Opening ports 80,443,$PANEL_PORT via UFW..."
  ufw allow 80,443,"$PANEL_PORT" || true
  ufw reload || true
fi

# ---------- Permissions ----------
chown -R www-data:www-data /var/www/pterodactyl || true
ok "Permissions set."

# ---------- Output ----------
clear
ok "PTERODACTYL PANEL INSTALL COMPLETE (panel-only)"
echo "=========================================="
echo "Panel HTTP (if used): http://$FQDN:$PANEL_PORT"
echo "Panel HTTPS: https://$FQDN"
echo "Admin username: $ADMIN_USER"
echo "Admin email: $ADMIN_EMAIL"
echo "Admin password: $ADMIN_PASS"
echo "DB password (pterodactyl user): $DB_PASS"
echo
echo "Self-signed cert installed at /etc/letsencrypt/live/$FQDN/"
echo "For production SSL run: certbot --nginx -d $FQDN"
echo "=========================================="

exit 0
