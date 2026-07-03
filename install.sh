#!/usr/bin/env bash
# ─── ThinClient Installer ────────────────────────────────────────────────────
# Installs the ThinClient system on a Linux host:
#   - thinclient-gui, thinclient-session, thinclient-users → /usr/local/bin/
#   - proxmox-thinclient.desktop → /usr/share/xsessions/
#   - openbox-rc.xml → /etc/xdg/openbox/rc.xml (if openbox present)
#   - Generates /var/lib/thinclient/ads/index.html from project READMEs
#
# Prerequisites (auto-installed if missing):
#   - zenity, openbox, curl, python3, python3-markdown, chromium
#
# Supports: Debian/Ubuntu (apt), Fedora/RHEL (dnf/yum), Arch (pacman), openSUSE (zypper)
#
# Usage: sudo ./install.sh [--no-ads]
# ─────────────────────────────────────────────────────────────────────────────

set -u

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root (sudo)" >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADS_DIR="/var/lib/thinclient/ads"
ADS_INDEX="$ADS_DIR/index.html"
ADS_CONF="/etc/thinclient/ads.conf"

log()  { echo -e "\e[1;34m[install]\e[0m $*"; }
warn() { echo -e "\e[1;33m[warn]\e[0m   $*" >&2; }
err()  { echo -e "\e[1;31m[fail]\e[0m   $*" >&2; }

# ─── 1. Binaries ─────────────────────────────────────────────────────────────
log "installing scripts to /usr/local/bin/"
for f in thinclient-gui thinclient-session thinclient-users thinclient-ads-build; do
    if [[ -f "$HERE/$f" ]]; then
        install -Dm755 "$HERE/$f" "/usr/local/bin/$f"
        log "  $f ✓"
    fi
done

# ─── 2. Session desktop file ─────────────────────────────────────────────────
if [[ -f "$HERE/proxmox-thinclient.desktop" ]]; then
    install -Dm644 "$HERE/proxmox-thinclient.desktop" \
        /usr/share/xsessions/proxmox-thinclient.desktop
    log "session entry ✓"
fi

# ─── 3. openbox rc.xml ───────────────────────────────────────────────────────
if [[ -f "$HERE/openbox-rc.xml" ]] && command -v openbox >/dev/null 2>&1; then
    install -Dm644 "$HERE/openbox-rc.xml" /etc/xdg/openbox/rc.xml
    log "openbox rc.xml ✓"
fi

# ─── 4. Dependencies ────────────────────────────────────────────────────────
log "checking dependencies..."

# Detect package manager
PKG_MGR=""
if   command -v dnf      >/dev/null 2>&1; then PKG_MGR=dnf
elif command -v apt-get  >/dev/null 2>&1; then PKG_MGR=apt-get
elif command -v yum      >/dev/null 2>&1; then PKG_MGR=yum
elif command -v pacman   >/dev/null 2>&1; then PKG_MGR=pacman
elif command -v zypper   >/dev/null 2>&1; then PKG_MGR=zypper
else
    warn "no supported package manager found (dnf/apt/yum/pacman/zypper)"
fi

# Distro-specific package names (Fedora/SUSE differ on some)
if [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" || "$PKG_MGR" == "zypper" ]]; then
    PKG_ZENITY=zenity
    PKG_OPENBOX=openbox
    PKG_CURL=curl
    PKG_PYTHON=python3
    PKG_MD=python3-markdown
    PKG_CHROMIUM=chromium
elif [[ "$PKG_MGR" == "pacman" ]]; then
    PKG_ZENITY=zenity
    PKG_OPENBOX=openbox
    PKG_CURL=curl
    PKG_PYTHON=python
    PKG_MD=python-markdown
    PKG_CHROMIUM=chromium
else
    PKG_ZENITY=zenity
    PKG_OPENBOX=openbox
    PKG_CURL=curl
    PKG_PYTHON=python3
    PKG_MD=python3-markdown
    PKG_CHROMIUM=chromium
fi

# Collect missing deps
declare -a MISSING=()
command -v zenity      >/dev/null 2>&1 || MISSING+=("$PKG_ZENITY")
command -v openbox     >/dev/null 2>&1 || MISSING+=("$PKG_OPENBOX")
command -v curl        >/dev/null 2>&1 || MISSING+=("$PKG_CURL")
command -v python3     >/dev/null 2>&1 || MISSING+=("$PKG_PYTHON")
command -v wmctrl      >/dev/null 2>&1 || MISSING+=("wmctrl")

# Browser: accept chromium, chromium-browser, google-chrome-stable
if ! command -v chromium           >/dev/null 2>&1 && \
   ! command -v chromium-browser   >/dev/null 2>&1 && \
   ! command -v google-chrome-stable >/dev/null 2>&1; then
    MISSING+=("$PKG_CHROMIUM")
fi

# Dedupe + strip empties
MISSING=( $(printf '%s\n' "${MISSING[@]}" | grep -v '^$' | sort -u) )

if [[ ${#MISSING[@]} -gt 0 && -n "$PKG_MGR" ]]; then
    log "installing via $PKG_MGR: ${MISSING[*]}"
    case "$PKG_MGR" in
        apt-get)
            apt-get update -qq
            apt-get install -y -qq "${MISSING[@]}" >/dev/null 2>&1
            ;;
        dnf|yum)
            "$PKG_MGR" install -y -q "${MISSING[@]}" >/dev/null 2>&1
            ;;
        pacman)
            pacman -Sy --noconfirm --needed "${MISSING[@]}" >/dev/null 2>&1
            ;;
        zypper)
            zypper --non-interactive --quiet install "${MISSING[@]}" >/dev/null 2>&1
            ;;
    esac
    rc=$?
    if [[ $rc -eq 0 ]]; then
        log "  deps installed ✓"
    else
        warn "  $PKG_MGR returned exit $rc — check output"
    fi
elif [[ ${#MISSING[@]} -gt 0 ]]; then
    warn "missing: ${MISSING[*]} — install manually"
else
    log "deps already present ✓"
fi

# ─── 5. Ads config + generation ─────────────────────────────────────────────
if [[ "${1:-}" != "--no-ads" ]]; then
    log "setting up project ads..."

    mkdir -p "$ADS_DIR" /etc/thinclient

    # Detect local repos from sibling directories (optional, added on top of GitHub)
    PARENT="$(dirname "$HERE")"
    REPOS=()
    for candidate in "$PARENT/ThinClient-For-Proxmox" "$PARENT/pam-proxmox" \
                     "/home/hx/ThinClient-For-Proxmox" "/home/hx/pam-proxmox"; do
        [[ -d "$candidate" ]] && REPOS+=("$candidate")
    done

    REPO_PATHS=""
    if [[ ${#REPOS[@]} -gt 0 ]]; then
        REPO_PATHS=$(IFS=:; echo "${REPOS[*]}")
    fi

    # Default org: IT-Kuny. All public repos under github.com/IT-Kuny are
    # fetched at build time and rendered as rotating slides.
    cat > "$ADS_CONF" <<EOF
# ThinClient ads configuration
#
# Slides source (pick any combination):
#   org=<github-org>            # fetches all public repos via GitHub API
#   repos=/path/a:/path/b       # additional local repos (optional)
#
# Regenerate after editing: sudo thinclient-ads-build
org=IT-Kuny
repos=$REPO_PATHS
rotate_interval=10
include_forked=false
include_archived=false

# Optional: raise GitHub API rate limit from 60/h to 5000/h
# github_token=ghp_xxx
EOF
    log "  ads.conf written (org=IT-Kuny${REPO_PATHS:+, ${#REPOS[@]} local repo(s)})"

    # Generate the HTML page
    /usr/local/bin/thinclient-ads-build && log "  ads page ✓" || \
        warn "ads build failed — run 'thinclient-ads-build' manually"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
log ""
log "ThinClient install complete."
log ""
log "Next steps:"
log "  1. Log out → select 'Proxmox Thin Client' at the display manager"
log "  2. First login → OOBE setup (Proxmox host, user, password)"
log "  3. To regenerate ads after README changes:"
log "     sudo thinclient-ads-build"
