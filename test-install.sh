#!/bin/bash
# Pterodactyl Full Auto-Installer (Panel + Wings)
# Supports Debian 11/12 and Ubuntu 20.04/22.04/24.04
# Interactive menu: Panel / Wings / Panel+Wings / System info / Exit
# WARNING: This script performs system installs (apt, composer, nginx, mariadb, redis, systemd services).
set -euo pipefail
IFS=$'\n\t'

# ---------------- Colors & helpers ----------------
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

if [ "$EUID" -ne 0 ]; then
  err "Run this script as root (sudo)."
fi

# ---------------- Detect OS ----------------
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

# ---------------- Utility functions ----------------
ask() {
  local prompt="$1" default="$2" var
  read -p "$prompt" var
  if [ -z "$var" ]; then
    echo "$default"
  else
    echo "$var"
  fi
}

set_env_value() {
  # args: key value (writes to .env in current dir)
  local key="$1" value="$2"
  if grep -qE "^${key}=" .env 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

# ---------------- Menu ----------------
show_menu() {
  cat <<'MENU'

============================================
      Pterodactyl Full Auto-Installer
============================================
1) Install Panel (Pterodactyl)
2) Install Wings (node)
3) Install Panel + Wings
4) System info
5) Exit
MENU
  read -p "Choose an option [1-5]: " MENU_CHOICE
  echo "$MENU_CHOICE"
}

# ---------------- Common cleanup for ondrej issues ----------------
cleanup_ondrej() {
  log "Cleaning any broken/old ondrej PPA files..."
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*ondrej* /etc/apt/sources.list.d/*ubuntu-php*; do
    [ -f "$f" ] && rm -f "$f"
  done
  for s in /etc/apt/sources.list.d/*.sources; do
    if grep -qi "ondrej" "$s" 2>/dev/null; then rm -f "$s"; fi
  done
  sed -i '/ondrej\/php/d' /etc/apt/sources.list 2>/dev/null || true
  apt-get update -y >/dev/null 2>&1 || true
  ok "Ondrej residues removed."
}

# ---------------- Panel Installer ----------------
install_panel() {
  log "=== PANEL INSTALLER ==="

  # Ask interactive questions
  FQDN="$(ask 'Panel Domain (FQDN, e.g. panel.example.com): ' '')"
  if [ -z "$FQDN" ]; then err "FQDN required."; fi

  ADMIN_EMAIL="$(ask "Admin Email [admin@$FQDN]: " "admin@$FQDN")"
  ADMIN_USER="$(ask "Admin Username [admin]: " "admin")"
  read -s -p "Admin Password (leave blank to auto-generate): " ADMIN_PASS
  echo
  if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS="$(openssl rand -base64 18)"
    warn "Random admin password generated: $ADMIN_PASS"
  fi
  ADMIN_FIRST="$(ask "Admin First Name [Admin]: " "Admin")"
  ADMIN_LAST="$(ask "Admin Last Name [User]: " "User")"

  echo
  echo "Choose PHP version:"
  echo " 1) 8.1"
  echo " 2) 8.2 (recommended)"
  echo " 3) 8.3"
  PHP_CHOICE="$(ask "Select (1/2/3) [2]: " "2")"
  case "$PHP_CHOICE" in
    1) PHP_VER="8.1";;
    2) PHP_VER="8.2";;
    3) PHP_VER="8.3";;
    *) PHP_VER="8.2";;
  esac

  TIMEZONE="Asia/Kolkata"
  DB_NAME="pterodactyl"
  DB_USER="pterodactyl"
  DB_PASS="$(openssl rand -hex 16)"  # safe for SQL

  log "Panel will be installed for ${FQDN}. PHP ${PHP_VER}. DB user ${DB_USER}."

  read -p "Press Enter to continue (or Ctrl+C to cancel) ..."

  # Clean ondrej files that cause errors
  cleanup_ondrej

  # Install prerequisites
  log "Installing prerequisites..."
  apt-get update -y
  apt-get install -y ca-certificates curl wget lsb-release gnupg2 software-properties-common unzip git tar build-essential openssl apt-transport-https || err "Failed installing prerequisites"
  ok "Prerequisites installed."

  # Install PHP via Sury (Debian) or Ondrej/Sury fallback (Ubuntu)
  log "Installing PHP ${PHP_VER}..."
  _install_php_pkgs() {
    apt-get install -y "php${1}" "php${1}-fpm" "php${1}-cli" "php${1}-mbstring" "php${1}-xml" "php${1}-curl" "php${1}-zip" "php${1}-gd" "php${1}-bcmath" "php${1}-mysql" || return 1
    return 0
  }

  if [[ "$OS_ID" == "debian" ]]; then
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
    SURY_CODENAME="${CODENAME:-bullseye}"
    printf "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n" "${SURY_CODENAME}" > /etc/apt/sources.list.d/sury-php.list
    apt-get update -y
    _install_php_pkgs "${PHP_VER}" || err "PHP install failed (Debian)"
  else
    # Try Ondrej PPA for supported codenames else fallback to Sury
    SUPPORTED_UBUNTU_CODENAMES=("bionic" "focal" "jammy" "noble")
    if printf '%s\n' "${SUPPORTED_UBUNTU_CODENAMES[@]}" | grep -qx "${CODENAME:-}"; then
      add-apt-repository -y ppa:ondrej/php || warn "add-apt-repository failed (continuing to fallback)"
      apt-get update -y || true
      if apt-cache policy | grep -q "ppa.launchpadcontent.net/ondrej/php"; then
        if ! _install_php_pkgs "${PHP_VER}"; then
          warn "Ondrej install failed — falling back to Sury"
        fi
      fi
    fi
    if ! command -v php >/dev/null 2>&1; then
      curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
      SURY_CODENAME="${CODENAME:-jammy}"
      # fallback check:
      if ! curl -sI "https://packages.sury.org/php/dists/${SURY_CODENAME}/Release" >/dev/null 2>&1; then
        SURY_CODENAME="jammy"
      fi
      printf "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n" "${SURY_CODENAME}" > /etc/apt/sources.list.d/sury-php.list
      apt-get update -y
      _install_php_pkgs "${PHP_VER}" || err "PHP install failed (Ubuntu fallback)"
    fi
  fi

  systemctl enable --now "php${PHP_VER}-fpm" || true
  ok "PHP ${PHP_VER} installed."

  # Install web stack
  log "Installing nginx, mariadb, redis..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx mariadb-server mariadb-client redis-server || err "Failed installing webstack"
  systemctl enable --now mariadb nginx redis-server || true
  ok "Webstack installed."

  # Create DB and user
  log "Creating database '${DB_NAME}' and user '${DB_USER}'..."
  mysql -u root <<SQL || err "MySQL step failed. Check root access."
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  ok "Database & user created."

  # Download panel
  log "Downloading Pterodactyl Panel..."
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl
  curl -sL -o panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" || err "Failed to download panel"
  tar -xzf panel.tar.gz
  rm -f panel.tar.gz
  cp .env.example .env || true
  chmod -R 755 storage bootstrap/cache || true
  chown -R www-data:www-data /var/www/pterodactyl || true
  ok "Panel files in /var/www/pterodactyl."

  # Update .env
  log "Writing .env values..."
  set_env_value "APP_URL" "https://${FQDN}"
  set_env_value "APP_TIMEZONE" "${TIMEZONE}"
  set_env_value "APP_ENVIRONMENT_ONLY" "false"
  set_env_value "DB_CONNECTION" "mysql"
  set_env_value "DB_HOST" "127.0.0.1"
  set_env_value "DB_PORT" "3306"
  set_env_value "DB_DATABASE" "${DB_NAME}"
  set_env_value "DB_USERNAME" "${DB_USER}"
  set_env_value "DB_PASSWORD" "${DB_PASS}"
  set_env_value "CACHE_DRIVER" "redis"
  set_env_value "SESSION_DRIVER" "redis"
  set_env_value "QUEUE_CONNECTION" "redis"
  set_env_value "REDIS_HOST" "127.0.0.1"
  set_env_value "MAIL_FROM_ADDRESS" "noreply@${FQDN}"
  set_env_value "MAIL_FROM_NAME" "\"Pterodactyl Panel\""

  # Temporary APP_KEY to avoid composer/artisan complaints
  TMP_APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"
  set_env_value "APP_KEY" "${TMP_APP_KEY}"

  ok ".env updated."

  # Composer / dependencies
  log "Installing composer and PHP dependencies..."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer || err "Composer install failed"
  export COMPOSER_ALLOW_SUPERUSER=1
  cd /var/www/pterodactyl
  COMPOSER_MEMORY_LIMIT=-1 composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction || err "Composer failed"
  ok "Composer deps installed."

  # Artisan tasks
  log "Running artisan commands (key, cache, migrate & seed)..."
  php artisan key:generate --force
  php artisan config:clear || true
  php artisan cache:clear || true
  php artisan migrate --seed --force || err "Migrations failed"
  ok "Artisan migrations & seeders complete."

  # Create admin user (p:user:make expects --name-first/--name-last)
  log "Creating admin user..."
  php artisan p:user:make \
    --email "${ADMIN_EMAIL}" \
    --username "${ADMIN_USER}" \
    --name-first "${ADMIN_FIRST}" \
    --name-last "${ADMIN_LAST}" \
    --admin 1 \
    --password "${ADMIN_PASS}" \
    --no-interaction || warn "Admin creation returned non-zero; check artisan output."

  ok "Admin creation attempted."

  # Create certs (always overwrite as requested)
  log "Generating self-signed certs at /etc/certs (always overwrite)..."
  mkdir -p /etc/certs
  openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/CN=${FQDN}/O=Pterodactyl" \
    -keyout /etc/certs/privkey.pem \
    -out /etc/certs/fullchain.pem || warn "OpenSSL exited non-zero"
  chmod 600 /etc/certs/privkey.pem || true
  chmod 644 /etc/certs/fullchain.pem || true
  ok "Self-signed certs created."

  # Nginx config (fastcgi to detected PHP-FPM)
  log "Detecting PHP-FPM socket..."
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
  ok "Using PHP-FPM socket: ${PHP_FPM_SOCK}"

  NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
  cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    server_name ${FQDN};
    return 301 https://\$host\$request_uri;
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

    ssl_certificate /etc/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/privkey.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${PHP_FPM_SOCK#/run/} # fallback handled below
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

  # If PHP_FPM_SOCK is tcp format, replace fastcgi_pass line correctly
  if [[ "$PHP_FPM_SOCK" == 127.* ]]; then
    sed -i "s|fastcgi_pass unix:.*|fastcgi_pass ${PHP_FPM_SOCK};|" "${NGINX_CONF}"
  else
    # Ensure unix: prefix
    sed -i "s|fastcgi_pass unix:.*|fastcgi_pass unix:${PHP_FPM_SOCK};|" "${NGINX_CONF}"
  fi

  rm -f /etc/nginx/sites-enabled/default
  ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/pterodactyl.conf
  nginx -t && systemctl restart nginx || warn "nginx test/restart failed - check logs"

  ok "Panel installation finished."
  echo "Panel: https://${FQDN}"
  echo "Admin: ${ADMIN_USER} / ${ADMIN_EMAIL} (pw: ${ADMIN_PASS})"
  echo "DB user: ${DB_USER} pw: ${DB_PASS}"
}

# ---------------- Wings Installer ----------------
install_wings() {
  log "=== WINGS INSTALLER ==="

  # Ask interactive for wings config
  NODE_FQDN="$(ask 'Node FQDN (e.g. node.example.com): ' '')"
  if [ -z "$NODE_FQDN" ]; then err "Node FQDN required."; fi

  # Ports (you requested to ask)
  WINGS_PORT="$(ask 'Enter Wings Port (default 8080): ' '8080')"
  BIND_PORT="$(ask 'Enter Wings Bind Port (default 2022): ' '2022')"

  # Token values, you requested separate asks
  NODE_UUID="$(ask 'Enter node UUID: ' '')"
  TOKEN_ID="$(ask 'Enter token_id: ' '')"
  TOKEN="$(ask 'Enter token: ' '')"

  log "Wings will be installed for Node ${NODE_FQDN}, port ${WINGS_PORT}, bind ${BIND_PORT}."

  read -p "Press Enter to continue (or Ctrl+C to cancel) ..."

  # Install prerequisites: curl, tar, jq, docker
  log "Installing prerequisites for Wings..."
  apt-get update -y
  apt-get install -y curl wget tar jq ca-certificates || err "Failed prerequisites"
  # Install Docker (simple route)
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing docker.io ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io || warn "docker.io install failed, please install docker manually"
    systemctl enable --now docker || true
  fi
  ok "Prerequisites installed."

  # Create /etc/certs and ALWAYS generate new certs (overwrite) as requested
  log "Creating /etc/certs and generating self-signed certs (overwrite)..."
  mkdir -p /etc/certs
  (cd /etc/certs && openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/CN=${NODE_FQDN}/O=Wings" \
    -keyout privkey.pem -out fullchain.pem) || warn "OpenSSL returned non-zero"
  chmod 600 /etc/certs/privkey.pem || true
  chmod 644 /etc/certs/fullchain.pem || true
  ok "Certs created at /etc/certs/fullchain.pem & privkey.pem (overwritten)."

  # Create wings directories & user
  log "Preparing /etc/wings and /var/lib/wings..."
  mkdir -p /etc/wings
  mkdir -p /var/lib/wings
  chown -R root:root /etc/wings
  ok "Directories ready."

  # Download wings binary (Linux amd64)
  log "Downloading Wings binary (linux/amd64) to /usr/local/bin/wings ..."
  WINGS_URL="https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"
  if curl -fsSL --head "$WINGS_URL" >/dev/null 2>&1; then
    curl -fsSL -o /usr/local/bin/wings "$WINGS_URL" || err "Failed to download wings binary"
    chmod +x /usr/local/bin/wings
  else
    warn "Could not fetch wings binary from GitHub. Please download manually to /usr/local/bin/wings."
  fi
  ok "Wings binary in place (if download succeeded)."

  # Build config.yml for wings (basic, using provided values)
  WINGS_CONFIG="/etc/wings/config.yml"
  log "Writing Wings config to ${WINGS_CONFIG} ..."
  cat > "${WINGS_CONFIG}" <<WCFG
debug: false
system:
  data: /var/lib/wings
api:
  host: 0.0.0.0
  port: ${WINGS_PORT}
  ssl:
    enabled: true
    cert: /etc/certs/fullchain.pem
    key: /etc/certs/privkey.pem
  upload_limit: 100
  token: "${TOKEN}"
  token_id: "${TOKEN_ID}"
  uuid: "${NODE_UUID}"
  # Note: The Pterodactyl Panel must point to this node: https://${NODE_FQDN}:${WINGS_PORT}
websocket:
  host: 0.0.0.0
  port: ${BIND_PORT}
  ssl:
    enabled: true
    cert: /etc/certs/fullchain.pem
    key: /etc/certs/privkey.pem
metrics:
  enabled: true
  driver: prometheus
  port: 8081
  path: /metrics
WCFG

  chmod 640 "${WINGS_CONFIG}" || true
  ok "Wings config written."

  # Create systemd service for wings
  log "Creating systemd service /etc/systemd/system/wings.service ..."
  cat > /etc/systemd/system/wings.service <<EOS
[Unit]
Description=Pterodactyl Wings
After=network.target docker.service
Wants=docker.service

[Service]
User=root
Group=root
WorkingDirectory=/etc/wings
ExecStart=/usr/local/bin/wings --config /etc/wings/config.yml
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOS

  systemctl daemon-reload
  systemctl enable --now wings || warn "Failed to start wings service (check journalctl -u wings)"
  ok "Wings service installed and attempted to start."

  echo
  ok "Wings installation completed."
  echo "Node: ${NODE_FQDN}"
  echo "Wings API Port: ${WINGS_PORT}"
  echo "Websocket Bind Port: ${BIND_PORT}"
  echo "Config: ${WINGS_CONFIG}"
}

# ---------------- System info ----------------
system_info() {
  echo "=== SYSTEM INFO ==="
  uname -a
  lsb_release -a 2>/dev/null || true
  echo
  echo "Disk:"
  df -h
  echo
  echo "Memory:"
  free -h
  echo
  echo "Docker:"
  docker --version 2>/dev/null || echo "docker not installed"
  echo
  read -p "Press Enter to return to menu..."
}

# ---------------- Main loop ----------------
while true; do
  CHOICE=$(show_menu)
  case "$CHOICE" in
    1) install_panel; break ;;
    2) install_wings; break ;;
    3) install_panel; install_wings; break ;;
    4) system_info ;;
    5) echo "Exiting."; exit 0 ;;
    *) echo "Invalid option."; ;;
  esac
done

echo
ok "Installer finished. Review output and logs (/var/log/syslog, journalctl -u wings, /var/www/pterodactyl/storage/logs/)."
#!/bin/bash
# Pterodactyl Full Auto-Installer (Panel + Wings)
# Supports Debian 11/12 and Ubuntu 20.04/22.04/24.04
# Interactive menu: Panel / Wings / Panel+Wings / System info / Exit
# WARNING: This script performs system installs (apt, composer, nginx, mariadb, redis, systemd services).
set -euo pipefail
IFS=$'\n\t'

# ---------------- Colors & helpers ----------------
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

if [ "$EUID" -ne 0 ]; then
  err "Run this script as root (sudo)."
fi

# ---------------- Detect OS ----------------
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

# ---------------- Utility functions ----------------
ask() {
  local prompt="$1" default="$2" var
  read -p "$prompt" var
  if [ -z "$var" ]; then
    echo "$default"
  else
    echo "$var"
  fi
}

set_env_value() {
  # args: key value (writes to .env in current dir)
  local key="$1" value="$2"
  if grep -qE "^${key}=" .env 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

# ---------------- Menu ----------------
show_menu() {
  cat <<'MENU'

============================================
      Pterodactyl Full Auto-Installer
============================================
1) Install Panel (Pterodactyl)
2) Install Wings (node)
3) Install Panel + Wings
4) System info
5) Exit
MENU
  read -p "Choose an option [1-5]: " MENU_CHOICE
  echo "$MENU_CHOICE"
}

# ---------------- Common cleanup for ondrej issues ----------------
cleanup_ondrej() {
  log "Cleaning any broken/old ondrej PPA files..."
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*ondrej* /etc/apt/sources.list.d/*ubuntu-php*; do
    [ -f "$f" ] && rm -f "$f"
  done
  for s in /etc/apt/sources.list.d/*.sources; do
    if grep -qi "ondrej" "$s" 2>/dev/null; then rm -f "$s"; fi
  done
  sed -i '/ondrej\/php/d' /etc/apt/sources.list 2>/dev/null || true
  apt-get update -y >/dev/null 2>&1 || true
  ok "Ondrej residues removed."
}

# ---------------- Panel Installer ----------------
install_panel() {
  log "=== PANEL INSTALLER ==="

  # Ask interactive questions
  FQDN="$(ask 'Panel Domain (FQDN, e.g. panel.example.com): ' '')"
  if [ -z "$FQDN" ]; then err "FQDN required."; fi

  ADMIN_EMAIL="$(ask "Admin Email [admin@$FQDN]: " "admin@$FQDN")"
  ADMIN_USER="$(ask "Admin Username [admin]: " "admin")"
  read -s -p "Admin Password (leave blank to auto-generate): " ADMIN_PASS
  echo
  if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS="$(openssl rand -base64 18)"
    warn "Random admin password generated: $ADMIN_PASS"
  fi
  ADMIN_FIRST="$(ask "Admin First Name [Admin]: " "Admin")"
  ADMIN_LAST="$(ask "Admin Last Name [User]: " "User")"

  echo
  echo "Choose PHP version:"
  echo " 1) 8.1"
  echo " 2) 8.2 (recommended)"
  echo " 3) 8.3"
  PHP_CHOICE="$(ask "Select (1/2/3) [2]: " "2")"
  case "$PHP_CHOICE" in
    1) PHP_VER="8.1";;
    2) PHP_VER="8.2";;
    3) PHP_VER="8.3";;
    *) PHP_VER="8.2";;
  esac

  TIMEZONE="Asia/Kolkata"
  DB_NAME="pterodactyl"
  DB_USER="pterodactyl"
  DB_PASS="$(openssl rand -hex 16)"  # safe for SQL

  log "Panel will be installed for ${FQDN}. PHP ${PHP_VER}. DB user ${DB_USER}."

  read -p "Press Enter to continue (or Ctrl+C to cancel) ..."

  # Clean ondrej files that cause errors
  cleanup_ondrej

  # Install prerequisites
  log "Installing prerequisites..."
  apt-get update -y
  apt-get install -y ca-certificates curl wget lsb-release gnupg2 software-properties-common unzip git tar build-essential openssl apt-transport-https || err "Failed installing prerequisites"
  ok "Prerequisites installed."

  # Install PHP via Sury (Debian) or Ondrej/Sury fallback (Ubuntu)
  log "Installing PHP ${PHP_VER}..."
  _install_php_pkgs() {
    apt-get install -y "php${1}" "php${1}-fpm" "php${1}-cli" "php${1}-mbstring" "php${1}-xml" "php${1}-curl" "php${1}-zip" "php${1}-gd" "php${1}-bcmath" "php${1}-mysql" || return 1
    return 0
  }

  if [[ "$OS_ID" == "debian" ]]; then
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
    SURY_CODENAME="${CODENAME:-bullseye}"
    printf "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n" "${SURY_CODENAME}" > /etc/apt/sources.list.d/sury-php.list
    apt-get update -y
    _install_php_pkgs "${PHP_VER}" || err "PHP install failed (Debian)"
  else
    # Try Ondrej PPA for supported codenames else fallback to Sury
    SUPPORTED_UBUNTU_CODENAMES=("bionic" "focal" "jammy" "noble")
    if printf '%s\n' "${SUPPORTED_UBUNTU_CODENAMES[@]}" | grep -qx "${CODENAME:-}"; then
      add-apt-repository -y ppa:ondrej/php || warn "add-apt-repository failed (continuing to fallback)"
      apt-get update -y || true
      if apt-cache policy | grep -q "ppa.launchpadcontent.net/ondrej/php"; then
        if ! _install_php_pkgs "${PHP_VER}"; then
          warn "Ondrej install failed — falling back to Sury"
        fi
      fi
    fi
    if ! command -v php >/dev/null 2>&1; then
      curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-archive-keyring.gpg
      SURY_CODENAME="${CODENAME:-jammy}"
      # fallback check:
      if ! curl -sI "https://packages.sury.org/php/dists/${SURY_CODENAME}/Release" >/dev/null 2>&1; then
        SURY_CODENAME="jammy"
      fi
      printf "deb [signed-by=/usr/share/keyrings/sury-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n" "${SURY_CODENAME}" > /etc/apt/sources.list.d/sury-php.list
      apt-get update -y
      _install_php_pkgs "${PHP_VER}" || err "PHP install failed (Ubuntu fallback)"
    fi
  fi

  systemctl enable --now "php${PHP_VER}-fpm" || true
  ok "PHP ${PHP_VER} installed."

  # Install web stack
  log "Installing nginx, mariadb, redis..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx mariadb-server mariadb-client redis-server || err "Failed installing webstack"
  systemctl enable --now mariadb nginx redis-server || true
  ok "Webstack installed."

  # Create DB and user
  log "Creating database '${DB_NAME}' and user '${DB_USER}'..."
  mysql -u root <<SQL || err "MySQL step failed. Check root access."
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  ok "Database & user created."

  # Download panel
  log "Downloading Pterodactyl Panel..."
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl
  curl -sL -o panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" || err "Failed to download panel"
  tar -xzf panel.tar.gz
  rm -f panel.tar.gz
  cp .env.example .env || true
  chmod -R 755 storage bootstrap/cache || true
  chown -R www-data:www-data /var/www/pterodactyl || true
  ok "Panel files in /var/www/pterodactyl."

  # Update .env
  log "Writing .env values..."
  set_env_value "APP_URL" "https://${FQDN}"
  set_env_value "APP_TIMEZONE" "${TIMEZONE}"
  set_env_value "APP_ENVIRONMENT_ONLY" "false"
  set_env_value "DB_CONNECTION" "mysql"
  set_env_value "DB_HOST" "127.0.0.1"
  set_env_value "DB_PORT" "3306"
  set_env_value "DB_DATABASE" "${DB_NAME}"
  set_env_value "DB_USERNAME" "${DB_USER}"
  set_env_value "DB_PASSWORD" "${DB_PASS}"
  set_env_value "CACHE_DRIVER" "redis"
  set_env_value "SESSION_DRIVER" "redis"
  set_env_value "QUEUE_CONNECTION" "redis"
  set_env_value "REDIS_HOST" "127.0.0.1"
  set_env_value "MAIL_FROM_ADDRESS" "noreply@${FQDN}"
  set_env_value "MAIL_FROM_NAME" "\"Pterodactyl Panel\""

  # Temporary APP_KEY to avoid composer/artisan complaints
  TMP_APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"
  set_env_value "APP_KEY" "${TMP_APP_KEY}"

  ok ".env updated."

  # Composer / dependencies
  log "Installing composer and PHP dependencies..."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer || err "Composer install failed"
  export COMPOSER_ALLOW_SUPERUSER=1
  cd /var/www/pterodactyl
  COMPOSER_MEMORY_LIMIT=-1 composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction || err "Composer failed"
  ok "Composer deps installed."

  # Artisan tasks
  log "Running artisan commands (key, cache, migrate & seed)..."
  php artisan key:generate --force
  php artisan config:clear || true
  php artisan cache:clear || true
  php artisan migrate --seed --force || err "Migrations failed"
  ok "Artisan migrations & seeders complete."

  # Create admin user (p:user:make expects --name-first/--name-last)
  log "Creating admin user..."
  php artisan p:user:make \
    --email "${ADMIN_EMAIL}" \
    --username "${ADMIN_USER}" \
    --name-first "${ADMIN_FIRST}" \
    --name-last "${ADMIN_LAST}" \
    --admin 1 \
    --password "${ADMIN_PASS}" \
    --no-interaction || warn "Admin creation returned non-zero; check artisan output."

  ok "Admin creation attempted."

  # Create certs (always overwrite as requested)
  log "Generating self-signed certs at /etc/certs (always overwrite)..."
  mkdir -p /etc/certs
  openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/CN=${FQDN}/O=Pterodactyl" \
    -keyout /etc/certs/privkey.pem \
    -out /etc/certs/fullchain.pem || warn "OpenSSL exited non-zero"
  chmod 600 /etc/certs/privkey.pem || true
  chmod 644 /etc/certs/fullchain.pem || true
  ok "Self-signed certs created."

  # Nginx config (fastcgi to detected PHP-FPM)
  log "Detecting PHP-FPM socket..."
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
  ok "Using PHP-FPM socket: ${PHP_FPM_SOCK}"

  NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
  cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    server_name ${FQDN};
    return 301 https://\$host\$request_uri;
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

    ssl_certificate /etc/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/privkey.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${PHP_FPM_SOCK#/run/} # fallback handled below
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

  # If PHP_FPM_SOCK is tcp format, replace fastcgi_pass line correctly
  if [[ "$PHP_FPM_SOCK" == 127.* ]]; then
    sed -i "s|fastcgi_pass unix:.*|fastcgi_pass ${PHP_FPM_SOCK};|" "${NGINX_CONF}"
  else
    # Ensure unix: prefix
    sed -i "s|fastcgi_pass unix:.*|fastcgi_pass unix:${PHP_FPM_SOCK};|" "${NGINX_CONF}"
  fi

  rm -f /etc/nginx/sites-enabled/default
  ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/pterodactyl.conf
  nginx -t && systemctl restart nginx || warn "nginx test/restart failed - check logs"

  ok "Panel installation finished."
  echo "Panel: https://${FQDN}"
  echo "Admin: ${ADMIN_USER} / ${ADMIN_EMAIL} (pw: ${ADMIN_PASS})"
  echo "DB user: ${DB_USER} pw: ${DB_PASS}"
}

# ---------------- Wings Installer ----------------
install_wings() {
  log "=== WINGS INSTALLER ==="

  # Ask interactive for wings config
  NODE_FQDN="$(ask 'Node FQDN (e.g. node.example.com): ' '')"
  if [ -z "$NODE_FQDN" ]; then err "Node FQDN required."; fi

  # Ports (you requested to ask)
  WINGS_PORT="$(ask 'Enter Wings Port (default 8080): ' '8080')"
  BIND_PORT="$(ask 'Enter Wings Bind Port (default 2022): ' '2022')"

  # Token values, you requested separate asks
  NODE_UUID="$(ask 'Enter node UUID: ' '')"
  TOKEN_ID="$(ask 'Enter token_id: ' '')"
  TOKEN="$(ask 'Enter token: ' '')"

  log "Wings will be installed for Node ${NODE_FQDN}, port ${WINGS_PORT}, bind ${BIND_PORT}."

  read -p "Press Enter to continue (or Ctrl+C to cancel) ..."

  # Install prerequisites: curl, tar, jq, docker
  log "Installing prerequisites for Wings..."
  apt-get update -y
  apt-get install -y curl wget tar jq ca-certificates || err "Failed prerequisites"
  # Install Docker (simple route)
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing docker.io ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io || warn "docker.io install failed, please install docker manually"
    systemctl enable --now docker || true
  fi
  ok "Prerequisites installed."

  # Create /etc/certs and ALWAYS generate new certs (overwrite) as requested
  log "Creating /etc/certs and generating self-signed certs (overwrite)..."
  mkdir -p /etc/certs
  (cd /etc/certs && openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/CN=${NODE_FQDN}/O=Wings" \
    -keyout privkey.pem -out fullchain.pem) || warn "OpenSSL returned non-zero"
  chmod 600 /etc/certs/privkey.pem || true
  chmod 644 /etc/certs/fullchain.pem || true
  ok "Certs created at /etc/certs/fullchain.pem & privkey.pem (overwritten)."

  # Create wings directories & user
  log "Preparing /etc/wings and /var/lib/wings..."
  mkdir -p /etc/wings
  mkdir -p /var/lib/wings
  chown -R root:root /etc/wings
  ok "Directories ready."

  # Download wings binary (Linux amd64)
  log "Downloading Wings binary (linux/amd64) to /usr/local/bin/wings ..."
  WINGS_URL="https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"
  if curl -fsSL --head "$WINGS_URL" >/dev/null 2>&1; then
    curl -fsSL -o /usr/local/bin/wings "$WINGS_URL" || err "Failed to download wings binary"
    chmod +x /usr/local/bin/wings
  else
    warn "Could not fetch wings binary from GitHub. Please download manually to /usr/local/bin/wings."
  fi
  ok "Wings binary in place (if download succeeded)."

  # Build config.yml for wings (basic, using provided values)
  WINGS_CONFIG="/etc/wings/config.yml"
  log "Writing Wings config to ${WINGS_CONFIG} ..."
  cat > "${WINGS_CONFIG}" <<WCFG
debug: false
system:
  data: /var/lib/wings
api:
  host: 0.0.0.0
  port: ${WINGS_PORT}
  ssl:
    enabled: true
    cert: /etc/certs/fullchain.pem
    key: /etc/certs/privkey.pem
  upload_limit: 100
  token: "${TOKEN}"
  token_id: "${TOKEN_ID}"
  uuid: "${NODE_UUID}"
  # Note: The Pterodactyl Panel must point to this node: https://${NODE_FQDN}:${WINGS_PORT}
websocket:
  host: 0.0.0.0
  port: ${BIND_PORT}
  ssl:
    enabled: true
    cert: /etc/certs/fullchain.pem
    key: /etc/certs/privkey.pem
metrics:
  enabled: true
  driver: prometheus
  port: 8081
  path: /metrics
WCFG

  chmod 640 "${WINGS_CONFIG}" || true
  ok "Wings config written."

  # Create systemd service for wings
  log "Creating systemd service /etc/systemd/system/wings.service ..."
  cat > /etc/systemd/system/wings.service <<EOS
[Unit]
Description=Pterodactyl Wings
After=network.target docker.service
Wants=docker.service

[Service]
User=root
Group=root
WorkingDirectory=/etc/wings
ExecStart=/usr/local/bin/wings --config /etc/wings/config.yml
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOS

  systemctl daemon-reload
  systemctl enable --now wings || warn "Failed to start wings service (check journalctl -u wings)"
  ok "Wings service installed and attempted to start."

  echo
  ok "Wings installation completed."
  echo "Node: ${NODE_FQDN}"
  echo "Wings API Port: ${WINGS_PORT}"
  echo "Websocket Bind Port: ${BIND_PORT}"
  echo "Config: ${WINGS_CONFIG}"
}

# ---------------- System info ----------------
system_info() {
  echo "=== SYSTEM INFO ==="
  uname -a
  lsb_release -a 2>/dev/null || true
  echo
  echo "Disk:"
  df -h
  echo
  echo "Memory:"
  free -h
  echo
  echo "Docker:"
  docker --version 2>/dev/null || echo "docker not installed"
  echo
  read -p "Press Enter to return to menu..."
}

# ---------------- Main loop ----------------
while true; do
  CHOICE=$(show_menu)
  case "$CHOICE" in
    1) install_panel; break ;;
    2) install_wings; break ;;
    3) install_panel; install_wings; break ;;
    4) system_info ;;
    5) echo "Exiting."; exit 0 ;;
    *) echo "Invalid option."; ;;
  esac
done

echo
ok "Installer finished. Review output and logs (/var/log/syslog, journalctl -u wings, /var/www/pterodactyl/storage/logs/)."
