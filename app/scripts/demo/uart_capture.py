#!/usr/bin/env python3
#
# Copyright (c) 2026 Nordic Semiconductor ASA
#
# SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
#
# Capture and pretty-print bootloader/app UART output for the secure-boot demo.
# Opens the serial port (the nRF9151DK console is VCOM1 @ 1,000,000 baud),
# optionally resets the device, then streams lines for a fixed duration with
# colored / prefixed highlighting of the interesting secure-boot lines.
#
#   python3 uart_capture.py --port /dev/cu.usbmodemXXXX1 --reset-serial 1051209525
#
# Requires pyserial (uses IOSSIOSPEED on macOS for the non-standard 1 Mbaud,
# which `stty` cannot set).

import argparse
import re
import subprocess
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("error: pyserial is required (pip install pyserial)")

C = {
    "reset": "\033[0m", "dim": "\033[2m", "bold": "\033[1m",
    "red": "\033[31m", "grn": "\033[32m", "yel": "\033[33m", "cya": "\033[36m",
}

# Lowercased substrings -> highlight colour for that device log line.
RED = ("didn't match", "validation failed", "unable to find bootable",
       "not valid", "failed to validate", "image in the primary slot is not valid")
YEL = ("invalidating key",)
GRN = ("signature verified", "verifying signature against key", "hash verified",
       "jumping to the first image")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def colour_for(line):
    low = line.lower()
    if any(k in low for k in RED):
        return C["red"]
    if any(k in low for k in YEL):
        return C["yel"] + C["bold"]
    if any(k in low for k in GRN):
        return C["grn"]
    if line.startswith("***"):
        return C["cya"]
    return C["dim"]


def emit(line):
    line = ANSI.sub("", line).rstrip("\r")
    if not line:
        return
    print(f"  {C['dim']}┃{C['reset']} {colour_for(line)}{line}{C['reset']}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=1000000)
    ap.add_argument("--seconds", type=float, default=8.0)
    ap.add_argument("--reset-serial", default=None, help="nrfutil device serial to reset after opening the port")
    ap.add_argument("--save", default=None, help="also write raw bytes here")
    a = ap.parse_args()

    s = serial.Serial(a.port, a.baud, timeout=0.1)
    s.reset_input_buffer()
    if a.reset_serial:
        subprocess.run(
            ["nrfutil", "device", "reset", "--serial-number", a.reset_serial, "--reset-kind", "RESET_SYSTEM"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    raw, buf = b"", b""
    end = time.time() + a.seconds
    while time.time() < end:
        d = s.read(4096)
        if not d:
            continue
        raw += d
        buf += d
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            emit(line.decode("utf-8", "replace"))
    if buf:
        emit(buf.decode("utf-8", "replace"))
    s.close()
    if a.save:
        with open(a.save, "wb") as f:
            f.write(raw)


if __name__ == "__main__":
    main()
