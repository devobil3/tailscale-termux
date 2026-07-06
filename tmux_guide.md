# 🖥️ tmux — The Complete Beginner's Guide

> **tmux** (Terminal MUltipleXer) lets you run multiple terminal sessions inside a single terminal window — and keep them alive even when you disconnect.

---

## 📦 Installation

| OS / Distro | Command |
|---|---|
| Ubuntu / Debian | `sudo apt install tmux` |
| Arch / Manjaro | `sudo pacman -S tmux` |
| macOS (Homebrew) | `brew install tmux` |
| Termux (Android) | `pkg install tmux` |
| Fedora / RHEL | `sudo dnf install tmux` |

Verify: `tmux -V`

---

## 🧠 Core Concepts

tmux is organized into three layers, like Russian nesting dolls:

```
Server
 └── Session  (a workspace — e.g. "work", "personal")
      └── Window  (like browser tabs)
           └── Pane  (split regions inside a window)
```

| Concept | Think of it as... |
|---|---|
| **Session** | A project or context (survives disconnection!) |
| **Window** | A tab within a session |
| **Pane** | A split within a window |

---

## ⌨️ The Prefix Key

Almost all tmux commands start with a **prefix key**. The default is:

> **`Ctrl + b`**

You press `Ctrl+b`, release both keys, then press the command key.

**Example:** `Ctrl+b` then `%` → splits the window vertically.

> [!TIP]
> Many users remap the prefix to `Ctrl+a` (like GNU Screen). See the [Configuration](#-configuration) section below.

---

## 🚀 Getting Started — Your First Session

```bash
# Start tmux (creates a new unnamed session)
tmux

# Start tmux with a named session
tmux new -s mysession

# Attach to an existing session
tmux attach -t mysession

# List all sessions
tmux ls

# Kill a session
tmux kill-session -t mysession
```

---

## 📋 Essential Keybindings Reference

> All shortcuts below assume you've pressed the prefix `Ctrl+b` first.

### 🗂️ Sessions

| Keys | Action |
|---|---|
| `d` | **Detach** from current session (session keeps running!) |
| `s` | List and switch between sessions (interactive) |
| `$` | Rename current session |
| `:new-session` | Create a new session |

### 🪟 Windows (Tabs)

| Keys | Action |
|---|---|
| `c` | **Create** a new window |
| `w` | List all windows (interactive picker) |
| `n` | Go to **next** window |
| `p` | Go to **previous** window |
| `0–9` | Switch to window by number |
| `,` | **Rename** current window |
| `&` | **Kill** current window (prompts for confirmation) |
| `f` | **Find** window by name |

### ▪️ Panes (Splits)

| Keys | Action |
|---|---|
| `%` | Split **vertically** (side by side) |
| `"` | Split **horizontally** (top and bottom) |
| Arrow keys | **Navigate** between panes |
| `o` | Cycle through panes |
| `z` | **Zoom** (toggle fullscreen for current pane) |
| `x` | **Kill** current pane |
| `{` | Move pane **left** |
| `}` | Move pane **right** |
| `q` | Show pane **numbers** (press number to jump) |
| `!` | Break pane into its own **new window** |
| `Ctrl+Arrow` | **Resize** pane in arrow direction |
| `Space` | Cycle through pane **layout presets** |

### 📜 Copy Mode (Scrollback)

| Keys | Action |
|---|---|
| `[` | **Enter** copy mode (scroll up through history) |
| `q` | **Exit** copy mode |
| Arrow / `PgUp` / `PgDn` | Scroll in copy mode |
| `Space` (vi) | Start selection |
| `Enter` (vi) | Copy selection |
| `]` | **Paste** copied text |

> [!NOTE]
> By default tmux uses emacs-style keys in copy mode. Enable vi-style keys in your config: `set-window-option -g mode-keys vi`

### ⚙️ Miscellaneous

| Keys | Action |
|---|---|
| `?` | Show **all keybindings** (help) |
| `:` | Open tmux **command prompt** |
| `t` | Show a **clock** in current pane |
| `~` | Show tmux **message log** |

---

## ⚙️ Configuration

tmux reads its config from `~/.tmux.conf` on startup.

### Example `~/.tmux.conf`

```bash
# ── Prefix ──────────────────────────────────────────
# Remap prefix from Ctrl+b to Ctrl+a
unbind C-b
set-option -g prefix C-a
bind-key C-a send-prefix

# ── Mouse support ────────────────────────────────────
set -g mouse on

# ── Pane splitting with intuitive keys ──────────────
bind | split-window -h   # Vertical split with |
bind - split-window -v   # Horizontal split with -
unbind '"'
unbind %

# ── Vim-style pane navigation ────────────────────────
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# ── Vi copy mode ─────────────────────────────────────
set-window-option -g mode-keys vi
bind-key -T copy-mode-vi v send-keys -X begin-selection
bind-key -T copy-mode-vi y send-keys -X copy-selection

# ── Appearance ───────────────────────────────────────
set -g default-terminal "screen-256color"

# Status bar colors
set -g status-bg colour235
set -g status-fg colour136

# Window status
set -g window-status-current-style fg=colour166,bold

# ── Start window/pane numbering at 1 ────────────────
set -g base-index 1
set -g pane-base-index 1

# ── Reload config easily ─────────────────────────────
bind r source-file ~/.tmux.conf \; display "Config reloaded!"
```

After saving, reload config without restarting:
```
Ctrl+b :source-file ~/.tmux.conf
```
Or if you added the bind above: `Ctrl+b r`

---

## 🖱️ Mouse Mode

Enable mouse support to:
- Click to select panes
- Scroll through history
- Drag pane borders to resize

```bash
# In ~/.tmux.conf
set -g mouse on
```

---

## 📌 Practical Workflows

### Workflow 1 — Remote Development

```bash
# On remote server: start a named session
tmux new -s dev

# ... do your work ...

# Disconnect (session keeps running on server!)
Ctrl+b d

# Reconnect later
ssh user@server
tmux attach -t dev
```

### Workflow 2 — Multi-pane Dev Setup

```bash
tmux new -s project

# Split into editor + terminal + logs
Ctrl+b %        # vertical split → editor | terminal
Ctrl+b "        # horizontal split → terminal / logs

# Navigate between panes with arrow keys
Ctrl+b ←/→/↑/↓
```

### Workflow 3 — Multiple Projects

```bash
# Project 1
tmux new -s frontend

# Detach, start Project 2
Ctrl+b d
tmux new -s backend

# Switch between projects interactively
tmux attach
Ctrl+b s        # shows session picker
```

---

## 🔌 Plugin Manager (TPM)

[TPM](https://github.com/tmux-plugins/tpm) lets you install tmux plugins easily.

```bash
# Install TPM
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

Add to `~/.tmux.conf`:
```bash
# Plugin manager
set -g @plugin 'tmux-plugins/tpm'

# Popular plugins
set -g @plugin 'tmux-plugins/tmux-sensible'    # Sane defaults
set -g @plugin 'tmux-plugins/tmux-resurrect'   # Save/restore sessions
set -g @plugin 'tmux-plugins/tmux-continuum'   # Auto-save sessions
set -g @plugin 'tmux-plugins/tmux-yank'        # Better clipboard

# Initialize TPM (keep at bottom!)
run '~/.tmux/plugins/tpm/tpm'
```

Install plugins: `Ctrl+b I` (capital i)

---

## 🧩 Useful tmux Commands (Command Line)

```bash
# Session management
tmux new -s NAME           # New named session
tmux attach -t NAME        # Attach to session
tmux ls                    # List sessions
tmux kill-session -t NAME  # Kill session
tmux kill-server           # Kill all sessions

# Rename session/window
tmux rename-session -t old new
tmux rename-window -t session:window newname

# Send a command to a pane
tmux send-keys -t session:window.pane "command" Enter
```

---

## 🆘 Quick Cheat Sheet

```
Prefix = Ctrl+b

SESSIONS          WINDOWS           PANES
─────────         ───────           ─────
d  detach         c  create         %  split right
s  switch         w  list           "  split down
$  rename         ,  rename         o  cycle
                  n  next           z  zoom
                  p  prev           x  kill
                  0-9 switch        q  show numbers
                  &  kill           ←↑↓→ navigate

COPY MODE         MISC
─────────         ────
[  enter          ?  help
q  exit           :  command prompt
]  paste          r  reload (custom)
```

---

## 🎯 Tips & Tricks

1. **Detach and reattach** — Your session keeps running even if you close the terminal. This is tmux's superpower.
2. **Name your sessions** — `tmux new -s myproject` makes it easy to find and reattach later.
3. **Use zoom (`Ctrl+b z`)** — Temporarily maximize any pane, then press again to restore splits.
4. **Nested tmux** — If you SSH into a machine running tmux, press `Ctrl+b Ctrl+b` to send commands to the inner tmux.
5. **Synchronize panes** — Type the same command in all panes at once:
   ```
   :setw synchronize-panes on
   ```
6. **Pipe pane output to a file**:
   ```
   :pipe-pane -o "cat >> ~/output.log"
   ```

---

> [!TIP]
> Press `Ctrl+b ?` at any time inside tmux to see the full list of all active keybindings.

---

*Happy multiplexing! 🚀*
