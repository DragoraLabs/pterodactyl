#!/usr/bin/env bash
# Pterodactyl All-in-One Installer - Multi-Distro 2026 Edition
# Supports: Ubuntu 22.04/24.04 • Debian 11/12/13 • Rocky/AlmaLinux 8/9
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail
IFS=$'\n\t'

# Colors
RED='\033[1;31m' GREEN='\033[1;32m' YELLOW='\033[1;33m' BLUE='\033[1;34m' NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && err "This script must be run as root (sudo)."

clear
echo -e "${GREEN}Pterodactyl All-in-One Installer  —  2026 Multi-Distro Edition${NC}"
echo "Supported: Ubuntu 22/24, Debian 11–13, Rocky/Alma 8/9"

# ─── OS & Package Manager Detection ────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    . /etc/os-release 2>/dev/null || err "Cannot read /etc/os-release"
else
    err "Cannot detect operating system (missing /etc/os-release)"
fi

ID="${ID:-unknown}"
VERSION_ID="${VERSION_ID:-unknown}"
CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"

log "Detected: $PRETTY_NAME  (ID=$ID  Version=$VERSION_ID  Codename=$CODENAME)"

case "$ID" in
    ubuntu)
        OS_FAMILY="debian"
        PKG="apt-get -yqq"
        PKG_UPDATE="apt-get update -yqq"
        PHP_REPO="ondrej/php"
        DOCKER_PKG="docker.io"
        ;;
    debian)
        OS_FAMILY="debian"
        PKG="apt-get -yqq"
        PKG_UPDATE="apt-get update -yqq"
        PHP_REPO="sury"   # deb.sury.org is very reliable for Debian
        DOCKER_PKG="docker.io"
        ;;
    rocky|almalinux|rhel|centos)
        OS_FAMILY="rhel"
        PKG="dnf -y -q"
        PKG_UPDATE="dnf makecache -q && dnf update -y -q"
        PHP_REPO="remi"
        DOCKER_PKG="docker-ce docker-ce-cli containerd.io"
        ;;
    *)
        err "Unsupported distribution: $ID $VERSION_ID\nCurrently supported families: debian-based & rhel-based"
        ;;
esac

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH_TAG="amd64" ;;
    aarch64) ARCH_TAG="arm64" ;;
    *)       err "Unsupported architecture: $ARCH" ;;
esac

log "Architecture: $ARCH ($ARCH_TAG)"

# ─── Helper: Install packages with detected manager ────────────────────────
install_pkgs() {
    $PKG install -y "$@" || err "Package installation failed"
}

# ─── Main Menu ─────────────────────────────────────────────────────────────
menu() {
    echo -e "
${GREEN}Select Option:${NC}

 1) Install Pterodactyl Panel              (port 8080 + HTTPS + Queue)
 2) Install Wings                           (Docker + SSL)
 3) Install Blueprint                       (theme/framework)
 4) Install Cloudflare Tunnel
 5) System Information
 6) Panel Image Changer
 7) Exit
"
    read -p "Choose [1-7]: " CHOICE
    case $CHOICE in
        1) install_panel ;;
        2) install_wings ;;
        3) install_blueprint ;;
        4) install_cloudflare_tunnel ;;
        5) system_info ;;
        6) panel_image_changer_menu ;;
        7) exit 0 ;;
        *) menu ;;
    esac
}

system_info() {
    echo -e "\n${GREEN}System Information${NC}"
    echo "OS:          $PRETTY_NAME"
    echo "Kernel:      $(uname -r)"
    echo "CPU Arch:    $ARCH"
    df -h /
    echo
    read -p "Press Enter..." dummy
    menu
}

# ─── Panel Installation ────────────────────────────────────────────────────
install_panel() {
    clear
    echo -e "${GREEN}→ Install Pterodactyl Panel${NC}\n"

    read -p "Panel FQDN (example: panel.example.com): " FQDN
    [[ -z "$FQDN" ]] && err "FQDN is required!"

    read -p "Admin Email     [admin@$FQDN]: " ADMIN_EMAIL; ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}
    read -p "Admin Username  [admin]: "      ADMIN_USER;   ADMIN_USER=${ADMIN_USER:-admin}
    read -s -p "Admin Password  (blank = random): " ADMIN_PASS; echo
    [[ -z "$ADMIN_PASS" ]] && ADMIN_PASS=$(openssl rand -base64 15) && warn "Generated password: $ADMIN_PASS"
    read -p "First Name      [Admin]: " ADMIN_FIRST; ADMIN_FIRST=${ADMIN_FIRST:-Admin}
    read -p "Last Name       [User]: "  ADMIN_LAST;  ADMIN_LAST=${ADMIN_LAST:-User}

    DB_PASS=$(openssl rand -hex 16)
    TIMEZONE="Etc/UTC"   # ← change if you want; better default than hardcoded Kolkata

    PTERO_DIR="/var/www/pterodactyl"

    log "Updating system..."
    $PKG_UPDATE

    log "Installing base dependencies..."
    if [[ $OS_FAMILY == "debian" ]]; then
        $PKG install ca-certificates curl wget tar unzip git gnupg lsb-release apt-transport-https nginx mariadb-server redis-server
    else
        $PKG install epel-release
        $PKG install curl wget tar unzip git nginx mariadb-server redis
    fi

    # ─ PHP (use best available repo) ───────────────────────────────
    log "Setting up PHP repository..."

    if [[ $OS_FAMILY == "debian" ]]; then
        if [[ $PHP_REPO == "sury" ]]; then
            curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
            echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $CODENAME main" > /etc/apt/sources.list.d/php.list
        else
            add-apt-repository ppa:ondrej/php -y
        fi
        $PKG_UPDATE
    else
        $PKG install https://rpms.remirepo.net/enterprise/remi-release-9.rpm || true   # 8 or 9
        dnf module reset php -y
        dnf module enable php:remi-8.3 -y   # or 8.2
    fi

    PHP_VER="8.3"   # 2026 recommendation
    log "Installing PHP $PHP_VER..."
    if [[ $OS_FAMILY == "debian" ]]; then
        install_pkgs php${PHP_VER} php${PHP_VER}-{fpm,cli,mysql,xml,curl,gd,zip,bcmath,mbstring,intl,tokenizer,common,imagick}
    else
        install_pkgs php php-{cli,fpm,mysqlnd,xml,curl,gd,zip,bcmath,mbstring,intl,tokenizer,common,imagick}
    fi

    systemctl enable --now php${PHP_VER}-fpm || systemctl enable --now php-fpm

    # MariaDB / MySQL setup (very simplified)
    log "Configuring MariaDB..."
    systemctl enable --now mariadb || err "MariaDB failed to start"

    mysql -u root <<SQL || true
CREATE DATABASE pterodactyl CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

    # ─ Download & Configure Panel ──────────────────────────────────────
    mkdir -p "$PTERO_DIR" && cd "$PTERO_DIR"
    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzf panel.tar.gz && rm panel.tar.gz
    cp .env.example .env
    chown -R www-data:www-data .  2>/dev/null || chown -R nginx:nginx .   # RHEL uses nginx

    sed -i "s|^APP_URL=.*|APP_URL=https://$FQDN|" .env
    sed -i "s|^APP_TIMEZONE=.*|APP_TIMEZONE=$TIMEZONE|" .env
    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env
    sed -i "s|^DB_USERNAME=.*|DB_USERNAME=pterodactyl|" .env
    sed -i "s|^DB_DATABASE=.*|DB_DATABASE=pterodactyl|" .env
    sed -i "s|^CACHE_DRIVER=.*|redis|" .env
    sed -i "s|^SESSION_DRIVER=.*|redis|" .env
    sed -i "s|^QUEUE_CONNECTION=.*|redis|" .env

    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    composer install --no-dev --optimize-autoloader --no-interaction

    php artisan key:generate --force
    php artisan p:environment:setup --no-interaction
    php artisan migrate --seed --force

    php artisan p:user:make \
      --email="$ADMIN_EMAIL" --username="$ADMIN_USER" \
      --name-first="$ADMIN_FIRST" --name-last="$ADMIN_LAST" \
      --password="$ADMIN_PASS" --admin=1 --no-interaction

    # Self-signed SSL (you should replace with real cert later)
    mkdir -p /etc/ssl/pterodactyl
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
      -subj "/CN=$FQDN" -keyout /etc/ssl/pterodactyl/privkey.pem \
      -out /etc/ssl/pterodactyl/fullchain.pem

    # Nginx config (simplified - adapt listen port / user if needed)
    cat > /etc/nginx/conf.d/pterodactyl.conf <<EOF
server {
    listen 8080 ssl http2;
    server_name $FQDN;
    root $PTERO_DIR/public;
    index index.php;
    ssl_certificate     /etc/ssl/pterodactyl/fullchain.pem;
    ssl_certificate_key /etc/ssl/pterodactyl/privkey.pem;
    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

    nginx -t && systemctl restart nginx || err "Nginx configuration test failed"

    # Queue worker (same as yours)
    cat > /etc/systemd/system/pteroq.service <<'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --sleep=3 --tries=3
WorkingDirectory=/var/www/pterodactyl
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    # RHEL usually uses nginx user/group
    sed -i 's/User=www-data/User=nginx/' /etc/systemd/system/pteroq.service 2>/dev/null || true
    sed -i 's/Group=www-data/Group=nginx/' /etc/systemd/system/pteroq.service 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable --now pteroq

    ok "Panel installation finished!"
    echo "URL:       https://$FQDN:8080"
    echo "Login:     $ADMIN_USER  /  $ADMIN_PASS"
    read -p "Press Enter to continue..." dummy
    menu
}

# ─── Wings Installation (no forced cgroup v1 anymore) ──────────────────────
install_wings() {
    clear
    echo -e "${GREEN}→ Install Wings${NC}\n"

    log "Installing Docker..."
    if [[ $OS_FAMILY == "debian" ]]; then
        install_pkgs "$DOCKER_PKG"
    else
        $PKG install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        install_pkgs "$DOCKER_PKG"
    fi
    systemctl enable --now docker

    mkdir -p /etc/pterodactyl /var/lib/pterodactyl/{volumes,logs}
    chmod 755 /etc/pterodactyl /var/lib/pterodactyl

    curl -L "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH_TAG}" -o /usr/local/bin/wings
    chmod u+x /usr/local/bin/wings

    # Self-signed cert (replace later)
    mkdir -p /etc/pterodactyl/ssl
    openssl req -new -x509 -nodes -days 3650 -newkey rsa:4096 \
      -keyout /etc/pterodactyl/ssl/privkey.pem \
      -out /etc/pterodactyl/ssl/fullchain.pem \
      -subj "/CN=$(hostname -f)"

    echo -e "\nEnter values from Panel → Nodes → Create Node\n"
    read -p "Panel URL[](https://...): " PANEL_URL
    read -p "Wings listen port [8080]: " WINGS_PORT; WINGS_PORT=${WINGS_PORT:-8080}
    read -p "SFTP port       [2022]: " SFTP_PORT; SFTP_PORT=${SFTP_PORT:-2022}
    read -p "Node UUID: " UUID
    read -p "Token ID: " TOKEN_ID
    read -p "Token: " TOKEN

cat > /etc/pterodactyl/config.yml <<EOF
uuid: "$UUID"
token_id: $TOKEN_ID
token: "$TOKEN"

api:
  host: 0.0.0.0
  port: $WINGS_PORT
  ssl:
    enabled: true
    cert: /etc/pterodactyl/ssl/fullchain.pem
    key: /etc/pterodactyl/ssl/privkey.pem

system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: $SFTP_PORT

remote: "$PANEL_URL"
EOF

    cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/var/lib/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=always
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wings

    ok "Wings installed!"
    echo "Check status:  systemctl status wings"
    echo "Logs:          journalctl -u wings -f"
    read -p "Press Enter..." dummy
    menu
}

# The rest of your functions (Blueprint, Cloudflare Tunnel, Image Changer, etc.)
# can stay almost the same — just make sure chown uses correct user (www-data or nginx)

# ─── Start ─────────────────────────────────────────────────────────────────
menu
