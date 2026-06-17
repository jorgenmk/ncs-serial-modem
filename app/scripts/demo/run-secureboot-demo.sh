#!/usr/bin/env bash
#
# Copyright (c) 2026 Nordic Semiconductor ASA
#
# SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
#
# Secure-boot demo runner (host side). Drives an attached nRF9151DK through the
# secure-boot test case using artifacts from the "Secure boot demo" workflow.
#
#   Step 1  Acquire the signed artifacts (download a GitHub run, or use a dir).
#   Step 2  Flash the BASE (good) image - provisions UICR and boots.
#   Step 3  Capture and print the boot logs (full trusted chain boots).
#   Step 4  Flash an untrusted APP -> rejected by MCUboot (app-key trust).
#   Step 5  Flash an untrusted MCUboot -> rejected by B0 (bootloader-key trust).
#   Step 6  Restore the trusted MCUboot + app -> boots again (nothing revoked).
#   Step 7  Flash a MCUboot signed by key 1 -> B0 revokes key 0, still boots.
#   Step 8  Re-flash the key-0 MCUboot -> now blocked (key 0 is revoked).
#
# Steps 4-8 touch only the MCUboot slots and/or app slot (touched-ranges erase),
# leaving B0 and the UICR key provisioning intact.
#
# Artifacts are expected as <dir>/signed-<variant>/release/... (the layout
# `gh run download` produces from the workflow's signed-<variant> artifacts).
#
# Usage:
#   ./run-secureboot-demo.sh --run-id <id> [--repo owner/name]
#   ./run-secureboot-demo.sh --artifacts-dir <dir>     # use already-downloaded
# Options:
#   --serial <SN>        nrfutil device serial      (default: autodetect)
#   --port <dev>         console serial port        (default: autodetect VCOM1)
#   --baud <n>           console baud               (default: 1000000)
#   --pause              wait for Enter between steps (nice for a live demo)

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUN_ID=""; REPO=""; ARTIFACTS_DIR=""; SERIAL=""; PORT=""; BAUD=1000000; PAUSE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --run-id)        RUN_ID="${2:?}"; shift 2 ;;
        --repo)          REPO="${2:?}"; shift 2 ;;
        --artifacts-dir) ARTIFACTS_DIR="${2:?}"; shift 2 ;;
        --serial)        SERIAL="${2:?}"; shift 2 ;;
        --port)          PORT="${2:?}"; shift 2 ;;
        --baud)          BAUD="${2:?}"; shift 2 ;;
        --pause)         PAUSE=1; shift ;;
        -h|--help)       sed -n '2,40p' "$0"; exit 0 ;;
        *)               echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# --- pretty output -----------------------------------------------------------

c_rst=$'\033[0m'; c_b=$'\033[1m'; c_dim=$'\033[2m'
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cya=$'\033[36m'; c_mag=$'\033[35m'

step() { printf '\n%s%s━━━ %s ━━━%s\n' "$c_b" "$c_cya" "$*" "$c_rst"; }
info() { printf '%s•%s %s\n' "$c_mag" "$c_rst" "$*"; }
ok()   { printf '%s✓ %s%s\n' "$c_grn" "$*" "$c_rst"; }
bad()  { printf '%s✗ %s%s\n' "$c_red" "$*" "$c_rst"; }
die()  { printf '%s✗ error:%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }
pause(){ [ "$PAUSE" -eq 1 ] && { printf '%s   …press Enter to continue%s' "$c_dim" "$c_rst"; read -r _; } || true; }

command -v nrfutil >/dev/null || die "nrfutil not found"
python3 -c "import serial" 2>/dev/null || die "pyserial not found (pip install pyserial)"

# --- autodetect device + console port ---------------------------------------

if [ -z "$SERIAL" ]; then
    SERIAL="$(nrfutil device list 2>/dev/null | grep -oE '^[0-9]{8,}' | head -1)"
    [ -n "$SERIAL" ] || die "no device found; pass --serial"
fi
if [ -z "$PORT" ]; then
    # The nRF9151DK console is VCOM1 (the second serial port).
    PORT="$(nrfutil device list 2>/dev/null | grep -oE '/dev/tty[^,]*, vcom: 1' | grep -oE '/dev/tty[^,]*' | head -1)"
    PORT="${PORT/tty./cu.}"   # use cu.* for reading on macOS
    [ -n "$PORT" ] || die "could not autodetect console port; pass --port"
fi
info "device serial : ${c_b}${SERIAL}${c_rst}"
info "console port  : ${c_b}${PORT}${c_rst} @ ${BAUD} baud"

CAPFILE="$(mktemp)"
capture() { # capture <seconds> <reset?>
    local secs="$1" reset="${2:-yes}"
    local args=(--port "$PORT" --baud "$BAUD" --seconds "$secs" --save "$CAPFILE")
    [ "$reset" = "yes" ] && args+=(--reset-serial "$SERIAL")
    python3 "${SELF_DIR}/uart_capture.py" "${args[@]}"
}
captured() { LC_ALL=C grep -qiE "$1" "$CAPFILE" 2>/dev/null; }   # captured <regex>?

# Program a variant's MCUboot into S0 + S1 only (touched-ranges erase), leaving
# B0, the UICR key provisioning and the app slot untouched.
flash_mcuboot() { # flash_mcuboot <release-dir> <label>
    local dir="$1" label="$2"
    info "writing ${c_b}${label}${c_rst} MCUboot -> slots S0 + S1 (touched-ranges erase; B0/UICR/app untouched)"
    nrfutil device program --firmware "${dir}/signed_by_b0_mcuboot.hex" --serial-number "$SERIAL" \
        --options chip_erase_mode=ERASE_RANGES_TOUCHED_BY_FIRMWARE >/dev/null
    nrfutil device program --firmware "${dir}/signed_by_b0_mcuboot_s1_variant.hex" --serial-number "$SERIAL" \
        --options chip_erase_mode=ERASE_RANGES_TOUCHED_BY_FIRMWARE >/dev/null
}

# Program a variant's application into the app slot only (touched-ranges erase),
# leaving B0, UICR and MCUboot untouched.
flash_app() { # flash_app <release-dir> <label>
    local dir="$1" label="$2"
    info "writing ${c_b}${label}${c_rst} application -> app slot (touched-ranges erase; bootloaders untouched)"
    nrfutil device program --firmware "${dir}/app_signed.hex" --serial-number "$SERIAL" \
        --options chip_erase_mode=ERASE_RANGES_TOUCHED_BY_FIRMWARE >/dev/null
}

# --- Step 1: acquire artifacts ----------------------------------------------

step "STEP 1  Acquire signed artifacts"
if [ -n "$RUN_ID" ]; then
    command -v gh >/dev/null || die "gh not found (needed for --run-id)"
    ARTIFACTS_DIR="$(mktemp -d)/artifacts"
    repo_arg=(); [ -n "$REPO" ] && repo_arg=(-R "$REPO")
    info "downloading artifacts from run ${c_b}${RUN_ID}${c_rst}${REPO:+ (${REPO})}"
    gh run download "$RUN_ID" "${repo_arg[@]}" --dir "$ARTIFACTS_DIR"
elif [ -n "$ARTIFACTS_DIR" ]; then
    info "using local artifacts: ${c_b}${ARTIFACTS_DIR}${c_rst}"
else
    die "provide --run-id <id> or --artifacts-dir <dir>"
fi

GOOD_DIR="${ARTIFACTS_DIR}/signed-good/release"
BAD_DIR="${ARTIFACTS_DIR}/signed-bad-keys/release"
REVOKE_DIR="${ARTIFACTS_DIR}/signed-revoke-key0/release"
GOOD_FULL="${GOOD_DIR}/full.hex"
for f in "$GOOD_FULL" \
         "${GOOD_DIR}/app_signed.hex" \
         "${BAD_DIR}/signed_by_b0_mcuboot.hex" \
         "${BAD_DIR}/app_signed.hex" \
         "${REVOKE_DIR}/signed_by_b0_mcuboot.hex"; do
    [ -f "$f" ] || die "expected artifact missing: $f"
done
ok "artifacts ready (good / bad-keys / revoke-key0)"
pause

# --- Step 2: flash the base (good) image ------------------------------------

step "STEP 2  Flash BASE image (trusted keys) - provisions the device"
info "recovering (clears AP-protect, full erase)"
nrfutil device recover --serial-number "$SERIAL" >/dev/null 2>&1 || true
info "programming ${c_b}$(basename "$GOOD_FULL")${c_rst} (ERASE_ALL - writes B0, UICR keys, MCUboot, app)"
nrfutil device program --firmware "$GOOD_FULL" --serial-number "$SERIAL" \
    --options chip_erase_mode=ERASE_ALL >/dev/null
ok "base image flashed"
pause

# --- Step 3: capture boot logs ----------------------------------------------

step "STEP 3  Boot the BASE image and capture logs"
info "resetting and capturing console (expect B0: 'Verifying signature against key 0' -> 'Firmware signature verified')"
capture 8 yes
if captured "Firmware signature verified" && captured "Booting Serial Modem"; then
    ok "VERDICT: base image verified by B0 (key 0) and booted to the app"
else
    bad "VERDICT: base image did not boot as expected"
fi
pause

# --- Step 4: untrusted application - rejected by MCUboot --------------------

step "STEP 4  Program UNTRUSTED APP (signed by an untrusted key) - expect MCUboot rejection"
flash_app "$BAD_DIR" "bad-key (untrusted)"
info "resetting (B0 still trusts MCUboot, but MCUboot must reject the app:"
info "  'Image in the primary slot is not valid' -> 'Unable to find bootable image')"
capture 8 yes
if captured "primary slot is not valid" || captured "Unable to find bootable image"; then
    ok "VERDICT: untrusted app REJECTED by MCUboot - B0+MCUboot boot, the app is refused"
else
    bad "VERDICT: untrusted app was NOT rejected - unexpected!"
fi
pause

# --- Step 5: untrusted MCUboot - rejected by B0 -----------------------------

step "STEP 5  Program UNTRUSTED MCUboot (signed by an untrusted key) - expect B0 rejection"
flash_mcuboot "$BAD_DIR" "bad-key (untrusted)"
info "resetting (expect B0 to REJECT: 'Public key didn't match' for every key)"
capture 8 yes
if captured "No bootable image found" || captured "Failed to validate signature"; then
    ok "VERDICT: bad-key MCUboot REJECTED by B0 - refuses to boot (no key was revoked)"
else
    bad "VERDICT: bad-key MCUboot was NOT rejected - unexpected!"
fi
pause

# --- Step 6: restore the trusted chain - proves nothing was revoked ---------

step "STEP 6  Restore the trusted chain (MCUboot + app) - it must boot again"
flash_mcuboot "$GOOD_DIR" "good (key 0)"
flash_app "$GOOD_DIR" "good (key 0)"
info "resetting (the untrusted rejections must NOT have revoked any trusted key)"
capture 8 yes
if captured "Firmware signature verified" && captured "Booting Serial Modem"; then
    ok "VERDICT: trusted chain boots again - the untrusted rejections revoked nothing"
else
    bad "VERDICT: trusted chain did not boot - unexpected!"
fi
pause

# --- Step 7: flash image signed by the NEXT key - triggers revocation -------

step "STEP 7  Flash MCUboot signed by key 1 - triggers revocation of key 0"
flash_mcuboot "$REVOKE_DIR" "revoke-key0 (key 1)"
info "resetting (expect B0 to validate against key 1 and 'Invalidating key 0')"
capture 8 yes
if captured "Invalidating key 0" && captured "Firmware signature verified"; then
    ok "VERDICT: image boots AND B0 permanently revoked key 0"
else
    bad "VERDICT: key-1 image did not boot / did not revoke key 0 - unexpected!"
fi
pause

# --- Step 8: back to the first image - now blocked by revocation ------------

step "STEP 8  Re-flash the GOOD (key 0) MCUboot - now blocked by revocation"
flash_mcuboot "$GOOD_DIR" "good (key 0)"
info "resetting (key 0 is revoked, so B0 must skip it and reject the image)"
capture 8 yes
if captured "Key 0 has been invalidated" && captured "No bootable image found"; then
    ok "VERDICT: good image now BLOCKED - key 0 is revoked, B0 refuses to boot it"
else
    bad "VERDICT: expected key-0-revocation block did not occur - unexpected!"
fi
rm -f "$CAPFILE"

printf '\n%s%s━━━ secure-boot demo complete ━━━%s\n' "$c_b" "$c_cya" "$c_rst"
info "note: key 0 is now permanently revoked on this device; a 'nrfutil device recover'"
info "      (done by STEP 2) erases UICR and restores all keys for the next run."
