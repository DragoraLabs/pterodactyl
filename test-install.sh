sudo bash -c 'cat > /tmp/pterodactyl-installer.sh <<'"'INSTALLER'"'
#!/bin/bash
# Pterodactyl Panel Auto-Installer (panel-only)
# Supports Debian 11/12 and Ubuntu 20.04/22.04/24.04
set -euo pipefail
IFS=$'\n\t'

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

if [ "$EUID" -ne 0 ]; then
  err "Run as root (sudo)."
fi

clear
echo -e "${GREEN}Pterodactyl Panel Auto-Installer (panel-only)${NC}"
echo

# Detect OS
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="$ID"
  OS_NAME="$NAME"
  OS_VER="$VERSION_ID"
  CODENAME="$(lsb_release -sc 2>/dev/null || true)"
else
  err "/etc/os-release not found — cannot detect OS."
fi
log "Detected OS: $OS_NAME $OS_VER (codename: ${CODENAME:-unknown})"

# ---------- User input ----------
read -p "Panel Domain (FQDN, e.g. panel.example.com): " FQDN
[[ -z "$FQDN" ]] && err "FQDN required."

read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

read -p "Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "Admin Password (leave blank to auto-generate): " ADMIN_PASS
echo
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS="$(openssl rand -base64 18)"
  warn "Random admin password generated: $ADMIN_PASS"
fi

read -p "Admin First Name [Admin]: " ADMIN_FIRST
ADMIN_FIRST=${ADMIN_FIRST:-Admin}
read -p "Admin Last Name [User]: " ADMIN_LAST
ADMIN_LAST=${ADMIN_LAST:-User}

echo
echo "Choose PHP version to install:"
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

TIMEZONE="Asia/Kolkata"
DB_NAME="pterodactyl"
DB_USER="pterodactyl"
DB_PASS="$(openssl rand -hex 16)"  # hex is safe for SQL

log "Working with: Domain=${FQDN} | Admin=${ADMIN_USER} | PHP=${PHP_VER}"
read -p "Press Enter to continue..."

# ---------- Cleanup broken Ondrej lists (avoid resolute/malformed) ----------
log "Removing any existing ondrej entries and malformed files..."
shopt -s nullglob
for f in /etc/apt/sources.list.d/*ondrej* /etc/apt/sources.list.d/*ubuntu-php*; do
  [ -f "$f" ] && rm -f "$f"
done
# Also remove any single malformed .sources file mentioning ondrej
for s in /etc/apt/sources.list.d/*.sources; do
  if grep -qi "ondrej" "$s" 2>/dev/null; then rm -f "$s"; fi
done
# ensure main sources file doesn't include ondrej
sed -i '/ondrej/d' /etc/apt/sources.list 2>/dev/null || true
apt-get update -y >/dev/null 2>&1 || true
ok "Ondrej residues removed (if present)."

# ---------- base packages ----------
log "Installing prerequisites..."
apt-get update -y
apt-get install -y ca-certificates curl wget lsb-release gnupg2 software-properties-common unzip git tar build-essential openssl apt-transport-https || err "Failed to install prerequisites"
ok "Prerequisites installed."

# ---------- PHP install helper ----------
_install_php_pkgs() {
  local v="$1"
  apt-get install -y "php${v}" "php${v}-fpm" "php${v}-cli" "php${v}-mbstring" "php${v}-xml" "php${v}-curl" "php${v}-zip" "php${v}-gd" "php${v}-bcmath" "php${v}-mysql" || return 1
  return 0
}

log "Installing PHP ${PHP_VER}..."

if [[ "$OS_ID" == "debian" ]]; then
  # Use packages.sury.org on Debian
  curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
  # choose a codename fallback
  SURY_CODENAME="${CODENAME}"
  if ! curl -sI "https://packages.sury.org/php/dists/${SURY_CODENAME}/Release" >/dev/null 2>&1; then
    SURY_CODENAME="bullseye"
    warn "Sury codename fallback -> ${SURY_CODENAME}"
  fi
  printf "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n" "${SURY_CODENAME}" > /etc/apt/sources.list.d/sury-php.list
  apt-get update -y
  _install_php_pkgs "${PHP_VER}" || err "Failed installing PHP ${PHP_VER} on Debian."
else
  # Ubuntu: try Ondrej PPA if codename supported, else fallback to Sury
  SUPPORTED_UBUNTU_CODENAMES=("bionic" "focal" "jammy" "noble")
  if printf '%s\n' "${SUPPORTED_UBUNTU_CODENAMES[@]}" | grep -qx "${CODENAME}"; then
    add-apt-repository -y ppa:ondrej/php || warn "add-apt-repository failed (continuing to fallback if needed)"
    apt-get update -y || true
    if apt-cache policy | grep -q "ppa.launchpadcontent.net/ondrej/php"; then
      _install_php_pkgs "${PHP_VER}" || warn "Ondrej install failed — will try Sury fallback"
    fi
  fi
  if ! command -v php >/dev/null 2>&1 || ! php -v >/dev/null 2>&1; then
    # Fallback to Sury
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
    SURY_CODENAME="${CODENAME}"
    if ! curl -sI "https://packages.sury.org/php/dists/${SURY_CODENAME}/Release" >/dev/null 2>&1; then
      SURY_CODENAME="jammy"
      warn "Sury codename fallback -> ${SURY_CODENAME}"
    fi
    printf "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n" "${SURY_CODENAME}" > /etc/apt/sources.list.d/sury-php.list
    apt-get update -y
    _install_php_pkgs "${PHP_VER}" || err "PHP install failed on Ubuntu fallback."
  fi
fi

ok "PHP ${PHP_VER} installed."
systemctl enable --now "php${PHP_VER}-fpm" >/dev/null 2>&1 || true

# ---------- webstack ----------
log "Installing nginx, mariadb, redis..."
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx mariadb-server mariadb-client redis-server || err "Failed installing webstack"
systemctl enable --now mariadb nginx redis-server || true
ok "Nginx, MariaDB, Redis installed."

# ---------- create DB & user ----------
log "Creating database '${DB_NAME}' and user '${DB_USER}'..."
mysql -u root <<SQL || err "MySQL commands failed (check root access)."
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
ok "Database and user created."

# ---------- download panel ----------
log "Downloading Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -sL -o panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" || err "Failed to download panel tarball"
tar -xzf panel.tar.gz
rm -f panel.tar.gz
chmod -R 755 storage bootstrap/cache || true
cp .env.example .env || true
ok "Panel downloaded."

# ---------- update .env (DB + app url etc) ----------
log "Updating .env (DB creds, APP_URL, timezone)..."
set_env() {
  key="$1"; val="$2"
  if grep -qE "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

set_env "APP_URL" "https://${FQDN}"
set_env "APP_TIMEZONE" "${TIMEZONE}"
set_env "APP_ENVIRONMENT_ONLY" "false"
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

# create a temporary APP_KEY to prevent composer/post-autoload errors
TMP_APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"
set_env "APP_KEY" "${TMP_APP_KEY}"

chown -R www-data:www-data /var/www/pterodactyl || true
ok ".env written."

# ---------- composer & deps ----------
log "Installing composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer || err "Composer install failed"
export COMPOSER_ALLOW_SUPERUSER=1

log "Installing PHP dependencies (composer)... This can take several minutes."
cd /var/www/pterodactyl
# make composer non-interactive and auto-yes
COMPOSER_MEMORY_LIMIT=-1 composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction || err "Composer install failed"

# after composer, generate a fresh proper APP_KEY
log "Generating application key and running artisan tasks..."
php artisan key:generate --force
php artisan config:clear || true
php artisan cache:clear || true

log "Running migrations & seeders..."
php artisan migrate --seed --force || err "Migrations failed — check DB credentials and logs"

# ---------- create admin user ----------
log "Creating admin user (artisan p:user:make)..."
php artisan p:user:make \
  --email "${ADMIN_EMAIL}" \
  --username "${ADMIN_USER}" \
  --name-first "${ADMIN_FIRST}" \
  --name-last "${ADMIN_LAST}" \
  --admin 1 \
  --password "${ADMIN_PASS}" \
  --no-interaction || warn "Admin creation returned non-zero; check artisan output."

ok "Admin creation attempted."

# ---------- detect PHP-FPM socket ----------
log "Detecting PHP-FPM socket for nginx config..."
PHP_FPM_SOCK=""
for s in /run/php/php*-fpm.sock /var/run/php/php*-fpm.sock; do
  if compgen -G "$s" > /dev/null; then
    PHP_FPM_SOCK="$(compgen -G "$s" | head -n1)"
    break
  fi
done
if [[ -z "$PHP_FPM_SOCK" ]]; then
  if systemctl is-active --quiet "php${PHP_VER}-fpm" 2>/dev/null; then
    PHP_FPM_SOCK="/run/php/php${PHP_VER}-fpm.sock"
  else
    PHP_FPM_SOCK="127.0.0.1:9000"
  fi
fi
if [[ "$PHP_FPM_SOCK" == /* ]]; then
  FASTCGI_PASS="unix:${PHP_FPM_SOCK}"
else
  FASTCGI_PASS="${PHP_FPM_SOCK}"
fi
log "PHP-FPM socket -> ${PHP_FPM_SOCK}"

# ---------- create self-signed ssl ----------
log "Generating self-signed certificate under /etc/certs/certs ..."
mkdir -p /etc/certs/certs
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/CN=${FQDN}/O=Pterodactyl" \
  -keyout /etc/certs/certs/privkey.pem \
  -out /etc/certs/certs/fullchain.pem || warn "OpenSSL returned non-zero (check /etc/certs/certs)"

chmod 644 /etc/certs/certs/fullchain.pem || true
chmod 600 /etc/certs/certs/privkey.pem || true
ok "Self-signed certificate created."

# ---------- nginx config ----------
log "Writing nginx config to /etc/nginx/sites-available/pterodactyl.conf ..."
NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
cat > "${NGINX_CONF}" <<'NGCONF'
server {
    listen 80;
    server_name __FQDN__;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name __FQDN__;

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
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass __FASTCGI__;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
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
NGCONF

# replace placeholders
sed -i "s|__FQDN__|${FQDN}|g" "${NGINX_CONF}"
sed -i "s|__FASTCGI__|${FASTCGI_PASS}|g" "${NGINX_CONF}"

# enable & restart nginx
rm -f /etc/nginx/sites-enabled/default
ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t && systemctl restart nginx || warn "nginx test/restart failed"

# ---------- finish ----------
clear
ok "PTERODACTYL PANEL INSTALL COMPLETE (panel-only)"
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
INSTALLER
bash /tmp/pterodactyl-installer.sh'
