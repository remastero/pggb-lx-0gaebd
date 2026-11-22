# PGGB for Linux: install script

`install_pggb.sh` installs PGGB from the PGGB for Linux kit (`pggb-linux-<version>.tar.gz`) for the user who runs it.

## What it needs

- A 64-bit x86 computer running Linux with glibc 2.36 or newer, systemd and ALSA.
- The kit file, `pggb-linux-<version>.tar.gz`.

## Install

Put the script next to the kit file. Then, as your normal user (not as root):

```sh
chmod +x install_pggb.sh
./install_pggb.sh --boot pggb-linux-<version>.tar.gz
```

The script:

- checks the computer first;
- unpacks PGGB into `~/pggb` (an existing `~/pggb` is moved aside to `~/pggb.old-<date-time>`, never deleted);
- installs PGGB as a systemd user service and starts it;
- with `--boot`, also starts PGGB at every boot without a login (sudo asks for your password once, for
  `loginctl enable-linger`);
- prints the web Remote's address.

Other ways to run it:

| Command | What it does |
|---|---|
| `./install_pggb.sh pggb-linux-<version>.tar.gz` | Install and start PGGB, without starting it at boot |
| `./install_pggb.sh --window pggb-linux-<version>.tar.gz` | Install only. Start it from your desktop with `~/pggb/bin/pggb-launch --window` |
| `./install_pggb.sh --remove` | Stop PGGB and remove it |

## The web Remote

Open `http://<this computer's address>:8180/` in a browser on the same network. The script prints the addresses PGGB
reports; later, `tail ~/pggb/logs/pggb.out` shows them again. If a firewall runs, allow TCP port 8180 from the local
network.

A new install starts a 30-day trial. Activate it on the Remote's License and About page.

## Every day

- Stop: `systemctl --user stop pggb`
- Start: `systemctl --user start pggb`
- PGGB's output: `~/pggb/logs/pggb.out`

## Updating PGGB

Run the script again with the new kit file. It stops the running PGGB, moves the old `~/pggb` aside and starts the new
one.

## Your settings

The script never touches your settings (`~/.config/pggb`) or PGGB's data (`~/PGGB`), not even with `--remove`. Delete
them yourself for a clean start.

---

Script version 1, 22 November 2026.
