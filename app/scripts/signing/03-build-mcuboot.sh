#!/usr/bin/env bash
#
# 03 - Build a new MCUboot (bootloader) image
#
# Rebuilds the bootloader in a SEPARATE build directory so the initial build is
# left intact, then collects the artifacts used for a bootloader update:
#   * signed_by_b0_mcuboot.hex / _s1_variant.hex          (flash to inactive slot)
#   * signed_by_mcuboot_and_b0_mcuboot.bin / _s1_variant  (FOTA, double-signed)
#
# Use this to ship a bootloader update: bump the version, optionally rotate the
# NSIB signing key (to revoke a lower-index NSIB key) and/or bake a different
# MCUboot app key (to rotate/revoke the app key).
#
# Required:
#   --version X.Y.Z+B     MCUboot/B0 version. MUST be higher than what is
#                         currently deployed, or B0 keeps booting the old image.
#
# Options:
#   --nsib-sign-index N   Which NSIB key (0..3) signs MCUboot. Default 0.
#                         Signing with a higher index revokes all lower NSIB
#                         keys on the device once it boots.
#   --app-key PEM         Override the MCUboot app-verification key to bake in.
#                         Default: the mcuboot key from 01-vault-setup.sh.
#   --build-dir DIR       Default: ${MCUBOOT_BUILD_DIR}
#   --print-only          Print the west command and exit.
#   --                    Pass remaining args straight to west build.

set -euo pipefail
SCRIPT_NAME="03-build-mcuboot"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MCUBOOT_VERSION=""
NSIB_SIGN_INDEX=0
APP_KEY=""          # empty => auto (Vault pubkey or exported PEM); set to override
PRINT_ONLY=0
EXTRA_WEST_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --version)         MCUBOOT_VERSION="${2:?--version needs a value}"; shift 2 ;;
        --nsib-sign-index) NSIB_SIGN_INDEX="${2:?--nsib-sign-index needs a value}"; shift 2 ;;
        --app-key)         APP_KEY="${2:?--app-key needs a value}"; shift 2 ;;
        --build-dir)       MCUBOOT_BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
        --print-only)      PRINT_ONLY=1; shift ;;
        --)                shift; EXTRA_WEST_ARGS=("$@"); break ;;
        -h|--help)         sed -n '2,30p' "$0"; exit 0 ;;
        *)                 err "unknown argument: $1 (see --help)" ;;
    esac
done

# --- Validate inputs ---------------------------------------------------------

[ -n "${MCUBOOT_VERSION}" ] || err \
"--version is required.
       It MUST be higher than the currently deployed bootloader version,
       otherwise B0 will refuse the update (anti-rollback). Example:
         ./03-build-mcuboot.sh --version 0.0.1+0"

case "${NSIB_SIGN_INDEX}" in
    0|1|2|3) ;;
    *) err "--nsib-sign-index must be 0..3 (got '${NSIB_SIGN_INDEX}')" ;;
esac

require_cmd west "Activate your NCS environment first."
require_exported_keys
[ -n "${APP_KEY}" ] && [ ! -f "${APP_KEY}" ] && err "--app-key file not found: ${APP_KEY}"

# Assemble the signing-key Kconfig args for the chosen NSIB signing index
# (adapts to exported keys / Vault mode).
build_kconfig_args "${NSIB_SIGN_INDEX}"

# Honour an explicit --app-key override (replace the baked app-key arg).
if [ -n "${APP_KEY}" ]; then
    KCONFIG_ARGS=( "${KCONFIG_ARGS[@]/-DSB_CONFIG_BOOT_SIGNATURE_KEY_FILE=*/-DSB_CONFIG_BOOT_SIGNATURE_KEY_FILE=\"${APP_KEY}\"}" )
    KEY_MODE_APP="override (${APP_KEY})"
fi

WEST_CMD=(
    west build
    --board "${BOARD}"
    --build-dir "${MCUBOOT_BUILD_DIR}"
    --pristine
    --sysbuild
    "${APP_DIR}"
    --
    "${KCONFIG_ARGS[@]}"
    "-DSB_CONFIG_SECURE_BOOT_MCUBOOT_VERSION=\"${MCUBOOT_VERSION}\""
)
[ "${#EXTRA_WEST_ARGS[@]}" -gt 0 ] && WEST_CMD+=("${EXTRA_WEST_ARGS[@]}")

log "MCUboot/B0 version    : ${MCUBOOT_VERSION}"
log "NSIB signing          : index ${NSIB_SIGN_INDEX} -> ${KEY_MODE_NSIB}"
[ "${NSIB_SIGN_INDEX}" -ne 0 ] && warn \
"signing with NSIB index ${NSIB_SIGN_INDEX} will REVOKE NSIB keys 0..$((NSIB_SIGN_INDEX-1)) on first boot."
log "MCUboot app key       : ${KEY_MODE_APP}"
printf '%s ' "${WEST_CMD[@]}" >&2; echo >&2

if [ "${PRINT_ONLY}" -eq 1 ]; then
    ok "--print-only set: not building."
    exit 0
fi

log "Building MCUboot (this takes a few minutes)..."
"${WEST_CMD[@]}"

# --- Collect bootloader-update artifacts -------------------------------------

mkdir -p "${OUT_DIR}"
DEST="${OUT_DIR}/mcuboot-${MCUBOOT_VERSION}"
mkdir -p "${DEST}"

declare -a ARTIFACTS=(
    signed_by_b0_mcuboot.hex
    signed_by_b0_mcuboot_s1_variant.hex
    signed_by_mcuboot_and_b0_mcuboot.bin
    signed_by_mcuboot_and_b0_mcuboot_s1_variant.bin
)
for a in "${ARTIFACTS[@]}"; do
    require_file "${MCUBOOT_BUILD_DIR}/${a}" "bootloader artifact"
    cp "${MCUBOOT_BUILD_DIR}/${a}" "${DEST}/"
done

ok "New MCUboot built -> ${DEST}"
log "Flash to inactive slot (debugger):"
log "    S0:  ${DEST}/signed_by_b0_mcuboot.hex"
log "    S1:  ${DEST}/signed_by_b0_mcuboot_s1_variant.hex"
log "FOTA (host both, device picks its inactive slot via the dual locator):"
log "    \"<host>/signed_by_mcuboot_and_b0_mcuboot.bin <host>/signed_by_mcuboot_and_b0_mcuboot_s1_variant.bin\""
log "Remember: S0 path FIRST, S1 path SECOND, separated by a single space."
