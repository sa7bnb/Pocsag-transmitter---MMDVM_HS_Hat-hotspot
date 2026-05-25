#!/usr/bin/env bash
#
# install-pocsag.sh  (v5 - complete, with OLED)
# =============================================================================
# Builds a standalone POCSAG pager transmitter on a Raspberry Pi using a
# factory MMDVM_HS_Hat hotspot on the GPIO header - no Pi-Star, no DAPNET.
#
# This single script does EVERYTHING worked out during setup:
#   * installs all build + runtime dependencies
#   * frees the GPIO UART (disable BT, remove serial console, kill getty)
#   * builds & installs MMDVMHost (the POCSAG engine)
#   * installs the mosquitto MQTT broker (required by modern MMDVMHost)
#   * OPTIONAL: builds the MMDVM_HS_Hat firmware and flashes a blank/new hat
#   * writes a POCSAG-only MMDVM.ini at 115200 baud (the HS_Hat host speed)
#   * installs an hs-reset helper that wakes the board on every start
#   * installs a systemd service that auto-starts everything on boot
#   * installs 'sendpage' to transmit a page via MQTT
#   * OPTIONAL: installs a 0.96" SSD1306 OLED status display (IP + TX type),
#     enabling I2C properly (raspi-config + i2c-dev) so it works after reboot
#   * reboots the Pi at the end so all the boot changes take effect
#
# Target:   Raspberry Pi OS Lite (Bookworm / Trixie), Pi 3 / 4 / Zero 2.
# Hardware: MMDVM_HS_Hat (single ADF7021) on the 40-pin GPIO header.
#           BOOT0 = GPIO20, RESET = GPIO21 (standard HS_Hat wiring).
#           OLED  = SSD1306 on I2C1 (GPIO2=SDA pin3, GPIO3=SCL pin5, 3.3V).
#
# After install + reboot:   sendpage <RIC> "your message"
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo bash $0" >&2
  exit 1
fi

# ---- fixed locations -------------------------------------------------------
CFG_DIR=/etc/pocsag
LOG_DIR=/var/log/mmdvm
HOST_SRC=/usr/local/src/MMDVMHost
FW_SRC=/usr/local/src/MMDVM_HS
SVC_USER=mmdvm
REMOTE_PORT=7642
MQTT_TOPIC="mmdvm/command"     # MMDVMHost subscribes to <base>/command; base defaults to mmdvm
BOOT0_GPIO=20
NRST_GPIO=21

# OLED display locations.
OLED_DIR=/opt/oled
OLED_VENV=$OLED_DIR/venv

# MQTT broker setup. MMDVMHost connects locally & anonymously, so we keep an
# anonymous loopback listener for it, and add a SEPARATE authenticated network
# listener for remote workstation clients.
MQTT_LOCAL_PORT=1883           # loopback only, anonymous, used by MMDVMHost
MQTT_NET_PORT=1884             # network, requires login, used by remote clients
MQTT_USER=mqtt                 # remote client username
MQTT_PASS=Password         # remote client password
MQTT_PASSFILE=/etc/mosquitto/passwd

echo "=============================================================="
echo "   POCSAG pager transmitter - complete installer (v5)"
echo "=============================================================="
echo

# ---- gather settings -------------------------------------------------------
read -rp "Transmitter callsign / node ID (e.g. SA7BNB, or NOCALL): " CALLSIGN
CALLSIGN=${CALLSIGN:-NOCALL}

read -rp "POCSAG frequency in Hz [default 433920000 = 433.920 MHz]: " FREQ
FREQ=${FREQ:-433920000}

read -rp "A pager RIC (capcode) for the install test [default 1234567]: " TEST_RIC
TEST_RIC=${TEST_RIC:-1234567}

# The MMDVM_HS_Hat firmware talks to the Pi at 115200 over the GPIO UART.
PORT=/dev/ttyAMA0
BAUD=115200

echo
echo "Firmware: the hat keeps its firmware on its own chip, independent of the"
echo "SD card. A fresh OS install on a hat that already works does NOT need a"
echo "re-flash. Only flash if the hat is brand-new / blank (only the PWR LED"
echo "lights, no blinking heartbeat)."
read -rp "Build and flash the hat firmware now? [y/N]: " DO_FLASH
DO_FLASH=${DO_FLASH:-N}

echo
echo "OLED: a 0.96\" SSD1306 display on the hat's I2C header can show the Pi's"
echo "IP address while idle, and the TX type (POCSAG) + RIC while paging."
read -rp "Install OLED status display support? [Y/n]: " DO_OLED
DO_OLED=${DO_OLED:-Y}

echo
echo "About to install with:"
echo "   Callsign : $CALLSIGN"
echo "   Frequency: $FREQ Hz"
echo "   Modem    : $PORT @ $BAUD baud (MMDVM_HS_Hat on GPIO)"
echo "   Test RIC : $TEST_RIC"
echo "   Flash FW : $DO_FLASH"
echo "   OLED     : $DO_OLED"
read -rp "Proceed? [Y/n]: " GO
[[ "${GO:-Y}" =~ ^[Nn] ]] && { echo "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# 1. DEPENDENCIES
# ---------------------------------------------------------------------------
echo
echo ">> [1/10] Installing dependencies..."
apt-get update -qq
# MMDVMHost build: git build-essential nlohmann-json3-dev libmosquitto-dev
# MQTT broker + client: mosquitto mosquitto-clients
# firmware build: gcc-arm-none-eabi ; flashing: stm32flash
# (pinctrl ships with Raspberry Pi OS Bookworm/Trixie)
apt-get install -y -qq \
  git build-essential nlohmann-json3-dev libmosquitto-dev \
  mosquitto mosquitto-clients \
  gcc-arm-none-eabi stm32flash

# ---------------------------------------------------------------------------
# 2. SERVICE USER
# ---------------------------------------------------------------------------
echo ">> [2/10] Creating service user '$SVC_USER'..."
id "$SVC_USER" &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
usermod -aG dialout,gpio "$SVC_USER" 2>/dev/null || usermod -aG dialout "$SVC_USER"

# ---------------------------------------------------------------------------
# 3. FREE THE GPIO UART  (the single biggest gotcha)
# ---------------------------------------------------------------------------
echo ">> [3/10] Freeing the GPIO UART for the hat..."
if [[ -f /boot/firmware/config.txt ]]; then BOOT=/boot/firmware; else BOOT=/boot; fi

grep -q '^enable_uart=1'        "$BOOT/config.txt" || echo 'enable_uart=1'        >> "$BOOT/config.txt"
grep -q '^dtoverlay=disable-bt' "$BOOT/config.txt" || echo 'dtoverlay=disable-bt' >> "$BOOT/config.txt"

# Remove any serial console token (serial0/ttyAMA0/ttyS0) from cmdline.txt.
# This is what blocks the modem if left in place.
sed -i -E 's/console=(serial0|ttyAMA0|ttyS0),[0-9]+ ?//g' "$BOOT/cmdline.txt"
# collapse any doubled spaces left behind
sed -i -E 's/  +/ /g; s/ +$//' "$BOOT/cmdline.txt"

systemctl disable --now serial-getty@ttyAMA0.service 2>/dev/null || true
systemctl disable --now serial-getty@serial0.service 2>/dev/null || true
systemctl disable --now hciuart.service               2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. BUILD & INSTALL MMDVMHost
# ---------------------------------------------------------------------------
echo ">> [4/10] Building MMDVMHost..."
if [[ -d "$HOST_SRC/.git" ]]; then git -C "$HOST_SRC" pull --ff-only; else
  rm -rf "$HOST_SRC"; git clone --depth 1 https://github.com/g4klx/MMDVMHost.git "$HOST_SRC"; fi
cd "$HOST_SRC"
make clean 2>/dev/null || true
make -j"$(nproc)"
[[ -x ./MMDVMHost ]] || { echo "ERROR: MMDVMHost build failed." >&2; exit 1; }
install -m 0755 MMDVMHost /usr/local/bin/MMDVMHost

# ---------------------------------------------------------------------------
# 5. MQTT BROKER
# ---------------------------------------------------------------------------
echo ">> [5/10] Configuring mosquitto MQTT broker..."
# Two listeners via per-listener security:
#   * loopback 1883, anonymous  -> MMDVMHost (unchanged, no auth needed)
#   * network  1884, login req. -> remote workstation clients
cat > /etc/mosquitto/conf.d/pager.conf <<EOF
per_listener_settings true

# Local listener for MMDVMHost (loopback only, anonymous).
listener $MQTT_LOCAL_PORT 127.0.0.1
allow_anonymous true

# Network listener for remote clients (username + password required).
listener $MQTT_NET_PORT 0.0.0.0
allow_anonymous false
password_file $MQTT_PASSFILE
EOF

# Create / update the remote client account.
# mosquitto 2.0 drops privileges to the 'mosquitto' user BEFORE its security
# module reads the password file, so the file must be READABLE by that user.
# A 600 root:root file is unreadable to it and the broker refuses to start.
# Use root:mosquitto 0640: readable by the broker, not writable by group/other
# (mosquitto warns and can refuse if the file is group/world writable).
mosquitto_passwd -b -c "$MQTT_PASSFILE" "$MQTT_USER" "$MQTT_PASS"
chown root:mosquitto "$MQTT_PASSFILE"
chmod 640 "$MQTT_PASSFILE"

systemctl enable --now mosquitto
systemctl restart mosquitto

# ---------------------------------------------------------------------------
# 6. FIRMWARE: build (optional) + install the post-reboot 'hs-flash' helper
# ---------------------------------------------------------------------------
# IMPORTANT: flashing CANNOT happen in this run. Freeing the GPIO UART in step
# 3 only takes effect after a reboot, so /dev/ttyAMA0 is not yet wired to the
# hat right now. Flashing is therefore a SEPARATE post-reboot step: run
# 'sudo hs-flash' after rebooting, and only if the hat is actually blank.
echo ">> [6/10] Setting up firmware tooling..."

# Install the hs-flash helper (builds the firmware if needed, then flashes).
cat > /usr/local/bin/hs-flash <<EOF
#!/usr/bin/env bash
# hs-flash - (re)flash the MMDVM_HS_Hat firmware. Run AFTER a reboot, and only
# if the hat is blank/new (only PWR lit, no blinking heartbeat).
set -euo pipefail
FW_SRC="$FW_SRC"
PORT="$PORT"
BOOT0=$BOOT0_GPIO
NRST=$NRST_GPIO
EOF
cat >> /usr/local/bin/hs-flash <<'EOF'
[[ $EUID -eq 0 ]] || { echo "run with sudo: sudo hs-flash" >&2; exit 1; }

if [[ ! -f "$FW_SRC/bin/mmdvm_f1.bin" ]]; then
  echo ">> Building firmware..."
  [[ -d "$FW_SRC/.git" ]] || git clone https://github.com/juribeparada/MMDVM_HS "$FW_SRC"
  cd "$FW_SRC"; git submodule update --init
  sed -i 's/^#define LIBRE_KIT_ADF7021/#define MMDVM_HS_HAT_REV12/' Config.h || true
  sed -i 's/^#define ZUMSPOT_ADF7021/#define MMDVM_HS_HAT_REV12/'  Config.h || true
  sed -i 's/^#define STM32_USB_HOST/#define STM32_USART1_HOST/'    Config.h || true
  make -j"$(nproc)"
fi
FWBIN="$FW_SRC/bin/mmdvm_f1.bin"
[[ -f "$FWBIN" ]] || { echo "ERROR: no firmware binary at $FWBIN" >&2; exit 1; }

systemctl stop pocsag 2>/dev/null || true
echo ">> Entering bootloader (BOOT0 high + reset)..."
pinctrl set "$BOOT0" op dh
pinctrl set "$NRST" op dl; sleep 1; pinctrl set "$NRST" ip; sleep 1
if ! stm32flash "$PORT" 2>&1 | grep -q "Device ID"; then
  echo "ERROR: bootloader did not respond." >&2
  echo "  - Did you reboot after the installer? (needed so $PORT is on GPIO)" >&2
  echo "  - Is the hat firmly seated on all 40 pins?" >&2
  pinctrl set "$BOOT0" op dl
  exit 1
fi
echo ">> Writing firmware..."
stm32flash -v -w "$FWBIN" "$PORT"
pinctrl set "$BOOT0" op dl
pinctrl set "$NRST" op dl; sleep 1; pinctrl set "$NRST" ip
echo ">> Done. Starting service..."
systemctl start pocsag 2>/dev/null || true
echo ">> Check: journalctl -u pocsag -n 20"
EOF
chmod 0755 /usr/local/bin/hs-flash

# Optionally pre-build the firmware now (compiling is safe before reboot).
if [[ "$DO_FLASH" =~ ^[Yy] ]]; then
  echo ">> Pre-building firmware (flash happens later via 'sudo hs-flash')..."
  if [[ -d "$FW_SRC/.git" ]]; then git -C "$FW_SRC" pull --ff-only || true; else
    rm -rf "$FW_SRC"; git clone https://github.com/juribeparada/MMDVM_HS "$FW_SRC"; fi
  cd "$FW_SRC"
  git submodule update --init
  sed -i 's/^#define LIBRE_KIT_ADF7021/#define MMDVM_HS_HAT_REV12/' Config.h || true
  sed -i 's/^#define ZUMSPOT_ADF7021/#define MMDVM_HS_HAT_REV12/'  Config.h || true
  sed -i 's/^#define STM32_USB_HOST/#define STM32_USART1_HOST/'    Config.h || true
  make -j"$(nproc)" || echo "WARNING: firmware build failed; you can retry later with 'sudo hs-flash'."
  FLASH_REMINDER=yes
else
  echo ">> Firmware flash not requested (hat keeps its existing firmware)."
  FLASH_REMINDER=no
fi

# ---------------------------------------------------------------------------
# 7. CONFIG FILE  (POCSAG only, 115200, Remote Control on, MQTT defaults)
# ---------------------------------------------------------------------------
echo ">> [7/10] Writing $CFG_DIR/MMDVM.ini ..."
mkdir -p "$CFG_DIR" "$LOG_DIR"
chown "$SVC_USER:$SVC_USER" "$LOG_DIR"
cat > "$CFG_DIR/MMDVM.ini" <<EOF
[General]
Callsign=$CALLSIGN
Id=1
Timeout=180
Duplex=0
Display=None
Daemon=0

[Info]
RXFrequency=$FREQ
TXFrequency=$FREQ
Power=1
Location=Local
Description=POCSAG

[Log]
DisplayLevel=2
FileLevel=1
FilePath=$LOG_DIR
FileRoot=MMDVM
FileRotate=1

[CW Id]
Enable=0

[Modem]
Protocol=uart
UARTPort=$PORT
UARTSpeed=$BAUD
TXInvert=1
RXInvert=0
PTTInvert=0
TXDelay=100
RXOffset=0
TXOffset=0
RXLevel=50
TXLevel=50
RFLevel=100
POCSAGTXLevel=50
RXDCOffset=0
TXDCOffset=0
Trace=0
Debug=0

[D-Star]
Enable=0
[DMR]
Enable=0
[System Fusion]
Enable=0
[P25]
Enable=0
[NXDN]
Enable=0
[M17]
Enable=0
[FM]
Enable=0
[AX.25]
Enable=0

[POCSAG]
Enable=1
Frequency=$FREQ

[D-Star Network]
Enable=0
[DMR Network]
Enable=0
[System Fusion Network]
Enable=0
[P25 Network]
Enable=0
[NXDN Network]
Enable=0
[M17 Network]
Enable=0
[POCSAG Network]
Enable=0
[AX.25 Network]
Enable=0

[Remote Control]
Enable=1
Port=$REMOTE_PORT
EOF
chown "$SVC_USER:$SVC_USER" "$CFG_DIR/MMDVM.ini"

# ---------------------------------------------------------------------------
# 8. hs-reset HELPER + SYSTEMD SERVICE
# ---------------------------------------------------------------------------
echo ">> [8/10] Installing hs-reset helper and systemd service..."
# Cheap HS_Hat clones have no pull-down on BOOT0, so after a cold boot the pin
# floats and the STM32 may not start its firmware. This drives BOOT0 low and
# resets the board into run mode before MMDVMHost opens the port.
cat > /usr/local/bin/hs-reset <<EOF
#!/usr/bin/env bash
# Put the MMDVM_HS_Hat into run mode (BOOT0 low) and reset it.
pinctrl set $BOOT0_GPIO op dl
pinctrl set $NRST_GPIO  op dl
sleep 1
pinctrl set $NRST_GPIO  ip
sleep 2
EOF
chmod 0755 /usr/local/bin/hs-reset

cat > /etc/systemd/system/pocsag.service <<EOF
[Unit]
Description=MMDVMHost POCSAG pager transmitter
After=network.target mosquitto.service
Wants=mosquitto.service

[Service]
User=$SVC_USER
Group=$SVC_USER
# '+' runs hs-reset as root so pinctrl may drive the GPIO pins.
ExecStartPre=+/usr/local/bin/hs-reset
ExecStart=/usr/local/bin/MMDVMHost $CFG_DIR/MMDVM.ini
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable pocsag.service

# ---------------------------------------------------------------------------
# 9. sendpage  (publishes a page over MQTT to MMDVMHost)
# ---------------------------------------------------------------------------
echo ">> [9/10] Installing 'sendpage'..."
cat > /usr/local/bin/sendpage <<EOF
#!/usr/bin/env bash
# sendpage <RIC> "message"  - transmit a local POCSAG page over RF.
set -euo pipefail
TOPIC="$MQTT_TOPIC"
EOF
cat >> /usr/local/bin/sendpage <<'EOF'
RIC="${1:?usage: sendpage <RIC> \"message\"}"
shift
MSG="$*"
[[ -z "$MSG" ]] && { echo 'usage: sendpage <RIC> "message"' >&2; exit 1; }
# Keep pages <= 80 chars; longer ones can wedge the modem.
if (( ${#MSG} > 80 )); then
  echo "WARNING: message ${#MSG} chars, truncating to 80." >&2
  MSG="${MSG:0:80}"
fi
mosquitto_pub -h 127.0.0.1 -t "$TOPIC" -m "page $RIC $MSG"
echo "sent: page $RIC $MSG"
EOF
chmod 0755 /usr/local/bin/sendpage

# ---------------------------------------------------------------------------
# 10. OPTIONAL: OLED STATUS DISPLAY  (0.96" SSD1306 on the I2C bus)
# ---------------------------------------------------------------------------
# A small Python daemon drives the screen. It is intentionally SEPARATE from
# MMDVMHost (which stays Display=None) so nothing needs to be recompiled with
# OLED support: the daemon owns the I2C bus alone, and learns about pages by
# subscribing to the local MQTT command topic (the same 'page <RIC> <msg>'
# that sendpage and the remote GUI publish).
if [[ "$DO_OLED" =~ ^[Yy] ]]; then
  echo ">> [10/10] Installing OLED status display support..."

  # I2C tooling + an isolated Python venv. The dev libs/fonts cover the case
  # where Pillow has to build from source on a minimal Lite image.
  apt-get install -y -qq \
    i2c-tools python3-venv python3-pip python3-dev fonts-dejavu-core \
    libjpeg-dev zlib1g-dev libfreetype6-dev

  # Enable the I2C bus (GPIO2=SDA pin3, GPIO3=SCL pin5).
  # IMPORTANT: 'dtparam=i2c_arm=on' alone only enables the controller; it does
  # NOT create the /dev/i2c-1 node - that comes from the i2c-dev kernel module.
  # raspi-config's do_i2c does BOTH (sets dtparam AND makes i2c-dev load at
  # boot), so the display is reachable straight after this script's reboot.
  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_i2c 0     # 0 = enable
  else
    grep -q '^dtparam=i2c_arm=on' "$BOOT/config.txt" || echo 'dtparam=i2c_arm=on' >> "$BOOT/config.txt"
  fi
  # Belt-and-suspenders: load i2c-dev now and on every boot regardless of the
  # above, so /dev/i2c-1 is guaranteed to appear.
  echo i2c-dev > /etc/modules-load.d/i2c-dev.conf
  modprobe i2c-dev 2>/dev/null || true

  # Let the service user reach /dev/i2c-1 (group may not exist yet on Lite).
  getent group i2c >/dev/null || groupadd --system i2c
  usermod -aG i2c "$SVC_USER" 2>/dev/null || true

  # Python venv with the display + MQTT libraries.
  install -d "$OLED_DIR"
  python3 -m venv "$OLED_VENV"
  "$OLED_VENV/bin/pip" install --quiet --upgrade pip
  "$OLED_VENV/bin/pip" install --quiet "luma.oled" "paho-mqtt"

  # The daemon itself (idle: callsign/IP/freq; on a page: TX POCSAG + RIC).
  cat > "$OLED_DIR/oled-status.py" <<'PYEOF'
#!/usr/bin/env python3
"""
oled-status.py - drive the MMDVM_HS_Hat 0.96" SSD1306 OLED.

Idle screen : callsign, IP address, frequency.
On TX       : shows "TX POCSAG" + RIC for a few seconds whenever a page is sent.

It learns about transmissions by subscribing to the local MQTT command topic
(the same 'page <RIC> <msg>' messages that sendpage and the GUI publish), so it
needs no extra wiring into MMDVMHost. Keep MMDVMHost's own OLED support OFF
(Display=None in MMDVM.ini) so that only this process owns the I2C bus.

Settings come from environment variables (set by the systemd unit), defaults:
    OLED_MQTT_HOST 127.0.0.1   OLED_MQTT_PORT 1883   OLED_MQTT_TOPIC mmdvm/command
    OLED_I2C_PORT 1   OLED_I2C_ADDR 0x3C   OLED_HEIGHT 64   OLED_ROTATE 0
    OLED_CALLSIGN ""  OLED_FREQ "" (Hz)   OLED_TX_HOLD 6 (seconds)
Confirm the address with `i2cdetect -y 1` (usually 0x3C, sometimes 0x3D).
"""
import os
import socket
import subprocess
import threading
import time

import paho.mqtt.client as mqtt
from luma.core.interface.serial import i2c
from luma.core.render import canvas
from luma.oled.device import ssd1306
from PIL import ImageFont


def _env(name, default):
    return os.environ.get(name, default)


MQTT_HOST  = _env("OLED_MQTT_HOST", "127.0.0.1")
MQTT_PORT  = int(_env("OLED_MQTT_PORT", "1883"))
MQTT_TOPIC = _env("OLED_MQTT_TOPIC", "mmdvm/command")
I2C_PORT   = int(_env("OLED_I2C_PORT", "1"))
I2C_ADDR   = int(_env("OLED_I2C_ADDR", "0x3C"), 16)
HEIGHT     = int(_env("OLED_HEIGHT", "64"))
ROTATE     = int(_env("OLED_ROTATE", "0"))
CALLSIGN   = _env("OLED_CALLSIGN", "").strip() or "POCSAG"
FREQ_HZ    = _env("OLED_FREQ", "").strip()
TX_HOLD    = float(_env("OLED_TX_HOLD", "6"))

_lock = threading.Lock()
_tx_until = 0.0
_tx_mode = ""
_tx_ric = ""


def freq_text():
    try:
        return f"{int(FREQ_HZ) / 1_000_000:.4f} MHz"
    except (ValueError, TypeError):
        return ""


def get_ip():
    """Best-effort primary LAN IP without actually sending packets."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("192.0.2.1", 9))   # TEST-NET-1; just picks the route
            return s.getsockname()[0]
        finally:
            s.close()
    except OSError:
        pass
    try:
        out = subprocess.check_output(["hostname", "-I"], text=True).split()
        return out[0] if out else "no IP"
    except Exception:
        return "no IP"


def load_font(size, bold=False):
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    try:
        return ImageFont.truetype(f"/usr/share/fonts/truetype/dejavu/{name}", size)
    except OSError:
        return ImageFont.load_default()


def set_tx(mode, ric):
    global _tx_until, _tx_mode, _tx_ric
    with _lock:
        _tx_mode = mode
        _tx_ric = ric
        _tx_until = time.monotonic() + TX_HOLD


def on_connect(client, userdata, flags, rc, *args):
    client.subscribe(MQTT_TOPIC)


def on_message(client, userdata, msg):
    try:
        payload = msg.payload.decode("utf-8", "replace").strip()
    except Exception:
        return
    parts = payload.split(maxsplit=2)
    if len(parts) >= 2 and parts[0].lower() == "page":
        set_tx("POCSAG", parts[1])


def mqtt_thread():
    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)  # paho-mqtt 2.x
    except (AttributeError, TypeError):
        client = mqtt.Client()                                  # paho-mqtt 1.x
    client.on_connect = on_connect
    client.on_message = on_message
    while True:
        try:
            client.connect(MQTT_HOST, MQTT_PORT, keepalive=30)
            client.loop_forever()
        except Exception:
            time.sleep(5)   # broker not up yet, or connection dropped: retry


def main():
    serial = i2c(port=I2C_PORT, address=I2C_ADDR)
    device = ssd1306(serial, width=128, height=HEIGHT, rotate=ROTATE)

    f_small = load_font(11)
    f_med   = load_font(14, bold=True)
    f_big   = load_font(26, bold=True)

    threading.Thread(target=mqtt_thread, daemon=True).start()

    ip = get_ip()
    last_ip = time.monotonic()
    fq = freq_text()

    while True:
        now = time.monotonic()
        if now - last_ip > 10:
            ip = get_ip()
            last_ip = now

        with _lock:
            txing = now < _tx_until
            mode = _tx_mode
            ric = _tx_ric

        with canvas(device) as draw:
            if txing:
                draw.text((4, 2), "TX", font=f_big, fill=255)
                draw.text((54, 6), mode, font=f_med, fill=255)
                draw.text((54, 28), f"RIC {ric}", font=f_small, fill=255)
                draw.rectangle((0, HEIGHT - 3, 127, HEIGHT - 1), fill=255)
            else:
                draw.text((0, 0), CALLSIGN, font=f_med, fill=255)
                draw.line((0, 18, 127, 18), fill=255)
                draw.text((0, 24), "IP " + ip, font=f_small, fill=255)
                if fq:
                    draw.text((0, 40), fq, font=f_small, fill=255)

        time.sleep(0.4)


if __name__ == "__main__":
    main()
PYEOF
  chmod 0755 "$OLED_DIR/oled-status.py"

  # systemd unit. Callsign / frequency / MQTT come straight from this install.
  cat > /etc/systemd/system/oled.service <<EOF
[Unit]
Description=MMDVM_HS_Hat OLED status display
After=network.target mosquitto.service
Wants=mosquitto.service

[Service]
User=$SVC_USER
Group=$SVC_USER
SupplementaryGroups=i2c
Environment=OLED_CALLSIGN=$CALLSIGN
Environment=OLED_FREQ=$FREQ
Environment=OLED_MQTT_HOST=127.0.0.1
Environment=OLED_MQTT_PORT=$MQTT_LOCAL_PORT
Environment=OLED_MQTT_TOPIC=$MQTT_TOPIC
# Adjust if i2cdetect shows a different address, a 128x32 panel,
# or the panel is mounted upside down:
#Environment=OLED_I2C_ADDR=0x3C
#Environment=OLED_HEIGHT=64
#Environment=OLED_ROTATE=0
ExecStart=$OLED_VENV/bin/python $OLED_DIR/oled-status.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable oled.service
  OLED_REMINDER=yes
else
  echo ">> [10/10] OLED display support not requested (skipping)."
  OLED_REMINDER=no
fi

# ---------------------------------------------------------------------------
echo
echo "=============================================================="
echo " Done. Summary of what happens after the reboot:"
echo "=============================================================="
echo " The pocsag service starts automatically and resets the hat."
echo " Check it:    systemctl status pocsag --no-pager"
echo "              journalctl -u pocsag -n 20"
echo "   (look for 'MMDVM protocol version' and 'POCSAG RF Parameters')"
echo
echo " Send a page: sendpage $TEST_RIC \"hello world\""
echo
echo " Remote clients (workstation GUI) connect with MQTT login:"
echo "     host: <this Pi's IP>   port: $MQTT_NET_PORT"
echo "     user: $MQTT_USER       pass: $MQTT_PASS"
echo
echo " Set your pager to: $FREQ Hz, RIC $TEST_RIC, 1200 baud, POCSAG."
if [[ "${OLED_REMINDER:-no}" == "yes" ]]; then
echo
echo " OLED: after the reboot the display starts on its own. If it stays blank,"
echo " confirm the panel is detected:  i2cdetect -y 1   (expect 3c, sometimes 3d)."
echo " Wrong address / upside-down / 128x32 panel? Edit the commented"
echo " Environment= lines in /etc/systemd/system/oled.service, then:"
echo "     sudo systemctl daemon-reload && sudo systemctl restart oled"
fi
if [[ "${FLASH_REMINDER:-no}" == "yes" ]]; then
echo
echo " BLANK HAT? The firmware was built but NOT flashed (the GPIO UART only"
echo " goes live after a reboot). So AFTER you reboot, if the hat is blank"
echo " (only PWR lit, no blinking LED), flash it with:"
echo "     sudo hs-flash"
fi
echo "=============================================================="
echo
echo " The GPIO UART (and I2C, if OLED) only take effect after a reboot,"
echo " so this Pi will now restart to finish the setup."
echo
echo " Rebooting in 10 seconds...  press Ctrl-C to cancel and reboot later."
for i in $(seq 10 -1 1); do
  printf "\r   %2d ... " "$i"
  sleep 1
done
printf "\r   rebooting now.   \n"
reboot
