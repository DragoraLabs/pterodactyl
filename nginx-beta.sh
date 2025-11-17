#!/bin/bash
# Pterodactyl Panel Installer (Fixed)
# Supports Debian 11+ and Ubuntu 20.04+/22.04+/24.04+
set -euo pipefail
IFS=$'\n\t'

# Colors
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# require root
if [ "$EUID" -ne 0 ]; then
  err "Run this script as root (sudo)."
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

# ---------- Ask user ----------
read -p "Panel Domain (FQDN, e.g. node.example.com): " FQDN
[[ -z "$FQDN" ]] && err "FQDN required."

read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "Admin Password (leave blank to generate random): " ADMIN_PASS
echo
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS="$(openssl rand -base64 12)"
  warn "Random admin password generated: $ADMIN_PASS"
fi

read -p "Admin First Name [Admin]: " ADMIN_FIRST
ADMIN_FIRST=${ADMIN_FIRST:-Admin}
read -p "Admin Last Name [User]: " ADMIN_LAST
ADMIN_LAST=${ADMIN_LAST:-User}

TIMEZONE="Asia/Kolkata"
DB_NAME="pterodactyl"
DB_USER="pterodactyl"
# Use hex password (no slashes/newlines) to avoid SQL quoting issues
DB_PASS="$(openssl rand -hex 16)"

log "Working with: Domain=$FQDN | Admin=$ADMIN_USER | Email=$ADMIN_EMAIL"
read -p "Press Enter to continue..."

# ---------- Remove old Ondrej residues (safe) ----------
log "Cleaning old ondrej residues (if any)..."
rm -f /etc/apt/sources.list.d/ondrej-php*.list 2>/dev/null || true
# remove any exact reference lines to ondrej to avoid resolute LSB issues
if [ -d /etc/apt/sources.list.d ]; then
  sed -i '/ondrej/d' /etc/apt/sources.list.d/* 2>/dev/null || true
fi
sed -i '/ondrej\/php/d' /etc/apt/sources.list 2>/dev/null || true
apt-get update -y || true
ok "Cleaned."

# ---------- Install base packages ----------
log "Installing prerequisites..."
apt-get update -y
apt-get install -y ca-certificates curl wget lsb-release gnupg2 software-properties-common unzip git tar build-essential openssl apt-transport-https || err "Failed to install prerequisites"
ok "Prerequisites installed."

# ---------- PHP repo & install (Debian vs Ubuntu) ----------
log "Installing PHP (8.2 recommended)..."

# Helper: install PHP packages list
_install_php_pkgs() {
  apt-get install -y php${1} php${1}-fpm php${1}-cli php${1}-mbstring php${1}-xml php${1}-curl php${1}-zip php${1}-gd php${1}-bcmath php${1}-mysql || return 1
}

if [[ "$OS_ID" == "debian" ]]; then
  log "Adding Sury PHP repo for Debian..."
  curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ ${CODENAME} main" > /etc/apt/sources.list.d/sury-php.list
  apt-get update -y
  if ! _install_php_pkgs 8.2; then
    err "PHP 8.2 install failed on Debian."
  fi
else
  # Ubuntu (try Ondrej; but if adding PPA fails or codename unsupported, fallback to sury)
  SUPPORTED_UBUNTU_CODENAMES=("bionic" "focal" "jammy" "noble") # noble = 24.04 LTS codename
  if printf '%s\n' "${SUPPORTED_UBUNTU_CODENAMES[@]}" | grep -qx "${CODENAME}"; then
    log "Adding Ondřej Surý PPA for PHP (Ubuntu ${CODENAME})..."
    # make sure there aren't leftover entries causing 'resolute' style errors
    rm -f /etc/apt/sources.list.d/ondrej-php*.list 2>/dev/null || true
    add-apt-repository -y ppa:ondrej/php || warn "add-apt-repository returned non-zero; will attempt fallback."
    apt-get update -y || true
    if apt-cache policy | grep -q "ppa.launchpad.net/ondrej/php"; then
      if ! _install_php_pkgs 8.2; then
        warn "Ondrej install failed; falling back to Sury (Debian) method."
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ ${CODENAME} main" > /etc/apt/sources.list.d/sury-php.list
        apt-get update -y
        _install_php_pkgs 8.2 || err "PHP install failed after fallback."
      fi
    else
      # fallback to sury if PPA not available
      log "Ondrej PPA not present; using Sury as fallback."
      curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ ${CODENAME} main" > /etc/apt/sources.list.d/sury-php.list
      apt-get update -y
      _install_php_pkgs 8.2 || err "PHP install failed on Ubuntu fallback."
    fi
  else
    warn "Ubuntu codename '${CODENAME}' is not in supported list for Ondrej PPA; using Sury fallback."
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
    # For some Ubuntu versions lsb_release -sc may produce an unsupported codename — use 'jammy' as safe fallback for package path if needed
    SURY_CODENAME="${CODENAME}"
    if ! curl -sI "https://packages.sury.org/php/dists/${SURY_CODENAME}/Release" >/dev/null 2>&1; then
      SURY_CODENAME="jammy"
      warn "Using sury codename fallback: ${SURY_CODENAME}"
    fi
    echo "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ ${SURY_CODENAME} main" > /etc/apt/sources.list.d/sury-php.list
    apt-get update -y
    _install_php_pkgs 8.2 || err "PHP install failed on Ubuntu using sury fallback."
  fi
fi

ok "PHP 8.2 installed."
systemctl enable --now php8.2-fpm || true

# ---------- Install Nginx, MariaDB, Redis ----------
log "Installing nginx, mariadb, redis..."
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx mariadb-server mariadb-client redis-server || err "Failed installing webstack"
systemctl enable --now mariadb || true
systemctl enable --now nginx || true
systemctl enable --now redis-server || true
ok "Nginx, MariaDB, Redis installed."

# ---------- Create DB and user ----------
log "Creating MySQL database and user..."
# Use here-doc safely; password is safe (hex)
mysql -u root <<SQL || err "MySQL commands failed."
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
CREATE DATABASE \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
ok "Database '${DB_NAME}' and user '${DB_USER}' created. (Password will be written to .env)"

# ---------- Download panel ----------
log "Downloading Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -sL -o panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" || err "Failed to download panel tarball"
tar -xzf panel.tar.gz
rm -f panel.tar.gz
chmod -R 755 storage bootstrap/cache || true
cp .env.example .env || true
ok "Panel downloaded."

# ---------- Update .env reliably ----------
log "Updating .env (DB credentials, APP_URL, timezone)..."
# ensure .env exists
if [ ! -f .env ]; then
  cp .env.example .env
fi

# helper to replace or add key
set_env() {
  local key="$1"; local val="$2"
  if grep -qE "^${key}=" .env; then
    # escape backslashes, slashes for sed safely
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

set_env "APP_URL" "https://${FQDN}"
set_env "APP_TIMEZONE" "${TIMEZONE}"
set_env "DB_CONNECTION" "mysql"
set_env "DB_HOST" "127.0.0.1"
set_env "DB_PORT" "3306"
set_env "DB_DATABASE" "${DB_NAME}"
set_env "DB_USERNAME" "${DB_USER}"
set_env "DB_PASSWORD" "${DB_PASS}"
set_env "CACHE_DRIVER" "redis"
set_env "SESSION_DRIVER" "redis"
set_env "QUEUE_CONNECTION" "redis"
set_env "REDIS_HOST" "127.0.0.1"
set_env "MAIL_FROM_ADDRESS" "noreply@${FQDN}"
set_env "MAIL_FROM_NAME" "\"Pterodactyl Panel\""

chown -R www-data:www-data /var/www/pterodactyl || true
ok ".env updated with DB credentials and APP_URL."

# ---------- Composer install & artisan tasks ----------
log "Installing Composer and PHP dependencies..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer || err "Composer install failed"
export COMPOSER_ALLOW_SUPERUSER=1
cd /var/www/pterodactyl
# ensure composer runs non-interactive and accepts root
composer install --no-dev --optimize-autoloader --no-interaction || err "Composer failed"

log "Running artisan setup: key, config/cache clear, migrations..."
php artisan key:generate --force
php artisan config:clear || true
php artisan cache:clear || true
php artisan migrate --seed --force || err "Migrations failed"

# ---------- Create admin user ----------
log "Creating admin user..."
# NOTE: p:user:make expects --name-first and --name-last (older mistakes used --first-name)
php artisan p:user:make \
  --email "${ADMIN_EMAIL}" \
  --username "${ADMIN_USER}" \
  --name-first "${ADMIN_FIRST}" \
  --name-last "${ADMIN_LAST}" \
  --admin 1 \
  --password "${ADMIN_PASS}" \
  --no-interaction || warn "Admin creation may have failed (check artisan output)."

ok "Admin user creation attempted."

# ---------- PHP-FPM socket autodetect ----------
log "Detecting PHP-FPM socket..."
PHP_FPM_SOCK=""
for s in /run/php/php*-fpm.sock /var/run/php/php*-fpm.sock; do
  if compgen -G "$s" > /dev/null; then
    PHP_FPM_SOCK="$(compgen -G "$s" | head -n1)"
    break
  fi
done
if [[ -z "$PHP_FPM_SOCK" ]]; then
  if systemctl is-active --quiet php8.2-fpm 2>/dev/null; then
    PHP_FPM_SOCK="/run/php/php8.2-fpm.sock"
  else
    PHP_FPM_SOCK="127.0.0.1:9000"
  fi
fi
log "Using PHP-FPM socket: ${PHP_FPM_SOCK}"

# prepare FASTCGI_PASS value (nginx config)
if [[ "$PHP_FPM_SOCK" == /* ]]; then
  FASTCGI_PASS="unix:${PHP_FPM_SOCK}"
else
  FASTCGI_PASS="${PHP_FPM_SOCK}"
fi

# ---------- Create self-signed SSL ----------
log "Creating self-signed SSL at /etc/certs/certs ..."
mkdir -p /etc/certs/certs
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=${FQDN}" \
  -keyout /etc/certs/certs/privkey.pem \
  -out /etc/certs/certs/fullchain.pem || warn "OpenSSL generation returned non-zero"

chmod 644 /etc/certs/certs/fullchain.pem || true
chmod 600 /etc/certs/certs/privkey.pem || true
ok "Self-signed cert created."

# ---------- Write Nginx config ----------
log "Writing Nginx config to /etc/nginx/sites-available/pterodactyl.conf (and enabling)..."
NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"

cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    server_name ${FQDN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${FQDN};

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
        fastcgi_pass ${FASTCGI_PASS};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# enable site
rm -f /etc/nginx/sites-enabled/default
ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/pterodactyl.conf

# test and reload nginx
nginx -t && systemctl restart nginx || warn "nginx test/ restart failed - check logs"

# ---------- Final output ----------
clear
ok "PTERODACTYL PANEL INSTALL COMPLETE"
echo "=========================================="
echo "Panel URL: https://${FQDN}"
echo "Admin username: ${ADMIN_USER}"
echo "Admin email: ${ADMIN_EMAIL}"
echo "Admin password: ${ADMIN_PASS}"
echo "DB user: ${DB_USER}"
echo "DB password: ${DB_PASS}"
echo "Self-signed cert: /etc/certs/certs/fullchain.pem"
echo "Nginx config: ${NGINX_CONF}"
echo "=========================================="
