# Tailscale in Termux — Complete Setup & Usage Guide

## Architecture Overview

```
Servers (phone-a, laptop, rpi...)     Android B (Client — this phone)
┌──────────────────────────────┐      ┌──────────────────────────────┐
│  Termux / Linux              │      │  Termux                      │
│  ├─ tailscaled (userspace)   │      │  ├─ tailscaled (userspace)   │
│  │  └─ SOCKS5: :1055         │◄────►│  │  └─ SOCKS5: :1055        │
│  ├─ sshd (Termux or proot)   │      │  ├─ ts-connect (SSH helper)  │
│  └─ tmux (session host)      │      │  ├─ ts-servers (registry)    │
└──────────────────────────────┘      │  └─ ts-sessions (manager)    │
         ↕ Tailnet (WireGuard mesh)   └──────────────────────────────┘
  100.x.x.x              100.y.y.y
```

**What you get:**
- Secure SSH from Android B into any registered server over the Tailnet.
- Seamless persistent terminal sessions with tmux (stay connected or reconnect without losing progress).
- Unified local management of all your server devices and active tmux sessions.

---

## ⚡ Quick Start — Using the Setup Scripts

> [!IMPORTANT]
> All devices must use the **same Tailscale account**. Create a free account at [tailscale.com](https://tailscale.com) before starting.

### Step 1: On the Server Device(s) (e.g. Android A, Laptop, etc.)
Copy `tailscale_server_setup.sh` to the server device and run it. You can define a custom hostname via the `HOSTNAME` environment variable:
```bash
# Example: naming this device "phone-a"
HOSTNAME=phone-a bash tailscale_server_setup.sh

# The script will install Tailscale, tmux, configure SSH, and print setup details.
# Start the SSH daemon:
termux-sshd-start   # If using Termux native SSH (default)
# OR
proot-sshd-start    # If using proot SSH
```

### Step 2: On Android B (this phone, client)
Run the client setup script to initialize the registry and install the management tools (`ts-servers`, `ts-connect`, `ts-sessions`):
```bash
bash ~/3/tailscale_client_setup.sh
```

### Step 3: Register the Server on Android B
Register the new server on your client device using the short name you prefer, the Tailscale hostname you defined in Step 1, the remote username, and port:
```bash
# Usage: ts-servers add <short_name> <tailscale_hostname> <user> <port>
# Example:
ts-servers add phone-a phone-a u0_a162 8022

# Verify connectivity:
ts-servers test phone-a
```

### Step 4: Daily Use (Connecting & Session Management)
Once registered, connect or list sessions from your client device easily:
```bash
# Connect using interactive menu (choose server and session):
ts-connect

# Directly connect to 'phone-a' with interactive session picker:
ts-connect phone-a

# Directly connect to a persistent tmux session 'main' on 'phone-a':
ts-connect phone-a main

# Check active tmux sessions across all registered servers:
ts-sessions all
```

---

## 📖 Manual Installation — Step by Step

### Prerequisites on Both Devices
- Termux installed from **F-Droid** or GitHub (NOT Google Play)
- Internet connection
- A Tailscale account (free at tailscale.com)

---

### Part 1: Android A — Install Tailscale in Termux

**1.1 Update packages and install dependencies:**
```bash
pkg update -y
pkg install curl wget grep dpkg -y
```

**1.2 Download and install the community `.deb` package:**
```bash
# Fetch the latest release tag
REPO="bropines/tailscale-termux-cli"
LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -Po '"tag_name": "\K.*?(?=")')
echo "Latest: $LATEST_TAG"

# Detect architecture (aarch64 for most modern Android phones)
ARCH=$(uname -m)   # e.g. aarch64

# Build download URL
DEB_VERSION=$(echo "$LATEST_TAG" | sed 's/^v//' | tr '-' '.')
DEB_FILE="tailscale-termux_${DEB_VERSION}_${ARCH}.deb"
DEB_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$DEB_FILE"

# Download
wget -O /tmp/$DEB_FILE "$DEB_URL"

# Install
dpkg -i /tmp/$DEB_FILE
```

**1.3 Install missing dependencies if dpkg reports them:**
```bash
apt --fix-broken install -y
```

**1.4 Fix script shebangs (required for Termux):**
```bash
termux-fix-shebang \
  $PREFIX/bin/tailscale-cli \
  $PREFIX/bin/tailscale-test \
  $PREFIX/bin/tailscale-update \
  $PREFIX/bin/tailscaled-log \
  $PREFIX/bin/tailscaled-start \
  $PREFIX/bin/tailscaled-stop
```

**1.5 Fix a fixed SOCKS5 port (optional but recommended):**
```bash
mkdir -p ~/.tailscale
echo "TS_SOCKS5_PORT=1055" > ~/.tailscale/.env
```

**1.6 Start the Tailscale daemon:**
```bash
tailscaled-start
# Output: "Done. SOCKS5 address: 127.0.0.1:1055"
```

**1.7 Authenticate to your Tailnet:**
```bash
tailscale-cli up --hostname=android-a-server
# This prints a URL — open it in a browser, log into your Tailscale account,
# and click Authorize Device.
```

**1.8 Confirm your Tailscale IP:**
```bash
tailscale-cli ip -4
# Example output: 100.80.10.5
```

---

### Part 2: Android A — Set Up SSH Server

> [!TIP]
> **Two SSH modes are available.** Choose one based on your needs:
> - **Termux mode (default, recommended)** — SSH runs directly in Termux. No proot-distro needed. Simpler and more stable.
> - **proot-distro mode (optional)** — SSH runs inside a Linux container. Use this if you need a full Linux environment (systemd services, apt packages, etc.).

#### Mode A: Termux SSH (Default — no proot-distro needed)

**2.1 Install openssh in Termux:**
```bash
pkg install openssh -y
```

**2.2 Generate SSH host keys:**
```bash
ssh-keygen -A
```

**2.3 Configure sshd:**
```bash
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
```

**2.4 Set your Termux user password:**
```bash
passwd
```

**2.5 Start sshd:**
```bash
# Start in background:
nohup sshd -D -p 8022 >> ~/.tailscale/termux-sshd.log 2>&1 &

# Verify:
pgrep -f sshd && echo "sshd running" || echo "sshd failed"
```

> [!NOTE]
> After running the setup script, a helper command `termux-sshd-start` is created that wraps all of this into one command.

---

#### Mode B: proot-distro SSH (Optional — requires proot-distro)

**2B.1 Install proot-distro and a Linux container (if not done already):**
```bash
pkg install proot-distro -y
proot-distro install ubuntu   # or debian, fedora
```

**2B.2 Login and install openssh-server:**
```bash
proot-distro login ubuntu
apt-get update && apt-get install -y openssh-server
```

**2B.3 Generate SSH host keys:**
```bash
# Inside proot-distro:
mkdir -p /etc/ssh /run/sshd
ssh-keygen -A
```

**2B.4 Configure sshd:**
```bash
# Inside proot-distro:
cat > /etc/ssh/sshd_config << 'EOF'
Port 2222
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding no
PrintMotd no
AllowTcpForwarding yes
GatewayPorts yes
EOF
```

**2B.5 Set a root password:**
```bash
# Inside proot-distro:
passwd root
exit
```

**2B.6 Start sshd from Termux:**
```bash
nohup proot-distro login ubuntu -- /usr/sbin/sshd -D -p 2222 \
  >> ~/.tailscale/proot-sshd.log 2>&1 &
pgrep -f "sshd -D" && echo "sshd running" || echo "failed"
```

> [!NOTE]
> After running the setup script with `SSH_MODE=proot`, the helper command `proot-sshd-start` is created.

---

### Part 3: Android B — Install & Configure Tailscale

**3.1 Follow the same steps 1.1–1.7 from Part 1**, but use `--hostname=android-b-client`:
```bash
tailscale-cli up --hostname=android-b-client
```

**3.2 Verify both devices are in the same Tailnet:**
```bash
tailscale-cli status
# You should see both android-a-server and android-b-client listed
# Example:
# android-a-server  100.80.10.5    linux   -
# android-b-client  100.80.10.8    android -
```

---

## 🔌 SSH Connection Examples

### Basic SSH (from Android B to Android A)
```bash
# Termux SSH mode (default, port 8022):
ssh -p 8022 <termux-username>@100.80.10.5

# proot-distro SSH mode (port 2222, user: root):
ssh -p 2222 root@100.80.10.5
```

### Using the ts-connect helper (Android B)
```bash
# Connect using the interactive server and tmux session picker:
ts-connect

# Connect to a specific server by name:
ts-connect phone-a

# Connect to phone-a and directly attach to session 'work':
ts-connect phone-a work
```

### SSH with a specific key (recommended over password)
```bash
# On Android B: generate a key if you don't have one
ssh-keygen -t ed25519 -C "android-b"

# Copy public key to Android A's proot-distro
ssh-copy-id -p 2222 root@100.80.10.5

# Now connect without a password:
ssh -p 2222 root@100.80.10.5
```

### Copy files between devices with scp
```bash
# Upload a file from Android B to Android A's proot-distro:
scp -P 2222 ~/myfile.txt root@100.80.10.5:/root/

# Download a file from Android A:
scp -P 2222 root@100.80.10.5:/root/data.tar.gz ~/downloads/
```

### Use rsync for directory sync
```bash
# Sync a local directory to Android A:
rsync -avz -e "ssh -p 2222" ~/projects/ root@100.80.10.5:/root/projects/

# Pull a directory from Android A:
rsync -avz -e "ssh -p 2222" root@100.80.10.5:/root/projects/ ~/sync/
```

---

## 🟢 tmux Session Persistence (Highly Recommended)

Android aggressively manages memory and kills background processes, which can terminate active SSH sessions. When combined with Tailscale SOCKS5 userspace drops or momentary sleep disconnects, a standard SSH connection can easily die, losing any active running tasks.

**tmux (Terminal Multiplexer)** solves this by keeping your shell sessions running on the server (Android A) even if you disconnect.

### Quick Start with tmux
Our helper script makes connecting to a persistent session extremely simple:
```bash
# 1. Connect using the interactive server/session picker:
ts-connect

# 2. Or connect straight to a server (e.g., 'phone-a') and attach to session 'main':
ts-connect phone-a main
```

If the connection is ever lost, just run the command again. You will resume exactly where you left off.

### Essential tmux Keybindings
All tmux commands begin with a **prefix shortcut**, which defaults to `Ctrl-b`. Press `Ctrl-b`, release it, then press one of the following keys:

| Command | Action | Description |
| :--- | :--- | :--- |
| **`Ctrl-b` then `d`** | **Detach** | Leave tmux running in the background and return to the normal terminal. |
| **`Ctrl-b` then `c`** | **New Window** | Create a new shell window inside the same session. |
| **`Ctrl-b` then `n`** | **Next Window** | Cycle to the next window. |
| **`Ctrl-b` then `p`** | **Prev Window** | Cycle to the previous window. |
| **`Ctrl-b` then `0–9`** | **Go to Window** | Switch directly to window index `0–9`. |
| **`Ctrl-b` then `"`** | **Split Horizontal**| Split the current pane into top and bottom panes. |
| **`Ctrl-b` then `%`** | **Split Vertical** | Split the current pane into left and right panes. |
| **`Ctrl-b` then `Arrow`**| **Move Focus** | Navigate between active panes. |
| **`Ctrl-b` then `[`** | **Scroll Mode** | Enable scrollback history. Use arrow keys/PageUp. Press `q` to exit. |

> [!TIP]
> **Mouse mode is enabled by default** via the setup script config. You can click on panes to select them, scroll through history directly using your screen or mouse wheel, and drag pane borders to resize them!

### Manual tmux Commands (No Helpers)
If you are connecting without the helper scripts:
```bash
# Connect and run tmux session check/create:
ssh -t -p 8022 u0_a162@100.80.10.5 "tmux attach-session -t main || tmux new-session -s main"
```
*(Note the `-t` flag in the `ssh` command: this is critical to force pseudo-TTY allocation required by tmux).*

### tmux Configuration Details
The setup script configures an optimized `~/.tmux.conf` on the server (both in native Termux and inside the `/root/` directory of the proot container):
* **`history-limit 10000`**: Increases the scrollback history buffer from the default 2000 lines.
* **`mouse on`**: Enables terminal mouse/scroll actions.
* **`aggressive-resize on`**: Dynamically resizes windows based on the size of the active client, rather than constraining it to the smallest client ever connected.
* **`renumber-windows on`**: Auto-compacts window numbers (0, 1, 2...) when a window is closed.
* **Sleek dark-mode status bar** showing the active session name on the left and date/time on the right.

---

## 🗂️ Multi-Server Registry & Management

You can configure and manage multiple server devices (e.g., several Android phones, laptops, or Raspberry Pis) from your client device (Android B). The client uses a registry file to look up usernames, ports, and hostnames automatically.

### 1. Server Registry Configuration
All registered servers are stored in the pipe-delimited flat file `~/.tailscale/servers.conf`:
```ini
# Format: name|tailscale_hostname|ssh_user|ssh_port
phone-a|phone-a|u0_a162|8022
laptop|my-laptop|user|22
rpi|raspberrypi|pi|22
```
* **name**: The short alias you use in commands (e.g., `phone-a`).
* **tailscale_hostname**: The device hostname defined during `tailscale_server_setup.sh` (which it registers on the Tailnet).
* **ssh_user**: The SSH login user (e.g., `u0_a162` on native Termux, `root` in proot, or standard users on other OS).
* **ssh_port**: The SSH listening port (e.g., `8022` or `22`).

---

### 2. Registry Management (`ts-servers`)
Use `ts-servers` to add, remove, and list servers from the registry:

* **List registered servers**:
  ```bash
  ts-servers list
  ```
* **Register a new server**:
  ```bash
  ts-servers add phone-b phone-b-server u0_a201 8022
  ```
* **Remove a registered server**:
  ```bash
  ts-servers remove phone-b
  ```
* **Test server connectivity**:
  ```bash
  ts-servers test          # Test all registered servers
  ts-servers test phone-a  # Test a specific server
  ```

---

### 3. Connecting to Servers (`ts-connect`)
`ts-connect` is your unified portal to connect to any registered server. It automatically handles SOCKS5 proxy routing, Tailscale IP resolution, and tmux session attachment.

* **Interactive picker mode** (highly recommended for mobile screens):
  ```bash
  ts-connect
  ```
  *This opens a menu listing all registered servers. Once you select one, it lists the active remote tmux sessions (or lets you create a new one/connect with plain SSH) via single keypress selectors.*

* **Quick-connect to server with session picker**:
  ```bash
  ts-connect phone-a
  ```
* **Direct connection to a specific session (attaches or creates)**:
  ```bash
  ts-connect phone-a main
  ```
* **Force create a new tmux session**:
  ```bash
  ts-connect phone-a --new work
  ```
* **Connect with a plain SSH session (no tmux)**:
  ```bash
  ts-connect phone-a --plain
  ```

---

### 4. Remote Session Management (`ts-sessions`)
Manage remote tmux sessions across any of your servers without connecting to them:

* **List sessions on a specific server**:
  ```bash
  ts-sessions phone-a
  ```
* **List sessions across ALL registered servers**:
  ```bash
  ts-sessions all
  ```
* **Kill a remote session**:
  ```bash
  ts-sessions phone-a kill work
  ```

---

## 🌐 SOCKS5 Proxy Usage (Android B)

Because Tailscale runs in userspace mode, it does not create a system-wide VPN.
Instead it exposes a local SOCKS5 proxy. Route any CLI tool through it:

### Export proxy for the current session
```bash
# Use the helper (Android B):
eval $(tailscale-proxy-env)
# This sets ALL_PROXY, HTTP_PROXY, HTTPS_PROXY to socks5://127.0.0.1:1055

# Now all supported tools route through Tailscale automatically:
curl https://myserver.example.com
git clone https://internal-repo.example.com/repo.git
```

### Use the proxy for a single command
```bash
# Read the SOCKS5 address (port changes each run unless .env is set):
PROXY=$(cat ~/.tailscale/socks_addr)

# curl through Tailscale:
curl --socks5-hostname "$PROXY" http://100.80.10.5:8080

# wget through Tailscale:
wget -e "use_proxy=yes" -e "socks_proxy=socks5://$PROXY" http://100.80.10.5/file
```

### SSH through the SOCKS5 proxy (if nc/ncat is available)
```bash
PROXY_ADDR=$(cat ~/.tailscale/socks_addr)
PROXY_HOST=${PROXY_ADDR%:*}
PROXY_PORT=${PROXY_ADDR#*:}

ssh -p 2222 \
    -o "ProxyCommand=nc -X 5 -x $PROXY_HOST:$PROXY_PORT %h %p" \
    root@100.80.10.5
```

---

## 🔁 Port Forwarding Examples

### Forward a remote port to your local machine (Android B)
```bash
# Access Android A's proot web server (port 80) locally at port 8080:
ssh -p 2222 -L 8080:localhost:80 root@100.80.10.5
# Then open http://localhost:8080 on Android B
```

### Expose Android B's local port on Android A (reverse tunnel)
```bash
# From Android B, expose Android B's local port 3000 to Android A:
ssh -p 2222 -R 9090:localhost:3000 root@100.80.10.5
# Now Android A can curl http://localhost:9090 to reach Android B:3000
```

### Persistent background tunnel
```bash
# Keep a tunnel alive in the background:
ssh -p 2222 -N -f -L 5432:localhost:5432 root@100.80.10.5
# Access Android A's PostgreSQL (or any port-5432 service) locally
```

---

## 🔄 Auto-Start and Persistence

### Start Tailscale automatically on Termux launch (both devices)
```bash
# Add to ~/.bashrc or ~/.bash_profile:
echo 'if ! pgrep -f "tailscaled.*statedir" > /dev/null 2>&1; then tailscaled-start > /dev/null 2>&1; fi' >> ~/.bashrc
```

### Auto-start proot SSH on Android A
```bash
# Add to ~/.bashrc on Android A after the Tailscale line:
echo 'if ! pgrep -f "sshd -D" > /dev/null 2>&1; then proot-sshd-start > /dev/null 2>&1; fi' >> ~/.bashrc
```

### Using termux-services for full service management
```bash
# Enable Tailscale as a persistent termux service (both devices):
tailscaled-start --service=on

# Check service status:
tailscaled-start --service=status

# Disable:
tailscaled-start --service=off
```

> [!NOTE]
> termux-services uses runit under the hood and requires `runsvdir` to be
> running. This is started automatically when a new Termux session opens if
> `termux-services` is installed. Keep at least one Termux session open.

---

## 📋 Command Reference

| Command | Device | Description |
| :--- | :---: | :--- |
| `tailscaled-start` | Both | Start Tailscale daemon in background |
| `tailscaled-stop` | Both | Stop Tailscale daemon |
| `tailscale-cli up --hostname=NAME` | Both | Authenticate and join Tailnet |
| `tailscale-cli status` | Both | Show all Tailnet devices |
| `tailscale-cli ip -4` | Both | Show this device's Tailscale IPv4 |
| `tailscale-cli down` | Both | Disconnect from Tailnet |
| `tailscaled-log` | Both | Follow daemon logs |
| `termux-sshd-start` | Server | Start sshd directly in Termux (default) |
| `proot-sshd-start` | Server | Start sshd inside proot-distro (optional) |
| `ts-servers` | Client | Manage server registry (list, add, remove, test) |
| `ts-connect` | Client | Unified SSH + tmux connection helper (interactive or direct) |
| `ts-sessions` | Client | Remote tmux session manager (list, kill) |
| `ssh-to-server` | Client | *[Deprecated]* Quick SSH helper (delegates to `ts-connect`) |
| `ssh-to-server-tmux` | Client | *[Deprecated]* Quick SSH with tmux (delegates to `ts-connect --tmux`) |
| `eval $(tailscale-proxy-env)` | Client | Set SOCKS5 proxy env variables |
| `tailscaled-start --service=on` | Both | Enable auto-start via termux-services |

---

## 🔧 Troubleshooting

### tailscaled starts but `tailscale-cli status` says "failed to connect"
```bash
# Check if the socket file exists:
ls -la ~/.tailscale/tailscaled.sock

# Wait a few more seconds, then retry — the daemon may still be initializing:
sleep 3 && tailscale-cli status

# Check logs for errors:
cat ~/.tailscale/tailscaled.log
```

### Cannot SSH into Android A from Android B
```bash
# 1. Verify Tailscale status on both devices:
tailscale-cli status   # run on each device

# 2. Verify sshd is running on Android A:
pgrep -f "sshd -D"

# 3. Test port reachability from Android B:
nc -z -w5 <android-a-tailscale-ip> 2222 && echo "reachable" || echo "blocked"

# 4. Check proot sshd logs on Android A:
cat ~/.tailscale/proot-sshd.log

# 5. Restart everything on Android A:
tailscaled-stop; tailscaled-start; proot-sshd-start
```

### Authentication URL not working
```bash
# The URL expires in ~10 minutes. Re-run:
tailscale-cli up --hostname=android-a-server

# If it gives "already connected", just disconnect and reconnect:
tailscale-cli down
tailscale-cli up --hostname=android-a-server
```

### Connection is slow or drops frequently
```bash
# Check which relay (DERP) server is being used:
tailscale-cli netcheck

# Force a direct connection attempt:
tailscale-cli ping <other-device-tailscale-ip>
```

### SOCKS5 port changes every restart
```bash
# Fix it permanently by setting TS_SOCKS5_PORT in the env file:
echo "TS_SOCKS5_PORT=1055" > ~/.tailscale/.env
# Then restart:
tailscaled-stop; tailscaled-start
```

---

## 📁 File Locations Reference

| File | Purpose |
| :--- | :--- |
| `~/.tailscale/tailscaled.sock` | Daemon control socket |
| `~/.tailscale/tailscaled.log` | Daemon logs |
| `~/.tailscale/tailscaled.state` | Tailscale state (auth token, etc.) |
| `~/.tailscale/socks_addr` | Current SOCKS5 address (e.g. 127.0.0.1:1055) |
| `~/.tailscale/.env` | Custom env vars (e.g. TS_SOCKS5_PORT) |
| `~/.tailscale/servers.conf` | Server registry flat file (Client) |
| `~/.tailscale/proot-sshd.log` | proot sshd logs (Server) |
| `$PREFIX/bin/tailscale-cli` | tailscale CLI wrapper |
| `$PREFIX/bin/tailscaled-start` | daemon start helper |
| `$PREFIX/bin/proot-sshd-start` | proot SSH launcher (Server) |
| `$PREFIX/bin/ts-servers` | Server registry manager command (Client) |
| `$PREFIX/bin/ts-connect` | Unified connector with tmux integration command (Client) |
| `$PREFIX/bin/ts-sessions` | Remote tmux session manager command (Client) |
| `$PREFIX/bin/ssh-to-server` | *[Deprecated]* quick SSH helper (Client) |
| `$PREFIX/bin/ssh-to-server-tmux` | *[Deprecated]* quick SSH helper with auto-attached tmux (Client) |
| `$PREFIX/bin/tailscale-proxy-env` | proxy env printer (Client) |
| `~/.tmux.conf` / `/root/.tmux.conf` | Optimized tmux configuration (Server) |
