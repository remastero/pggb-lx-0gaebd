# PGGB for Linux: install script

`install_pggb.sh` installs PGGB from the PGGB for Linux kit (`pggb-linux-<version>.tar.gz`) for the user who runs it.

## Get the kit

The newest kit is in this repository: `pggb-linux-9.1.47.tar.gz`, a test build of 24 November 2026. Download it with
its checksum file and the script into one folder, then check the kit:

```sh
curl -LO https://github.com/remastero/pggb-lx-0gaebd/raw/main/pggb-linux-9.1.47.tar.gz
curl -LO https://github.com/remastero/pggb-lx-0gaebd/raw/main/pggb-linux-9.1.47.tar.gz.sha256
curl -LO https://github.com/remastero/pggb-lx-0gaebd/raw/main/install_pggb.sh
sha256sum -c pggb-linux-9.1.47.tar.gz.sha256
```

`sha256sum` prints `pggb-linux-9.1.47.tar.gz: OK` when the kit is complete. Then install or update as below, with
`pggb-linux-9.1.47.tar.gz` in place of `pggb-linux-<version>.tar.gz`. An update keeps your settings and your licence.

## What it needs

- A 64-bit x86 computer running Linux with glibc 2.36 or newer and systemd.
- The kit file, `pggb-linux-<version>.tar.gz`.
- sudo. The script asks for your password once, at the start.

ALSA's tools are installed by the script when they are missing (with pacman, apt, dnf or zypper; on other systems it
tells you what to install).

## Install

Put the script next to the kit file. Then, as your normal user (not as root):

```sh
chmod +x install_pggb.sh
./install_pggb.sh --boot pggb-linux-<version>.tar.gz
```

The script:

- checks the computer first;
- asks for your password once (sudo), for everything below that needs it;
- unpacks PGGB into `~/pggb` (an existing `~/pggb` is moved aside to `~/pggb.old-<date-time>`, never deleted);
- installs ALSA's tools if they are missing, and adds you to the `audio` group;
- sets up the PGGB Bridge (below);
- installs PGGB as a systemd user service and starts it;
- with `--boot`, also starts PGGB at every boot without a login (`loginctl enable-linger`);
- prints the PGGB Bridge's state and the web Remote's address.

Running it again is safe: it repairs a setup left half done.

Other ways to run it:

| Command | What it does |
|---|---|
| `./install_pggb.sh pggb-linux-<version>.tar.gz` | Install and start PGGB, without starting it at boot |
| `./install_pggb.sh --direct-ethernet pggb-linux-<version>.tar.gz` | Install and start PGGB with Direct Ethernet (below). Add `--boot` to start it at boot. |
| `./install_pggb.sh --no-direct-ethernet pggb-linux-<version>.tar.gz` | Install and start PGGB without Direct Ethernet. |
| `./install_pggb.sh --no-bridge pggb-linux-<version>.tar.gz` | Install and start PGGB without setting up the PGGB Bridge. |
| `./install_pggb.sh --window pggb-linux-<version>.tar.gz` | Install only. Start it from your desktop with `~/pggb/bin/pggb-launch --window` |
| `./install_pggb.sh --remove` | Stop PGGB and remove it, with the PGGB Bridge's files |

## The PGGB Bridge

With the PGGB Bridge, a music player on this computer plays into PGGB-Live, which processes its audio and plays it to
your DAC. The script sets it up on every install unless you give `--no-bridge`:

- ALSA's loopback card `PGGBBridge`, loaded now and at every boot;
- the device `pggb_bridge` ("PGGB Bridge") for players that list ALSA devices by name;
- a mark that keeps PulseAudio and PipeWire off the card, when either is installed.

To use it:

- In your player, choose the device `pggb_bridge` (PGGB Bridge), or `hw:CARD=PGGBBridge,DEV=0`. Do not choose
  `plughw:`, `default` or `dmix`: they can change the audio before PGGB gets it.
- In PGGB-Live, choose the input "Device Input (PGGB Bridge)", press Play, then start the player.

Notes:

- If you use ALSA's loopback card for something else, the script keeps your card, with its number and name, and makes
  the bridge a second one.
- When the script ends with "Reboot now", reboot: it says why. It does so when it added you to the `audio` group (PGGB
  gets the group only when it starts after a reboot), when Linux was updated since the computer started, or when the
  loopback module is in use.
- `--remove` removes the PGGB Bridge's files. ALSA's packages stay.

## Direct Ethernet (optional)

With Direct Ethernet, PGGB sends Bypass streams to a PGGB-Audio-Link (PAL) endpoint as raw Ethernet frames when both
computers are wired to the same network and the endpoint supports it. Without Direct Ethernet, these streams use UDP.
Upsampled streams and Wi-Fi use TCP either way. The kit in this repository has it.

Direct Ethernet is off unless you request it. `--direct-ethernet` enables it: PGGB runs as a system service instead of a
user service, still under your user account, with one extra network permission, CAP_NET_RAW, to send raw Ethernet
frames.

- Updates keep your Direct Ethernet setting.
- `--no-direct-ethernet` disables it again. `--remove` removes it along with PGGB.
- PGGB's own switch, Allow Direct Ethernet, is with the PAL endpoint's settings and is on by default.
- PGGB started from your desktop with `--window` does not have this network permission, so Bypass streams use UDP.
- With an older kit that has no Direct Ethernet, `--direct-ethernet` sets up the service but says that the kit has no
  Direct Ethernet: PGGB sends over UDP until you update to a kit that has it.

## The web Remote

Open `http://<this computer's address>:8180/` in a browser on the same network. The script prints the addresses PGGB
reports; later, `tail ~/pggb/logs/pggb.out` shows them again. If a firewall runs, allow TCP port 8180 from the local
network.

A new install starts a 30-day trial. Activate it on the Remote's License and About page.

## Every day

- Stop: `systemctl --user stop pggb`
- Start: `systemctl --user start pggb`
- With Direct Ethernet: `sudo systemctl stop pggb` and `sudo systemctl start pggb`
- PGGB's output: `~/pggb/logs/pggb.out`

## Updating PGGB

Run the script again with the new kit file. It stops the running PGGB, moves the old `~/pggb` aside and starts the new
one. Updates keep your Direct Ethernet setting and check the PGGB Bridge.

## Your settings

The script never touches your settings (`~/.config/pggb`) or PGGB's data (`~/PGGB`), not even with `--remove`. Delete
them yourself for a clean start.

---

Script version 3.1, 23 November 2026.
