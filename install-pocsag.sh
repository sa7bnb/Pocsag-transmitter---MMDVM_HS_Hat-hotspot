#!/usr/bin/env bash
#
# install-pocsag.sh  (v3 - complete)
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
#
# Target:   Raspberry Pi OS Lite (Bookworm / Trixie), Pi 3 / 4 / Zero 2.
# Hardware: MMDVM_HS_Hat (single ADF7021) on the 40-pin GPIO header.
#           BOOT0 = GPIO20, RESET = GPIO21 (standard HS_Hat wiring).
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

# MQTT broker setup. MMDVMHost connects locally & anonymously, so we keep an
# anonymous loopback listener for it, and add a SEPARATE authenticated network
# listener for remote workstation clients.
MQTT_LOCAL_PORT=1883           # loopback only, anonymous, used by MMDVMHost
MQTT_NET_PORT=1884             # network, requires login, used by remote clients
MQTT_USER=mqtt                 # remote client username
MQTT_PASS=Password         # remote client password
MQTT_PASSFILE=/etc/mosquitto/passwd

echo "=============================================================="
echo "   POCSAG pager transmitter - complete installer (v3)"
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
echo "About to install with:"
echo "   Callsign : $CALLSIGN"
echo "   Frequency: $FREQ Hz"
echo "   Modem    : $PORT @ $BAUD baud (MMDVM_HS_Hat on GPIO)"
echo "   Test RIC : $TEST_RIC"
echo "   Flash FW : $DO_FLASH"
read -rp "Proceed? [Y/n]: " GO
[[ "${GO:-Y}" =~ ^[Nn] ]] && { echo "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# 1. DEPENDENCIES
# ---------------------------------------------------------------------------
echo
echo ">> [1/9] Installing dependencies..."
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
echo ">> [2/9] Creating service user '$SVC_USER'..."
id "$SVC_USER" &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
usermod -aG dialout,gpio "$SVC_USER" 2>/dev/null || usermod -aG dialout "$SVC_USER"

# ---------------------------------------------------------------------------
# 3. FREE THE GPIO UART  (the single biggest gotcha)
# ---------------------------------------------------------------------------
echo ">> [3/9] Freeing the GPIO UART for the hat..."
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
echo ">> [4/9] Building MMDVMHost..."
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
echo ">> [5/9] Configuring mosquitto MQTT broker..."
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
# The password file must be owned by root (modern mosquitto warns and will
# eventually refuse to load a file the broker's own user could modify).
# mosquitto reads it at startup while still root, then drops privileges.
mosquitto_passwd -b -c "$MQTT_PASSFILE" "$MQTT_USER" "$MQTT_PASS"
chown root:root "$MQTT_PASSFILE"
chmod 600 "$MQTT_PASSFILE"

systemctl enable --now mosquitto
systemctl restart mosquitto

# ---------------------------------------------------------------------------
# 6. FIRMWARE: build (optional) + install the post-reboot 'hs-flash' helper
# ---------------------------------------------------------------------------
# IMPORTANT: flashing CANNOT happen in this run. Freeing the GPIO UART in step
# 3 only takes effect after a reboot, so /dev/ttyAMA0 is not yet wired to the
# hat right now. Flashing is therefore a SEPARATE post-reboot step: run
# 'sudo hs-flash' after rebooting, and only if the hat is actually blank.
echo ">> [6/9] Setting up firmware tooling..."

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
echo ">> [7/9] Writing $CFG_DIR/MMDVM.ini ..."
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
echo ">> [8/9] Installing hs-reset helper and systemd service..."
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
echo ">> [9/9] Installing 'sendpage'..."
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
echo
echo "=============================================================="
echo " Done."
echo "=============================================================="
echo " The GPIO UART was reconfigured, so REBOOT before first use:"
echo "     sudo reboot"
echo
echo " After reboot the service starts automatically and resets the hat."
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
if [[ "${FLASH_REMINDER:-no}" == "yes" ]]; then
echo
echo " BLANK HAT? The firmware was built but NOT flashed (the GPIO UART only"
echo " goes live after a reboot). So AFTER you reboot, if the hat is blank"
echo " (only PWR lit, no blinking LED), flash it with:"
echo "     sudo hs-flash"
fi
echo "=============================================================="
