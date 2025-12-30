#!/bin/bash
# COMPLETE Pterodactyl Installer + Fixed Panel Image Changer (one by one or all)
# Debian 11 Bullseye - December 30, 2025
set -euo pipefail
IFS=$'\n\t'

RED='\033[1;31m' GREEN='\033[1;32m' YELLOW='\033[1;33m' BLUE='\033[1;34m' NC='\033[0m'
log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && err "Run as root (sudo)."

clear
echo -e "${GREEN}Pterodactyl Complete Installer + Image Changer${NC}"
echo "Date: December 30, 2025"

# Detect OS
. /etc/os-release 2>/dev/null || err "Cannot detect OS"
CODENAME="${VERSION_CODENAME:-$(lsb_release -sc 2>/dev/null || echo bullseye)}"
log "Detected: $NAME $VERSION_ID (codename: $CODENAME)"

PTERO_DIR="/var/www/pterodactyl"

menu() {
    echo -e "
${GREEN}Select Option:${NC}

 1) Install Pterodactyl Panel (port 8080 + HTTPS + Queue Worker)
 2) Install Wings (Node)
 3) Install Blueprint (theme/framework)
 4) Install Cloudflare Tunnel (cloudflared)
 5) System Info
 6) Panel Image Changer (favicons + SVGs)
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
    echo "OS: $PRETTY_NAME"
    echo "Kernel: $(uname -r)"
    echo "CPU: $(lscpu | grep 'Model name:' | cut -d: -f2 | xargs)"
    df -h /
    echo
    read -p "Press Enter..." dummy
    menu
}

install_panel() {
    clear
    echo -e "${GREEN}→ Install Pterodactyl Panel (port 8080 + HTTPS + Queue Worker)${NC}\n"

    read -p "Panel FQDN (e.g. panel.example.com): " FQDN
    [[ -z "$FQDN" ]] && err "FQDN required!"

    read -p "Admin Email [admin@$FQDN]: " ADMIN_EMAIL
    ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$FQDN"}

    read -p "Admin Username [admin]: " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}

    read -s -p "Admin Password (blank = random): " ADMIN_PASS
    echo
    [[ -z "$ADMIN_PASS" ]] && ADMIN_PASS="$(openssl rand -base64 12)" && warn "Generated password: $ADMIN_PASS"

    read -p "Admin First Name [Admin]: " ADMIN_FIRST; ADMIN_FIRST=${ADMIN_FIRST:-Admin}
    read -p "Admin Last Name [User]: " ADMIN_LAST;   ADMIN_LAST=${ADMIN_LAST:-User}

    DB_PASS="$(openssl rand -hex 16)"
    TIMEZONE="Asia/Kolkata"

    log "Cleaning old repositories..."
    rm -f /etc/apt/sources.list.d/*ondrej* /etc/apt/sources.list.d/*php* /etc/apt/sources.list.d/*sury* 2>/dev/null
    sed -i '/ondrej\/php/d;/sury.org/d;/ppa.launchpad.net/d;/resolute/d' /etc/apt/sources.list 2>/dev/null
    apt update -y || true

    log "Installing base dependencies..."
    apt install -y ca-certificates curl wget tar unzip git gnupg lsb-release apt-transport-https \
        nginx mariadb-server redis-server

    # PHP - Sury repo
    log "Adding Sury PHP repository..."
    curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
    echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ bullseye main" > /etc/apt/sources.list.d/php-sury.list
    apt update -y || err "Sury repo update failed"

    echo "PHP Version (recommended: 8.2 or 8.3):"
    echo "  1) 8.1   2) 8.2   3) 8.3"
    read -p "Select [2]: " PV; PV=${PV:-2}
    case $PV in 1) PHP_VER="8.1";; 2) PHP_VER="8.2";; 3) PHP_VER="8.3";; *) PHP_VER="8.2";; esac

    apt install -y php${PHP_VER} php${PHP_VER}-{fpm,cli,mysql,xml,curl,gd,zip,bcmath,mbstring,intl,tokenizer,common}
    systemctl enable --now php${PHP_VER}-fpm

    # Database
    mysql -u root <<SQL
DROP DATABASE IF EXISTS pterodactyl;
CREATE DATABASE pterodactyl CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON pterodactyl.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

    # Panel download & config
    mkdir -p "$PTERO_DIR" && cd "$PTERO_DIR"
    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzf panel.tar.gz && rm panel.tar.gz
    cp .env.example .env
    chown -R www-data:www-data .

    sed -i "s|^APP_URL=.*|APP_URL=https://$FQDN:8080|" .env
    sed -i "s|^APP_TIMEZONE=.*|APP_TIMEZONE=$TIMEZONE|" .env
    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" .env
    sed -i "s|^DB_USERNAME=.*|DB_USERNAME=pterodactyl|" .env
    sed -i "s|^DB_DATABASE=.*|DB_DATABASE=pterodactyl|" .env
    sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env
    sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env
    sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env

    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    composer install --no-dev --optimize-autoloader --no-interaction
    php artisan key:generate --force
    php artisan migrate --seed --force

    php artisan p:user:make \
      --email "$ADMIN_EMAIL" \
      --username "$ADMIN_USER" \
      --name-first "$ADMIN_FIRST" \
      --name-last "$ADMIN_LAST" \
      --password "$ADMIN_PASS" \
      --admin 1 --no-interaction || true

    # SSL
    mkdir -p /etc/certs/panel
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/CN=$FQDN" \
      -keyout /etc/certs/panel/privkey.pem -out /etc/certs/panel/fullchain.pem

    # Nginx
    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 8080 ssl http2;
    server_name $FQDN _;
    root $PTERO_DIR/public;
    index index.php;
    ssl_certificate /etc/certs/panel/fullchain.pem;
    ssl_certificate_key /etc/certs/panel/privkey.pem;
    client_max_body_size 100M;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \\n post_max_size=100M";
    }
    location ~ /\.ht { deny all; }
}
EOF

    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx || err "Nginx failed"

    # Queue Worker
    log "Setting up pteroq.service..."
    cat > /etc/systemd/system/pteroq.service <<'EOF'
[Unit]
Description=Pterodactyl Panel Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --sleep=3 --tries=3 --max-time=3600
WorkingDirectory=/var/www/pterodactyl
TimeoutStartSec=0
StandardOutput=append:/var/log/pteroq.log
StandardError=append:/var/log/pteroq.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable pteroq.service
    systemctl start pteroq.service

    clear
    ok "Panel + Queue Worker Installation Complete!"
    echo "URL:          https://$FQDN:8080"
    echo "Admin:        $ADMIN_USER / $ADMIN_EMAIL"
    echo "Password:     $ADMIN_PASS"
    echo "Queue Logs:   /var/log/pteroq.log"
    read -p "Press Enter..." dummy
    menu
}

install_wings() {
    clear
    echo -e "${GREEN}→ Install Wings${NC}\n"

    read -p "Panel URL[](https://...): " PANEL_URL
    [[ ! $PANEL_URL =~ ^https:// ]] && err "Must start with https://"

    read -p "Wings Port [8080]: " WINGS_PORT; WINGS_PORT=${WINGS_PORT:-8080}
    read -p "SFTP Port [2022]: " SFTP_PORT; SFTP_PORT=${SFTP_PORT:-2022}

    read -p "Node UUID: " UUID
    read -p "Token ID: " TOKEN_ID
    read -p "Token: " TOKEN

    apt install -y docker.io
    systemctl enable --now docker

    mkdir -p /etc/certs/wings
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
      -subj "/CN=$(hostname)" \
      -keyout /etc/certs/wings/privkey.pem \
      -out /etc/certs/wings/fullchain.pem

    curl -L "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$(uname -m)" -o /usr/local/bin/wings
    chmod +x /usr/local/bin/wings

    cat > /etc/pterodactyl/config.yml <<EOF
uuid: "$UUID"
token_id: $TOKEN_ID
token: "$TOKEN"

api:
  host: 0.0.0.0
  port: $WINGS_PORT
  ssl:
    enabled: true
    cert: /etc/certs/wings/fullchain.pem
    key: /etc/certs/wings/privkey.pem

system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: $SFTP_PORT

remote: "$PANEL_URL"
EOF

    cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings
After=docker.service network.target
Requires=docker.service

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

    ok "Wings installed!"
    read -p "Press Enter..." dummy
    menu
}

install_blueprint() {
    clear
    echo -e "${GREEN}→ Install Blueprint${NC}\n"

    read -p "Pterodactyl directory [/var/www/pterodactyl]: " PTERO_DIR
    PTERO_DIR=${PTERO_DIR:-/var/www/pterodactyl}

    [ ! -d "$PTERO_DIR/public" ] && err "Invalid directory"

    cd "$PTERO_DIR" || err "Cannot cd"

    apt install -y curl wget unzip
    wget "$(curl -s https://api.github.com/repos/BlueprintFramework/framework/releases/latest | grep browser_download_url | grep release.zip | cut -d\" -f4)" -O release.zip
    unzip -o release.zip
    rm release.zip

    apt install -y ca-certificates curl git gnupg unzip wget zip
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
    apt update
    apt install -y nodejs
    npm install -g yarn
    yarn install

    cat > .blueprintrc <<'EOF'
WEBUSER="www-data"
OWNERSHIP="www-data:www-data"
USERSHELL="/bin/bash"
EOF

    chmod +x blueprint.sh
    bash ./blueprint.sh

    ok "Blueprint installed!"
    read -p "Press Enter..." dummy
    menu
}

install_cloudflare_tunnel() {
    clear
    echo -e "${GREEN}→ Install Cloudflare Tunnel${NC}\n"

    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list

    apt update && apt install -y cloudflared

    ok "cloudflared installed!"
    echo "1. https://one.dash.cloudflare.com → Zero Trust → Networks → Tunnels"
    echo "2. Create tunnel → Cloudflared → copy token"
    echo

    read -p "Paste token (or blank): " TOKEN
    if [[ -n "$TOKEN" ]]; then
        nohup cloudflared tunnel run --token "$TOKEN" >/var/log/cloudflared.log 2>&1 &
        ok "Tunnel started! Logs: /var/log/cloudflared.log"
    else
        warn "Run later: cloudflared tunnel run --token YOUR_TOKEN"
    fi

    read -p "Press Enter..." dummy
    menu
}

panel_image_changer_menu() {
    clear
    echo -e "${GREEN}Panel Image Changer (with artisan down/up)${NC}\n"

    if [ ! -d "$PTERO_DIR/public" ]; then
        err "Panel not found at $PTERO_DIR. Install panel first (option 1)!"
    fi

    cd "$PTERO_DIR" || err "Cannot cd to $PTERO_DIR"

    echo "WARNING: Panel will be in maintenance mode (503) for ~30-90 seconds"
    read -p "Continue? (y/N): " confirm
    [[ ! $confirm =~ ^[Yy]$ ]] && { echo "Aborted."; read -p "Press Enter..." dummy; menu; }

    log "Maintenance mode ON..."
    php artisan down || warn "down failed - continuing anyway"

    echo "Choose replacement type:"
    echo "  1) favicons (/public/favicons/) - 25+ files"
    echo "  2) 4 Main SVGs (server_installing, server_error, pterodactyl, not_found)"
    echo "  3) images in /public/assets/svgs/ (10+ files)"
    echo
    read -p "Select [1-3]: " SUBCHOICE

    case $SUBCHOICE in
        1) replace_favicons_menu ;;
        2) replace_main_svgs_menu ;;
        3) replace_all_svgs_menu ;;
        *) panel_image_changer_menu ;;
    esac

    log "Maintenance mode OFF..."
    php artisan up || warn "up failed - run manually"

    log "Clearing caches..."
    php artisan cache:clear
    php artisan view:clear
    php artisan config:cache || true

    log "Reloading Nginx..."
    systemctl reload nginx || warn "Nginx reload failed"

    ok "Image replacement complete!"
    echo "→ Open in incognito or Ctrl + Shift + R to see changes"
    echo
    read -p "Press Enter..." dummy
    menu
}

get_source_image() {
    local prompt="$1"
    local img=""
    while true; do
        read -p "$prompt" img
        if [[ -z "$img" ]]; then
            warn "Cannot be empty. Try again."
            continue
        fi

        if [[ $img =~ ^https?:// ]]; then
            log "Downloading..."
            curl -s -L -o /tmp/ptero-img "$img" || { warn "Download failed!"; continue; }
            img="/tmp/ptero-img"
        fi

        if [ ! -f "$img" ]; then
            warn "File not found! Try again."
            continue
        fi

        echo "$img"
        break
    done
}

install_image_tools() {
    apt update -qq && apt install -y imagemagick librsvg2-bin pngquant || err "Failed to install image tools"
}

replace_favicons_menu() {
    clear
    echo -e "${GREEN}Replace Favicons (25+ files)${NC}\n"
    install_image_tools

    echo "Choose method:"
    echo "  1) One image for favicons"
    echo "  2) One by one (separate image for each file)"
    read -p "Select [1-2]: " method

    if [ "$method" == "1" ]; then
        SOURCE_IMG=$(get_source_image "Enter ONE image for all favicons: ")
        replace_favicons_all "$SOURCE_IMG"
    else
        replace_favicons_one_by_one
    fi

    read -p "Press Enter to return..." dummy
    panel_image_changer_menu
}

replace_favicons_all() {
    local src="$1"
    FAV_DIR="$PTERO_DIR/public/favicons"
    mkdir -p "$FAV_DIR"

    declare -A fav_map=(
        ["android-chrome-192x192.png"]="192" ["android-chrome-512x512.png"]="512"
        ["android-icon-144x144.png"]="144" ["android-icon-192x192.png"]="192"
        ["android-icon-36x36.png"]="36" ["android-icon-48x48.png"]="48"
        ["android-icon-72x72.png"]="72" ["android-icon-96x96.png"]="96"
        ["apple-icon-114x114.png"]="114" ["apple-icon-120x120.png"]="120"
        ["apple-icon-144x144.png"]="144" ["apple-icon-152x152.png"]="152"
        ["apple-icon-180x180.png"]="180" ["apple-icon-57x57.png"]="57"
        ["apple-icon-60x60.png"]="60" ["apple-icon-72x72.png"]="72"
        ["apple-icon-76x76.png"]="76" ["apple-icon-precomposed.png"]="180"
        ["apple-icon.png"]="180" ["apple-touch-icon.png"]="180"
        ["favicon-16x16.png"]="16" ["favicon-32x32.png"]="32" ["favicon-96x96.png"]="96"
        ["ms-icon-144x144.png"]="144" ["ms-icon-150x150.png"]="150"
        ["ms-icon-310x310.png"]="310" ["ms-icon-70x70.png"]="70"
        ["mstile-150x150.png"]="150" ["safari-pinned-tab.svg"]="512"
    )

    for f in "${!fav_map[@]}"; do
        s=${fav_map[$f]}
        convert "$src" -resize ${s}x${s}^ -gravity center -extent ${s}x${s} -strip \
                -quality 90 "$FAV_DIR/$f" && ok "Created: $f (${s}x${s})"
    done

    convert "$src" -resize 256x256 -define icon:auto-resize=256,128,64,48,32,16 \
            "$FAV_DIR/favicon.ico" && ok "favicon.ico (multi-size)"

    chown -R www-data:www-data "$FAV_DIR"
    ok "All favicons replaced with one image!"
}

replace_favicons_one_by_one() {
    FAV_DIR="$PTERO_DIR/public/favicons"
    mkdir -p "$FAV_DIR"

    declare -A fav_map=(
        ["android-chrome-192x192.png"]="192" ["android-chrome-512x512.png"]="512"
        ["android-icon-144x144.png"]="144" ["android-icon-192x192.png"]="192"
        ["android-icon-36x36.png"]="36" ["android-icon-48x48.png"]="48"
        ["android-icon-72x72.png"]="72" ["android-icon-96x96.png"]="96"
        ["apple-icon-114x114.png"]="114" ["apple-icon-120x120.png"]="120"
        ["apple-icon-144x144.png"]="144" ["apple-icon-152x152.png"]="152"
        ["apple-icon-180x180.png"]="180" ["apple-icon-57x57.png"]="57"
        ["apple-icon-60x60.png"]="60" ["apple-icon-72x72.png"]="72"
        ["apple-icon-76x76.png"]="76" ["apple-icon-precomposed.png"]="180"
        ["apple-icon.png"]="180" ["apple-touch-icon.png"]="180"
        ["favicon-16x16.png"]="16" ["favicon-32x32.png"]="32" ["favicon-96x96.png"]="96"
        ["ms-icon-144x144.png"]="144" ["ms-icon-150x150.png"]="150"
        ["ms-icon-310x310.png"]="310" ["ms-icon-70x70.png"]="70"
        ["mstile-150x150.png"]="150" ["safari-pinned-tab.svg"]="512"
    )

    for f in "${!fav_map[@]}"; do
        echo "For file: $f"
        SOURCE_IMG=$(get_source_image "Enter image for $f: ")
        s=${fav_map[$f]}
        convert "$SOURCE_IMG" -resize ${s}x${s}^ -gravity center -extent ${s}x${s} -strip \
                -quality 90 "$FAV_DIR/$f" && ok "Updated: $f"
    done

    chown -R www-data:www-data "$FAV_DIR"
    ok "Favicons replaced one by one!"
}

replace_main_svgs_menu() {
    clear
    echo -e "${GREEN}Replace 4 Main SVGs${NC}\n"
    install_image_tools

    echo "Choose method:"
    echo "  1) One image for all 4 SVGs"
    echo "  2) One by one (separate image for each)"
    read -p "Select [1-2]: " method

    if [ "$method" == "1" ]; then
        SOURCE_IMG=$(get_source_image "Enter ONE image for all 4 SVGs: ")
        replace_main_svgs_all "$SOURCE_IMG"
    else
        replace_main_svgs_one_by_one
    fi

    read -p "Press Enter..." dummy
    panel_image_changer_menu
}

replace_main_svgs_all() {
    local src="$1"
    SVG_DIR="$PTERO_DIR/public/assets/svgs"
    mkdir -p "$SVG_DIR"

    declare -A svgs=(
        ["server_installing.svg"]="Server installing"
        ["server_error.svg"]="Server error"
        ["pterodactyl.svg"]="Login logo"
        ["not_found.svg"]="Not found"
    )

    for f in "${!svgs[@]}"; do
        target="$SVG_DIR/$f"
        if rsvg-convert -f svg "$src" -o "$target" 2>/dev/null; then
            ok "Vector SVG: $f"
        else
            warn "PNG fallback: $f"
            convert "$src" -resize 512x512 -strip -quality 95 "${target%.svg}.png"
        fi
    done

    chown -R www-data:www-data "$SVG_DIR"
    ok "4 main SVGs replaced with one image!"
}

replace_main_svgs_one_by_one() {
    SVG_DIR="$PTERO_DIR/public/assets/svgs"
    mkdir -p "$SVG_DIR"

    declare -A svgs=(
        ["server_installing.svg"]="Server installing"
        ["server_error.svg"]="Server error"
        ["pterodactyl.svg"]="Login logo"
        ["not_found.svg"]="Not found"
    )

    for f in "${!svgs[@]}"; do
        echo "For file: $f (${svgs[$f]})"
        SOURCE_IMG=$(get_source_image "Enter image for $f: ")
        target="$SVG_DIR/$f"
        if rsvg-convert -f svg "$SOURCE_IMG" -o "$target" 2>/dev/null; then
            ok "Vector SVG: $f"
        else
            warn "PNG fallback: $f"
            convert "$SOURCE_IMG" -resize 512x512 -strip -quality 95 "${target%.svg}.png"
        fi
    done

    chown -R www-data:www-data "$SVG_DIR"
    ok "4 main SVGs replaced one by one!"
}

replace_all_svgs_menu() {
    clear
    echo -e "${GREEN}Replace ALL in /assets/svgs/${NC}\n"
    install_image_tools

    echo "Choose method:"
    echo "  1) One image for ALL files"
    echo "  2) One by one (separate image for each file)"
    read -p "Select [1-2]: " method

    if [ "$method" == "1" ]; then
        SOURCE_IMG=$(get_source_image "Enter ONE image for all files: ")
        replace_all_svgs_all "$SOURCE_IMG"
    else
        replace_all_svgs_one_by_one
    fi

    read -p "Press Enter..." dummy
    panel_image_changer_menu
}

replace_all_svgs_all() {
    local src="$1"
    SVG_DIR="$PTERO_DIR/public/assets/svgs"
    mkdir -p "$SVG_DIR"

    count=0
    for file in "$SVG_DIR"/*.{svg,png,jpg,jpeg}; do
        [ -f "$file" ] || continue
        ((count++))
        base=$(basename "$file")
        if rsvg-convert -f svg "$src" -o "$file" 2>/dev/null; then
            ok "Vector SVG: $base"
        else
            warn "PNG fallback: $base"
            convert "$src" -resize 512x512 -strip -quality 95 "$file"
        fi
    done

    [ $count -eq 0 ] && warn "No files found in $SVG_DIR"

    chown -R www-data:www-data "$SVG_DIR"
    ok "All $count images replaced with one image!"
}

replace_all_svgs_one_by_one() {
    SVG_DIR="$PTERO_DIR/public/assets/svgs"
    mkdir -p "$SVG_DIR"

    for file in "$SVG_DIR"/*.{svg,png,jpg,jpeg}; do
        [ -f "$file" ] || continue
        base=$(basename "$file")
        echo "For file: $base"
        SOURCE_IMG=$(get_source_image "Enter image for $base: ")
        if rsvg-convert -f svg "$SOURCE_IMG" -o "$file" 2>/dev/null; then
            ok "Vector SVG: $base"
        else
            warn "PNG fallback: $base"
            convert "$SOURCE_IMG" -resize 512x512 -strip -quality 95 "$file"
        fi
    done

    chown -R www-data:www-data "$SVG_DIR"
    ok "All images replaced one by one!"
}

menu
