# tailscale-termux

Tailscale-powered SSH toolkit for Termux on Android. Connect any number of devices over a private WireGuard mesh and manage persistent tmux sessions from your phone.

## Architecture

```
Servers (phone-a, laptop, rpi...)     Client (Android / Termux)
┌──────────────────────────────┐      ┌──────────────────────────────┐
│  Termux / Linux              │      │  Termux                      │
│  ├─ tailscaled (userspace)   │      │  ├─ tailscaled (userspace)   │
│  │  └─ SOCKS5: :1055         │◄────►│  │  └─ SOCKS5: :1055        │
│  ├─ sshd (Termux or proot)   │      │  ├─ ts-connect               │
│  └─ tmux (session host)      │      │  ├─ ts-servers               │
└──────────────────────────────┘      │  └─ ts-sessions              │
         ↕ Tailnet (WireGuard mesh)   └──────────────────────────────┘
  100.x.x.x              100.y.y.y
```

**What you get:**
- Secure SSH into any registered server over the Tailnet — no port-forwarding, no static IPs.
- Persistent terminal sessions with **tmux** (reconnect without losing work even after Android kills the app).
- Unified management of all your devices and active sessions from one phone.

---

## Files

| File | Purpose |
| :--- | :--- |
| `tailscale_server_setup.sh` | Server setup: install Tailscale + tmux, configure sshd, write helper commands |
| `tailscale_client_setup.sh` | Client setup: configure Tailscale, initialise server registry, install `ts-*` commands |
| `ts-connect` | Unified connector — resolves Tailscale IP, sets SOCKS5 proxy, interactive or direct tmux attach |
| `ts-servers` | Manage the server registry (list, add, remove, test) |
| `ts-sessions` | Query and kill remote tmux sessions across all registered servers |

---

## Quick Start

> [!IMPORTANT]
> All devices must use the **same Tailscale account**. Create a free account at [tailscale.com](https://tailscale.com) before starting.

### Step 1 — Set up the server device(s)

Copy `tailscale_server_setup.sh` to each server device and run it:

```bash
# Set a friendly Tailscale hostname (optional; script will prompt if omitted)
HOSTNAME=phone-a bash tailscale_server_setup.sh
```

The script installs Tailscale, tmux, and openssh, then prints the Tailscale IP and SSH port. When done, start the SSH daemon:

```bash
termux-sshd-start   # Termux native SSH (default, port 8022)
# OR
proot-sshd-start    # proot-distro SSH (port 2222, if SSH_MODE=proot was used)
```

### Step 2 — Set up the client device

Run the client setup script on the device you will connect *from*:

```bash
bash tailscale_client_setup.sh
```

This configures Tailscale, creates `~/.tailscale/servers.conf`, and installs `ts-connect`, `ts-servers`, and `ts-sessions` into `$PREFIX/bin`.

### Step 3 — Register the server

```bash
# ts-servers add <short_name> <tailscale_hostname> <user> <port>
ts-servers add phone-a phone-a u0_a162 8022

# Verify connectivity
ts-servers test phone-a
```

### Step 4 — Connect

```bash
# Interactive server + session picker
ts-connect

# Connect to a specific server (interactive session picker)
ts-connect phone-a

# Attach directly to a named tmux session (creates it if absent)
ts-connect phone-a main

# Check sessions across all registered servers
ts-sessions all
```

---

## Manual Installation

### Prerequisites (both devices)

- Termux from **F-Droid** or GitHub (not Google Play)
- Internet connection
- A Tailscale account

### 1 — Install Tailscale

```bash
pkg update -y
pkg install curl wget grep dpkg -y

REPO="bropines/tailscale-termux-cli"
LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -Po '"tag_name": "\K.*?(?=")')

ARCH=$(uname -m)
DEB_VERSION=$(echo "$LATEST_TAG" | sed 's/^v//' | tr '-' '.')
DEB_FILE="tailscale-termux_${DEB_VERSION}_${ARCH}.deb"
DEB_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$DEB_FILE"

wget -O /tmp/$DEB_FILE "$DEB_URL"
dpkg -i /tmp/$DEB_FILE
apt --fix-broken install -y
```

Fix shebangs (required in Termux):

```bash
termux-fix-shebang \
  $PREFIX/bin/tailscale-cli \
  $PREFIX/bin/tailscale-test \
  $PREFIX/bin/tailscale-update \
  $PREFIX/bin/tailscaled-log \
  $PREFIX/bin/tailscaled-start \
  $PREFIX/bin/tailscaled-stop
```

Pin the SOCKS5 port so it doesn't change between restarts:

```bash
mkdir -p ~/.tailscale
echo "TS_SOCKS5_PORT=1055" > ~/.tailscale/.env
```

### 2 — Start Tailscale and authenticate

```bash
tailscaled-start
# Output: "Done. SOCKS5 address: 127.0.0.1:1055"

tailscale-cli up --hostname=my-device-name
# Opens a URL — authorise the device in your browser
```

### 3 — Configure SSH (server devices only)

**Termux SSH (default, recommended):**

```bash
pkg install openssh -y
ssh-keygen -A
cat > $PREFIX/etc/ssh/sshd_config << 'EOF'
Port 8022
ListenAddress 0.0.0.0
PasswordAuthentication yes
X11Forwarding no
PrintMotd no
AllowTcpForwarding yes
GatewayPorts yes
Subsystem sftp $PREFIX/libexec/sftp-server
EOF
passwd
nohup sshd -D -p 8022 >> ~/.tailscale/termux-sshd.log 2>&1 &
```

**proot-distro SSH (optional — full Linux environment):**

```bash
pkg install proot-distro -y
proot-distro install ubuntu
proot-distro login ubuntu -- bash -c "
  apt-get update && apt-get install -y openssh-server
  mkdir -p /etc/ssh /run/sshd && ssh-keygen -A
  cat > /etc/ssh/sshd_config << 'EOF'
Port 2222
PermitRootLogin yes
PasswordAuthentication yes
UsePAM no
AllowTcpForwarding yes
GatewayPorts yes
EOF
  passwd root"
nohup proot-distro login ubuntu -- /usr/sbin/sshd -D -p 2222 \
  >> ~/.tailscale/proot-sshd.log 2>&1 &
```

> The setup script (`SSH_MODE=proot`) handles all of this automatically and installs a `proot-sshd-start` helper.

---

## tmux Session Persistence

Android kills background processes aggressively, which can terminate an active SSH session. **tmux** keeps your shell running on the server side so you can always reconnect where you left off.

```bash
# Reconnect to an existing session or create one named 'main':
ts-connect phone-a main
```

### Essential keybindings

All tmux commands start with the prefix `Ctrl-b` (press and release), then:

| Key | Action |
| :--- | :--- |
| `d` | Detach (leave session running in background) |
| `c` | New window |
| `n` / `p` | Next / previous window |
| `0–9` | Jump to window by index |
| `"` | Split pane horizontally |
| `%` | Split pane vertically |
| `Arrow` | Move focus between panes |
| `[` | Scroll mode (arrow keys / PageUp, `q` to exit) |

> [!TIP]
> **Mouse mode is enabled by default** via the setup script. Click panes to focus, scroll to browse history, drag borders to resize.

### tmux config applied by the setup script

- `history-limit 10000` — larger scrollback buffer
- `mouse on` — mouse/touch support
- `aggressive-resize on` — window size follows the active client
- `renumber-windows on` — gaps auto-close when a window is closed
- Sleek dark status bar showing session name and clock
- **`tmux-resurrect` & `tmux-continuum` integration**:
  - Automatically saves the tmux environment (including pane layout, working directories, and running processes) every 15 minutes.
  - Automatically restores your last saved state whenever the tmux server is launched (e.g. after a phone reboot, after Termux is force closed, or when you connect via `ts-connect`).
  - **Manual Save**: `Ctrl-b` followed by `Ctrl-s`
  - **Manual Restore**: `Ctrl-b` followed by `Ctrl-r`

---

## Multi-Server Management

### Server registry (`~/.tailscale/servers.conf`)

```ini
# Format: name|tailscale_hostname|ssh_user|ssh_port
phone-a|phone-a|u0_a162|8022
laptop|my-laptop|user|22
rpi|raspberrypi|pi|22
```

### `ts-servers` — registry management

```bash
ts-servers list                          # List all registered servers
ts-servers add laptop my-laptop user 22  # Register a new server
ts-servers remove laptop                 # Remove a server
ts-servers test                          # Test all servers
ts-servers test phone-a                  # Test a specific server
```

### `ts-connect` — connect with tmux

```bash
ts-connect                    # Interactive server + session picker
ts-connect phone-a            # Session picker for a specific server
ts-connect phone-a main       # Attach to (or create) session 'main'
ts-connect phone-a --new work # Force-create a new session named 'work'
ts-connect phone-a --plain    # Plain SSH, no tmux
```

### `ts-sessions` — remote session management

```bash
ts-sessions phone-a           # List sessions on one server
ts-sessions all               # List sessions on all servers
ts-sessions phone-a kill work # Kill a named session remotely
```

---

## SOCKS5 Proxy

Tailscale runs in userspace and exposes a local SOCKS5 proxy at `127.0.0.1:1055`. Route CLI tools through it:

```bash
# Export proxy env for the current shell session
eval $(tailscale-proxy-env)
# Sets ALL_PROXY, HTTP_PROXY, HTTPS_PROXY → socks5://127.0.0.1:1055

# Single command via proxy
curl --socks5-hostname 127.0.0.1:1055 http://100.x.x.x:8080

# Raw SSH through the SOCKS5 proxy
ssh -p 8022 \
    -o "ProxyCommand=nc -X 5 -x 127.0.0.1:1055 %h %p" \
    user@100.x.x.x
```

---

## Port Forwarding

```bash
# Local forward — access a remote port locally
ssh -p 8022 -L 8080:localhost:80 user@100.x.x.x

# Reverse tunnel — expose a local port on the remote
ssh -p 8022 -R 9090:localhost:3000 user@100.x.x.x

# Persistent background tunnel
ssh -p 8022 -N -f -L 5432:localhost:5432 user@100.x.x.x
```

---

## Auto-Start

The setup script `tailscale_server_setup.sh` offers to configure auto-start automatically.

### 1 — Auto-Start on Termux Shell Open

Using `termux-services` (runit supervisor), services are started automatically in the background whenever you open a Termux session.

```bash
# Enable Tailscale, native SSH daemon, and Wake Lock
sv-enable tailscaled
sv-enable sshd
sv-enable wake-lock

# Or for proot-distro SSH mode:
sv-enable tailscaled
sv-enable proot-sshd
sv-enable wake-lock

# Check status of the services
sv status tailscaled sshd wake-lock
```

### 2 — Auto-Start on Phone Restart (Termux:Boot)

To make your server survive phone restarts without manually opening Termux:

1. Enable the services via `termux-services` as described above (or let the setup script do it).
2. Install the **Termux:Boot** application from F-Droid or GitHub.
3. Open the **Termux:Boot** application once to register it with the OS.
4. The setup script creates a boot script at `~/.termux/boot/start-tailscale-ssh` which:
   - Acquires a wake lock (`termux-wake-lock`) to keep the CPU awake.
   - Starts the `service-daemon` which brings up all enabled services.

---

## Command Reference

| Command | Device | Description |
| :--- | :---: | :--- |
| `tailscaled-start` | Both | Start Tailscale daemon |
| `tailscaled-stop` | Both | Stop Tailscale daemon |
| `tailscale-cli up --hostname=NAME` | Both | Authenticate and join Tailnet |
| `tailscale-cli status` | Both | Show all Tailnet devices |
| `tailscale-cli ip -4` | Both | Show this device's Tailscale IPv4 |
| `tailscale-cli down` | Both | Disconnect from Tailnet |
| `tailscaled-log` | Both | Follow daemon logs |
| `termux-sshd-start` | Server | Start sshd in Termux |
| `proot-sshd-start` | Server | Start sshd inside proot-distro |
| `ts-servers` | Client | Server registry manager |
| `ts-connect` | Client | SSH + tmux connection helper |
| `ts-sessions` | Client | Remote tmux session manager |
| `eval $(tailscale-proxy-env)` | Client | Set SOCKS5 proxy env vars |
| `tailscaled-start --service=on` | Both | Enable via termux-services |

---

## Troubleshooting

**`tailscale-cli status` says "failed to connect"**
```bash
ls -la ~/.tailscale/tailscaled.sock   # Check socket exists
sleep 3 && tailscale-cli status       # Daemon may still be initialising
cat ~/.tailscale/tailscaled.log       # Check logs
```

**Cannot SSH into server**
```bash
tailscale-cli status                              # Verify both devices are online
pgrep -f "sshd -D"                               # Confirm sshd is running on server
nc -z -w5 <server-tailscale-ip> 8022 && echo ok  # Test port reachability
tailscaled-stop; tailscaled-start; termux-sshd-start  # Restart everything
```

**Auth URL expired**
```bash
tailscale-cli down && tailscale-cli up --hostname=my-device
```

**Connection slow or dropping**
```bash
tailscale-cli netcheck                     # Check DERP relay latency
tailscale-cli ping <other-device-ip>       # Test direct path
```

**SOCKS5 port changes every restart**
```bash
echo "TS_SOCKS5_PORT=1055" > ~/.tailscale/.env
tailscaled-stop; tailscaled-start
```

---

## File Locations

| Path | Purpose |
| :--- | :--- |
| `~/.tailscale/tailscaled.sock` | Daemon control socket |
| `~/.tailscale/tailscaled.log` | Daemon logs |
| `~/.tailscale/tailscaled.state` | Auth state |
| `~/.tailscale/socks_addr` | Current SOCKS5 address |
| `~/.tailscale/.env` | Custom env vars (e.g. `TS_SOCKS5_PORT`) |
| `~/.tailscale/servers.conf` | Server registry (client) |
| `~/.tailscale/proot-sshd.log` | proot sshd logs (server) |
| `~/.tailscale/termux-sshd.log` | Termux sshd logs (server) |
| `$PREFIX/bin/tailscale-cli` | Tailscale CLI wrapper |
| `$PREFIX/bin/tailscaled-start` | Daemon start helper |
| `$PREFIX/bin/ts-servers` | Registry manager (client) |
| `$PREFIX/bin/ts-connect` | Connector with tmux (client) |
| `$PREFIX/bin/ts-sessions` | Session manager (client) |
| `$PREFIX/bin/tailscale-proxy-env` | Proxy env printer (client) |
| `~/.tmux.conf` | Optimised tmux config (server) |

---

## Credits

Uses the community Tailscale package for Termux by [bropines/tailscale-termux-cli](https://github.com/bropines/tailscale-termux-cli), which patches Tailscale for Android's Netlink limitations and enables rootless userspace networking.
