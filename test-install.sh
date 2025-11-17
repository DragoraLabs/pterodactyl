#!/usr/bin/env bash
# Pterodactyl FULL Auto-Installer (Panel + Wings + Cloudflare guidance)
# Supports Debian 11/12 and Ubuntu 20.04/22.04/24.04 (and WSL2)
# WARNING: run as root. This will install packages, write certs and services.
set -euo pipefail
IFS=$'\n\t'

# ---------- Colors ----------
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# ---------- Require root ----------
if [ "$EUID" -ne 0 ]; then
  err "Run this script as root (sudo)."
fi

# ---------- Detect OS ----------
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

# ---------- Helpers ----------
set_env() {
  local key="$1"; local val="$2"
  if grep -qE "^${key}=" "$ENVFILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENVFILE"
  else
    echo "${key}=${val}" >> "$ENVFILE"
  fi
}

_install_php_pkgs() {
  local ver="$1"
  apt-get install -y "php${ver}" "php${ver}-fpm" "php${ver}-cli" "php${ver}-mbstring" "php${ver}-xml" "php${ver}-curl" "php${ver}-zip" "php${ver}-gd" "php${ver}-bcmath" "php${ver}-mysql" || return 1
  return 0
}

# ---------- Menu ----------
cat <<'MENU'
============================================
      Pterodactyl Full Auto-Installer
============================================
  1) Install Panel only
  2) Install Wings (node) only
  3) Install Panel + Wings (full)
  4) System info
  5) Exit
MENU

read -p "Choose an option [1-5] (default 3 - full): " MENU_CHOICE
MENU_CHOICE=${MENU_CHOICE:-3}

# ---------- Common interactive inputs ----------
ask_common_panel() {
  read -p "Panel Domain (FQDN, e.g. panel.example.com): " FQDN
  [[ -z "$FQDN" ]] && err "FQDN required."

  read -p "Admin Email [admin@${FQDN}]: " ADMIN_EMAIL
  ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@${FQDN}"}

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

  TIMEZONE="Asia/Kolkata"
  DB_NAME="pterodactyl"
  DB_USER="pterodactyl"
  DB_PASS="$(openssl rand -hex 16)"

  log "Panel will be installed for domain: ${FQDN}, PHP ${PHP_VER}"
}

ask_common_wings() {
  read -p "Wings Node FQDN (e.g. node.panel.example.com) [use same domain if single host]: " WINGS_FQDN
  WINGS_FQDN=${WINGS_FQDN:-$FQDN}

  read -p "Wings Port (panel-facing) [default 8080]: " WINGS_PORT
  WINGS_PORT=${WINGS_PORT:-8080}

  read -p "Wings Bind Port (internal bind for servers, default 2022): " WINGS_BIND_PORT
  WINGS_BIND_PORT=${WINGS_BIND_PORT:-2022}

  read -p "Node UUID (from Panel): " NODE_UUID
  read -p "Token ID (from Panel): " TOKEN_ID
  read -p "Token (from Panel): " TOKEN_SECRET

  read -p "Always generate/overwrite certs at /etc/certs? (yes/no) [yes]: " GEN_CERTS
  GEN_CERTS=${GEN_CERTS:-yes}
}

sys_info() {
  echo "---- System info ----"
  uname -a
  echo
  lsb_release -a 2>/dev/null || true
  echo
  echo "Memory:"
  free -h
  echo
  echo "Disk:"
  df -h
  echo "---------------------"
}

# ---------- Steps: common cleaning & prerequisites ----------
common_prep() {
  log "Cleaning old Ondrej residues (if any)..."
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*ondrej* /etc/apt/sources.list.d/*ubuntu-php*; do
    [ -f "$f" ] && rm -f "$f" || true
  done
  for s in /etc/apt/sources.list.d/*.sources; do
    if grep -qi "ondrej" "$s" 2>/dev/null; then rm -f "$s"; fi
  done
  sed -i '/ondrej\/php/d' /etc/apt/sources.list 2>/dev/null || true
  apt-get update -y || true
  ok "Cleaned."

  log "Installing base prerequisites..."
  apt-get update -y
  apt-get install -y ca-certificates curl wget gnupg2 lsb-release apt-transport-https software-properties-common unzip git tar build-essential openssl || err "Failed prerequisites"
  ok "Prerequisites installed."
}

# ---------- Install PHP ----------
install_php() {
  local ver="$1"
  log "Installing PHP ${ver}..."

  if [[ "$OS_ID" == "debian" ]]; then
    log "Adding Sury repo for Debian..."
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
    SURY_CODENAME="${CODENAME:-bullseye}"
    if ! curl -sI "https://packages.sury.org/php/dists/${SURY_CODENAME}/Release" >/dev/null 2>&1; then
      SURY_CODENAME="bullseye"
      warn "Sury codename fallback -> ${SURY_CODENAME}"
    fi
    printf "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n" "${SURY_CODENAME}" > /etc/apt/sources.list.d/sury-php.list
    apt-get update -y
    _install_php_pkgs "${ver}" || err "PHP ${ver} failed on Debian"
  else
    # Ubuntu: try Ondrej PPA for supported codenames, else fallback to Sury
    SUPPORTED_UBUNTU_CODENAMES=("bionic" "focal" "jammy" "noble")
    if printf '%s\n' "${SUPPORTED_UBUNTU_CODENAMES[@]}" | grep -qx "${CODENAME}"; then
      add-apt-repository -y ppa:ondrej/php || warn "add-apt-repository returned non-zero"
      apt-get update -y || true
      if apt-cache policy | grep -q "ppa.launchpadcontent.net/ondrej/php"; then
        _install_php_pkgs "${ver}" || warn "Ondrej install failed, will try Sury fallback"
      fi
    fi
    if ! command -v php >/dev/null 2>&1; then
      curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
      SURY_CODENAME="${CODENAME:-jammy}"
      if ! curl -sI "https://packages.sury.org/php/dists/${SURY_CODENAME}/Release" >/dev/null 2>&1; then
        SURY_CODENAME="jammy"
        warn "Sury codename fallback -> ${SURY_CODENAME}"
      fi
      printf "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n" "${SURY_CODENAME}" > /etc/apt/sources.list.d/sury-php.list
      apt-get update -y
      _install_php_pkgs "${ver}" || err "PHP ${ver} failed on Ubuntu fallback"
    fi
  fi

  systemctl enable --now "php${ver}-fpm" >/dev/null 2>&1 || true
  ok "PHP ${ver} installed and php${ver}-fpm enabled."
}

# ---------- Install web stack ----------
install_webstack() {
  log "Installing nginx, mariadb-server, redis..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx mariadb-server redis-server || err "Failed to install web stack"
  systemctl enable --now nginx mariadb redis-server || true
  ok "Web stack installed & started."
}

# ---------- Install Panel ----------
install_panel() {
  ask_common_panel

  common_prep

  install_php "${PHP_VER}"

  install_webstack

  log "Creating DB and user '${DB_USER}'..."
  mysql -u root <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  ok "Database and user created."

  log "Downloading Pterodactyl panel..."
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl
  curl -sL -o panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" || err "Failed to download panel tarball"
  tar -xzf panel.tar.gz
  rm -f panel.tar.gz
  chmod -R 755 storage bootstrap/cache || true
  cp .env.example .env || true
  ENVFILE="/var/www/pterodactyl/.env"

  log "Updating .env..."
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

  # Temporary minimal APP_KEY to avoid composer script errors; will be properly generated after composer
  TMP_APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"
  set_env "APP_KEY" "${TMP_APP_KEY}"

  chown -R www-data:www-data /var/www/pterodactyl || true
  ok ".env configured."

  log "Installing Composer..."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer || err "Composer install failed"
  export COMPOSER_ALLOW_SUPERUSER=1

  cd /var/www/pterodactyl
  log "Running composer install (non-interactive). This may take several minutes..."
  COMPOSER_MEMORY_LIMIT=-1 composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction || err "Composer install failed"

  log "Running artisan key:generate, cache clear and migrations..."
  php artisan key:generate --force
  php artisan config:clear || true
  php artisan cache:clear || true
  php artisan migrate --seed --force || err "Migrations failed"

  log "Creating admin user..."
  # p:user:make supports --name-first and --name-last as of recent versions
  php artisan p:user:make \
    --email "${ADMIN_EMAIL}" \
    --username "${ADMIN_USER}" \
    --name-first "${ADMIN_FIRST}" \
    --name-last "${ADMIN_LAST}" \
    --admin 1 \
    --password "${ADMIN_PASS}" \
    --no-interaction || warn "Admin creation may have returned non-zero (check artisan output)."

  ok "Panel installed and admin user attempted."

  # detect php-fpm socket for nginx config
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

  # create certs directory and generate certs (overwrite)
  mkdir -p /etc/certs/certs
  log "Generating self-signed certificate at /etc/certs/certs (will overwrite if exists)..."
  openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/CN=${FQDN}/O=Pterodactyl" \
    -keyout /etc/certs/certs/privkey.pem \
    -out /etc/certs/certs/fullchain.pem || warn "OpenSSL returned non-zero"
  chmod 644 /etc/certs/certs/fullchain.pem || true
  chmod 600 /etc/certs/certs/privkey.pem || true
  ok "Certs generated."

  # Nginx config
  NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
  log "Writing Nginx config to ${NGINX_CONF} ..."
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
    sendfile off;

    ssl_certificate /etc/certs/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/certs/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
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
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

  rm -f /etc/nginx/sites-enabled/default
  ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/pterodactyl.conf
  nginx -t && systemctl restart nginx || warn "nginx test/restart failed"

  ok "Panel setup complete."
  echo
  echo "Panel URL: https://${FQDN}"
  echo "Admin username: ${ADMIN_USER}"
  echo "Admin email: ${ADMIN_EMAIL}"
  echo "Admin password: ${ADMIN_PASS}"
  echo "DB user: ${DB_USER}"
  echo "DB password: ${DB_PASS}"
  echo
  echo "Cloudflare guidance (if using Cloudflare Tunnel):"
  echo " - Service Type: HTTPS"
  echo " - URL (to route to): https://localhost:443"
  echo " - Additional settings -> TLS: No TLS Verify = ON"
  echo
}

# ---------- Install Wings ----------
install_wings() {
  # Allow to re-use FQDN from Panel if already set, else prompt for basic values
  if [[ -z "${FQDN:-}" ]]; then
    read -p "Wings Node FQDN (e.g. node.example.com): " WINGS_FQDN
  else
    read -p "Wings Node FQDN (default: ${FQDN}): " WINGS_FQDN
    WINGS_FQDN=${WINGS_FQDN:-$FQDN}
  fi

  read -p "Wings Port (http/s endpoint for panel, default 8080): " WINGS_PORT
  WINGS_PORT=${WINGS_PORT:-8080}

  read -p "Wings bind port (daemon bind_port for nodes, default 2022): " WINGS_BIND_PORT
  WINGS_BIND_PORT=${WINGS_BIND_PORT:-2022}

  read -p "Node UUID (from Panel): " NODE_UUID
  read -p "Token ID (from Panel): " TOKEN_ID
  read -p "Token (from Panel): " TOKEN_SECRET

  read -p "Always generate new certs for Wings at /etc/certs? (yes/no) [yes]: " GEN_CERTS
  GEN_CERTS=${GEN_CERTS:-yes}

  # install prereqs: docker, curl, tar
  log "Installing Wings prerequisites (docker, curl)..."
  apt-get update -y
  apt-get install -y curl tar wget jq ca-certificates apt-transport-https gnupg2 lsb-release || true

  # docker install (if missing)
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker (official convenience script)..."
    curl -fsSL https://get.docker.com | bash || warn "Docker install failed — ensure docker is installed"
    systemctl enable --now docker || true
  fi

  # create certs
  mkdir -p /etc/certs
  if [[ "$GEN_CERTS" == "yes" || "$GEN_CERTS" == "y" ]]; then
    log "Generating/overwriting certs at /etc/certs/fullchain.pem and /etc/certs/privkey.pem ..."
    (cd /etc/certs && openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
      -subj "/CN=${WINGS_FQDN}/O=Pterodactyl-Wings" \
      -keyout privkey.pem -out fullchain.pem) || warn "openssl returned non-zero"
    chmod 600 /etc/certs/privkey.pem || true
    chmod 644 /etc/certs/fullchain.pem || true
  fi

  # create wings config directory
  mkdir -p /etc/pterodactyl
  WINGS_CFG="/etc/pterodactyl/config.yml"

  log "Writing Wings config to ${WINGS_CFG} ..."
  cat > "${WINGS_CFG}" <<YML
# Pterodactyl Wings configuration autogenerated by installer
uuid: "${NODE_UUID}"
token_id: "${TOKEN_ID}"
token: "${TOKEN_SECRET}"

[web]
  listen: "0.0.0.0:${WINGS_PORT}"
  host: "${WINGS_FQDN}"

[remote]
  # listening port for remote server connections
  bind: "0.0.0.0:${WINGS_BIND_PORT}"

[ssl]
  enabled: true
  # path to fullchain and private key
  cert: /etc/certs/fullchain.pem
  key: /etc/certs/privkey.pem

[system]
  data: /var/lib/pterodactyl/volumes
  # path for wings to store data, logs, etc
  log: /var/log/wings.log
YML

  chown -R root:root /etc/pterodactyl
  chmod 600 "${WINGS_CFG}" || true

  # download wings binary
  log "Downloading Wings binary (latest)..."
  WINGS_BIN="/usr/local/bin/wings"
  curl -fsSL -o "${WINGS_BIN}" "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64" || err "Failed to download wings binary"
  chmod +x "${WINGS_BIN}" || true
  ok "Wings binary installed at ${WINGS_BIN}"

  # create systemd service
  cat > /etc/systemd/system/wings.service <<'SERVICE'
[Unit]
Description=Pterodactyl Wings
After=docker.service
Requires=docker.service

[Service]
User=root
Group=root
WorkingDirectory=/etc/pterodactyl
ExecStart=/usr/local/bin/wings --config /etc/pterodactyl/config.yml
Restart=on-failure
StartLimitInterval=600
StartLimitBurst=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable --now wings.service || warn "Failed to enable/start wings.service automatically"
  ok "Wings service enabled and started (check 'systemctl status wings')."

  echo
  echo "Wings setup summary:"
  echo " - Node FQDN: ${WINGS_FQDN}"
  echo " - Panel will talk to Wings at: https://${WINGS_FQDN}:${WINGS_PORT} (if behind Cloudflare, use tunnel)"
  echo " - Wings systemd service: wings.service"
  echo " - Wings config: ${WINGS_CFG}"
  echo " - Certs: /etc/certs/fullchain.pem (cert), /etc/certs/privkey.pem (key)"
  echo
}

# ---------- Main: route menu choices ----------
case "${MENU_CHOICE}" in
  1)
    install_panel
    ;;
  2)
    install_wings
    ;;
  3)
    install_panel
    echo
    read -p "Proceed to install and configure Wings on this host? (y/N): " PROCEED_W
    PROCEED_W=${PROCEED_W:-N}
    if [[ "${PROCEED_W,,}" == "y" || "${PROCEED_W,,}" == "yes" ]]; then
      install_wings
    else
      log "Skipping Wings installation as requested."
      echo "If you want to install Wings later, re-run and choose option 2."
    fi
    ;;
  4)
    sys_info
    ;;
  5)
    echo "Bye."
    exit 0
    ;;
  *)
    warn "Unknown option, performing full install (panel + wings)."
    install_panel
    install_wings
    ;;
esac

# ---------- final instructions ----------
echo
ok "ALL DONE. Useful commands:"
echo " - Check Panel logs: tail -f /var/www/pterodactyl/storage/logs/laravel-$(date +%F).log"
echo " - Check Wings logs: journalctl -u wings -f"
echo " - Nginx logs: /var/log/nginx/pterodactyl.app-error.log"
echo
echo -e "${YELLOW}If you're using Cloudflare (proxy/Tunnel):${NC}"
echo " - Create Cloudflare Tunnel or Route to forward your subdomain to https://localhost:443"
echo " - In Cloudflare published app: Service Type = HTTPS, URL = https://localhost:443"
echo " - Additional application settings -> TLS: set 'No TLS Verify' ON"
echo
echo "Panel URL: https://${FQDN}"
echo "Admin username: ${ADMIN_USER}"
echo "Admin email: ${ADMIN_EMAIL}"
echo "Admin password: ${ADMIN_PASS}"
echo "DB user: ${DB_USER}"
echo "DB pass: ${DB_PASS}"
echo
ok "Script finished. Please check logs and the running services."
