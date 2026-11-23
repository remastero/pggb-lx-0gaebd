#!/usr/bin/env bash
# Install PGGB for Linux from its kit, as the kit's install notes describe, for the user who runs this script.
#
#   ./install_pggb.sh pggb-linux-<version>.tar.gz           install, then start PGGB as a user service (no screen)
#   ./install_pggb.sh --boot pggb-linux-<version>.tar.gz    the same, and start PGGB at every boot without a login
#   ./install_pggb.sh --window pggb-linux-<version>.tar.gz  install only; start it from the desktop yourself
#   ./install_pggb.sh --remove                              stop PGGB and remove it (your settings are kept)
#
# Run it as your normal user, not as root. sudo is used only for --boot (loginctl enable-linger).
# An existing ~/pggb is moved aside to ~/pggb.old-<date-time>, never deleted. Your settings (~/.config/pggb) and
# data (~/PGGB) are never touched. The PGGB Bridge is set up separately: see the install notes.
set -euo pipefail

APP_DIR="$HOME/pggb"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/pggb.service"
OUT_LOG="$APP_DIR/logs/pggb.out"
ME="${USER:-$(id -un)}"   # the user name, also where USER is not set

say()  { printf '%s\n' "$*"; }
fail() { printf 'Stopped: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

BOOT=0
WINDOW=0
REMOVE=0
KIT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --boot)    BOOT=1 ;;
        --window)  WINDOW=1 ;;
        --remove)  REMOVE=1 ;;
        -h|--help) usage 0 ;;
        -*)        say "Unknown option: $1"; usage 2 ;;
        *)         [ -z "$KIT" ] || fail "give one kit file only"; KIT="$1" ;;
    esac
    shift
done

[ "$(id -u)" -ne 0 ] || fail "run this as your normal user, not as root (PGGB runs as your user)."

have_user_systemd() {
    command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

stop_service() {
    if have_user_systemd && systemctl --user is-active --quiet pggb 2>/dev/null; then
        say "Stopping the running PGGB service..."
        systemctl --user stop pggb
    fi
}

# ---------------------------------------------------------------- remove
if [ "$REMOVE" -eq 1 ]; then
    [ -z "$KIT" ] || fail "--remove takes no kit file."
    stop_service
    if have_user_systemd; then
        systemctl --user disable pggb >/dev/null 2>&1 || true
    fi
    if [ -f "$UNIT" ]; then
        rm -f "$UNIT"
        have_user_systemd && systemctl --user daemon-reload || true
        say "Removed the user service."
    fi
    if [ -d "$APP_DIR" ]; then
        [ -x "$APP_DIR/bin/pggb-launch" ] || fail "$APP_DIR does not look like PGGB's folder (no bin/pggb-launch); left as it is."
        rm -rf "$APP_DIR"
        say "Removed $APP_DIR."
    else
        say "No $APP_DIR to remove."
    fi
    say "Kept: your settings in ~/.config/pggb and PGGB's data in ~/PGGB. Remove them too for a clean start."
    say "If you ran --boot only for PGGB, you can also run: sudo loginctl disable-linger $ME"
    exit 0
fi

# ---------------------------------------------------------------- checks
[ -n "$KIT" ] || { say "Give the kit file (pggb-linux-<version>.tar.gz)."; usage 2; }
[ -f "$KIT" ] || fail "no such file: $KIT"

arch="$(uname -m)"
[ "$arch" = "x86_64" ] || fail "PGGB for Linux needs a 64-bit x86 computer; this one is $arch."

glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')"
[ -n "$glibc" ] || fail "could not read the glibc version (getconf GNU_LIBC_VERSION)."
gmaj="${glibc%%.*}"
gmin="${glibc#*.}"
gmin="${gmin%%.*}"
if [ "$gmaj" -lt 2 ] || { [ "$gmaj" -eq 2 ] && [ "$gmin" -lt 36 ]; }; then
    fail "PGGB for Linux needs glibc 2.36 or newer; this system has $glibc."
fi

if [ "$WINDOW" -eq 0 ] && ! have_user_systemd; then
    fail "systemd's user manager is not reachable (systemctl --user). Log in to this user directly (not with su), or install with --window and start PGGB yourself."
fi

tar -tzf "$KIT" 2>/dev/null | grep -x 'pggb/bin/pggb-launch' >/dev/null \
    || fail "$KIT is not a PGGB for Linux kit (it has no pggb/bin/pggb-launch)."

# ---------------------------------------------------------------- install
stop_service
if [ -e "$APP_DIR" ]; then
    old="$APP_DIR.old-$(date +%Y%m%d-%H%M%S)"
    mv "$APP_DIR" "$old"
    say "Moved the previous $APP_DIR to $old (delete it when you no longer need it)."
fi

say "Unpacking $KIT into $HOME..."
tar -xzf "$KIT" -C "$HOME"
[ -x "$APP_DIR/bin/pggb-launch" ] || fail "the kit unpacked, but $APP_DIR/bin/pggb-launch is missing."
say "PGGB is in $APP_DIR."

if [ "$WINDOW" -eq 1 ]; then
    say ""
    say "Start PGGB from a terminal in your desktop session:  $APP_DIR/bin/pggb-launch --window"
    say "Its output goes to $OUT_LOG."
    exit 0
fi

mkdir -p "$UNIT_DIR"
cp "$APP_DIR/pggb.service" "$UNIT"
systemctl --user daemon-reload
if [ "$BOOT" -eq 1 ]; then
    say "Starting PGGB at every boot needs your user to linger (sudo asks for your password)."
    sudo loginctl enable-linger "$ME"
    systemctl --user enable pggb
fi
systemctl --user restart pggb
say "PGGB is running as a user service."

# The web Remote: PGGB writes its addresses to its log a few seconds after it starts.
addrs=""
for _ in $(seq 1 20); do
    if [ -f "$OUT_LOG" ] && grep -q ':8180/' "$OUT_LOG"; then
        addrs="$(grep -o 'http://[^ ]*:8180/[^ ]*' "$OUT_LOG" | sort -u)"
        break
    fi
    sleep 1
done

say ""
if [ -n "$addrs" ]; then
    say "Open the web Remote in a browser on the same network, at the address for the adapter you use:"
    printf '%s\n' "$addrs" | sed 's/^/  /'
else
    say "Open the web Remote at http://<this computer's address>:8180/ in a browser on the same network."
    say "PGGB writes its addresses to its log a few seconds after it starts:  tail $OUT_LOG"
fi
say "If a firewall runs, allow TCP port 8180 from the local network."
say "A new install starts a 30-day trial; activate on the Remote's License and About page."
say ""
say "Stop:     systemctl --user stop pggb"
say "Start:    systemctl --user start pggb"
say "Remove:   $0 --remove"
if [ "$BOOT" -eq 0 ]; then
    say "To start PGGB at every boot without a login, run this script again with --boot."
fi
