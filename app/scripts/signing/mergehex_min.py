#!/usr/bin/env python3
#
# Copyright (c) 2026 Nordic Semiconductor ASA
#
# SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
#
# Minimal stand-in for zephyr/scripts/build/mergehex.py, for signing
# environments that don't have a full NCS/zephyr checkout (only `pip install
# intelhex`). Implements just the subset the signing scripts use:
#
#     mergehex_min.py -o OUTPUT IN1 IN2 [IN3 ...]
#
# Merges non-overlapping Intel HEX files (b0 / provisioning / MCUboot / app).
# Point the signing scripts at it with MERGEHEX=/path/to/mergehex_min.py.

import argparse
from intelhex import IntelHex

ap = argparse.ArgumentParser(description="Merge non-overlapping Intel HEX files.")
ap.add_argument("-o", "--output", required=True, help="Output .hex file")
ap.add_argument("files", nargs="+", help="Input .hex files")
args = ap.parse_args()

merged = IntelHex()
for f in args.files:
    merged.merge(IntelHex(f), overlap="error")
merged.write_hex_file(args.output)
