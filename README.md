# POCSAG Pager Transmitter

A standalone POCSAG pager transmitter for the Raspberry Pi using a factory
**MMDVM_HS_Hat** hotspot — **without Pi-Star and without DAPNET**.

The included installer (`install-pocsag.sh`) builds and configures everything
from a clean OS: it builds MMDVMHost, frees the GPIO UART, sets up the MQTT
broker, installs a systemd service that starts on boot, and gives you a simple
`sendpage` command to transmit a page.

## Tested hardware

This has been built and tested on:

- **Raspberry Pi 4**
- **MMDVM_HS_Hat** (single ADF7021, simplex) on the 40-pin GPIO header
- BOOT0 = GPIO20, RESET = GPIO21 (standard HS_Hat wiring)

It should also work on other Pi models that expose the GPIO UART (Pi 3, Pi Zero 2),
but those are untested.

## Requirements

- **Raspberry Pi OS Lite (64-bit)** — flash it with the Raspberry Pi Imager.
  A desktop image is not needed; Lite is recommended.
- An MMDVM_HS_Hat seated on the GPIO header.
https://www.amazon.se/UHF-Hotspot-modul-st%C3%B6der-D-Star-l%C3%A4gen-statusvisning/dp/B0FQJTJMGR
- Network access to the Pi (SSH is enough).

> **Note:** Transmitting on the air requires a valid amateur radio licence, and
> you are responsible for using a frequency and power level that are legal in
> your country. The default frequency in the installer (433.920 MHz) is an
> example only.

## Installation

1. Flash **Raspberry Pi OS Lite (64-bit)** to an SD card and boot the Pi.

2. Copy `install-pocsag.sh` to the Pi (for example with `scp`, or clone this repo):

   ```bash
   git clone https://github.com/<your-user>/<your-repo>.git
   cd <your-repo>
   ```

3. Run the installer:

   ```bash
   sudo bash install-pocsag.sh
   ```

   Answer the prompts (callsign, frequency, test RIC). On the firmware question
   answer **N** if your hat already works (firmware lives on the hat's own chip
   and survives an SD-card reinstall); answer **y** only if the hat is brand-new
   or blank (only the PWR LED lights, no blinking heartbeat).

4. **Reboot** when the installer asks — this is required, because freeing the
   GPIO UART only takes effect after a reboot:

   ```bash
   sudo reboot
   ```

After the reboot the service starts automatically.

## Usage

Send a page locally on the Pi:

```bash
sendpage 1234567 "hello world"
```

Check the service and logs:

```bash
systemctl status pocsag --no-pager
journalctl -u pocsag -n 20
```

Set your pager to: the chosen frequency, the RIC you paged, **1200 baud, POCSAG**.

## Flashing a blank hat

If your hat is brand-new and has no firmware, flash it **after** the reboot
(the GPIO UART must be live first):

```bash
sudo hs-flash
```

## Remote client (workstation)

The installer opens an authenticated MQTT listener so you can send pages from
another computer on your network:

- **Port:** 1884
- **Username:** `mqtt`
- **Password:** `Password`

A small Python GUI client (`pager_gui_auth.py`) is included. On your workstation:

```bash
pip install paho-mqtt          # plus 'sudo apt install python3-tk' on Linux
python3 pager_gui_auth.py
```

Enter the Pi's IP address, port `1884`, the username and password above, a RIC
and a message, then press **Send**. The settings (except the password) are saved
to `~/.pager_client.json`.

## How it works

- **MMDVMHost** is the POCSAG engine; it talks to the hat over the GPIO UART at
  115200 baud and is configured for POCSAG only.
- Modern MMDVMHost takes commands over **MQTT**, so a local **mosquitto** broker
  is installed. MMDVMHost connects anonymously on a loopback-only listener
  (127.0.0.1:1883), while remote clients use a separate authenticated listener
  (port 1884).
- Sending a page publishes `page <RIC> <message>` to the MQTT topic
  `mmdvm/command`, which MMDVMHost transmits.

## Files

- `install-pocsag.sh` — the all-in-one installer.
- `pager_gui_auth.py` — workstation GUI client (authenticated MQTT).

## Disclaimer

This software is for amateur radio and educational use only. Use it only on
frequencies and at power levels you are licensed and legally permitted to use.
