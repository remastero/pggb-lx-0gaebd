#!/usr/bin/env bash
# Install PGGB for Linux from its kit, as the kit's install notes describe, for the user who runs this script.
#
#   ./install_pggb.sh pggb-linux-<version>.tar.gz           install, then start PGGB as a user service (no screen)
#   ./install_pggb.sh --boot pggb-linux-<version>.tar.gz    the same, and start PGGB at every boot without a login
#   ./install_pggb.sh --direct-ethernet pggb-linux-<version>.tar.gz
#                         the same, with Direct Ethernet to PGGB-Audio-Link endpoints (add --boot to start it at boot)
#   ./install_pggb.sh --no-direct-ethernet pggb-linux-<version>.tar.gz
#                         the same, with Direct Ethernet taken away again
#   ./install_pggb.sh --no-bridge pggb-linux-<version>.tar.gz
#                         the same, without setting up the PGGB Bridge (one set up before is left as it is)
#   ./install_pggb.sh --window pggb-linux-<version>.tar.gz  install only; start it from the desktop yourself
#   ./install_pggb.sh --remove                              stop PGGB and remove it and the PGGB Bridge's files
#                                                           (your settings and ALSA's packages are kept)
#
# Run it as your normal user, not as root. sudo asks for your password once, at the start, for what needs it: ALSA's
# tools when they are missing, the PGGB Bridge, the audio group, --boot (loginctl enable-linger) and Direct Ethernet.
# The PGGB Bridge, which takes a player's audio into PGGB-Live, is set up on every install unless --no-bridge is given:
# ALSA's loopback card "PGGBBridge" (loaded now and at every boot), the device "pggb_bridge" for players, and a mark that
# keeps PulseAudio and PipeWire off that card. Running the script again repairs a setup left half done.
# Direct Ethernet is off on a first install, and an update keeps it as it was. With it, PGGB runs as a system service,
# still as your user, with one extra permission: CAP_NET_RAW, which lets it send raw Ethernet frames.
# An existing ~/pggb is moved aside to ~/pggb.old-<date-time>, never deleted. Your settings (~/.config/pggb) and
# data (~/PGGB) are never touched.
# Version 3.1, 23 November 2026.
set -euo pipefail

APP_DIR="$HOME/pggb"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/pggb.service"
SYSTEM_UNIT="${PGGB_SYSTEM_UNIT:-/etc/systemd/system/pggb.service}"   # Direct Ethernet's unit (the variable: for tests)
SYSTEM_MARK="# pggb.service -- written by install_pggb.sh"
OUT_LOG="$APP_DIR/logs/pggb.out"
ME="${USER:-$(id -un)}"   # the user name, also where USER is not set

# The PGGB Bridge's files (the kit's install notes, "PGGB Bridge"). Each starts with BRIDGE_MARK; --remove and a re-run
# touch only files that carry it.
BRIDGE_MARK="# PGGB Bridge -- written by install_pggb.sh"
BR_MODPROBE=/etc/modprobe.d/pggb-bridge.conf
BR_LOAD=/etc/modules-load.d/pggb-bridge.conf
BR_ALIAS=/etc/alsa/conf.d/60-pggb-bridge.conf
BR_ASOUND=/etc/asound.conf   # the alias goes here, between BRIDGE_MARK and BR_END, where ALSA reads no conf.d
BR_END="# end of the PGGB Bridge -- written by install_pggb.sh"
BR_UDEV=/etc/udev/rules.d/89-pggb-bridge.rules

say()  { printf '%s\n' "$*"; }
fail() { printf 'Stopped: %s\n' "$*" >&2; exit 1; }

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit "${1:-0}"
}

BOOT=0
WINDOW=0
REMOVE=0
BRIDGE=1    # 0: --no-bridge
DIRECT=""   # empty: as it was (off on a first install); 1: --direct-ethernet; 0: --no-direct-ethernet
KIT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --boot)    BOOT=1 ;;
        --window)  WINDOW=1 ;;
        --remove)  REMOVE=1 ;;
        --no-bridge) BRIDGE=0 ;;
        --direct-ethernet)    [ "$DIRECT" != 0 ] || fail "give --direct-ethernet or --no-direct-ethernet, not both."; DIRECT=1 ;;
        --no-direct-ethernet) [ "$DIRECT" != 1 ] || fail "give --direct-ethernet or --no-direct-ethernet, not both."; DIRECT=0 ;;
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

# One password prompt for the whole run: sudo -v once, and its timestamp kept fresh until the script ends.
SUDO_KEEP=""
sudo_once() {
    [ -z "$SUDO_KEEP" ] || return 0
    command -v sudo >/dev/null 2>&1 || fail "this needs sudo, which this system does not have: $1."
    say "sudo asks for your password once, for: $1."
    sudo -v || fail "sudo did not accept the password."
    # its own input and output, so that a pipe from this script (| tee) closes when the script ends
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null || exit 0; sleep 50; done ) </dev/null >/dev/null 2>&1 &
    SUDO_KEEP=$!
    trap 'kill "$SUDO_KEEP" 2>/dev/null || true' EXIT
}

# Direct Ethernet is on while this script's system unit is installed. A system unit of that name that this script did
# not write is never touched.
direct_was_on() {
    [ -f "$SYSTEM_UNIT" ] || return 1
    grep -q "^$SYSTEM_MARK" "$SYSTEM_UNIT" \
        || fail "$SYSTEM_UNIT was not written by this script; it is left as it is. Move it away, then run this script again."
}

stop_service() {
    if have_user_systemd && systemctl --user is-active --quiet pggb 2>/dev/null; then
        say "Stopping the running PGGB service..."
        systemctl --user stop pggb
    fi
    if direct_was_on && systemctl is-active --quiet pggb 2>/dev/null; then
        say "Stopping the running PGGB service..."
        sudo systemctl stop pggb
    fi
}

remove_user_unit() {
    if have_user_systemd; then
        systemctl --user disable pggb >/dev/null 2>&1 || true
    fi
    if [ -f "$UNIT" ]; then
        rm -f "$UNIT"
        have_user_systemd && systemctl --user daemon-reload || true
        say "Removed the user service."
    fi
}

remove_system_unit() {
    sudo systemctl disable --now pggb >/dev/null 2>&1 || true
    sudo rm -f "$SYSTEM_UNIT"
    sudo systemctl daemon-reload
    say "Removed the Direct Ethernet service, and with it PGGB's network permission."
}

# Direct Ethernet's needs: systemd running the system (not only a user manager) and sudo, and a home folder path a unit
# file can name as it is
need_system_systemd() {
    command -v sudo >/dev/null 2>&1 || fail "Direct Ethernet needs sudo, which this system does not have."
    command -v systemctl >/dev/null 2>&1 || fail "Direct Ethernet needs systemd."
    case "$(systemctl is-system-running 2>/dev/null || true)" in
        ""|offline|unknown) fail "Direct Ethernet needs systemd running this system (systemctl is-system-running)." ;;
    esac
    case "$APP_DIR" in
        *[!A-Za-z0-9._/-]*) fail "Direct Ethernet's service needs a home folder path with no spaces or special characters; yours is $HOME." ;;
    esac
}

# The system unit: the kit's user unit, run by the system's manager as this user, with CAP_NET_RAW as an ambient
# capability (as the PGGB-Audio-Link endpoint's own unit holds it). The app itself is not changed, so it starts exactly
# as the user service starts it.
write_system_unit() {
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
$SYSTEM_MARK (Direct Ethernet).
# PGGB with no screen, as a system service so that it can hold one extra permission, CAP_NET_RAW: PGGB may then send raw
# Ethernet frames to a PGGB-Audio-Link endpoint (Direct Ethernet). It runs as $ME, with the kit's own launcher, as the
# user service does. To take it away: install_pggb.sh --no-direct-ethernet <kit>, or install_pggb.sh --remove.
[Unit]
Description=PGGB with no screen (its screen is the web Remote), with Direct Ethernet
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=exec
User=$ME
WorkingDirectory=~
ExecStart=$APP_DIR/bin/pggb-launch
AmbientCapabilities=CAP_NET_RAW
KillMode=mixed
TimeoutStopSec=15
Restart=no

[Install]
WantedBy=multi-user.target
EOF
    sudo install -m 644 "$tmp" "$SYSTEM_UNIT"
    rm -f "$tmp"
}

# Does this kit's PGGB have Direct Ethernet on Linux (9.1.48 and newer)? Its program then carries the Linux reason text
# "... needs PGGB's network permission on this computer"; older kits carry the switch's name but no Linux raw Ethernet.
kit_has_direct() { grep -a -q "network permission on this computer" "$APP_DIR/bin/pggb" 2>/dev/null; }
KIT_VER=""   # the kit's version, from its file name (pggb-linux-<version>.tar.gz), for the messages

# After the start: does the running PGGB hold CAP_NET_RAW (bit 13 of its effective set)?
direct_check() {
    local pid cap=""
    pid="$(systemctl show -p MainPID --value pggb 2>/dev/null || true)"
    if [ -n "$pid" ] && [ "$pid" != 0 ] && [ -r "/proc/$pid/status" ]; then
        cap="$(awk '/^CapEff:/ {print $2}' "/proc/$pid/status")"
    fi
    if [ -n "$cap" ] && [ $(( 0x$cap & 0x2000 )) -ne 0 ]; then
        say "Direct Ethernet: PGGB holds its network permission."
    elif [ -n "$cap" ]; then
        say "Note: PGGB started without its network permission, so it sends over UDP. See: systemctl status pggb"
    else
        say "Could not read PGGB's network permission yet. See: systemctl status pggb"
    fi
}

# ---------------------------------------------------------------- ALSA, the audio group, the PGGB Bridge
alsa_present() { command -v aplay >/dev/null 2>&1 && [ -f /usr/share/alsa/alsa.conf ]; }

# The command that installs ALSA's tools (alsa-utils, which brings alsa-lib) with this system's package manager
alsa_install_cmd() {
    if command -v pacman >/dev/null 2>&1; then echo "pacman -S --needed --noconfirm alsa-utils"
    elif command -v apt-get >/dev/null 2>&1; then echo "apt-get install -y alsa-utils"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf install -y alsa-utils"
    elif command -v zypper >/dev/null 2>&1; then echo "zypper --non-interactive install alsa-utils"
    fi
}

setup_alsa() {
    local cmd
    alsa_present && return 0
    cmd="$(alsa_install_cmd)"
    if [ -z "$cmd" ]; then
        say "ALSA's tools are missing, and this script does not know this system's package manager."
        say "Install alsa-utils (with alsa-lib) yourself, then run this script again."
        return 0
    fi
    say "ALSA's tools are missing; installing them: sudo $cmd"
    if ! sudo $cmd; then
        case "$cmd" in
            apt-get*) sudo apt-get update && sudo $cmd || true ;;   # a new system may not have read its package lists yet
        esac
    fi
    if alsa_present; then
        say "ALSA's tools are installed."
    else
        case "$cmd" in
            pacman*) say "ALSA's tools could not be installed. Run: sudo pacman -Syu alsa-utils   then run this script again." ;;
            *)       say "ALSA's tools could not be installed. Run: sudo $cmd   then run this script again." ;;
        esac
    fi
}

in_audio_group() { id -nG "$ME" | tr ' ' '\n' | grep -x audio >/dev/null; }

GROUP_ADDED=0
setup_audio_group() {
    in_audio_group && return 0
    getent group audio >/dev/null || sudo groupadd -r audio
    sudo usermod -aG audio "$ME"
    GROUP_ADDED=1
    say "Added $ME to the audio group."
}

bridge_card() { grep -E '^ *[0-9]+ \[PGGBBridge *\]' /proc/asound/cards >/dev/null 2>&1; }
aloop_loaded() { grep -E '^snd_aloop ' /proc/modules >/dev/null 2>&1; }

# Another use of snd-aloop: a configuration other than ours that loads it or sets its options, or (before ours exists) a
# loaded loopback card that is not the bridge. Then the bridge becomes the second card and the other keeps its own.
other_aloop() {
    local f
    for f in /etc/modprobe.d/*.conf /usr/lib/modprobe.d/*.conf /etc/modules-load.d/*.conf /usr/lib/modules-load.d/*.conf; do
        [ -f "$f" ] || continue
        [ "$f" = "$BR_MODPROBE" ] || [ "$f" = "$BR_LOAD" ] && continue
        grep -E '^[[:space:]]*(options[[:space:]]+)?snd[-_]aloop([[:space:]]|$)' "$f" >/dev/null && return 0
    done
    [ -f "$BR_MODPROBE" ] && return 1
    grep -E '^ *[0-9]+ \[' /proc/asound/cards 2>/dev/null | grep -E '\]: Loopback' | grep -v '\[PGGBBridge' >/dev/null
}

# The other loopback card's own option (index, id or pcm_substreams) where another configuration sets one value for it:
# the bridge's options keep it, so that the other card keeps its number and name (11-23: with -1 its card 2 became 0).
other_opt() {
    local f v
    for f in /etc/modprobe.d/*.conf /usr/lib/modprobe.d/*.conf; do
        [ -f "$f" ] && [ "$f" != "$BR_MODPROBE" ] || continue
        v="$(sed -n -E "s/^[[:space:]]*options[[:space:]]+snd[-_]aloop[[:space:]](.*[[:space:]])?$1=([^[:space:],]+)([[:space:]].*)?$/\2/p" "$f" 2>/dev/null | tail -n 1)" || v=""
        if [ -n "$v" ]; then echo "$v"; return 0; fi
    done
    return 0
}

# A root file with this content (its first line BRIDGE_MARK): written when it differs; a file of the same name that this
# script did not write is left as it is. Sets CHANGED=1 when it writes.
CHANGED=0
put_bridge_file() {
    local path=$1 content=$2 tmp
    if [ -f "$path" ]; then
        if [ "$(cat "$path")" = "$content" ]; then return 0; fi
        if ! grep -qF "$BRIDGE_MARK" "$path"; then
            say "Note: $path is not this script's; it is left as it is (the PGGB Bridge may then not work)."
            return 0
        fi
    fi
    tmp="$(mktemp)"
    printf '%s\n' "$content" > "$tmp"
    sudo install -D -m 644 "$tmp" "$path"
    rm -f "$tmp"
    CHANGED=1
}

# The alias's lines; the alias goes to /etc/alsa/conf.d where ALSA reads it, else into /etc/asound.conf between markers
alias_lines() {
    cat <<'EOF'
pcm.pggb_bridge {
	type empty
	slave.pcm "hw:CARD=PGGBBridge,DEV=0"
	hint {
		show on
		description "PGGB Bridge"
	}
}
EOF
}
alsa_reads_confd() { [ -d /etc/alsa/conf.d ] || grep -q '/etc/alsa/conf.d' /usr/share/alsa/alsa.conf 2>/dev/null; }

asound_without_block() { [ -f "$BR_ASOUND" ] && awk -v b="$BRIDGE_MARK" -v e="$BR_END" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$BR_ASOUND"; }

put_asound_block() {
    local tmp want
    want="$(printf '%s\n%s\n%s' "$BRIDGE_MARK" "$(alias_lines)" "$BR_END")"
    if [ -f "$BR_ASOUND" ] && awk -v b="$BRIDGE_MARK" -v e="$BR_END" '$0 == b {on = 1} on {print} $0 == e {on = 0}' "$BR_ASOUND" | cmp -s - <(printf '%s\n' "$want"); then
        return 0
    fi
    tmp="$(mktemp)"
    { asound_without_block || true; printf '%s\n' "$want"; } > "$tmp"
    sudo install -m 644 "$tmp" "$BR_ASOUND"
    rm -f "$tmp"
    CHANGED=1
}

REBOOT_WHY=""
setup_bridge() {
    local opts oi od os mods_dir="/usr/lib/modules/$(uname -r)"
    [ -d "$mods_dir" ] || mods_dir="/lib/modules/$(uname -r)"
    if other_aloop; then
        oi="$(other_opt index)"; od="$(other_opt id)"; os="$(other_opt pcm_substreams)"
        case "$oi" in ""|7) oi=-1 ;; esac   # the bridge keeps 7
        case "$od" in ""|PGGBBridge) od=Loopback ;; esac
        opts="options snd-aloop enable=1,1 index=$oi,7 id=$od,PGGBBridge pcm_substreams=${os:-8},1"
        say "The PGGB Bridge: snd-aloop is used for another loopback card here, so the bridge is its second card."
    else
        opts="options snd-aloop index=7 id=PGGBBridge pcm_substreams=1"
    fi
    CHANGED=0
    put_bridge_file "$BR_MODPROBE" "$(printf '%s\n%s' "$BRIDGE_MARK" "$opts")"
    put_bridge_file "$BR_LOAD" "$(printf '%s\n%s' "$BRIDGE_MARK" "snd-aloop")"
    if alsa_reads_confd; then
        put_bridge_file "$BR_ALIAS" "$(printf '%s\n%s' "$BRIDGE_MARK" "$(alias_lines)")"
    else
        put_asound_block
    fi
    if command -v pulseaudio >/dev/null 2>&1 || command -v pipewire >/dev/null 2>&1; then
        put_bridge_file "$BR_UDEV" "$(printf '%s\n%s' "$BRIDGE_MARK" 'SUBSYSTEM=="sound", ATTRS{id}=="PGGBBridge", ENV{PULSE_IGNORE}="1", ENV{ACP_IGNORE}="1"')"
        sudo udevadm control --reload 2>/dev/null || true
    fi
    [ "$CHANGED" -eq 0 ] || say "The PGGB Bridge's files are in place."
    # the card now, with the files above (the udev mark first, so the sound servers never take it)
    if bridge_card; then
        return 0
    elif [ ! -d "$mods_dir" ]; then
        REBOOT_WHY="Linux was updated since this computer started (no modules for the running $(uname -r))"
    elif aloop_loaded; then
        if sudo modprobe -r snd-aloop 2>/dev/null; then
            sudo modprobe snd-aloop || REBOOT_WHY="snd-aloop did not load again"
        else
            REBOOT_WHY="snd-aloop is loaded and in use, so its new card comes at the next start"
        fi
    else
        sudo modprobe snd-aloop || REBOOT_WHY="snd-aloop did not load (see: sudo modprobe snd-aloop)"
    fi
    if [ -z "$REBOOT_WHY" ]; then
        for _ in $(seq 1 10); do bridge_card && break; sleep 0.5; done
        bridge_card || REBOOT_WHY="the card did not appear"
    fi
}

# What the listener needs to know, after PGGB has started
bridge_report() {
    say ""
    say "The PGGB Bridge:"
    if bridge_card; then
        say "  the card: $(grep -E '^ *[0-9]+ \[PGGBBridge' /proc/asound/cards | tr -s ' ' | sed 's/^ //')"
    else
        say "  the card: not loaded yet; it comes with the reboot below."
    fi
    if command -v aplay >/dev/null 2>&1; then
        if aplay -L 2>/dev/null | grep -x pggb_bridge >/dev/null; then
            say "  the device for players: pggb_bridge (\"PGGB Bridge\" in aplay -L)"
        else
            say "  the device for players: pggb_bridge, not listed by aplay -L yet${REBOOT_WHY:+ (after the reboot)}"
        fi
    fi
    say "  In your player, choose the device \"pggb_bridge\" (PGGB Bridge), or hw:CARD=PGGBBridge,DEV=0."
    say "  Not plughw:, default or dmix: they can change the audio before PGGB gets it."
    say "  In PGGB-Live, choose the input \"Device Input (PGGB Bridge)\", press Play, then start the player."
}

# The last word: a reboot, when the card waits for one, or when the audio group was added and PGGB would not get it
# otherwise. A user manager keeps the groups it started with, and with --boot it outlives every logout, so only a reboot
# gives the user service (or a desktop session's PGGB) the new group; the Direct Ethernet system service takes it at its
# own restart.
reboot_note() {
    local why=()
    [ -z "$REBOOT_WHY" ] || why+=("the PGGB Bridge's card: $REBOOT_WHY")
    if [ "$GROUP_ADDED" -eq 1 ] && { [ "$WINDOW" -eq 1 ] || [ "$DIRECT" -eq 0 ]; }; then
        why+=("you were added to the audio group, which PGGB gets only when it starts after a reboot")
    fi
    [ "${#why[@]}" -gt 0 ] || return 0
    say ""
    if [ "$BRIDGE" -eq 1 ]; then
        say "Reboot now; after it the PGGB Bridge (and any DAC) are ready."
    else
        say "Reboot now; after it PGGB can open any DAC."
    fi
    printf '  (%s)\n' "${why[@]}"
}

remove_bridge() {
    local f gone=0 tmp
    for f in "$BR_MODPROBE" "$BR_LOAD" "$BR_ALIAS" "$BR_UDEV"; do
        if [ -f "$f" ] && grep -qF "$BRIDGE_MARK" "$f"; then sudo rm -f "$f"; gone=1; fi
    done
    if [ -f "$BR_ASOUND" ] && grep -qxF "$BRIDGE_MARK" "$BR_ASOUND"; then
        tmp="$(mktemp)"
        asound_without_block > "$tmp" || true
        if grep -q '[^[:space:]]' "$tmp"; then sudo install -m 644 "$tmp" "$BR_ASOUND"; else sudo rm -f "$BR_ASOUND"; fi
        rm -f "$tmp"
        gone=1
    fi
    if [ "$gone" -eq 1 ]; then
        sudo udevadm control --reload 2>/dev/null || true
        say "Removed the PGGB Bridge's files; its card goes at the next start. ALSA's packages stay."
    fi
}

bridge_files_present() {
    local f
    for f in "$BR_MODPROBE" "$BR_LOAD" "$BR_ALIAS" "$BR_UDEV"; do
        [ -f "$f" ] && grep -qF "$BRIDGE_MARK" "$f" && return 0
    done
    [ -f "$BR_ASOUND" ] && grep -qxF "$BRIDGE_MARK" "$BR_ASOUND"
}

# ---------------------------------------------------------------- remove
if [ "$REMOVE" -eq 1 ]; then
    [ -z "$KIT" ] || fail "--remove takes no kit file."
    [ -z "$DIRECT" ] || fail "--remove takes Direct Ethernet away too; give it alone."
    if direct_was_on || bridge_files_present; then
        sudo_once "the PGGB service and the PGGB Bridge's files"
    fi
    stop_service
    remove_user_unit
    if direct_was_on; then
        remove_system_unit
    fi
    remove_bridge
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
if [ "$WINDOW" -eq 1 ] && [ -n "$DIRECT" ]; then
    fail "--window starts no service, and Direct Ethernet is the service's permission; give one of them."
fi
if [ -z "$DIRECT" ]; then   # an update keeps Direct Ethernet as it was
    if direct_was_on; then DIRECT=1; else DIRECT=0; fi
fi

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

if [ "$WINDOW" -eq 0 ] && [ "$DIRECT" -eq 0 ] && ! have_user_systemd; then
    fail "systemd's user manager is not reachable (systemctl --user). Log in to this user directly (not with su), or install with --window and start PGGB yourself."
fi
if [ "$WINDOW" -eq 0 ] && [ "$DIRECT" -eq 1 ]; then
    need_system_systemd
fi

# grep reads the whole list (no -q): under pipefail, an early exit would kill tar (SIGPIPE) and refuse a good kit
tar -tzf "$KIT" 2>/dev/null | grep -x 'pggb/bin/pggb-launch' >/dev/null \
    || fail "$KIT is not a PGGB for Linux kit (it has no pggb/bin/pggb-launch)."
KIT_VER="$(basename "$KIT" | sed -n 's/^pggb-linux-\([0-9][0-9.]*[0-9]\)\.tar\.gz$/\1/p')"

# ---------------------------------------------------------------- one password prompt, for all that needs it
why=""
alsa_present || why="${why:+$why, }ALSA's tools"
[ "$BRIDGE" -eq 0 ] || why="${why:+$why, }the PGGB Bridge"
in_audio_group || why="${why:+$why, }the audio group"
[ "$BOOT" -eq 0 ] || why="${why:+$why, }starting at boot"
{ [ "$DIRECT" -eq 1 ] || direct_was_on; } && why="${why:+$why, }the Direct Ethernet service"
[ -z "$why" ] || sudo_once "$why"

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

# ALSA's tools, the audio group and the PGGB Bridge, before PGGB starts so that it finds them
setup_alsa
setup_audio_group
if [ "$BRIDGE" -eq 1 ]; then
    setup_bridge
fi

if [ "$WINDOW" -eq 1 ]; then
    [ "$BRIDGE" -eq 0 ] || bridge_report
    say ""
    say "Start PGGB from a terminal in your desktop session:  $APP_DIR/bin/pggb-launch --window"
    say "Its output goes to $OUT_LOG."
    reboot_note
    exit 0
fi

if [ "$DIRECT" -eq 1 ]; then
    # from the user service: it goes (one PGGB at a time), and starting at boot carries over
    if have_user_systemd && systemctl --user is-enabled --quiet pggb 2>/dev/null; then BOOT=1; fi
    remove_user_unit
    say "Direct Ethernet: PGGB runs as a system service with one extra permission."
    write_system_unit
    sudo systemctl daemon-reload
    if [ "$BOOT" -eq 1 ]; then
        sudo systemctl enable pggb
    fi
    sudo systemctl restart pggb
    if kit_has_direct; then
        say "PGGB is running as a system service, with Direct Ethernet."
        direct_check
    else   # the service stays, so that an update to a kit with Direct Ethernet keeps it
        say "PGGB is running as a system service."
        say "This kit${KIT_VER:+ ($KIT_VER)} has no Direct Ethernet (it needs PGGB for Linux 9.1.48 or newer); PGGB sends over UDP."
    fi
else
    if direct_was_on; then   # --no-direct-ethernet: back to the user service; starting at boot carries over
        if systemctl is-enabled --quiet pggb 2>/dev/null; then BOOT=1; fi
        remove_system_unit
    fi
    mkdir -p "$UNIT_DIR"
    cp "$APP_DIR/pggb.service" "$UNIT"
    systemctl --user daemon-reload
    if [ "$BOOT" -eq 1 ]; then
        say "Starting PGGB at every boot: your user lingers (loginctl enable-linger)."
        sudo loginctl enable-linger "$ME"
        systemctl --user enable pggb
    fi
    systemctl --user restart pggb
    say "PGGB is running as a user service."
fi

# The web Remote: PGGB writes its addresses to its log a few seconds after it starts.
addrs=""
for _ in $(seq 1 20); do
    if [ -f "$OUT_LOG" ] && grep -q ':8180/' "$OUT_LOG"; then
        addrs="$(grep -o 'http://[^ ]*:8180/[^ ]*' "$OUT_LOG" | sort -u)"
        break
    fi
    sleep 1
done

[ "$BRIDGE" -eq 0 ] || bridge_report
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
if [ "$DIRECT" -eq 1 ]; then
    say "Stop:     sudo systemctl stop pggb"
    say "Start:    sudo systemctl start pggb"
else
    say "Stop:     systemctl --user stop pggb"
    say "Start:    systemctl --user start pggb"
fi
say "Remove:   $0 --remove"
if [ "$DIRECT" -eq 1 ]; then
    systemctl is-enabled --quiet pggb 2>/dev/null \
        || say "To start PGGB at every boot, run this script again with --boot."
elif [ "$BOOT" -eq 0 ]; then
    say "To start PGGB at every boot without a login, run this script again with --boot."
fi
reboot_note
