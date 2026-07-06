#!/data/data/com.termux/files/usr/bin/env bash
# =============================================================================
# Tailscale CLIENT Setup — Android B (This Phone)
# =============================================================================
# This script configures Tailscale on Android B so it can connect to Android A
# (the server) over the Tailnet. Tailscale is assumed to already be installed.
# If not installed, this script will install it automatically.
#
# Run this on Android B (this phone) inside Termux:
#   bash tailscale_client_setup.sh
#
# Required: Android A's Tailscale IP or hostname (you get it after Android A
# runs its setup script).
#   SERVER_IP=100.x.x.x bash tailscale_client_setup.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — edit these if needed
# ---------------------------------------------------------------------------
SERVER_IP="${SERVER_IP:-}"          # Android A's Tailscale IP (optional, set later)
SOCKS5_PORT="${SOCKS5_PORT:-1055}"  # Must match Android A's SSH_PORT? No — this phone's SOCKS5
SSH_PORT="${SSH_PORT:-2222}"        # Must match Android A's SSH_PORT
HOSTNAME_LABEL="android-b-client"  # Name for this device in your Tailnet
# ---------------------------------------------------------------------------

BOLD="\033[1m"; RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}━━━  $*  ━━━${RESET}"; }

# ════════════════════════════════════════════════════════════════════
header "Step 1: Ensure Tailscale is installed"
# ════════════════════════════════════════════════════════════════════
if command -v tailscaled &>/dev/null; then
    success "Tailscale is already installed."
else
    warn "Tailscale not found. Installing now..."
    pkg update -y -q
    pkg install -y -q curl wget grep dpkg termux-services runit 2>/dev/null || true
    apt --fix-broken install -y -q 2>/dev/null || true

    REPO="bropines/tailscale-termux-cli"
    LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -Po '"tag_name": "\K.*?(?=")')
    [ -z "$LATEST_TAG" ] && die "Could not fetch latest release tag."

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

    TMP_DIR=$(mktemp -d "$HOME/tmp.XXXXXX")
    trap 'rm -rf "$TMP_DIR"' EXIT

    wget -q --show-progress -O "$TMP_DIR/$DEB_FILE" "$DEB_URL"
    pkill -f tailscaled 2>/dev/null || true
    dpkg -i "$TMP_DIR/$DEB_FILE" || true
    apt --fix-broken install -y -q 2>/dev/null || true

    termux-fix-shebang \
        "$PREFIX/bin/tailscale-cli" \
        "$PREFIX/bin/tailscale-test" \
        "$PREFIX/bin/tailscale-update" \
        "$PREFIX/bin/tailscaled-log" \
        "$PREFIX/bin/tailscaled-start" \
        "$PREFIX/bin/tailscaled-stop" 2>/dev/null || true

    success "Tailscale installed."
fi

# ════════════════════════════════════════════════════════════════════
header "Step 2: Configure fixed SOCKS5 port"
# ════════════════════════════════════════════════════════════════════
ENV_FILE="$HOME/.tailscale/.env"
mkdir -p "$HOME/.tailscale"
cat > "$ENV_FILE" <<EOF
# Tailscale environment — sourced by tailscaled-start
TS_SOCKS5_PORT=$SOCKS5_PORT
EOF
success "SOCKS5 port fixed to $SOCKS5_PORT (saved to $ENV_FILE)"

# ════════════════════════════════════════════════════════════════════
header "Step 3: Start tailscaled daemon"
# ════════════════════════════════════════════════════════════════════
info "Stopping any previous tailscaled instance..."
pkill -f tailscaled 2>/dev/null || true
sleep 1

info "Starting tailscaled..."
tailscaled-start
sleep 2

if pgrep -f "tailscaled.*statedir" &>/dev/null; then
    success "tailscaled is running. SOCKS5 at 127.0.0.1:$SOCKS5_PORT"
else
    die "tailscaled failed to start. Check: cat ~/.tailscale/tailscaled.log"
fi

# ════════════════════════════════════════════════════════════════════
header "Step 4: Authenticate to Tailscale"
# ════════════════════════════════════════════════════════════════════
CURRENT_STATUS=$(tailscale-cli status 2>&1 || true)

if echo "$CURRENT_STATUS" | grep -q "Logged out\|NeedsLogin\|not logged in"; then
    echo ""
    echo -e "${YELLOW}This device is not yet authenticated to a Tailnet.${RESET}"
    echo "Make sure you authenticate to the SAME Tailscale account as Android A."
    echo ""
    read -rp "Press ENTER to authenticate now, or Ctrl-C to do it manually later..."
    tailscale-cli up --hostname="$HOSTNAME_LABEL" || warn "Re-run manually: tailscale-cli up --hostname=$HOSTNAME_LABEL"
else
    success "Already authenticated to Tailnet."
    echo "$CURRENT_STATUS"
fi

# ════════════════════════════════════════════════════════════════════
header "Step 5: Install SSH client and helpers"
# ════════════════════════════════════════════════════════════════════
info "Installing openssh, netcat, and tmux..."
pkg install -y -q openssh netcat-openbsd tmux 2>/dev/null || pkg install -y -q openssh ncat tmux 2>/dev/null || true
success "SSH and tmux client tools ready."

# ════════════════════════════════════════════════════════════════════
header "Step 6: Create SSH and session helper scripts"
# ════════════════════════════════════════════════════════════════════

# --- Initialize servers registry ---
REGISTRY_FILE="$HOME/.tailscale/servers.conf"
if [ ! -f "$REGISTRY_FILE" ]; then
    cat > "$REGISTRY_FILE" <<'EOF_REG'
# Tailscale SSH Server Registry
# Format: name|tailscale_hostname|ssh_user|ssh_port
# Example:
# phone-a|phone-a|u0_a162|8022
EOF_REG
    success "Initialized empty server registry: $REGISTRY_FILE"
fi

# --- Install ts-servers helper ---
TS_SERVERS_BIN="$PREFIX/bin/ts-servers"
cat > "$TS_SERVERS_BIN" <<'EOF_SERVERS'
#!/data/data/com.termux/files/usr/bin/bash
# Server registry manager for Tailscale multi-server SSH.

REGISTRY="$HOME/.tailscale/servers.conf"
mkdir -p "$HOME/.tailscale"
touch "$REGISTRY"

show_usage() {
    echo "Usage: ts-servers <command> [args]"
    echo ""
    echo "Commands:"
    echo "  list                                 List all registered servers"
    echo "  add <name> <hostname> <user> <port>  Register a new server"
    echo "  remove <name>                        Remove a registered server"
    echo "  test [name]                          Test connectivity to server(s)"
    exit 1
}

if [ $# -lt 1 ]; then
    show_usage
fi

CMD="$1"
shift

case "$CMD" in
    list)
        if [ ! -s "$REGISTRY" ] || [ "$(grep -v '^#' "$REGISTRY" | wc -l)" -eq 0 ]; then
            echo "No servers registered yet. Register one with:"
            echo "  ts-servers add <name> <hostname> <user> <port>"
            exit 0
        fi
        echo -e "NAME\t\tHOSTNAME\t\tUSER\t\tPORT"
        echo -e "----\t\t--------\t\t----\t\t----"
        grep -v '^#' "$REGISTRY" | while IFS='|' read -r name host user port; do
            if [ -n "$name" ]; then
                printf "%-15s %-22s %-15s %s\n" "$name" "$host" "$user" "$port"
            fi
        done
        ;;
    add)
        if [ $# -lt 4 ]; then
            echo "Error: Missing arguments."
            echo "Usage: ts-servers add <name> <hostname> <user> <port>"
            exit 1
        fi
        NAME=$(echo "$1" | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]')
        HOST=$(echo "$2" | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]')
        USER="$3"
        PORT="$4"
        
        # Check if already exists
        if grep -q "^$NAME|" "$REGISTRY" 2>/dev/null; then
            echo "Error: A server with name '$NAME' is already registered."
            exit 1
        fi
        
        echo "$NAME|$HOST|$USER|$PORT" >> "$REGISTRY"
        echo "Successfully registered server '$NAME' ($HOST) with user $USER on port $PORT."
        ;;
    remove)
        if [ $# -lt 1 ]; then
            echo "Error: Missing server name."
            echo "Usage: ts-servers remove <name>"
            exit 1
        fi
        NAME="$1"
        if ! grep -q "^$NAME|" "$REGISTRY" 2>/dev/null; then
            echo "Error: Server '$NAME' not found."
            exit 1
        fi
        # Remove line
        grep -v "^$NAME|" "$REGISTRY" > "${REGISTRY}.tmp" || true
        mv "${REGISTRY}.tmp" "$REGISTRY"
        echo "Successfully removed server '$NAME'."
        ;;
    test)
        TARGET="${1:-}"
        # Helper to test one server
        test_one() {
            local name="$1"
            local host="$2"
            local user="$3"
            local port="$4"
            
            echo -n "Testing '$name' ($host)... "
            # First find IP via tailscale status
            local ip=$(tailscale-cli status 2>/dev/null | awk -v h="$host" '$2 == h { print $1; exit }')
            if [ -z "$ip" ]; then
                echo -e "\033[31m[OFFLINE]\033[0m (Could not resolve '$host' on Tailnet)"
                return 1
            fi
            
            # Read local socks proxy info
            local socks_addr="127.0.0.1:1055"
            local socks_file="$HOME/.tailscale/socks_addr"
            if [ -f "$socks_file" ]; then
                socks_addr=$(cat "$socks_file")
            fi
            
            # Test port via SOCKS5 proxy command using nc
            if nc -z -x "$socks_addr" -X 5 "$ip" "$port" 2>/dev/null; then
                echo -e "\033[32m[ONLINE]\033[0m (IP: $ip, SSH port $port is reachable)"
                return 0
            else
                # Try directly in case socks5 proxy is bypassed or failed
                if nc -z -w 3 "$ip" "$port" 2>/dev/null; then
                    echo -e "\033[33m[ONLINE - NO PROXY]\033[0m (IP: $ip, SOCKS5 failed but port reachable directly)"
                    return 0
                else
                    echo -e "\033[31m[UNREACHABLE]\033[0m (IP: $ip, Port $port is closed or blocked)"
                    return 1
                fi
            fi
        }
        
        if [ -n "$TARGET" ]; then
            LINE=$(grep "^$TARGET|" "$REGISTRY" 2>/dev/null || true)
            if [ -z "$LINE" ]; then
                echo "Error: Server '$TARGET' not found."
                exit 1
            fi
            IFS='|' read -r name host user port <<< "$LINE"
            test_one "$name" "$host" "$user" "$port"
        else
            if [ ! -s "$REGISTRY" ] || [ "$(grep -v '^#' "$REGISTRY" | wc -l)" -eq 0 ]; then
                echo "No servers registered to test."
                exit 0
            fi
            grep -v '^#' "$REGISTRY" | while IFS='|' read -r name host user port; do
                if [ -n "$name" ]; then
                    test_one "$name" "$host" "$user" "$port"
                fi
            done
        fi
        ;;
    *)
        show_usage
        ;;
esac
EOF_SERVERS
termux-fix-shebang "$TS_SERVERS_BIN"
chmod +x "$TS_SERVERS_BIN"
success "Created helper: ts-servers"

# --- Install ts-connect helper ---
TS_CONNECT_BIN="$PREFIX/bin/ts-connect"
cat > "$TS_CONNECT_BIN" <<'EOF_CONNECT'
#!/data/data/com.termux/files/usr/bin/bash
# Unified connector for Tailscale multi-server SSH with tmux support.

REGISTRY="$HOME/.tailscale/servers.conf"

# Load manual servers into arrays if registry exists
SERVERS=()
HOSTS=()
USERS=()
PORTS=()
count=0

if [ -f "$REGISTRY" ]; then
    while IFS='|' read -r name host user port || [ -n "$name" ]; do
        # Skip comments and empty lines
        [[ "$name" =~ ^# ]] && continue
        [ -z "$name" ] && continue
        SERVERS+=("$name")
        HOSTS+=("$host")
        USERS+=("$user")
        PORTS+=("$port")
        ((count++))
    done < "$REGISTRY"
fi

# Auto-detect active Tailscale servers
echo "Scanning Tailnet for auto-detected servers..."
local_ip=$(tailscale-cli ip -4 2>/dev/null | head -1 || echo "")

while read -r ip host owner os status_val info; do
    [ -z "$ip" ] && continue
    [ "$ip" = "$local_ip" ] && continue
    [[ "$status_val" =~ offline ]] && continue
    
    # Skip if already in manual registry
    exists=false
    for s in "${SERVERS[@]}"; do
        if [ "$s" = "$host" ]; then
            exists=true
            break
        fi
    done
    [ "$exists" = true ] && continue
    
    SERVERS+=("$host")
    HOSTS+=("$ip")
    USERS+=("$(whoami)")
    PORTS+=("8022")
    ((count++))
done < <(tailscale-cli status 2>/dev/null || true)

if [ "$count" -eq 0 ]; then
    echo "Error: No servers registered or auto-detected on Tailnet. Please register a server first using:"
    echo "  ts-servers add <name> <hostname> <user> <port>"
    exit 1
fi

select_server() {
    echo "Select a server to connect:"
    for i in "${!SERVERS[@]}"; do
        echo "  $((i+1))) ${SERVERS[$i]} (${HOSTS[$i]})"
    done
    read -rp "Choice [1-$count]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
        SERVER_INDEX=$((choice-1))
    else
        echo "Invalid choice."
        exit 1
    fi
}

SERVER_NAME=""
SESSION_NAME=""
MODE="tmux" # 'tmux' or 'plain'
CREATE_NEW=false

# Parse arguments
if [ $# -eq 0 ]; then
    select_server
    SERVER_NAME="${SERVERS[$SERVER_INDEX]}"
else
    # Find matching server name
    SERVER_NAME="$1"
    SERVER_INDEX=-1
    for i in "${!SERVERS[@]}"; do
        if [ "${SERVERS[$i]}" = "$SERVER_NAME" ]; then
            SERVER_INDEX=$i
            break
        fi
    done
    if [ "$SERVER_INDEX" -eq -1 ]; then
        echo "Error: Server '$SERVER_NAME' not found in registry."
        exit 1
    fi
    shift
fi

# Extract profile details
HOST="${HOSTS[$SERVER_INDEX]}"
USER="${USERS[$SERVER_INDEX]}"
PORT="${PORTS[$SERVER_INDEX]}"

# Parse remaining arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --plain)
            MODE="plain"
            shift
            ;;
        --new)
            CREATE_NEW=true
            if [ $# -lt 2 ]; then
                echo "Error: --new requires a session name."
                exit 1
            fi
            SESSION_NAME="$2"
            shift 2
            ;;
        *)
            SESSION_NAME="$1"
            shift
            ;;
    esac
done

# Resolve Tailscale IP
if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IP="$HOST"
else
    echo "Resolving IP for $HOST on Tailnet..."
    IP=$(tailscale-cli status 2>/dev/null | awk -v h="$HOST" '$2 == h { print $1; exit }')
    if [ -z "$IP" ]; then
        echo "Error: Could not resolve '$HOST' on Tailnet. Is the server online and authenticated?"
        exit 1
    fi
fi

socks_addr="127.0.0.1:1055"
socks_file="$HOME/.tailscale/socks_addr"
if [ -f "$socks_file" ]; then
    socks_addr=$(cat "$socks_file")
fi

PROXY_HOST="${socks_addr%:*}"
PROXY_PORT="${socks_addr#*:}"

# Connection command builder
run_ssh() {
    local cmd="$1"
    if [ -n "$cmd" ]; then
        ssh -t -p "$PORT" \
            -o "ProxyCommand=nc -X 5 -x $PROXY_HOST:$PROXY_PORT %h %p" \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            "$USER@$IP" "$cmd"
    else
        ssh -p "$PORT" \
            -o "ProxyCommand=nc -X 5 -x $PROXY_HOST:$PROXY_PORT %h %p" \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            "$USER@$IP"
    fi
}

if [ "$MODE" = "plain" ]; then
    echo "Connecting to $USER@$IP ($SERVER_NAME) in plain mode..."
    run_ssh ""
    exit 0
fi

# Check if remote has tmux
echo "Checking remote tmux installation..."
HAS_TMUX=$(ssh -p "$PORT" -o "ProxyCommand=nc -X 5 -x $PROXY_HOST:$PROXY_PORT %h %p" -o ConnectTimeout=5 "$USER@$IP" "command -v tmux &>/dev/null && echo yes || echo no" 2>/dev/null || echo "timeout")

if [ "$HAS_TMUX" = "timeout" ]; then
    echo "Error: Connection timed out or server unreachable."
    exit 1
elif [ "$HAS_TMUX" != "yes" ]; then
    echo "Warning: tmux is not installed on the remote server '$SERVER_NAME'."
    read -rp "Connect in plain SSH mode instead? [Y/n] " answer
    if [[ "$answer" =~ ^[Nn] ]]; then
        exit 0
    else
        run_ssh ""
        exit 0
    fi
fi

# If a session name is provided directly or via --new
if [ -n "$SESSION_NAME" ]; then
    if [ "$CREATE_NEW" = true ]; then
        echo "Creating and attaching to new tmux session '$SESSION_NAME'..."
        run_ssh "tmux new-session -A -s $SESSION_NAME"
    else
        echo "Attaching to or creating tmux session '$SESSION_NAME'..."
        run_ssh "tmux attach-session -t $SESSION_NAME || tmux new-session -s $SESSION_NAME"
    fi
    exit 0
fi

# Session picker: query active tmux sessions on remote
echo "Retrieving active tmux sessions on '$SERVER_NAME'..."
SESSIONS_RAW=$(ssh -p "$PORT" -o "ProxyCommand=nc -X 5 -x $PROXY_HOST:$PROXY_PORT %h %p" -o ConnectTimeout=5 "$USER@$IP" "tmux list-sessions -F '#S|#{session_windows}|#{session_attached}' 2>/dev/null" || echo "")

# Parse sessions
ACTIVE_SESSIONS=()
WINDOW_COUNTS=()
ATTACHED_STATUS=()
s_count=0

if [ -n "$SESSIONS_RAW" ]; then
    while IFS='|' read -r s_name s_windows s_attached; do
        if [ -n "$s_name" ]; then
            ACTIVE_SESSIONS+=("$s_name")
            WINDOW_COUNTS+=("$s_windows")
            ATTACHED_STATUS+=("$s_attached")
            ((s_count++))
        fi
    done <<< "$SESSIONS_RAW"
fi

echo ""
echo "Active tmux sessions on '$SERVER_NAME':"
if [ $s_count -eq 0 ]; then
    echo "  (No active sessions found)"
else
    for i in "${!ACTIVE_SESSIONS[@]}"; do
        status="detached"
        [ "${ATTACHED_STATUS[$i]}" -gt 0 ] && status="attached"
        win_word="window"
        [ "${WINDOW_COUNTS[$i]}" -ne 1 ] && win_word="windows"
        echo "  $((i+1))) ${ACTIVE_SESSIONS[$i]} (${WINDOW_COUNTS[$i]} $win_word, $status)"
    done
fi
echo "  $((s_count+1))) [+ Create new session]"
echo "  $((s_count+2))) [Plain SSH session (no tmux)]"
echo ""

read -rp "Choice [1-$((s_count+2))]: " s_choice

if [[ "$s_choice" =~ ^[0-9]+$ ]]; then
    if [ "$s_choice" -ge 1 ] && [ "$s_choice" -le "$s_count" ]; then
        # Picked existing
        SELECTED_SESSION="${ACTIVE_SESSIONS[$((s_choice-1))]}"
        echo "Attaching to session '$SELECTED_SESSION'..."
        run_ssh "tmux attach-session -t $SELECTED_SESSION"
    elif [ "$s_choice" -eq "$((s_count+1))" ]; then
        # Create new
        read -rp "Enter new session name [default: main]: " new_name
        new_name="${new_name:-main}"
        new_name=$(echo "$new_name" | tr -cd '[:alnum:]_-')
        echo "Starting session '$new_name'..."
        run_ssh "tmux new-session -A -s $new_name"
    elif [ "$s_choice" -eq "$((s_count+2))" ]; then
        # Plain
        echo "Connecting in plain mode..."
        run_ssh ""
    else
        echo "Invalid choice."
        exit 1
    fi
else
    echo "Invalid choice."
    exit 1
fi
EOF_CONNECT
termux-fix-shebang "$TS_CONNECT_BIN"
chmod +x "$TS_CONNECT_BIN"
success "Created helper: ts-connect"

# --- Install ts-sessions helper ---
TS_SESSIONS_BIN="$PREFIX/bin/ts-sessions"
cat > "$TS_SESSIONS_BIN" <<'EOF_SESSIONS'
#!/data/data/com.termux/files/usr/bin/bash
# Session manager for remote tmux sessions across Tailscale servers.

REGISTRY="$HOME/.tailscale/servers.conf"


show_usage() {
    echo "Usage: ts-sessions <server_name|all> [kill <session_name>]"
    echo ""
    echo "Examples:"
    echo "  ts-sessions all                  List active sessions on all registered servers"
    echo "  ts-sessions phone-a              List active sessions on phone-a"
    echo "  ts-sessions phone-a kill work    Kill session 'work' on phone-a"
    exit 1
}

if [ $# -lt 1 ]; then
    show_usage
fi

TARGET="$1"
CMD="${2:-}"
SESSION_NAME="${3:-}"

# Load manual servers into arrays if registry exists
SERVERS=()
HOSTS=()
USERS=()
PORTS=()
count=0

if [ -f "$REGISTRY" ]; then
    while IFS='|' read -r name host user port || [ -n "$name" ]; do
        # Skip comments and empty lines
        [[ "$name" =~ ^# ]] && continue
        [ -z "$name" ] && continue
        SERVERS+=("$name")
        HOSTS+=("$host")
        USERS+=("$user")
        PORTS+=("$port")
        ((count++))
    done < "$REGISTRY"
fi

# Auto-detect active Tailscale servers
echo "Scanning Tailnet for auto-detected servers..."
local_ip=$(tailscale-cli ip -4 2>/dev/null | head -1 || echo "")

while read -r ip host owner os status_val info; do
    [ -z "$ip" ] && continue
    [ "$ip" = "$local_ip" ] && continue
    [[ "$status_val" =~ offline ]] && continue
    
    # Skip if already in manual registry
    exists=false
    for s in "${SERVERS[@]}"; do
        if [ "$s" = "$host" ]; then
            exists=true
            break
        fi
    done
    [ "$exists" = true ] && continue
    
    SERVERS+=("$host")
    HOSTS+=("$ip")
    USERS+=("$(whoami)")
    PORTS+=("8022")
    ((count++))
done < <(tailscale-cli status 2>/dev/null || true)

if [ "$count" -eq 0 ]; then
    echo "Error: No servers registered or auto-detected on Tailnet. Please register a server first using:"
    echo "  ts-servers add <name> <hostname> <user> <port>"
    exit 1
fi

list_sessions() {
    local name="$1"
    local host="$2"
    local user="$3"
    local port="$4"
    local quiet="${5:-false}"
    
    # Resolve Tailscale IP
    local ip
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip="$host"
    else
        ip=$(tailscale-cli status 2>/dev/null | awk -v h="$host" '$2 == h { print $1; exit }')
        if [ -z "$ip" ]; then
            [ "$quiet" = false ] && echo "Error: Could not resolve '$host' on Tailnet."
            return 1
        fi
    fi
    
    local socks_addr="127.0.0.1:1055"
    local socks_file="$HOME/.tailscale/socks_addr"
    if [ -f "$socks_file" ]; then
        socks_addr=$(cat "$socks_file")
    fi
    local ph="${socks_addr%:*}"
    local pp="${socks_addr#*:}"
    
    # Test if port reachable
    if ! nc -z -x "$socks_addr" -X 5 "$ip" "$port" 2>/dev/null; then
        [ "$quiet" = false ] && echo "$name ($host): offline/unreachable"
        return 1
    fi
    
    local sessions=$(ssh -p "$port" -o "ProxyCommand=nc -X 5 -x $ph:$pp %h %p" -o ConnectTimeout=5 "$user@$ip" "tmux list-sessions -F '#S|#{session_windows}|#{session_attached}' 2>/dev/null" || echo "")
    
    echo "$name ($host):"
    if [ -z "$sessions" ]; then
        echo "  (No active tmux sessions)"
    else
        while IFS='|' read -r s_name s_windows s_attached; do
            if [ -n "$s_name" ]; then
                local status="detached"
                [ "$s_attached" -gt 0 ] && status="attached"
                local win_word="window"
                [ "$s_windows" -ne 1 ] && win_word="windows"
                echo "  - $s_name ($s_windows $win_word, $status)"
            fi
        done <<< "$sessions"
    fi
    echo ""
}

kill_session() {
    local name="$1"
    local host="$2"
    local user="$3"
    local port="$4"
    local session="$5"
    
    # Resolve Tailscale IP
    local ip
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip="$host"
    else
        ip=$(tailscale-cli status 2>/dev/null | awk -v h="$host" '$2 == h { print $1; exit }')
        if [ -z "$ip" ]; then
            echo "Error: Could not resolve '$host' on Tailnet."
            return 1
        fi
    fi
    
    local socks_addr="127.0.0.1:1055"
    local socks_file="$HOME/.tailscale/socks_addr"
    if [ -f "$socks_file" ]; then
        socks_addr=$(cat "$socks_file")
    fi
    local ph="${socks_addr%:*}"
    local pp="${socks_addr#*:}"
    
    echo "Killing session '$session' on '$name' ($host)..."
    ssh -p "$port" -o "ProxyCommand=nc -X 5 -x $ph:$pp %h %p" -o ConnectTimeout=5 "$user@$ip" "tmux kill-session -t $session 2>/dev/null"
    if [ $? -eq 0 ]; then
        echo "Successfully killed session '$session'."
    else
        echo "Error: Failed to kill session. Does it exist?"
    fi
}

if [ "$TARGET" = "all" ]; then
    if [ -n "$CMD" ]; then
        echo "Error: Cannot run command '$CMD' on 'all' target."
        exit 1
    fi
    for i in "${!SERVERS[@]}"; do
        list_sessions "${SERVERS[$i]}" "${HOSTS[$i]}" "${USERS[$i]}" "${PORTS[$i]}" true
    done
else
    # Find matching server
    idx=-1
    for i in "${!SERVERS[@]}"; do
        if [ "${SERVERS[$i]}" = "$TARGET" ]; then
            idx=$i
            break
        fi
    done
    if [ $idx -eq -1 ]; then
        echo "Error: Server '$TARGET' not found."
        exit 1
    fi
    
    if [ "$CMD" = "kill" ]; then
        if [ -z "$SESSION_NAME" ]; then
            echo "Error: Session name required to kill."
            exit 1
        fi
        kill_session "${SERVERS[$idx]}" "${HOSTS[$idx]}" "${USERS[$idx]}" "${PORTS[$idx]}" "$SESSION_NAME"
    elif [ -n "$CMD" ]; then
        echo "Error: Unknown command '$CMD'."
        show_usage
    else
        list_sessions "${SERVERS[$idx]}" "${HOSTS[$idx]}" "${USERS[$idx]}" "${PORTS[$idx]}" false
    fi
fi
EOF_SESSIONS
termux-fix-shebang "$TS_SESSIONS_BIN"
chmod +x "$TS_SESSIONS_BIN"
success "Created helper: ts-sessions"

# --- Install deprecated ssh-to-server legacy wrapper ---
SSH_HELPER="$PREFIX/bin/ssh-to-server"
cat > "$SSH_HELPER" <<'HELPER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Legacy wrapper for ts-connect.

echo "WARNING: 'ssh-to-server' is deprecated. Please use 'ts-connect' instead."
echo "Delegating to: ts-connect"
echo ""

exec ts-connect "$@"
HELPER_EOF
termux-fix-shebang "$SSH_HELPER"
chmod +x "$SSH_HELPER"
success "Created legacy wrapper: ssh-to-server"

# --- Install deprecated ssh-to-server-tmux legacy wrapper ---
SSH_TMUX_HELPER="$PREFIX/bin/ssh-to-server-tmux"
cat > "$SSH_TMUX_HELPER" <<'HELPER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Legacy wrapper for ts-connect --tmux.

echo "WARNING: 'ssh-to-server-tmux' is deprecated. Please use 'ts-connect' or 'ssh-to-server --tmux' instead."
echo "Delegating to: ts-connect --tmux"
echo ""

exec ts-connect --tmux "$@"
HELPER_EOF
termux-fix-shebang "$SSH_TMUX_HELPER"
chmod +x "$SSH_TMUX_HELPER"
success "Created legacy wrapper: ssh-to-server-tmux"

# --- proxy-env: prints export statements for routing through Tailscale ---
PROXY_HELPER="$PREFIX/bin/tailscale-proxy-env"
cat > "$PROXY_HELPER" <<PHELPER_EOF
#!/data/data/com.termux/files/usr/bin/bash
# Prints proxy environment variables to route traffic through Tailscale SOCKS5.
# Usage: source \$(tailscale-proxy-env)
#    or: eval \$(tailscale-proxy-env)
ADDR=\$(cat "\$HOME/.tailscale/socks_addr" 2>/dev/null || echo "127.0.0.1:${SOCKS5_PORT}")
echo "export ALL_PROXY=socks5://\$ADDR"
echo "export HTTP_PROXY=socks5://\$ADDR"
echo "export HTTPS_PROXY=socks5://\$ADDR"
PHELPER_EOF
termux-fix-shebang "$PROXY_HELPER"
chmod +x "$PROXY_HELPER"
success "Created: tailscale-proxy-env"

# ════════════════════════════════════════════════════════════════════
header "Step 7: Verify Tailnet connectivity"
# ════════════════════════════════════════════════════════════════════
MY_IP=$(tailscale-cli ip -4 2>/dev/null | head -1 || echo "<not yet authenticated>")
echo ""
echo -e "${BOLD}This device (Android B) Tailscale IP: ${CYAN}${MY_IP}${RESET}"

if [ -n "$SERVER_IP" ]; then
    info "Testing connectivity to server at $SERVER_IP:$SSH_PORT..."
    if nc -z -w5 "$SERVER_IP" "$SSH_PORT" 2>/dev/null; then
        success "Port $SSH_PORT on $SERVER_IP is reachable! SSH is ready."
    else
        warn "Cannot reach $SERVER_IP:$SSH_PORT. Make sure:"
        echo "    - The server is running tailscaled-start"
        echo "    - The server is running SSH daemon (termux-sshd-start or proot-sshd-start)"
        echo "    - Both devices are on the same Tailnet"
    fi
fi

# ════════════════════════════════════════════════════════════════════
header "Summary"
# ════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  Android B (Client) Setup Complete!${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  This device IP  : ${BOLD}${MY_IP}${RESET}"
echo -e "  SOCKS5 Proxy    : ${BOLD}127.0.0.1:${SOCKS5_PORT}${RESET}"
echo ""
echo -e "${BOLD}Next Step: Register your first server device!${RESET}"
echo "  Run this command to register a server:"
echo "    ts-servers add <name> <hostname> <user> <port>"
echo "  Example:"
echo "    ts-servers add phone-a phone-a u0_a162 8022"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo "  Manage servers:         ts-servers list|add|remove|test"
echo "  Connect to a server:    ts-connect [server_name]"
echo "  Manage remote sessions:  ts-sessions <server_name|all> [kill <session>]"
echo "  Set proxy for session:   eval \$(tailscale-proxy-env)"
echo "  Check Tailnet status:    tailscale-cli status"
echo "  View daemon logs:        cat ~/.tailscale/tailscaled.log"
echo ""
