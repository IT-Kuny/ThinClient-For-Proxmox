# ThinClient for Proxmox

A kiosk-style thin client that boots into a Proxmox VM via SPICE. Designed for home labs, small offices, or any setup where a cheap node should become a terminal for Proxmox-hosted desktops.

Multi-user safe, supports multiple VMs, optional SSO via Proxmox credentials.

---

## Features

- **Interactive login** — no hardcoded credentials, OOBE on first launch
- **VM picker** — shows all VMs the user has permissions for, with SPICE/status columns
- **Offline node toggle** — hide/show VMs on offline Proxmox nodes
- **Real boot phases** — 6-phase wait with accurate status (VM running → guest agent → Xorg → LightDM → greeter/session)
- **Kiosk ads** — background browser shows rotating slides generated from your GitHub org's READMEs
- **Multi-user** — default mode shows VM login screen; each user authenticates locally
- **Optional autologin** — `AUTO_VM_LOGIN=1` injects Proxmox-mapped credentials via guest agent
- **Session integration** — GDM/LightDM/SDDM `.desktop` entry
- **Post-session menu** — connect another VM or logout
- **Distro-aware installer** — auto-detects dnf/apt/yum/pacman/zypper

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│ ThinClient Node (Herista, kiosk)                           │
│                                                            │
│   ┌──────────────────────────────────────────────────┐     │
│   │ openbox (WM)                                     │     │
│   │                                                  │     │
│   │   ┌────────────────────────────────────────┐     │     │
│   │   │ chromium --start-fullscreen            │     │     │
│   │   │   file:///var/lib/thinclient/ads/      │     │     │
│   │   │          index.html                    │     │     │
│   │   │   (layer=below, IT-Kuny READMEs)       │     │     │
│   │   └────────────────────────────────────────┘     │     │
│   │                                                  │     │
│   │   ┌────────────────────────────────────────┐     │     │
│   │   │ zenity dialogs (layer=above)           │     │     │
│   │   │   - VM picker                          │     │     │
│   │   │   - Progress bar (phase text)          │     │     │
│   │   │   - Post-session menu                  │     │     │
│   │   └────────────────────────────────────────┘     │     │
│   └──────────────────────────────────────────────────┘     │
│                                                            │
│   thinclient-gui (bash) ── Proxmox API ──┐                 │
│       ↓                                   │                 │
│   remote-viewer (SPICE) ──────────────────┘                 │
└────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────────┐
│ Proxmox Host                                               │
│   VM 300 (LXDE + LightDM + pam_proxmox)                    │
│   VM 301, 302, ...                                         │
└────────────────────────────────────────────────────────────┘
```

---

## Installation

### ThinClient Node

Requirements: fresh Debian/Fedora/Arch install with Xorg + a display manager (GDM/LightDM/SDDM).

```bash
git clone https://github.com/IT-Kuny/ThinClient-For-Proxmox.git
cd ThinClient-For-Proxmox
sudo ./install.sh
```

The installer:
1. Copies scripts to `/usr/local/bin/`
2. Installs session entry to `/usr/share/xsessions/`
3. Installs openbox config with window-layer rules
4. Installs dependencies (zenity, openbox, curl, chromium, wmctrl, python3)
5. Generates ad page from GitHub org READMEs → `/var/lib/thinclient/ads/index.html`

Log out, select **"Proxmox Thin Client"** at the display manager. First login shows OOBE setup.

### Client VM

For manual login mode (default), no special setup on the VM — just install LXDE/XFCE/GNOME + a display manager.

For SSO mode (`AUTO_VM_LOGIN=1`), install [pam_proxmox](https://github.com/IT-Kuny/pam-proxmox) on the VM:

```bash
git clone https://github.com/IT-Kuny/pam-proxmox.git
cd pam-proxmox
make
sudo ./setup-vm.sh   # purges light-locker, installs PAM module, wires lightdm
```

Configure `/etc/security/pam_proxmox.conf`:
```
host=10.64.0.200
port=8006
realm=pam
verify_ssl=0
force_user=root
map_hx=root       # map local user "hx" → Proxmox user "root"
```

---

## Usage

### First login (OOBE)

1. Select "Proxmox Thin Client" at display manager
2. Fullscreen xterm asks: Proxmox host, username, password
3. Lists available VMs (verifies permissions)
4. Optional: save credentials for next boot
5. Optional: enable VM autologin via Proxmox mapping

### Subsequent logins

- If `AUTO_RECONNECT=1` + `DEFAULT_VMID=300` set → boots directly into VM 300
- Otherwise: VM picker shows

### Connect to a VM

1. Select VM from list
2. If VM is offline → starts automatically, phases show in progress bar
3. Ads browser runs in background the whole time
4. SPICE opens when ready:
  - `AUTO_VM_LOGIN=0` → VM login screen
  - `AUTO_VM_LOGIN=1` → VM desktop (injected credentials auto-logged-in)

### Post-session

After SPICE closes:
- "Connect another VM" → back to VM picker
- "Logout" → return to display manager

---

## Configuration

### `~/.thinclient_creds`

```bash
PROXY="10.64.0.200"
USERNAME="root@pam"
PASSWORD="***"
DEFAULT_VMID=300        # optional, used with AUTO_RECONNECT
AUTO_RECONNECT=0        # 1 = skip VM picker, connect default VM
AUTO_VM_LOGIN=0         # 1 = inject credentials for VM autologin
```

### `/etc/thinclient/ads.conf`

```bash
org=IT-Kuny                  # GitHub org to fetch READMEs from
rotate_interval=10           # seconds per slide
include_forked=false         # show forked repos
include_archived=false       # show archived repos
# github_token=ghp_xxx       # optional, raises rate limit to 5000/h
# repos=/path/to/local/repo  # optional, adds local repos to rotation
```

Regenerate ads:
```bash
sudo thinclient-ads-build
```

### VM User Configs (for `AUTO_VM_LOGIN=1`)

```bash
thinclient-users add           # create new VM user config
thinclient-users list          # show all configs
thinclient-users set-default   # mark one as default
thinclient-users delete        # remove
```

Files stored in `~/.thinclient_vm_users/<name>.conf` (chmod 600).

---

## Boot Phases

When a VM needs to be started, ThinClient waits through 6 real phases:

| Phase | %  | Check                                  | Timeout |
|-------|----|----------------------------------------|---------|
| 1     | 5  | `POST /status/start`                   | —       |
| 2     | 15 | VM `status == "running"`               | 60s     |
| 3     | 35 | Guest agent ping                       | 60s     |
| 4     | 55 | `pgrep -x Xorg` via guest-exec         | 45s     |
| 5     | 75 | `systemctl is-active lightdm` (or gdm) | 30s     |
| 6     | 85 | Mode-dependent (see below)             | 30s     |
| Final | 95 | Settle + SPICE proxy fetch             | 2s      |

**Phase 6 mode-dependent:**
- `AUTO_VM_LOGIN=0` → waits for greeter process (`lightdm-gtk-greeter` etc)
- `AUTO_VM_LOGIN=1` → waits for desktop session (`startlxde`, `gnome-session`, etc)

---

## Components

| File                        | Purpose                                              |
|-----------------------------|------------------------------------------------------|
| `thinclient-gui`            | Main bash script (~1100 LOC)                         |
| `thinclient-session`        | X session wrapper (starts openbox + thinclient-gui)  |
| `thinclient-users`          | CLI for VM user configs                              |
| `thinclient-ads-build`      | Python script: GitHub org READMEs → HTML kiosk page  |
| `install.sh`                | Distro-aware installer                               |
| `openbox-rc.xml`            | Window layer rules (browser=below, zenity=above)     |
| `proxmox-thinclient.desktop`| Display manager session entry                        |
| `lxde-logout`               | Triggers VM shutdown via Proxmox API (runs on VM)    |

---

## Multi-User Mode (default)

- No autologin on VMs
- Each user authenticates locally at the VM's login screen
- Proxmox serves purely as a SPICE gatekeeper (ThinClient auth)
- pam_proxmox on the VM enables SSO (user types Proxmox password at greeter)

**Setup:**
1. Create local users on VM: `sudo adduser alice`
2. Optional: install pam_proxmox on VM with `map_alice=<proxmox_user>`
3. On ThinClient: each user has own `~/.thinclient_creds` (via OOBE)

## Autologin Mode (`AUTO_VM_LOGIN=1`)

For single-user convenience. ThinClient injects credentials via QEMU guest agent before SPICE connect.

**Requirements per VM:**
1. `pam_proxmox` installed (with inject file support)
2. `map_<user>` entry in `/etc/security/pam_proxmox.conf`
3. Guest agent running
4. `thinclient-users add` on ThinClient (stores VM user config)

**Inject flow:**
```
ThinClient auth → Proxmox API
  ↓
vm_inject_credentials() via guest-exec
  → writes /var/run/pam-proxmox/inject.conf in VM
  → file self-destructs after 5 minutes
  ↓
SPICE connect → LightDM starts
  ↓
pam_proxmox reads inject.conf → auth success
  ↓
Autologin as mapped user
```

---

## Troubleshooting

### VM shows "connection refused" after boot
- Guest agent not running in VM → `systemctl enable --now qemu-guest-agent`
- SPICE not configured → set `vga=qxl` in Proxmox VM config

### Session locks after 10 minutes
- `light-locker` is running → `sudo apt purge light-locker` (or dnf/pacman equivalent)
- `pam_proxmox` repo's `setup-vm.sh` handles this automatically

### Zenity dialogs hidden behind browser
- Ensure openbox config installed: `sudo install -m644 openbox-rc.xml /etc/xdg/openbox/rc.xml`
- Browser must use `--start-fullscreen`, NOT `--kiosk` (override-redirect bypasses WM)

### Ads page not generating
- Check `/etc/thinclient/ads.conf` exists
- Run manually: `sudo thinclient-ads-build` (shows errors)
- Rate limit? Set `github_token=` in config

### Guest-exec returns "property not defined"
- Make sure request is JSON, not form-data:
  - Content-Type: `application/json`
  - Body: `{"command":["binary","arg1","arg2"]}`

---

## Credits

Based on [KBapna/ThinClient_For_Proxmox](https://github.com/KBapna/ThinClient_For_Proxmox). Rewritten with:
- Multi-user support
- Zenity GUI
- Real boot phase detection
- Kiosk ad system
- Distro-aware installer
- Session integration (GDM/LightDM/SDDM)

## License

MIT
