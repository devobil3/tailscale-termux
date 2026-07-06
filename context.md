# Tailscale & SSH Connection Context (Android A ↔ Android B)

This file contains the full context of our current setup to bootstrap a new AI assistant session.

---

## 1. Project Goal
Set up a secure, stable connection from **Android B** (this phone, client) to **Android A** (server phone) over a Tailscale network in Termux, allowing:
* Native Termux SSH access (default, port `8022`) or proot-distro SSH access (optional, port `2222`).
* Network traffic routing using Tailscale's userspace SOCKS5 proxy.
* Persistent shell sessions using **tmux** (so connections don't drop when Android kills background tasks or Tailscale momentarily reconnects).

---

## 2. Environment & Configuration Details
* **Termux Environment**: Both devices run Termux on Android 11+.
* **Tailscale Package**: Installed via `bropines/tailscale-termux-cli` (patched for Android Netlink limitations).
* **Userspace Mode**: Tailscale runs without root using `--tun=userspace-networking` and sets up a SOCKS5 proxy (default: `127.0.0.1:1055` via `~/.tailscale/.env`).
* **Device Profiles**:
  * **Android A (Server)**:
    * Tailscale IP: `100.103.134.45` (hostname: `android-a-server`)
    * Termux Unix User: `u0_a162`
    * SSH Port: `8022`
  * **Android B (Client - This Phone)**:
    * Tailscale IP: `100.89.38.62` (hostname: `android-b-client`)
    * Termux Unix User: `u0_a349`

---

## 3. Files in Active Workspace (`~/3/`)
1. **[tailscale_server_setup.sh](file:///data/data/com.termux/files/home/3/tailscale_server_setup.sh)**: Server setup script. Installs Tailscale and tmux, configures SSH server, and configures an optimized `.tmux.conf` on the server host. Accepts customizable Tailnet hostname via `HOSTNAME` env var.
2. **[tailscale_client_setup.sh](file:///data/data/com.termux/files/home/3/tailscale_client_setup.sh)**: Client setup script. Configures Tailscale on the client, initializes the registry file (`~/.tailscale/servers.conf`), and installs the connection/management commands.
3. **[tailscale_usage_guide.md](file:///data/data/com.termux/files/home/3/tailscale_usage_guide.md)**: Comprehensive setup, manual configuration, and usage guide including sections on tmux session persistence and multi-server management.
4. **[ts-servers](file:///data/data/com.termux/files/home/3/ts-servers)**: Command utility to manage the server registry (list, add, remove, test connectivity).
5. **[ts-connect](file:///data/data/com.termux/files/home/3/ts-connect)**: Unified connector command that resolves IP, sets up SOCKS5 proxy routing, and handles interactive server/tmux session picker or direct session attachment.
6. **[ts-sessions](file:///data/data/com.termux/files/home/3/ts-sessions)**: Utility to query and manage remote tmux sessions across any or all registered servers.

---

## 4. Helper Commands Installed on Android B (Client)
* **`ts-servers`**: Manage registered server profiles (stores data in `~/.tailscale/servers.conf`).
* **`ts-connect`**: Connect to any registered server. Supports interactive menus or direct attachment (`ts-connect <name> [session]`).
* **`ts-sessions`**: Query remote sessions (`ts-sessions <name|all>`) or kill them (`ts-sessions <name> kill <session>`).
* **`tailscale-proxy-env`**: Prints export proxy statements for routing CLI tools through Tailscale's userspace proxy.
* **`ssh-to-server` & `ssh-to-server-tmux`**: Legacy deprecated wrappers delegating to `ts-connect`.

---

## 5. Next Steps / Verification
* **Status**: Multi-server registry and multi-session tmux management have been fully implemented and documented.
* **Verification steps**:
  1. Copy `tailscale_server_setup.sh` to a server, run it (e.g. `HOSTNAME=phone-a bash tailscale_server_setup.sh`), and start the SSH server.
  2. Run `tailscale_client_setup.sh` on Android B.
  3. Register the server: `ts-servers add phone-a phone-a <user> <port>`
  4. Test connectivity: `ts-servers test phone-a`
  5. Connect and manage: Run `ts-connect` and verify interactive server/session lists function correctly.
  6. Query sessions globally: Run `ts-sessions all` to check session state on all registered servers.
