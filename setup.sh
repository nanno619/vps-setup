#!/usr/bin/env bash
#
# setup.sh - Interactive LEMP + Laravel server setup for Ubuntu 26.04 (Vultr)
#
# Turns a fresh Ubuntu 26.04 server into a secured Laravel host:
#   Linux hardening, Nginx, MySQL 8.4, PHP 8.5, Composer, Node.js,
#   your Laravel app from Git, and free HTTPS from Let's Encrypt.
#
# Usage (as root on a NEW server):
#   curl -fsSLO https://raw.githubusercontent.com/nanno619/vps-setup/main/setup.sh
#   less setup.sh          # read it before running it
#   sudo bash setup.sh
#
# Safe to re-run: steps that are already done are skipped.

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="/var/log/vps-setup.log"
readonly TESTED_UBUNTU="26.04"
readonly GITHUB_ED25519_FP="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
readonly MIN_NODE="20.19"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_BLUE=$'\e[34m'
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

STEP_NO=0
step() { STEP_NO=$((STEP_NO + 1)); printf '\n%s==> Step %d: %s%s\n' "$C_BOLD$C_BLUE" "$STEP_NO" "$1" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✔ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '    %s! %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
die()  { printf '\n%s✘ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

on_error() {
  local code=$? line=${1:-?}
  printf '\n%s✘ Something failed (line %s, exit code %s).%s\n' "$C_RED" "$line" "$code" "$C_RESET" >&2
  printf '  Full log: %s\n  Fix the problem, then run the script again; finished steps are skipped.\n' "$LOG_FILE" >&2
}
trap 'on_error $LINENO' ERR

# Print to the real terminal only (never into the log file).
to_tty() { printf '%s\n' "$*" > /dev/tty; }

# --------------------------------------------------------------------------
# Question helpers
# --------------------------------------------------------------------------
# ask "Question" "default" "regex" "hint"  -> prints the answer
ask() {
  local prompt=$1 default=${2-} regex=${3-} hint=${4-} answer
  while true; do
    if [[ -n $default ]]; then
      read -r -p "  $prompt [$default]: " answer
      answer=${answer:-$default}
    else
      read -r -p "  $prompt: " answer
    fi
    if [[ -z $answer ]]; then warn "This can't be empty."; continue; fi
    if [[ -n $regex && ! $answer =~ $regex ]]; then
      if [[ -n $hint ]]; then warn "$hint"; else warn "That does not look right. Try again."; fi
      continue
    fi
    printf '%s' "$answer"
    return 0
  done
}

# ask_optional "Question" "regex" "hint"  -> prints the answer, or nothing if left empty
ask_optional() {
  local prompt=$1 regex=${2-} hint=${3-} answer
  while true; do
    read -r -p "  $prompt: " answer
    if [[ -z $answer ]]; then return 0; fi
    if [[ -n $regex && ! $answer =~ $regex ]]; then
      if [[ -n $hint ]]; then warn "$hint"; else warn "That does not look right. Try again."; fi
      continue
    fi
    printf '%s' "$answer"
    return 0
  done
}

# ask_yn "Question" "y|n"  -> exit status 0 for yes, 1 for no
ask_yn() {
  local prompt=$1 default=${2:-y} answer hint="[Y/n]"
  [[ $default == n ]] && hint="[y/N]"
  while true; do
    read -r -p "  $prompt $hint: " answer
    answer=${answer:-$default}
    case ${answer,,} in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

# ask_secret "Question" min_length -> prints the answer (asked twice)
ask_secret() {
  local prompt=$1 min=${2:-12} a b
  while true; do
    read -r -s -p "  $prompt: " a; echo >&2
    if (( ${#a} < min )); then warn "Use at least $min characters."; continue; fi
    if [[ $a =~ [[:space:]\'\"\\\`\$] ]]; then warn "Please avoid spaces, quotes, backslashes, \$ and backticks."; continue; fi
    read -r -s -p "  Type it again: " b; echo >&2
    if [[ $a != "$b" ]]; then warn "They don't match. Try again."; continue; fi
    printf '%s' "$a"
    return 0
  done
}

random_password() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 28; }

# --------------------------------------------------------------------------
# Small utilities
# --------------------------------------------------------------------------
apt_get() { apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y "$@"; }

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

# Run a command as the new user, inside the app directory.
as_user() { sudo -u "$NEW_USER" -H bash -c "cd '$APP_DIR' && $*"; }

# Can the new user read the repo? (BatchMode: never stop to ask for a password.)
repo_readable() { sudo -u "$NEW_USER" -H env GIT_SSH_COMMAND="ssh -o BatchMode=yes" git ls-remote "$REPO_URL" >/dev/null 2>&1; }

# set_env FILE KEY VALUE: replaces "KEY=..." or "# KEY=..." or appends it.
set_env() {
  local file=$1 key=$2 value=$3 tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ "^[#[:space:]]*" k "=" { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

server_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'; }

dns_points_here() {
  local name=$1 ip=$2
  dig +short "$name" A @1.1.1.1 2>/dev/null | grep -qx "$ip"
}

# --------------------------------------------------------------------------
# Pre-flight checks
# --------------------------------------------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "Run this script as root: sudo bash setup.sh"
  [[ -t 0 ]] || die "This script is interactive. Download it first, then run: sudo bash setup.sh"

  # shellcheck disable=SC1091
  . /etc/os-release
  printf '%s\nvps-setup %s - Laravel server setup%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
  info "Detected: ${PRETTY_NAME:-unknown OS}"
  if [[ ${ID:-} != ubuntu ]]; then
    die "This script only supports Ubuntu."
  fi
  if [[ ${VERSION_ID:-} != "$TESTED_UBUNTU" ]]; then
    warn "This script was written and tested for Ubuntu $TESTED_UBUNTU."
    ask_yn "Continue anyway?" n || exit 1
  fi

  if command -v cloud-init >/dev/null 2>&1; then
    info "Waiting for the server's first-boot setup (cloud-init) to finish..."
    cloud-init status --wait >/dev/null 2>&1 || true
  fi

  SERVER_IP=$(server_ip)
  [[ -n $SERVER_IP ]] || die "Couldn't find this server's IPv4 address."
  info "Server IP: $SERVER_IP"
}

# --------------------------------------------------------------------------
# Questions (all asked up front, so the rest can run on its own)
# --------------------------------------------------------------------------
collect_answers() {
  printf '\n%sAnswer a few questions. Press Enter to accept the [default].%s\n' "$C_BOLD" "$C_RESET"

  printf '\n%sYour login%s\n' "$C_BOLD" "$C_RESET"
  NEW_USER=$(ask "New username (you'll log in as this user, not root)" "farhan" '^[a-z_][a-z0-9_-]{0,31}$' "Use lowercase letters, numbers, - or _.")
  if id "$NEW_USER" >/dev/null 2>&1; then
    info "User '$NEW_USER' already exists; its password won't be changed."
    USER_PASSWORD=""
  else
    info "This password is used for sudo (admin commands), not for SSH login."
    USER_PASSWORD=$(ask_secret "Password for $NEW_USER (min. 12 characters)" 12)
  fi

  SSH_PUBKEY=""
  if [[ -s /root/.ssh/authorized_keys ]] && ask_yn "Copy root's existing SSH key(s) to $NEW_USER?" y; then
    SSH_PUBKEY="__COPY_ROOT__"
  else
    info "On your Mac, run:  cat ~/.ssh/id_farhan.pub   (or your own .pub file)"
    while true; do
      read -r -p "  Paste your PUBLIC SSH key (starts with ssh-...): " SSH_PUBKEY
      if printf '%s\n' "$SSH_PUBKEY" | ssh-keygen -l -f /dev/stdin >/dev/null 2>&1; then break; fi
      warn "That isn't a valid public key. Paste the whole single line from the .pub file."
    done
  fi
  HOST_ALIAS=$(ask "Short name for this server on your Mac (for 'ssh <name>')" "vultr" '^[A-Za-z0-9._-]+$')

  printf '\n%sYour Laravel app%s\n' "$C_BOLD" "$C_RESET"
  if ask_yn "Deploy a Laravel app from Git now?" y; then
    INSTALL_APP=1
    while true; do
      REPO_URL=$(ask "Git repo SSH address (git@github.com:user/repo.git)")
      if [[ $REPO_URL =~ ^https://([^/]+)/(.+)$ ]]; then
        REPO_URL="git@${BASH_REMATCH[1]}:${BASH_REMATCH[2]%.git}.git"
        info "Converted to SSH address: $REPO_URL"
      fi
      if [[ $REPO_URL =~ ^git@([^:]+):[A-Za-z0-9._/-]+$ ]]; then REPO_HOST=${BASH_REMATCH[1]}; break; fi
      warn "Use the SSH address from the green 'Code' button, e.g. git@github.com:nanno619/fresh-laravel.git"
    done
    REPO_BRANCH=$(ask "Branch to deploy" "main" '^[A-Za-z0-9._/-]+$')

    info "No domain yet? Leave it empty: the site will run on http://$SERVER_IP,"
    info "and you can run this script again later to add the domain and HTTPS."
    DOMAIN=$(ask_optional "Domain name, without www (optional)" '^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$' "Enter just the domain, like cendanastudio.com, or leave it empty.")
    DOMAIN=${DOMAIN,,}
    WITH_WWW=0
    if [[ -n $DOMAIN ]] && ask_yn "Also serve www.$DOMAIN?" y; then WITH_WWW=1; fi

    # Default names: from the domain if there is one, otherwise from the repo name.
    local default_name
    if [[ -n $DOMAIN ]]; then
      default_name=${DOMAIN%%.*}
    else
      default_name=$(basename "${REPO_URL##*:}" .git)
    fi
    APP_DIR=$(ask "App folder" "/var/www/$default_name" '^/var/www/[A-Za-z0-9._-]+$' "Use /var/www/<name> with no spaces.")
    APP_NAME=$(ask "App name (shown in the browser title)" "$default_name" '^[^"\\`$]+$' "Avoid quotes, backslashes, \$ and backticks.")

    local db_default=${default_name//[^A-Za-z0-9_]/_}
    DB_NAME=$(ask "MySQL database name" "$db_default" '^[A-Za-z0-9_]{1,32}$' "Letters, numbers and _ only.")
    DB_USER=$(ask "MySQL username for the app" "$db_default" '^[A-Za-z0-9_]{1,32}$' "Letters, numbers and _ only.")
    if ask_yn "Generate a strong database password for you?" y; then
      DB_PASS=$(random_password)
    else
      DB_PASS=$(ask_secret "Database password" 12)
    fi

    ENABLE_HTTPS=0
    if [[ -z $DOMAIN ]]; then
      info "HTTPS needs a domain, so it's skipped for now."
    elif ask_yn "Set up free HTTPS (Let's Encrypt)? Your DNS must already point here" y; then
      ENABLE_HTTPS=1
      LE_EMAIL=$(ask "Email for certificate notices" "" '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' "Enter a valid email address.")
    fi
  else
    INSTALL_APP=0
    ENABLE_HTTPS=0
  fi

  printf '\n%sSummary%s\n' "$C_BOLD" "$C_RESET"
  info "User:          $NEW_USER (SSH key login only)"
  info "Installs:      Nginx, MySQL 8.4, PHP (Ubuntu's version), Composer, firewall, auto-updates"
  if (( INSTALL_APP )); then
    if [[ -n $DOMAIN ]]; then
      info "Domain:        $DOMAIN$( (( WITH_WWW )) && printf ' + www.%s' "$DOMAIN")"
    else
      info "Domain:        none yet (site on http://$SERVER_IP)"
    fi
    info "Repo:          $REPO_URL ($REPO_BRANCH)"
    info "App folder:    $APP_DIR"
    info "Database:      $DB_NAME (user $DB_USER)"
    info "HTTPS:         $( (( ENABLE_HTTPS )) && echo "yes, email $LE_EMAIL" || echo no)"
  fi
  printf '\n  %sAfter this, root and password logins over SSH will be switched off.%s\n' "$C_YELLOW" "$C_RESET"
  ask_yn "Start the setup?" y || die "Cancelled. Nothing was changed."
}

# --------------------------------------------------------------------------
# Steps
# --------------------------------------------------------------------------
update_system() {
  step "Update the system"
  apt_get update
  apt_get upgrade
  apt_get install ca-certificates curl git unzip bind9-dnsutils openssl
  ok "System updated"
}

create_user() {
  step "Create user '$NEW_USER'"
  if id "$NEW_USER" >/dev/null 2>&1; then
    info "User already exists."
  else
    useradd --create-home --shell /bin/bash "$NEW_USER"
    printf '%s:%s\n' "$NEW_USER" "$USER_PASSWORD" | chpasswd
    ok "User created"
  fi
  usermod -aG sudo "$NEW_USER"

  local home ssh_dir keys
  home=$(getent passwd "$NEW_USER" | cut -d: -f6)
  ssh_dir="$home/.ssh"
  keys="$ssh_dir/authorized_keys"
  install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$ssh_dir"
  touch "$keys"
  if [[ $SSH_PUBKEY == "__COPY_ROOT__" ]]; then
    local line
    while IFS= read -r line; do
      if [[ -n $line ]] && ! grep -qxF "$line" "$keys"; then
        printf '%s\n' "$line" >> "$keys"
      fi
    done < /root/.ssh/authorized_keys
  elif ! grep -qxF "$SSH_PUBKEY" "$keys"; then
    printf '%s\n' "$SSH_PUBKEY" >> "$keys"
  fi
  chown "$NEW_USER:$NEW_USER" "$keys"
  chmod 600 "$keys"

  if ! ssh-keygen -l -f "$keys" >/dev/null 2>&1; then
    die "No valid SSH key in $keys. Stopping before SSH lockdown so you don't get locked out."
  fi
  ok "SSH key installed for $NEW_USER and added to the sudo group"
}

harden_ssh() {
  step "Lock down SSH (no root login, no passwords)"
  # Files in sshd_config.d are read before sshd_config and the FIRST value wins,
  # so "00-" makes these settings beat anything else, including cloud-init's file.
  cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
# Written by vps-setup
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
EOF
  if [[ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]]; then
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/50-cloud-init.conf
  fi
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    echo "ssh_pwauth: false" > /etc/cloud/cloud.cfg.d/99-disable-ssh-password.cfg
  fi

  sshd -t || die "The SSH config has an error; SSH was NOT restarted."
  systemctl restart ssh

  local effective
  effective=$(sshd -T 2>/dev/null)
  grep -qx "permitrootlogin no" <<< "$effective" || die "Root login is still allowed. Check /etc/ssh/sshd_config.d/."
  grep -qx "passwordauthentication no" <<< "$effective" || die "Password login is still allowed. Check /etc/ssh/sshd_config.d/."
  grep -qx "kbdinteractiveauthentication no" <<< "$effective" || die "Keyboard-interactive login is still allowed."
  ok "SSH now accepts key logins only (checked with sshd -T)"
}

auto_updates_and_swap() {
  step "Automatic security updates and swap"
  pkg_installed unattended-upgrades || apt_get install unattended-upgrades
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  ok "Security updates install automatically every day"

  if [[ -n $(swapon --show --noheadings) ]]; then
    info "Swap already exists: $(swapon --show --noheadings | awk '{print $1, $3}')"
  elif [[ -e /swapfile ]]; then
    warn "/swapfile exists but isn't active; leaving it alone."
  else
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Created a 2 GB swap file"
  fi
}

install_php() {
  step "Install PHP, its extensions and Composer"
  apt_get install php-fpm php-cli php-mysql php-mbstring php-xml php-curl php-zip \
    php-bcmath php-intl php-gd php-redis composer
  PHP_V=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
  PHP_SOCK="/run/php/php${PHP_V}-fpm.sock"

  # Turn off features abused by the PHP2Shell family of attacks (Laravel uses neither).
  cat > "/etc/php/${PHP_V}/fpm/conf.d/99-hardening.ini" <<'EOF'
; Written by vps-setup
session.upload_progress.enabled = 0
fatal_error_backtraces = 0
EOF
  systemctl enable --now "php${PHP_V}-fpm" >/dev/null
  systemctl restart "php${PHP_V}-fpm"
  ok "PHP $PHP_V installed ($(dpkg-query -W -f='${Version}' "php${PHP_V}-fpm")), hardening settings applied"
  ok "Composer $(composer --version --no-ansi 2>/dev/null | awk '{print $3}') installed"
}

install_mysql() {
  step "Install MySQL and secure it"
  pkg_installed mysql-server || apt_get install mysql-server
  systemctl enable --now mysql >/dev/null

  # Same clean-up that mysql_secure_installation does.
  mysql <<'SQL'
DELETE FROM mysql.user WHERE User = '';
DELETE FROM mysql.user WHERE User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db = 'test' OR Db = 'test\\_%';
FLUSH PRIVILEGES;
SQL
  ok "MySQL $(mysql -N -e 'SELECT VERSION();') installed and secured"

  if (( INSTALL_APP )); then
    mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    ok "Database '$DB_NAME' and user '$DB_USER' ready"
  fi
}

install_nginx_and_firewall() {
  step "Install Nginx and turn on the firewall"
  pkg_installed nginx || apt_get install nginx
  systemctl enable --now nginx >/dev/null

  # Hide the version: comment out any existing server_tokens line, then add ours
  # right after "http {". Safe to re-run (our own line is replaced, not duplicated).
  local conf=/etc/nginx/nginx.conf
  sed -i '/server_tokens off; # vps-setup/d' "$conf"
  sed -i -E 's/^([[:space:]]*)server_tokens[[:space:]]/\1# server_tokens /' "$conf"
  sed -i -E '0,/^[[:space:]]*http[[:space:]]*\{/s//&\n\tserver_tokens off; # vps-setup/' "$conf"
  nginx -t 2>/dev/null || die "Nginx config test failed after setting server_tokens."
  systemctl reload nginx
  ok "Nginx running, version number hidden"

  pkg_installed ufw || apt_get install ufw
  ufw allow OpenSSH >/dev/null
  ufw allow 'Nginx Full' >/dev/null
  ufw --force enable >/dev/null
  ok "Firewall on: SSH (22), HTTP (80) and HTTPS (443) allowed, everything else blocked"
}

setup_deploy_key() {
  step "Give the server read access to your Git repo"
  local home key cfg known
  home=$(getent passwd "$NEW_USER" | cut -d: -f6)
  key="$home/.ssh/deploy_key"
  cfg="$home/.ssh/config"
  known="$home/.ssh/known_hosts"

  if [[ ! -f $key ]]; then
    sudo -u "$NEW_USER" ssh-keygen -q -t ed25519 -N "" -C "$(hostname) deploy key" -f "$key"
  fi
  if ! grep -qE "^Host[[:space:]]+${REPO_HOST//./\\.}\$" "$cfg" 2>/dev/null; then
    printf '\nHost %s\n    HostName %s\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' \
      "$REPO_HOST" "$REPO_HOST" "$key" >> "$cfg"
  fi
  chown "$NEW_USER:$NEW_USER" "$cfg"; chmod 600 "$cfg"

  # Trust the Git host's key; for GitHub, check it against GitHub's published fingerprint.
  if ! sudo -u "$NEW_USER" ssh-keygen -F "$REPO_HOST" -f "$known" >/dev/null 2>&1; then
    local scanned
    scanned=$(ssh-keyscan -t ed25519 "$REPO_HOST" 2>/dev/null)
    [[ -n $scanned ]] || die "Couldn't reach $REPO_HOST to read its SSH key."
    if [[ $REPO_HOST == github.com ]]; then
      local fp
      fp=$(ssh-keygen -l -f /dev/stdin <<< "$scanned" | awk '{print $2}')
      [[ $fp == "$GITHUB_ED25519_FP" ]] || die "github.com's key fingerprint ($fp) doesn't match GitHub's published one. Stopping for safety."
    else
      warn "Trusting $REPO_HOST's key without a fingerprint check (only GitHub's is built in)."
    fi
    printf '%s\n' "$scanned" >> "$known"
    chown "$NEW_USER:$NEW_USER" "$known"; chmod 644 "$known"
  fi

  if repo_readable; then
    ok "The server can already read $REPO_URL"
    return
  fi

  to_tty ""
  to_tty "${C_BOLD}Action needed: add this deploy key to your repo${C_RESET}"
  to_tty "  1. Open your repo on $REPO_HOST -> Settings -> Deploy keys -> Add deploy key"
  to_tty "     (GitLab: Settings -> Repository -> Deploy keys)"
  to_tty "  2. Title: $(hostname)   Key: copy the whole line below"
  to_tty "  3. Leave 'Allow write access' UNTICKED, then save."
  to_tty ""
  to_tty "$(cat "$key.pub")"
  to_tty ""
  local reply
  while true; do
    printf '  Press Enter once the key is added (or type "skip" to stop here): ' > /dev/tty
    read -r reply < /dev/tty
    if [[ ${reply,,} == skip ]]; then
      die "Stopped before cloning. Add the deploy key, then run the script again."
    fi
    if repo_readable; then
      ok "Access confirmed"
      return
    fi
    warn "Still no access. Check the key was saved on the right repo, and the repo address is correct."
  done
}

deploy_app() {
  step "Download and install the Laravel app"
  if [[ -d $APP_DIR/.git ]]; then
    info "$APP_DIR is already a Git repo; pulling the latest code."
    as_user "git pull --ff-only"
  else
    if [[ -d $APP_DIR && -n $(ls -A "$APP_DIR") ]]; then
      die "$APP_DIR exists and isn't empty. Move it away or choose another folder."
    fi
    install -d -o "$NEW_USER" -g www-data "$APP_DIR"
    sudo -u "$NEW_USER" -H git clone --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
  fi
  [[ -f $APP_DIR/artisan ]] || die "$APP_DIR has no 'artisan' file. Is this a Laravel project?"
  ok "Code is in $APP_DIR"

  info "Installing PHP packages (composer install)..."
  as_user "composer install --no-dev --optimize-autoloader --no-interaction"
  ok "PHP packages installed"

  if [[ -f $APP_DIR/package.json ]]; then
    build_frontend
  else
    info "No package.json, so there's no frontend to build."
  fi

  configure_env

  info "Creating the database tables..."
  as_user "php artisan migrate --force"
  as_user "php artisan storage:link" >/dev/null 2>&1 || true
  ok "Database migrated"

  fix_permissions
  as_user "php artisan optimize" >/dev/null
  ok "Laravel caches built (php artisan optimize)"
}

build_frontend() {
  local candidate
  if ! command -v node >/dev/null 2>&1; then
    candidate=$(apt-cache policy nodejs | awk '/Candidate:/ {print $2}')
    if [[ -z $candidate || $candidate == "(none)" ]] || ! dpkg --compare-versions "$candidate" ge "$MIN_NODE"; then
      warn "Ubuntu's Node.js ($candidate) is older than $MIN_NODE, which Vite needs. Skipping the frontend build."
      return
    fi
    apt_get install nodejs npm
  fi
  ok "Node.js $(node -v) available"

  if [[ -f $APP_DIR/package-lock.json ]]; then
    info "Installing JavaScript packages (npm ci)..."
    as_user "npm ci --no-fund --no-audit"
  else
    warn "No package-lock.json in the repo; using 'npm install'. Commit package-lock.json so deploys are repeatable."
    as_user "npm install --no-fund --no-audit"
  fi
  info "Building CSS and JavaScript (npm run build)..."
  as_user "npm run build"
  ok "Frontend built into public/build"
}

configure_env() {
  local env="$APP_DIR/.env" scheme=http
  (( ENABLE_HTTPS )) && scheme=https

  if [[ ! -f $env ]]; then
    [[ -f $APP_DIR/.env.example ]] || die "No .env.example in the repo to start from."
    sudo -u "$NEW_USER" cp "$APP_DIR/.env.example" "$env"
  fi
  set_env "$env" APP_NAME "\"$APP_NAME\""
  set_env "$env" APP_ENV production
  set_env "$env" APP_DEBUG false
  set_env "$env" APP_URL "$scheme://${DOMAIN:-$SERVER_IP}"
  set_env "$env" DB_CONNECTION mysql
  set_env "$env" DB_HOST 127.0.0.1
  set_env "$env" DB_PORT 3306
  set_env "$env" DB_DATABASE "$DB_NAME"
  set_env "$env" DB_USERNAME "$DB_USER"
  set_env "$env" DB_PASSWORD "\"$DB_PASS\""
  chown "$NEW_USER:www-data" "$env"
  chmod 640 "$env"

  if ! grep -qE '^APP_KEY=.+' "$env"; then
    as_user "php artisan key:generate --force" >/dev/null
  fi
  ok ".env written (production mode, debug OFF)"
}

fix_permissions() {
  usermod -aG www-data "$NEW_USER"
  chown -R "$NEW_USER:www-data" "$APP_DIR"
  chmod -R ug+rwX "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"
  find "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" -type d -exec chmod g+s {} +
  chmod 640 "$APP_DIR/.env"
  ok "File permissions set (owner $NEW_USER, group www-data)"
}

configure_site() {
  local site_name names listen_opt site
  if [[ -n $DOMAIN ]]; then
    site_name=$DOMAIN
    names=$DOMAIN
    (( WITH_WWW )) && names="$DOMAIN www.$DOMAIN"
    listen_opt=""
  else
    # No domain: answer requests to the server's IP address.
    site_name=$(basename "$APP_DIR")
    names="_"
    listen_opt=" default_server"
  fi
  site="/etc/nginx/sites-available/$site_name"
  step "Nginx config for ${DOMAIN:-$SERVER_IP}"

  cat > "$site" <<EOF
# Written by vps-setup. Based on Laravel's deployment docs.
server {
    listen 80${listen_opt};
    listen [::]:80${listen_opt};
    server_name ${names};
    root ${APP_DIR}/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    # Only index.php is ever executed, so uploaded .php files can't run.
    location ~ ^/index\.php(/|\$) {
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_split_path_info ^(.+\.php)(/.*)\$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
  # Keep Certbot's HTTPS additions if the site was set up before.
  if [[ -n $DOMAIN && -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]]; then
    info "A certificate already exists; Certbot will re-apply HTTPS below."
  fi
  ln -sf "$site" "/etc/nginx/sites-enabled/$site_name"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t 2>/dev/null || die "Nginx config test failed. See: nginx -t"
  systemctl reload nginx
  ok "Site enabled: http://${DOMAIN:-$SERVER_IP}"
}

setup_https() {
  step "Free HTTPS with Let's Encrypt"
  local names=("$DOMAIN") args=() missing=()
  (( WITH_WWW )) && names+=("www.$DOMAIN")
  for n in "${names[@]}"; do
    dns_points_here "$n" "$SERVER_IP" || missing+=("$n")
    args+=(-d "$n")
  done
  if (( ${#missing[@]} )); then
    warn "DNS for ${missing[*]} doesn't point to $SERVER_IP yet, so HTTPS was skipped."
    warn "Point an A record at $SERVER_IP, wait for it to spread, then run:"
    warn "  sudo certbot --nginx --redirect -m $LE_EMAIL --agree-tos ${args[*]}"
    HTTPS_DONE=0
    return
  fi

  pkg_installed python3-certbot-nginx || apt_get install certbot python3-certbot-nginx
  certbot --nginx --non-interactive --agree-tos --redirect -m "$LE_EMAIL" "${args[@]}"
  if certbot renew --dry-run >/dev/null 2>&1; then
    ok "Automatic renewal tested"
  else
    warn "Renewal test failed; check: sudo certbot renew --dry-run"
  fi
  as_user "php artisan optimize" >/dev/null
  HTTPS_DONE=1
  ok "HTTPS on: https://$DOMAIN"
}

write_deploy_script() {
  local home app name script
  home=$(getent passwd "$NEW_USER" | cut -d: -f6)
  app=$(basename "$APP_DIR")
  name="deploy-$app.sh"
  script="$home/$name"
  cat > "$script" <<EOF
#!/usr/bin/env bash
# Update $app after you push new code. Written by vps-setup.
# Usage: ~/$name
set -Eeuo pipefail
cd "$APP_DIR"

php artisan down --retry=15 || true
trap 'php artisan up' EXIT

git pull --ff-only
composer install --no-dev --optimize-autoloader --no-interaction
if [[ -f package.json ]]; then
  if [[ -f package-lock.json ]]; then npm ci --no-fund --no-audit; else npm install --no-fund --no-audit; fi
  npm run build
fi
php artisan migrate --force
php artisan optimize
php artisan queue:restart >/dev/null 2>&1 || true

# Clear PHP's code cache so the new code is used (asks for your password).
sudo systemctl reload php${PHP_V}-fpm
echo "Deployed."
EOF
  chown "$NEW_USER:$NEW_USER" "$script"
  chmod 750 "$script"
  DEPLOY_SCRIPT=$script
  ok "Deploy script for future updates: $script"
}

final_summary() {
  local url="http://${DOMAIN:-$SERVER_IP}"
  (( ${HTTPS_DONE:-0} )) && url="https://$DOMAIN"

  to_tty ""
  to_tty "${C_BOLD}${C_GREEN}Setup finished.${C_RESET}"
  to_tty ""
  to_tty "${C_BOLD}1. Test your login BEFORE closing this window${C_RESET}"
  to_tty "   On your Mac, add this to ~/.ssh/config (IdentityFile = your PRIVATE key file):"
  to_tty ""
  to_tty "     Host $HOST_ALIAS"
  to_tty "         HostName $SERVER_IP"
  to_tty "         User $NEW_USER"
  to_tty "         IdentityFile ~/.ssh/id_$NEW_USER"
  to_tty "         IdentitiesOnly yes"
  to_tty ""
  to_tty "   Then, in a NEW terminal window:  ssh $HOST_ALIAS"
  to_tty "   If it fails, fix it from this window. Vultr's 'View Console' also still works."
  if (( INSTALL_APP )); then
    to_tty ""
    to_tty "${C_BOLD}2. Your site${C_RESET}:  $url"
    to_tty "   Code:    $APP_DIR"
    to_tty "   Updates: ~/$(basename "$DEPLOY_SCRIPT")   (run as $NEW_USER)"
    if [[ -z $DOMAIN ]]; then
      to_tty "   Adding a domain later: point its A record at $SERVER_IP, then run"
      to_tty "   'sudo bash setup.sh' again with the same repo and folder, and enter the domain."
    fi
    to_tty ""
    to_tty "${C_BOLD}3. Database password (shown once, not saved in the log)${C_RESET}"
    to_tty "   Database: $DB_NAME   User: $DB_USER   Password: $DB_PASS"
    to_tty "   It's also in $APP_DIR/.env. Save it in your password manager."
  fi
  if [[ -f /var/run/reboot-required ]]; then
    to_tty ""
    to_tty "${C_YELLOW}A reboot is needed to finish updates. After your login test works: sudo reboot${C_RESET}"
  fi
  to_tty ""
  to_tty "Log: $LOG_FILE"
}

# --------------------------------------------------------------------------
main() {
  preflight
  collect_answers

  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  printf '\n===== vps-setup %s started %s =====\n' "$SCRIPT_VERSION" "$(date -Is)"

  update_system
  create_user
  harden_ssh
  auto_updates_and_swap
  install_php
  install_mysql
  install_nginx_and_firewall

  HTTPS_DONE=0
  if (( INSTALL_APP )); then
    setup_deploy_key
    deploy_app
    configure_site
    (( ENABLE_HTTPS )) && setup_https
    write_deploy_script
  fi

  printf '\n===== vps-setup finished %s =====\n' "$(date -Is)"
  final_summary
}

# Run only when executed (not when sourced, e.g. for testing).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
