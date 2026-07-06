#!/data/data/com.termux/files/usr/bin/env bash
# =============================================================================
# Tailscale SERVER Setup — Android A
# =============================================================================
# This script installs and configures Tailscale in Termux on Android A, then
# sets up an SSH server so Android B can connect to it over the Tailnet.
#
# Run this script on Android A inside Termux:
#   bash tailscale_server_setup.sh
#
# SSH_MODE controls where sshd is installed (default: termux):
#   SSH_MODE=termux  — install openssh directly in Termux (recommended, no proot needed)
#   SSH_MODE=proot   — install openssh inside a proot-distro container
#
# Examples:
#   bash tailscale_server_setup.sh                      # Termux SSH (default)
#   SSH_MODE=proot DISTRO=debian bash tailscale_server_setup.sh  # proot SSH
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — edit these if needed
# ---------------------------------------------------------------------------
SSH_MODE="${SSH_MODE:-termux}"       # 'termux' (default) or 'proot'
DISTRO="${DISTRO:-ubuntu}"          # proot-distro name (only used when SSH_MODE=proot)
SOCKS5_PORT="${SOCKS5_PORT:-1055}"  # fixed SOCKS5 port for reproducibility
SSH_PORT="${SSH_PORT:-8022}"        # SSH port (Termux default: 8022, proot common: 2222)
HOSTNAME="${HOSTNAME:-}"            # Tailscale hostname (optional)
# ---------------------------------------------------------------------------

BOLD="\033[1m"; RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}━━━  $*  ━━━${RESET}"; }

# Helper to read from TTY if stdin is redirected (e.g. curl ... | bash)
read_interactive() {
    local prompt="$1"
    local var_name="$2"
    if [ -t 0 ]; then
        read -rp "$prompt" "$var_name"
    elif [ -c /dev/tty ]; then
        read -rp "$prompt" "$var_name" < /dev/tty
    else
        eval "$var_name=''"
    fi
}

# Determine Tailscale Hostname
# Ignore default localhost/127.0.0.1 values set by Termux shell env
if [ "${HOSTNAME}" = "localhost" ] || [ "${HOSTNAME}" = "127.0.0.1" ]; then
    HOSTNAME=""
fi

if [ -z "${HOSTNAME}" ]; then
    # Try to get Android model name, clean it up for Tailscale (alphanumeric and dashes only)
    MODEL=$(getprop ro.product.model 2>/dev/null | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]' || echo "")
    if [ -n "$MODEL" ]; then
        DEFAULT_HOSTNAME="termux-${MODEL}"
    else
        DEFAULT_HOSTNAME="termux-server-$(shuf -i 1000-9999 -n 1)"
    fi
    info "No HOSTNAME environment variable provided."
    read_interactive "Enter tailscale hostname to use (Press ENTER for default '$DEFAULT_HOSTNAME'): " USER_INPUT
    if [ -n "$USER_INPUT" ]; then
        HOSTNAME=$(echo "$USER_INPUT" | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]')
    else
        HOSTNAME="$DEFAULT_HOSTNAME"
    fi
fi
info "Using Tailscale hostname: $HOSTNAME"

# ════════════════════════════════════════════════════════════════════
header "Step 1: Install dependencies in Termux"
# ════════════════════════════════════════════════════════════════════
info "Updating package lists..."
pkg update -y -q

info "Installing required Termux packages..."
pkg install -y -q curl wget grep dpkg termux-services runit tmux git 2>/dev/null || true
apt --fix-broken install -y -q 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════
header "Step 2: Install Tailscale (bropines/tailscale-termux-cli)"
# ════════════════════════════════════════════════════════════════════
if command -v tailscaled &>/dev/null; then
    warn "Tailscale is already installed. Skipping download."
else
    info "Fetching latest tailscale-termux-cli release..."
    REPO="bropines/tailscale-termux-cli"
    LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -Po '"tag_name": "\K.*?(?=")')
    [ -z "$LATEST_TAG" ] && die "Could not fetch latest release tag. Check internet connection."

    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) ARCH="aarch64" ;;
        armv7l|armv8l|arm) ARCH="arm" ;;
        i686|i386) ARCH="i686" ;;
        x86_64|amd64) ARCH="x86_64" ;;
        *) die "Unsupported architecture: $ARCH" ;;
    esac

    DEB_VERSION=$(echo "$LATEST_TAG" | sed 's/^v//' | tr '-' '.')
    DEB_FILE="tailscale-termux_${DEB_VERSION}_${ARCH}.deb"
    DEB_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$DEB_FILE"

    info "Downloading $DEB_FILE (release $LATEST_TAG)..."
    TMP_DIR=$(mktemp -d "$HOME/tmp.XXXXXX")
    trap 'rm -rf "$TMP_DIR"' EXIT

    wget -q --show-progress -O "$TMP_DIR/$DEB_FILE" "$DEB_URL"

    info "Installing package..."
    pkill -f tailscaled 2>/dev/null || true
    dpkg -i "$TMP_DIR/$DEB_FILE" || true
    apt --fix-broken install -y -q 2>/dev/null || true

    info "Fixing script shebangs for Termux..."
    termux-fix-shebang \
        "$PREFIX/bin/tailscale-cli" \
        "$PREFIX/bin/tailscale-test" \
        "$PREFIX/bin/tailscale-update" \
        "$PREFIX/bin/tailscaled-log" \
        "$PREFIX/bin/tailscaled-start" \
        "$PREFIX/bin/tailscaled-stop" 2>/dev/null || true
fi

success "Tailscale binaries ready."

# ════════════════════════════════════════════════════════════════════
header "Step 3: Configure fixed SOCKS5 port"
# ════════════════════════════════════════════════════════════════════
ENV_FILE="$HOME/.tailscale/.env"
mkdir -p "$HOME/.tailscale"
cat > "$ENV_FILE" <<EOF
# Tailscale environment — sourced by tailscaled-start
TS_SOCKS5_PORT=$SOCKS5_PORT
EOF
success "SOCKS5 port fixed to $SOCKS5_PORT (saved to $ENV_FILE)"

# ════════════════════════════════════════════════════════════════════
header "Step 4: Start tailscaled daemon"
# ════════════════════════════════════════════════════════════════════
info "Starting tailscaled..."
pkill -f tailscaled 2>/dev/null || true
sleep 1
tailscaled-start
sleep 2

if pgrep -f "tailscaled.*statedir" &>/dev/null; then
    success "tailscaled is running. SOCKS5 at 127.0.0.1:$SOCKS5_PORT"
else
    die "tailscaled failed to start. Check logs: cat ~/.tailscale/tailscaled.log"
fi

# ════════════════════════════════════════════════════════════════════
header "Step 5: Authenticate to Tailscale"
# ════════════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}You need to authenticate this device to your Tailnet.${RESET}"
echo "Run the following command and open the printed URL in a browser:"
echo ""
echo -e "  ${BOLD}tailscale-cli up --hostname=$HOSTNAME${RESET}"
echo ""
read_interactive "Press ENTER to run this now, or Ctrl-C to skip and run manually later..." DUMMY_VAR
IS_CONNECTED=false
if tailscale-cli status &>/dev/null; then
    IS_CONNECTED=true
fi

if [ "$IS_CONNECTED" = true ]; then
    info "Tailscale is already authenticated."
    read_interactive "Force re-authentication to get a new login URL? [y/N]: " FORCE_REAUTH_CHOICE
    if [[ "$FORCE_REAUTH_CHOICE" =~ ^[Yy] ]]; then
        info "Executing: tailscale-cli up --hostname=$HOSTNAME --force-reauth"
        tailscale-cli up --hostname="$HOSTNAME" --force-reauth || warn "If it timed out, re-run manually: tailscale-cli up --hostname=$HOSTNAME --force-reauth"
    else
        info "Executing: tailscale-cli up --hostname=$HOSTNAME"
        if tailscale-cli up --hostname="$HOSTNAME"; then
            success "Tailscale hostname updated silently."
        else
            warn "Tailscale command failed. Re-run manually: tailscale-cli up --hostname=$HOSTNAME"
        fi
    fi
else
    info "Executing: tailscale-cli up --hostname=$HOSTNAME"
    if tailscale-cli up --hostname="$HOSTNAME"; then
        success "Tailscale connection check completed successfully."
    else
        warn "Tailscale command failed. If it timed out, please re-run manually: tailscale-cli up --hostname=$HOSTNAME"
    fi
fi

# ════════════════════════════════════════════════════════════════════
header "Step 6: Install and configure SSH server (mode: $SSH_MODE)"
# ════════════════════════════════════════════════════════════════════

if [ "$SSH_MODE" = "proot" ]; then
    # ── proot-distro mode (optional) ──────────────────────────────
    if ! command -v proot-distro &>/dev/null; then
        warn "proot-distro is not installed. Skipping proot SSH setup."
        warn "To enable it later: pkg install proot-distro && proot-distro install ubuntu"
        warn "Then re-run: SSH_MODE=proot bash tailscale_server_setup.sh"
        SSH_MODE="skip"
    elif ! proot-distro list 2>/dev/null | grep -q "$DISTRO"; then
        warn "proot-distro container '$DISTRO' is not installed. Skipping proot SSH setup."
        warn "To install it: proot-distro install $DISTRO"
        warn "Then re-run: SSH_MODE=proot DISTRO=$DISTRO bash tailscale_server_setup.sh"
        SSH_MODE="skip"
    else
        info "Installing openssh-server, tmux, and git inside proot-distro ($DISTRO)..."
        proot-distro login "$DISTRO" -- bash -c "
            set -e
            if command -v apt &>/dev/null; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -q
                apt-get install -y -q openssh-server sudo tmux git
            elif command -v dnf &>/dev/null; then
                dnf install -y -q openssh-server sudo tmux git
            elif command -v pacman &>/dev/null; then
                pacman -Sy --noconfirm openssh sudo tmux git
            else
                echo 'ERROR: No supported package manager found.'
                exit 1
            fi
            mkdir -p /etc/ssh /run/sshd
            [ ! -f /etc/ssh/ssh_host_rsa_key ] && ssh-keygen -A
            cat > /etc/ssh/sshd_config <<'SSHD_EOF'
Port ${SSH_PORT}
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
AllowTcpForwarding yes
GatewayPorts yes
Banner /root/.tailscale/ssh_banner
SSHD_EOF
            cat > /root/.tmux.conf <<'TMUX_EOF'
# Increase scrollback history limit
set -g history-limit 10000

# Enable mouse support
set -g mouse on

# Constrain window size
setw -g aggressive-resize on

# Auto renumber windows
set -g renumber-windows on

# Visual styling
set -g status-bg black
set -g status-fg white
set -g status-left-length 30
set -g status-left '#[fg=green][#S] '
set -g status-right '#[fg=yellow]%Y-%m-%d %H:%M '

# --- Tmux Resurrect & Continuum ---
set -g @continuum-restore 'on'
set -g @continuum-save-interval '0'
set -g @resurrect-capture-pane-contents 'on'
set -g @resurrect-processes 'ssh mysql psql sqlite3 htop top man less tail watch "~python" "~node"'

run-shell ~/.tmux/plugins/tmux-resurrect/resurrect.tmux
run-shell ~/.tmux/plugins/tmux-continuum/continuum.tmux
run-shell -b ~/.tailscale/tmux-smart-backup.sh
TMUX_EOF
            mkdir -p /root/.tmux/plugins
            [ ! -d /root/.tmux/plugins/tmux-resurrect ] && git clone --quiet https://github.com/tmux-plugins/tmux-resurrect /root/.tmux/plugins/tmux-resurrect || true
            [ ! -d /root/.tmux/plugins/tmux-continuum ] && git clone --quiet https://github.com/tmux-plugins/tmux-continuum /root/.tmux/plugins/tmux-continuum || true
            
            # Create smart backup script inside proot
            mkdir -p /root/.tailscale
            cat > /root/.tailscale/tmux-smart-backup.sh <<'BACKUP_EOF'
#!/usr/bin/env bash
# Smart adaptive backup for tmux using exponential backoff.
# Active: backup every ~1 min | Idle: backoff to 30 min | Max: 60 backups
# Detection: reads session_activity timestamp (single integer, near-zero cost)
RESURRECT_DIR="$HOME/.tmux/resurrect"
MIN_INTERVAL=60
MAX_INTERVAL=1800
CURRENT_INTERVAL=$MIN_INTERVAL
LAST_ACTIVITY_TS=0

mkdir -p "$RESURRECT_DIR"

while true; do
    sleep "$CURRENT_INTERVAL"

    # Exit if tmux server is gone
    if ! tmux info >/dev/null 2>&1; then
        exit 0
    fi

    # Single cheap query: last user-input timestamp across all sessions
    LATEST_ACTIVITY=$(tmux list-sessions -F '#{session_activity}' 2>/dev/null | sort -rn | head -1)
    [ -z "$LATEST_ACTIVITY" ] && continue

    if [ "$LATEST_ACTIVITY" != "$LAST_ACTIVITY_TS" ]; then
        # User was active since last check — backup and reset to fast polling
        LAST_ACTIVITY_TS="$LATEST_ACTIVITY"
        CURRENT_INTERVAL=$MIN_INTERVAL
        if [ -f "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" ]; then
            tmux run-shell "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" >/dev/null 2>&1
            ls -t "$RESURRECT_DIR"/tmux_resurrect_*.txt 2>/dev/null | tail -n +61 | xargs rm -f
        fi
    else
        # No activity — exponential backoff (1m -> 2m -> 4m -> ... -> 30m cap)
        CURRENT_INTERVAL=$((CURRENT_INTERVAL * 2))
        [ $CURRENT_INTERVAL -gt $MAX_INTERVAL ] && CURRENT_INTERVAL=$MAX_INTERVAL
    fi
done
BACKUP_EOF
            chmod +x /root/.tailscale/tmux-smart-backup.sh

            echo 'Set a root password (used to SSH in from Android B):'
            passwd root
            mkdir -p /root/.tailscale
            echo "[TS-SSH] user=root port=${SSH_PORT}" > /root/.tailscale/ssh_banner
        " || { warn "Failed to configure SSH and tmux inside proot-distro. Skipping."; SSH_MODE="skip"; }
        [ "$SSH_MODE" = "proot" ] && success "OpenSSH configured inside $DISTRO on port $SSH_PORT."
    fi

elif [ "$SSH_MODE" = "termux" ]; then
    # ── Termux native mode (default) ──────────────────────────────
    info "Installing openssh directly in Termux..."
    pkg install -y -q openssh 2>/dev/null || true

    # Generate host keys if not present
    if [ ! -f "$PREFIX/etc/ssh/ssh_host_rsa_key" ]; then
        info "Generating SSH host keys..."
        ssh-keygen -A 2>/dev/null || true
    fi

    # Write sshd_config for Termux (non-root, high port)
    SSHD_CONF="$PREFIX/etc/ssh/sshd_config"
    cat > "$SSHD_CONF" <<EOF
Port $SSH_PORT
ListenAddress 0.0.0.0
PasswordAuthentication yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
AllowTcpForwarding yes
GatewayPorts yes
Banner $HOME/.tailscale/ssh_banner
Subsystem sftp $PREFIX/libexec/sftp-server
EOF

    mkdir -p "$HOME/.tailscale"
    echo "[TS-SSH] user=$(whoami) port=$SSH_PORT" > "$HOME/.tailscale/ssh_banner"

    success "OpenSSH configured in Termux on port $SSH_PORT."
    echo ""
    echo -e "${BOLD}${YELLOW}┌─────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}${YELLOW}│  ACTION REQUIRED: Set your Termux SSH password           │${RESET}"
    echo -e "${BOLD}${YELLOW}│                                                          │${RESET}"
    echo -e "${BOLD}${YELLOW}│  Run this command NOW (after the script finishes):        │${RESET}"
    echo -e "${BOLD}${YELLOW}│                                                          │${RESET}"
    echo -e "${BOLD}${YELLOW}│    passwd                                                │${RESET}"
    echo -e "${BOLD}${YELLOW}│                                                          │${RESET}"
    echo -e "${BOLD}${YELLOW}│  Android B will use this password to SSH in.             │${RESET}"
    echo -e "${BOLD}${YELLOW}└─────────────────────────────────────────────────────────┘${RESET}"
    echo ""
fi

# ════════════════════════════════════════════════════════════════════
header "Step 7: Create SSH launcher script"
# ════════════════════════════════════════════════════════════════════

if [ "$SSH_MODE" = "termux" ]; then
    SSHD_LAUNCHER="$PREFIX/bin/termux-sshd-start"
    cat > "$SSHD_LAUNCHER" <<RUNNER_EOF
#!/data/data/com.termux/files/usr/bin/bash
# Starts sshd directly in Termux (no proot needed).
SSH_PORT="${SSH_PORT}"
LOG="\$HOME/.tailscale/termux-sshd.log"

if pgrep -f "sshd" &>/dev/null; then
    echo "sshd is already running."
    exit 0
fi

mkdir -p "\$HOME/.tailscale"
echo "[TS-SSH] user=\$(whoami) port=\$SSH_PORT" > "\$HOME/.tailscale/ssh_banner"

echo "Starting Termux sshd on port \$SSH_PORT..."
nohup sshd -D -p "\$SSH_PORT" >> "\$LOG" 2>&1 &
sleep 2

if pgrep -f "sshd" &>/dev/null; then
    TS_IP=\$(tailscale-cli ip -4 2>/dev/null | head -1 || echo "<tailscale-ip>")
    WHOAMI=\$(whoami)
    echo "sshd running. SSH in from Android B:"
    echo "  ssh -p \$SSH_PORT \$WHOAMI@\$TS_IP"
else
    echo "ERROR: sshd failed to start. Check: cat \$LOG"
    exit 1
fi
RUNNER_EOF
    termux-fix-shebang "$SSHD_LAUNCHER"
    chmod +x "$SSHD_LAUNCHER"
    success "Created launcher: termux-sshd-start"

elif [ "$SSH_MODE" = "proot" ]; then
    SSHD_LAUNCHER="$PREFIX/bin/proot-sshd-start"
    cat > "$SSHD_LAUNCHER" <<RUNNER_EOF
#!/data/data/com.termux/files/usr/bin/bash
# Starts sshd inside proot-distro (${DISTRO}), running in background.
DISTRO="${DISTRO}"
SSH_PORT="${SSH_PORT}"
LOG="\$HOME/.tailscale/proot-sshd.log"

if pgrep -f "sshd -D" &>/dev/null; then
    echo "sshd is already running."
    exit 0
fi

proot-distro login "\$DISTRO" -- bash -c "mkdir -p /root/.tailscale && echo '[TS-SSH] user=root port=\$SSH_PORT' > /root/.tailscale/ssh_banner"

echo "Starting sshd inside \$DISTRO on port \$SSH_PORT..."
nohup proot-distro login "\$DISTRO" -- /usr/sbin/sshd -D -p "\$SSH_PORT" >> "\$LOG" 2>&1 &
sleep 2

if pgrep -f "sshd -D" &>/dev/null; then
    TS_IP=\$(tailscale-cli ip -4 2>/dev/null | head -1 || echo "<tailscale-ip>")
    echo "sshd running. SSH in from Android B:"
    echo "  ssh -p \$SSH_PORT root@\$TS_IP"
else
    echo "ERROR: sshd failed. Check: cat \$LOG"
    exit 1
fi
RUNNER_EOF
    termux-fix-shebang "$SSHD_LAUNCHER"
    chmod +x "$SSHD_LAUNCHER"
    success "Created launcher: proot-sshd-start"

else
    warn "SSH launcher skipped (SSH_MODE=skip). Set up SSH manually later."
fi

# ════════════════════════════════════════════════════════════════════
header "Step 8: Enable Auto-Start via termux-services"
# ════════════════════════════════════════════════════════════════════
AUTO_START_ENABLED=false

read_interactive "Enable automatic service startup for Tailscale and SSH via termux-services? [Y/n]: " AUTO_START_CHOICE
if [[ -z "$AUTO_START_CHOICE" || "$AUTO_START_CHOICE" =~ ^[Yy] ]]; then
    if ! command -v service-daemon &>/dev/null; then
        warn "termux-services is not fully installed. Trying to install..."
        pkg install -y -q termux-services runit || true
    fi

    if command -v service-daemon &>/dev/null; then
        info "Enabling tailscaled in termux-services..."
        sv-enable tailscaled || warn "Failed to enable tailscaled service"

        if [ "$SSH_MODE" = "termux" ]; then
            info "Enabling native sshd in termux-services..."
            sv-enable sshd || warn "Failed to enable sshd service"
            AUTO_START_ENABLED=true
        elif [ "$SSH_MODE" = "proot" ]; then
            info "Setting up custom proot-sshd service in termux-services..."
            PROOT_SERVICE_DIR="$PREFIX/var/service/proot-sshd"
            mkdir -p "$PROOT_SERVICE_DIR/log"

            # Create proot-sshd/run
            cat > "$PROOT_SERVICE_DIR/run" <<RUN_EOF
#!/data/data/com.termux/files/usr/bin/sh
exec 2>&1
export HOME=$HOME
exec proot-distro login "$DISTRO" -- /usr/sbin/sshd -D -p "$SSH_PORT"
RUN_EOF
            chmod +x "$PROOT_SERVICE_DIR/run"

            # Create proot-sshd/log/run
            cat > "$PROOT_SERVICE_DIR/log/run" <<'LOG_EOF'
#!/data/data/com.termux/files/usr/bin/sh
pwd=${PWD%/*}
service=${pwd##*/}
mkdir -p "$LOGDIR/sv/$service"
exec svlogd -tt "$LOGDIR/sv/$service"
LOG_EOF
            chmod +x "$PROOT_SERVICE_DIR/log/run"

            info "Enabling proot-sshd in termux-services..."
            sv-enable proot-sshd || warn "Failed to enable proot-sshd service"
            AUTO_START_ENABLED=true
        else
            warn "SSH mode is skip. Only tailscaled was enabled."
        fi
    else
        warn "service-daemon is not available. Skipping termux-services setup."
    fi
else
    info "Skipping termux-services auto-start configuration."
fi

# ════════════════════════════════════════════════════════════════════
header "Step 9: Configure Auto-Start on Boot (Termux:Boot)"
# ════════════════════════════════════════════════════════════════════
BOOT_SCRIPT_CREATED=false

read_interactive "Configure auto-start on device reboot (requires Termux:Boot app)? [Y/n]: " BOOT_CHOICE
if [[ -z "$BOOT_CHOICE" || "$BOOT_CHOICE" =~ ^[Yy] ]]; then
    BOOT_DIR="$HOME/.termux/boot"
    mkdir -p "$BOOT_DIR"
    BOOT_SCRIPT="$BOOT_DIR/start-tailscale-ssh"

    cat > "$BOOT_SCRIPT" <<'BOOT_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Auto-start Tailscale and SSH on phone boot via Termux:Boot

# Acquire a wake-lock so the device doesn't sleep in background
if [ -x /data/data/com.termux/files/usr/bin/termux-wake-lock ]; then
    /data/data/com.termux/files/usr/bin/termux-wake-lock
fi

# Give Android a moment to settle network connectivity on boot
sleep 5

# Start services if termux-services is installed
if [ -x /data/data/com.termux/files/usr/bin/service-daemon ]; then
    export SVDIR=/data/data/com.termux/files/usr/var/service
    export LOGDIR=/data/data/com.termux/files/usr/var/log
    /data/data/com.termux/files/usr/bin/service-daemon start
else
    # Fallback to direct background execution if termux-services is not available
    if [ -x /data/data/com.termux/files/usr/bin/tailscaled-start ]; then
        /data/data/com.termux/files/usr/bin/tailscaled-start >/dev/null 2>&1
    fi
    if [ -x /data/data/com.termux/files/usr/bin/termux-sshd-start ]; then
        /data/data/com.termux/files/usr/bin/termux-sshd-start >/dev/null 2>&1
    fi
    if [ -x /data/data/com.termux/files/usr/bin/proot-sshd-start ]; then
        /data/data/com.termux/files/usr/bin/proot-sshd-start >/dev/null 2>&1
    fi
fi
BOOT_EOF

    chmod +x "$BOOT_SCRIPT"
    BOOT_SCRIPT_CREATED=true
    success "Boot script configured at: $BOOT_SCRIPT"
else
    info "Skipping Termux:Boot configuration."
fi

# ════════════════════════════════════════════════════════════════════
header "Step 10: Configure tmux (Termux Host)"
# ════════════════════════════════════════════════════════════════════
TMUX_CONF="$HOME/.tmux.conf"
if [ ! -f "$TMUX_CONF" ] || ! grep -q "Tailscale setup optimizations" "$TMUX_CONF" 2>/dev/null; then
    info "Writing tmux configuration to $TMUX_CONF..."
    cat >> "$TMUX_CONF" << 'TMUX_EOF'

# --- Tailscale setup optimizations ---
# Increase scrollback history limit
set -g history-limit 10000

# Enable mouse support
set -g mouse on

# Constrain window size
setw -g aggressive-resize on

# Auto renumber windows
set -g renumber-windows on

# Visual styling
set -g status-bg black
set -g status-fg white
set -g status-left-length 30
set -g status-left '#[fg=green][#S] '
set -g status-right '#[fg=yellow]%Y-%m-%d %H:%M '
TMUX_EOF
    success "tmux configuration updated on Termux host."
else
    success "tmux configuration already optimized on Termux host."
fi

# Configure tmux-resurrect & tmux-continuum for session survival
info "Installing tmux plugins (tmux-resurrect and tmux-continuum)..."
mkdir -p "$HOME/.tmux/plugins"
if [ ! -d "$HOME/.tmux/plugins/tmux-resurrect" ]; then
    git clone --quiet https://github.com/tmux-plugins/tmux-resurrect "$HOME/.tmux/plugins/tmux-resurrect" || warn "Failed to clone tmux-resurrect"
fi
if [ ! -d "$HOME/.tmux/plugins/tmux-continuum" ]; then
    git clone --quiet https://github.com/tmux-plugins/tmux-continuum "$HOME/.tmux/plugins/tmux-continuum" || warn "Failed to clone tmux-continuum"
fi

# Create smart backup script on Termux Host
info "Creating smart backup script..."
mkdir -p "$HOME/.tailscale"
cat > "$HOME/.tailscale/tmux-smart-backup.sh" <<'BACKUP_EOF'
#!/usr/bin/env bash
# Smart adaptive backup for tmux using exponential backoff.
# Active: backup every ~1 min | Idle: backoff to 30 min | Max: 60 backups
# Detection: reads session_activity timestamp (single integer, near-zero cost)
RESURRECT_DIR="$HOME/.tmux/resurrect"
MIN_INTERVAL=60
MAX_INTERVAL=1800
CURRENT_INTERVAL=$MIN_INTERVAL
LAST_ACTIVITY_TS=0

mkdir -p "$RESURRECT_DIR"

while true; do
    sleep "$CURRENT_INTERVAL"

    # Exit if tmux server is gone
    if ! tmux info >/dev/null 2>&1; then
        exit 0
    fi

    # Single cheap query: last user-input timestamp across all sessions
    LATEST_ACTIVITY=$(tmux list-sessions -F '#{session_activity}' 2>/dev/null | sort -rn | head -1)
    [ -z "$LATEST_ACTIVITY" ] && continue

    if [ "$LATEST_ACTIVITY" != "$LAST_ACTIVITY_TS" ]; then
        # User was active since last check — backup and reset to fast polling
        LAST_ACTIVITY_TS="$LATEST_ACTIVITY"
        CURRENT_INTERVAL=$MIN_INTERVAL
        if [ -f "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" ]; then
            tmux run-shell "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" >/dev/null 2>&1
            ls -t "$RESURRECT_DIR"/tmux_resurrect_*.txt 2>/dev/null | tail -n +61 | xargs rm -f
        fi
    else
        # No activity — exponential backoff (1m -> 2m -> 4m -> ... -> 30m cap)
        CURRENT_INTERVAL=$((CURRENT_INTERVAL * 2))
        [ $CURRENT_INTERVAL -gt $MAX_INTERVAL ] && CURRENT_INTERVAL=$MAX_INTERVAL
    fi
done
BACKUP_EOF
chmod +x "$HOME/.tailscale/tmux-smart-backup.sh"

# Clean up any old configurations first, then append the clean block
info "Updating plugin configuration in $TMUX_CONF..."
sed -i '/tmux-resurrect/d; /tmux-continuum/d; /continuum-restore/d; /continuum-save-interval/d; /resurrect-capture-pane-contents/d; /resurrect-processes/d; /tmux-smart-backup.sh/d; /after-save-environment/d' "$TMUX_CONF" 2>/dev/null || true

cat >> "$TMUX_CONF" << 'TMUX_EOF'

# --- Tmux Resurrect & Continuum ---
set -g @continuum-restore 'on'
set -g @continuum-save-interval '0'
set -g @resurrect-capture-pane-contents 'on'
set -g @resurrect-processes 'ssh mysql psql sqlite3 htop top man less tail watch "~python" "~node"'

run-shell ~/.tmux/plugins/tmux-resurrect/resurrect.tmux
run-shell ~/.tmux/plugins/tmux-continuum/continuum.tmux
run-shell -b ~/.tailscale/tmux-smart-backup.sh
TMUX_EOF

# ════════════════════════════════════════════════════════════════════
header "Step 11: Summary"
# ════════════════════════════════════════════════════════════════════
sleep 2
TAILSCALE_IP=$(tailscale-cli ip -4 2>/dev/null | head -1 || echo "<not yet authenticated>")
SSH_USER=$([ "$SSH_MODE" = "termux" ] && whoami || echo "root")
SSH_TARGET="${SSH_USER}@${TAILSCALE_IP}"

case "$SSH_MODE" in
    termux)  SSH_LAUNCHER="termux-sshd-start";  SSH_LOG="~/.tailscale/termux-sshd.log" ;;
    proot)   SSH_LAUNCHER="proot-sshd-start";   SSH_LOG="~/.tailscale/proot-sshd.log"  ;;
    *)       SSH_LAUNCHER="(skipped — configure SSH later)" ; SSH_LOG="n/a" ;;
esac

echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  Android A (Server) Setup Complete!${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  Tailscale IP   : ${BOLD}${TAILSCALE_IP}${RESET}"
echo -e "  SOCKS5 Proxy   : ${BOLD}127.0.0.1:${SOCKS5_PORT}${RESET}"
echo -e "  SSH Mode       : ${BOLD}${SSH_MODE}${RESET}"
echo -e "  SSH Port       : ${BOLD}${SSH_PORT}${RESET}"
[ "$SSH_MODE" = "proot" ] && echo -e "  proot-distro   : ${BOLD}${DISTRO}${RESET}"
echo -e "  Auto-Start     : ${BOLD}$([ "$AUTO_START_ENABLED" = true ] && echo "Enabled (termux-services)" || echo "Disabled")${RESET}"
echo -e "  Boot Auto-Start: ${BOLD}$([ "$BOOT_SCRIPT_CREATED" = true ] && echo "Configured (~/.termux/boot)" || echo "Disabled")${RESET}"
echo ""
echo -e "${BOLD}Status & Management:${RESET}"
if [ "$AUTO_START_ENABLED" = true ]; then
    echo "  Services are managed automatically by termux-services."
    if [ "$SSH_MODE" = "termux" ]; then
        echo "  - Check status: sv status tailscaled sshd"
        echo "  - Restart:      sv restart tailscaled sshd"
    elif [ "$SSH_MODE" = "proot" ]; then
        echo "  - Check status: sv status tailscaled proot-sshd"
        echo "  - Restart:      sv restart tailscaled proot-sshd"
    fi
else
    echo "  Start manually using:"
    echo "    tailscaled-start"
    echo "    $SSH_LAUNCHER"
fi
echo ""
if [ "$BOOT_SCRIPT_CREATED" = true ]; then
    echo -e "${YELLOW}${BOLD}⚠  ACTION REQUIRED to survive phone reboots:${RESET}"
    echo "  1. Install \"Termux:Boot\" app on this device (available on F-Droid)."
    echo "  2. Launch the \"Termux:Boot\" app once to register it with the OS."
    echo "  3. The boot script will then execute automatically on every restart."
    echo ""
fi
echo -e "${BOLD}On Android B (Client):${RESET}"
echo "  1. Run client setup:      bash tailscale_client_setup.sh"
echo "  2. Then SSH in:           ssh -p ${SSH_PORT} ${SSH_TARGET}"
echo ""
echo -e "  Tailscale logs : ${BOLD}cat ~/.tailscale/tailscaled.log${RESET}"
echo -e "  SSH logs       : ${BOLD}cat $SSH_LOG${RESET}"
echo ""
