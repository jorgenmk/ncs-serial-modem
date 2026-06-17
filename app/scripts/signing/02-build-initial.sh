#!/usr/bin/env bash
#
# 02 - Build the initial image (B0 + MCUboot + app)
#
# Runs a pristine sysbuild with the Vault-exported keys wired in via Kconfig:
#   * NSIB signing key   -> SB_CONFIG_SECURE_BOOT_SIGNING_KEY_FILE  (nsib_0)
#   * NSIB key list       -> SB_CONFIG_SECURE_BOOT_PUBLIC_KEY_FILES  (nsib_1,2,3)
#     (this is what provisions all 4 public keys into B0 for later revocation)
#   * MCUboot app key     -> SB_CONFIG_BOOT_SIGNATURE_KEY_FILE       (mcuboot)
#   * MCUboot version     -> SB_CONFIG_SECURE_BOOT_MCUBOOT_VERSION
#
# It then merges the bootloader pieces (b0 + signed MCUboot S0/S1 + provisioning)
# into a single 'bootloader_only.hex'. That image is the reusable base: a freshly
# signed app (04-sign-app.sh) is merged onto it to make a full flashable image,
# without rebuilding the bootloader.
#
# Required (provided by 01-vault-setup.sh): exported key PEMs in signing-keys/.
#
# Options:
#   --version X.Y.Z+B   MCUboot/B0 image version    (default: ${MCUBOOT_VERSION_DEFAULT})
#   --build-dir DIR     build directory             (default: ${BUILD_DIR})
#   --print-only        print the west command and exit (no build)
#   --                  pass any following args straight to west build

set -euo pipefail
SCRIPT_NAME="02-build-initial"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MCUBOOT_VERSION="${MCUBOOT_VERSION_DEFAULT}"
PRINT_ONLY=0
EXTRA_WEST_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --version)    MCUBOOT_VERSION="${2:?--version needs a value}"; shift 2 ;;
        --build-dir)  BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
        --print-only) PRINT_ONLY=1; shift ;;
        --)           shift; EXTRA_WEST_ARGS=("$@"); break ;;
        -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
        *)            err "unknown argument: $1 (see --help)" ;;
    esac
done

# --- Preconditions -----------------------------------------------------------

require_cmd west "Activate your NCS environment (e.g. 'source <ncs>/zephyr/zephyr-env.sh' or the nRF toolchain)."
require_exported_keys

# Assemble the signing-key Kconfig args (adapts to exported keys / Vault mode).
build_kconfig_args 0

WEST_CMD=(
    west build
    --board "${BOARD}"
    --build-dir "${BUILD_DIR}"
    --pristine
    --sysbuild
    "${APP_DIR}"
    --
    "${KCONFIG_ARGS[@]}"
    "-DSB_CONFIG_SECURE_BOOT_MCUBOOT_VERSION=\"${MCUBOOT_VERSION}\""
)
[ "${#EXTRA_WEST_ARGS[@]}" -gt 0 ] && WEST_CMD+=("${EXTRA_WEST_ARGS[@]}")

log "NSIB signing (idx 0) : ${KEY_MODE_NSIB}"
log "MCUboot app key      : ${KEY_MODE_APP}"
log "MCUboot/B0 version   : ${MCUBOOT_VERSION}"
printf '%s ' "${WEST_CMD[@]}" >&2; echo >&2

if [ "${PRINT_ONLY}" -eq 1 ]; then
    ok "--print-only set: not building."
    exit 0
fi

# --- Build -------------------------------------------------------------------

log "Building (this takes a few minutes)..."
"${WEST_CMD[@]}"

# --- Produce the reusable bootloader-only image ------------------------------

require_python_imgtool
require_file "${MERGEHEX}" "mergehex.py"

mkdir -p "${OUT_DIR}"
BOOTLOADER_HEX="${OUT_DIR}/bootloader_only.hex"

# Bootloader pieces, no application image.
PIECES=(
    "${BUILD_DIR}/b0/zephyr/zephyr.hex"
    "${BUILD_DIR}/signed_by_b0_mcuboot.hex"
    "${BUILD_DIR}/signed_by_b0_mcuboot_s1_variant.hex"
    "${BUILD_DIR}/app_provision.hex"
)
for p in "${PIECES[@]}"; do
    require_file "$p" "expected build artifact"
done

log "Merging bootloader-only image -> ${BOOTLOADER_HEX}"
"${PYTHON}" "${MERGEHEX}" -o "${BOOTLOADER_HEX}" "${PIECES[@]}"

# Stash the unsigned app payload so 04-sign-app.sh has a default input.
cp "${BUILD_DIR}/app/zephyr/tfm_merged.hex" "${OUT_DIR}/app_unsigned.hex"

ok "Initial build complete."
log "Full merged image     : ${BUILD_DIR}/merged.hex"
log "Bootloader-only image : ${BOOTLOADER_HEX}   (reuse for new signed apps)"
log "Unsigned app payload  : ${OUT_DIR}/app_unsigned.hex"
log "Next: ./04-sign-app.sh   (sign an app via Vault and merge onto the bootloader)"
