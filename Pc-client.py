#!/usr/bin/env python3
"""
POCSAG pager client (MQTT, authenticated) with a small GUI.

  * Pager device IP field   (the Raspberry Pi running the hotspot)
  * RIC (pager address) field
  * Message box
  * Send button   -> publishes 'page <RIC> <message>' to the Pi's MQTT broker,
                     logging in with a username + password
  * Save settings -> stores IP / port / user / RIC in a config file

Config file:  ~/.pager_client.json   (the password is NOT stored on disk)

Defaults match the installer:
    port 1884, user 'mqtt', password 'AutoPassword'

Requirements (install once on your workstation):
    pip install paho-mqtt
    # tkinter ships with Python on Windows/macOS; on Linux: sudo apt install python3-tk
"""
import json
import os
import tkinter as tk
from tkinter import messagebox

import paho.mqtt.publish as publish

CONFIG_PATH = os.path.join(os.path.expanduser("~"), ".pager_client.json")
DEFAULTS = {
    "host": "192.168.1.120",     # Raspberry Pi IP
    "port": 1884,                # authenticated network listener
    "topic": "mmdvm/command",    # topic MMDVMHost listens on
    "user": "mqtt",              # MQTT username
    "ric": "1234567",            # last-used pager RIC
}
DEFAULT_PASS = "Password"    # pre-filled password (matches the installer)


def load_config():
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG_PATH) as f:
            cfg.update(json.load(f))
    except (OSError, ValueError):
        pass
    return cfg


def save_config(cfg):
    # Only persist non-secret fields.
    data = {k: cfg[k] for k in ("host", "port", "topic", "user", "ric") if k in cfg}
    try:
        with open(CONFIG_PATH, "w") as f:
            json.dump(data, f, indent=2)
        return True
    except OSError as e:
        messagebox.showwarning("Config", f"Could not save config:\n{e}")
        return False


class PagerApp:
    def __init__(self, root):
        self.cfg = load_config()
        root.title("POCSAG Pager")
        root.resizable(False, False)
        pad = {"padx": 8, "pady": 4}

        tk.Label(root, text="Pager device IP:").grid(row=0, column=0, sticky="e", **pad)
        self.host = tk.Entry(root, width=26)
        self.host.insert(0, self.cfg["host"])
        self.host.grid(row=0, column=1, **pad)

        tk.Label(root, text="Port:").grid(row=1, column=0, sticky="e", **pad)
        self.port = tk.Entry(root, width=26)
        self.port.insert(0, str(self.cfg["port"]))
        self.port.grid(row=1, column=1, **pad)

        tk.Label(root, text="Username:").grid(row=2, column=0, sticky="e", **pad)
        self.user = tk.Entry(root, width=26)
        self.user.insert(0, self.cfg["user"])
        self.user.grid(row=2, column=1, **pad)

        tk.Label(root, text="Password:").grid(row=3, column=0, sticky="e", **pad)
        self.pw = tk.Entry(root, width=26, show="*")
        self.pw.insert(0, DEFAULT_PASS)
        self.pw.grid(row=3, column=1, **pad)

        tk.Label(root, text="RIC (address):").grid(row=4, column=0, sticky="e", **pad)
        self.ric = tk.Entry(root, width=26)
        self.ric.insert(0, self.cfg["ric"])
        self.ric.grid(row=4, column=1, **pad)

        tk.Label(root, text="Message:").grid(row=5, column=0, sticky="ne", **pad)
        self.msg = tk.Text(root, width=32, height=4)
        self.msg.grid(row=5, column=1, **pad)

        btns = tk.Frame(root)
        btns.grid(row=6, column=0, columnspan=2, pady=8)
        tk.Button(btns, text="Save settings", command=self.save).pack(side="left", padx=6)
        tk.Button(btns, text="Send", width=10, command=self.send).pack(side="left", padx=6)

        self.status = tk.Label(root, text="", fg="gray")
        self.status.grid(row=7, column=0, columnspan=2, pady=(0, 8))

    def _set_status(self, text, color="gray"):
        self.status.config(text=text, fg=color)

    def _collect(self):
        self.cfg["host"] = self.host.get().strip()
        self.cfg["user"] = self.user.get().strip()
        self.cfg["ric"] = self.ric.get().strip()
        try:
            self.cfg["port"] = int(self.port.get().strip())
        except ValueError:
            self.cfg["port"] = DEFAULTS["port"]

    def save(self):
        self._collect()
        if save_config(self.cfg):
            self._set_status("Settings saved (password not stored).", "green")

    def send(self):
        self._collect()
        host = self.cfg["host"]
        user = self.cfg["user"]
        pw = self.pw.get()
        ric = self.cfg["ric"]
        text = self.msg.get("1.0", "end").strip()

        if not host:
            self._set_status("Set the pager device IP.", "red"); return
        if not ric.isdigit():
            self._set_status("RIC must be numeric.", "red"); return
        if not text:
            self._set_status("Message is empty.", "red"); return
        if len(text) > 80:
            text = text[:80]
            self._set_status("Message trimmed to 80 chars.", "orange")

        payload = f"page {ric} {text}"
        auth = {"username": user, "password": pw} if user else None
        try:
            publish.single(
                self.cfg["topic"],
                payload=payload,
                hostname=host,
                port=self.cfg["port"],
                auth=auth,
                keepalive=5,
            )
        except Exception as e:
            self._set_status(f"Send failed: {e}", "red")
            return

        save_config(self.cfg)
        self._set_status(f"Sent to {ric}.", "green")


def main():
    root = tk.Tk()
    PagerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
