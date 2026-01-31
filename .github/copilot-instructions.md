# Guidance for AI Coding Agents

## Quick summary
- Purpose: Make a Raspberry Pi Zero(W/2W) act as a USB mass-storage device backed by a file (`/piusb.bin`), and share that storage over LAN via Samba so users can drop .gcode files for printers. Key components: `install.sh`, `usbshare.py`, and documentation in `README.md`.

## Big-picture architecture (the "why")
- A loopback vfat file (`/piusb.bin`) is created and mounted at `/mnt/usb_share` and exposed as a virtual USB mass-storage gadget using the kernel `g_multi` module.
- Samba shares `/mnt/usb_share` as `[usb]` so laptops can write files to it.
- `usbshare.py` (a watchdog) monitors `/mnt/usb_share`. On relevant file events it unmounts/remounts the gadget (via `modprobe g_multi -r` / `modprobe g_multi ...`) so the connected USB host sees file updates.

## Key files and what they control
- `install.sh` — the canonical installation flow. It:
  - verifies/asks about hardware via `/proc/device-tree/model`.
  - installs packages (`samba`, `winbind`, `python3-pip`, `python3-watchdog`).
  - appends `dtoverlay=dwc2` and `dwc2` configuration for USB gadget support and edits `cmdline.txt` to add `modules-load=dwc2`.
  - creates `/piusb.bin` (default `2048 MB`) and configures `/etc/fstab` to mount it at boot.
  - appends Samba block for `[usb]`, copies `usbshare.py` to `/usr/local/share/` and creates/enables `usbshare.service`.
- `usbshare.py` — Python watchdog script:
  - Watches `/mnt/usb_share` with `watchdog` library.
  - Uses `ACT_EVENTS = [DirDeletedEvent, DirMovedEvent, FileDeletedEvent, FileModifiedEvent, FileMovedEvent]` and `ACT_TIME_OUT = 5` to decide when to re-cycle the gadget.
  - Runs shell commands (via `subprocess.run`) to `modprobe` and `sync`.
- `README.md` — operational instructions and manual commands (useful test steps and troubleshooting). Use this as single-source for expected behavior and user-facing steps.

## Important commands to run / test (copyable)
- Manual test of gadget connect: `sudo /sbin/modprobe g_multi file=/piusb.bin stall=0 removable=1`
- Manual disconnect: `sudo /sbin/modprobe g_multi -r`
- Run watcher manually: `sudo python3 /usr/local/share/usbshare.py`
- Check service logs: `journalctl -u usbshare.service -f` or `sudo systemctl status usbshare.service`
- Check Samba service: `sudo systemctl status smbd` and list share: `smbclient -L localhost -N`
- Inspect mounted file: `mount | grep /mnt/usb_share` and `df -h /mnt/usb_share`

## Project-specific conventions and patterns
- Paths are absolute and rooted at `/` (e.g., `/piusb.bin`, `/mnt/usb_share`, `/usr/local/share/usbshare.py`). Expect scripts to use `sudo` and systemd service management.
- `install.sh` is interactive and defensive: it checks for existing markers before appending (helper `append_text_to_file`) and prompts for user choices.
- `usbshare.py` uses `logging` (default INFO in distributed code) — search for `logger.debug` calls to find internal state helpful for tests.
- The project assumes Raspberry Pi OS 32-bit Lite and known Pi Zero models. `install.sh` has explicit compatibility checks but allows proceeding if user confirms.

## Troubleshooting & edge cases agents should be aware of
- The USB data cable must have 5V line disabled (README explains physical tape method). Tests should account for this when reproducing hardware behaviour.
- `cmdline.txt` edits must be a single-line append (`modules-load=dwc2`); watch out when running script on systems that have `/boot/firmware` instead of `/boot` (script handles both).
- Watcher re-attach lifecycle: ensure at least `ACT_TIME_OUT` seconds after file write before expecting the gadget reconnect.
- Because the gadget is created from `piusb.bin` in `/`, keep disk-space checks in mind (install script calculates space and offers smaller file alternatives).

## Safe changes & tests an AI agent can attempt
- Small, non-intrusive tasks: fix typos in README, add more logging, add tests that run `usbshare.py` with a temporary directory and a mocked `modprobe` (use mocking for subprocess calls).
- When adding tests, prefer to avoid running actual `modprobe` or `systemctl` in CI; mock those shell interactions and verify the script's logic around `ACT_TIME_OUT` and event handling.

## Where to look for context while coding
- `README.md` — expected user flow, manual commands and troubleshooting (source of truth for behavior).
- `install.sh` — the end-to-end installer, patterns for idempotent edits, compatibility checks, and package list.
- `usbshare.py` — event handling, timeouts, and exact commands executed when cycling the USB gadget.

## Acceptance criteria for PRs touching core behavior
1. Changes must preserve the `g_multi` lifecycle semantics (unmount → sync → mount) and not shorten `ACT_TIME_OUT` unexpectedly.
2. Installer changes should be idempotent and safe for interactive runs (preserve `append_text_to_file` semantics).
3. New features must include a minimal test plan (unit tests with subprocess mocks and a manual test checklist in `README.md`).

---

If you'd like, I can:
- Add a short automated test scaffold (using `pytest` + `unittest.mock`) that verifies `DirtyHandler` and `run_command` behavior, or
- Improve `README.md` sections with explicit commands for developers running the service locally.

Please tell me which of the above (if any) you'd like me to add or clarify. 😊
