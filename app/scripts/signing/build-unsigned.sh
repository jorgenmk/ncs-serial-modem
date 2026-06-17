#!/usr/bin/env bash
#
# build-unsigned.sh - CI / untrusted build stage
#
# Builds b0 + MCUboot + app and exports ONLY the unsigned artifacts plus a
# manifest of (non-secret) signing parameters. No production private key and no
# Vault are involved here - this can run in a public CI. The real MCUboot app
# PUBLIC key is baked in so MCUboot will later verify the Vault-signed app; the
# NSIB signature produced by this build uses a throwaway debug key and is
# discarded (sign-release.sh re-signs everything in the secure environment).
#
# Produces (under signing-out/unsigned/):
#   b0.hex                  immutable bootloader (key-agnostic)
#   mcuboot_s0.hex          unsigned MCUboot, S0 variant
#   mcuboot_s1.hex          unsigned MCUboot, S1 variant
#   app_unsigned.hex        unsigned TF-M + app merge
#   manifest.env            signing parameters captured from the build
#
# Options:
#   --version X.Y.Z+B    MCUboot/B0 version           (default: ${MCUBOOT_VERSION_DEFAULT})
#   --app-version X      app image version            (default: ${APP_VERSION_DEFAULT})
#   --build-dir DIR      build directory              (default: ${BUILD_DIR})
#   --use-existing       harvest from an existing build dir (skip west build)
#   --print-only         print the west command and exit

set -euo pipefail
SCRIPT_NAME="build-unsigned"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MCUBOOT_VERSION="${MCUBOOT_VERSION_DEFAULT}"
APP_VERSION="${APP_VERSION_DEFAULT}"
USE_EXISTING=0
PRINT_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --version)      MCUBOOT_VERSION="${2:?}"; shift 2 ;;
        --app-version)  APP_VERSION="${2:?}"; shift 2 ;;
        --build-dir)    BUILD_DIR="${2:?}"; shift 2 ;;
        --use-existing) USE_EXISTING=1; shift ;;
        --print-only)   PRINT_ONLY=1; shift ;;
        -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
        *)              err "unknown argument: $1 (see --help)" ;;
    esac
done

# The MCUboot app PUBLIC key must be present so it gets baked into MCUboot.
require_file "$(mcuboot_pub_pem)" \
    "MCUboot app public key ($(mcuboot_pub_pem)). Run 01-vault-setup.sh, or copy the public key here."

# --- Build (unless harvesting an existing build) -----------------------------

if [ "${USE_EXISTING}" -eq 0 ]; then
    require_cmd west "Activate your NCS environment first."
    # MCUBOOT_BAKE_PUBKEY (handled by APP_DIR/sysbuild.cmake) makes BOTH MCUboot
    # variants bake the real app-verification PUBLIC key, WITHOUT touching
    # SB_CONFIG_BOOT_SIGNATURE_KEY_FILE. So every in-build signing step (app,
    # bootloader-FOTA) still uses the default debug PRIVATE key and succeeds -
    # those signed outputs are discarded; we harvest the unsigned payloads. NSIB
    # also uses the debug key here (discarded; sign-release.sh regenerates
    # provisioning and re-signs MCUboot/app via Vault).
    MCUBOOT_PUB="$(mcuboot_pub_pem)"
    WEST_CMD=(
        west build --board "${BOARD}" --build-dir "${BUILD_DIR}" --pristine --sysbuild "${APP_DIR}"
        --
        "-DMCUBOOT_BAKE_PUBKEY=${MCUBOOT_PUB}"
        "-DSB_CONFIG_SECURE_BOOT_MCUBOOT_VERSION=\"${MCUBOOT_VERSION}\""
        # Enable B0/NSIB validation logging on the console (the demo's
        # "Verifying signature against key N" / "Invalidating key N" lines).
        # Minimal log mode + default level 0 keep every other b0 module silent.
        "-Db0_CONFIG_LOG=y"
        "-Db0_CONFIG_LOG_MODE_MINIMAL=y"
        "-Db0_CONFIG_LOG_DEFAULT_LEVEL=0"
        "-Db0_CONFIG_SECURE_BOOT_VALIDATION_LOG_LEVEL_INF=y"
    )
    log "Building unsigned artifacts (real app pubkey baked into MCUboot; debug keys discarded)..."
    printf '%s ' "${WEST_CMD[@]}" >&2; echo >&2
    [ "${PRINT_ONLY}" -eq 1 ] && { ok "--print-only set: not building."; exit 0; }
    "${WEST_CMD[@]}"

    # Self-check 1: the real app public key was baked into BOTH MCUboot variants.
    for img in mcuboot mcuboot_s1_variant; do
        cfg="${BUILD_DIR}/${img}/zephyr/.config"
        if [ -f "${cfg}" ] && ! grep -q "CONFIG_BOOT_SIGNATURE_KEY_FILE=\"${MCUBOOT_PUB}\"" "${cfg}"; then
            err "MCUboot image '${img}' did NOT bake ${MCUBOOT_PUB}
       (found: $(grep -E '^CONFIG_BOOT_SIGNATURE_KEY_FILE=' "${cfg}" || echo '<unset>')).
       SB_CONFIG_BOOT_SIGNATURE_KEY_FILE did not propagate. Aborting."
        fi
    done
    ok "Verified: MCUboot S0/S1 bake the real app pubkey (build's own signatures are discarded)."
else
    [ "${PRINT_ONLY}" -eq 1 ] && { ok "--use-existing + --print-only: nothing to do."; exit 0; }
    log "Harvesting from existing build dir: ${BUILD_DIR}"
fi

# --- Harvest unsigned binaries -----------------------------------------------

mkdir -p "${UNSIGNED_DIR}"
harvest() {  # harvest <src> <dst-name>
    require_file "$1" "unsigned build artifact for $2"
    cp "$1" "${UNSIGNED_DIR}/$2"
}
harvest "${BUILD_DIR}/b0/zephyr/zephyr.hex"                 "b0.hex"
harvest "${BUILD_DIR}/mcuboot/zephyr/zephyr.hex"            "mcuboot_s0.hex"
harvest "${BUILD_DIR}/mcuboot_s1_variant/zephyr/zephyr.hex" "mcuboot_s1.hex"
harvest "${BUILD_DIR}/app/zephyr/tfm_merged.hex"            "app_unsigned.hex"

# --- Capture signing parameters from build.ninja into the manifest -----------
# These are non-secret, board/config-derived values; we read them straight out
# of the build so the secure environment replays the exact same parameters.

NINJA="${BUILD_DIR}/build.ninja"
require_file "${NINJA}" "build.ninja (needed to capture signing parameters)"
field() {  # field <command-substr> <flag-name-without-dashes>  -> value after the flag
    grep -rhoE "$1[^&]*" "${NINJA}" 2>/dev/null | grep -oE "[-][-]$2 [^ ]+" | head -1 | awk '{print $2}'
}

MAGIC_VALUE="$(field 'validation_data\.py' 'magic-value')"
VAL_SKIP="$(field 'validation_data\.py' 'skip')"
VAL_OFFSET="$(field 'validation_data\.py' 'offset')"
PROV_S0_ADDR="$(field 'provision\.py' 's0-addr')"
PROV_S1_ADDR="$(field 'provision\.py' 's1-addr')"
PROV_ADDR="$(field 'provision\.py' 'provision-addr')"
PROV_MAX_SIZE="$(field 'provision\.py' 'max-size')"
PROV_COUNTER_SLOTS="$(field 'provision\.py' 'num-counter-slots-version')"
PROV_OTP_WIDTH="$(field 'provision\.py' 'otp-write-width')"
MCUBOOT_SLOT_SIZE="$(grep -rhoE 'imgtool\.py sign[^&]*rom-fixed[^&]*' "${NINJA}" | grep -oE '[-][-]slot-size [^ ]+' | head -1 | awk '{print $2}')"

# Board/SoC split from BOARD (e.g. nrf9151dk/nrf9151/ns).
BOARD_NAME="$(echo "${BOARD}" | cut -d/ -f1)"
SOC_NAME="$(echo "${BOARD}" | cut -d/ -f2)"

# sdk-nrf revision this bundle was built against; the signing stage fetches its
# bootloader helper scripts at this exact revision so the formats match.
NCS_REVISION="$(git -C "${NCS_DIR}/nrf" rev-parse HEAD 2>/dev/null || true)"

cat > "${UNSIGNED_DIR}/${MANIFEST_FILE_NAME}" <<EOF
# Signing parameters captured by build-unsigned.sh - consumed by sign-release.sh.
# Non-secret, board/config-derived values. Safe to publish alongside artifacts.
BOARD_NAME="${BOARD_NAME}"
SOC_NAME="${SOC_NAME}"
NCS_REVISION="${NCS_REVISION}"

# NSIB (B0 signs MCUboot)
MAGIC_VALUE="${MAGIC_VALUE}"
VAL_SKIP="${VAL_SKIP:-0x200}"
VAL_OFFSET="${VAL_OFFSET:-0}"
MCUBOOT_VERSION="${MCUBOOT_VERSION}"
MCUBOOT_SLOT_SIZE="${MCUBOOT_SLOT_SIZE:-49152}"
MCUBOOT_HEADER_SIZE="${HEADER_SIZE}"
MCUBOOT_ALIGN="${ALIGN}"

# B0 provisioning (public key hash list)
PROV_S0_ADDR="${PROV_S0_ADDR:-0x8000}"
PROV_S1_ADDR="${PROV_S1_ADDR:-0x14000}"
PROV_ADDR="${PROV_ADDR}"
PROV_MAX_SIZE="${PROV_MAX_SIZE:-0x280}"
PROV_COUNTER_SLOTS="${PROV_COUNTER_SLOTS:-40}"
PROV_OTP_WIDTH="${PROV_OTP_WIDTH:-2}"

# Application (MCUboot signs the app); slot0 (primary app) is at 0x20000.
APP_VERSION="${APP_VERSION}"
APP_SLOT_SIZE="${SLOT_SIZE}"
APP_HEADER_SIZE="${HEADER_SIZE}"
APP_ALIGN="${ALIGN}"
APP_LOAD_ADDR="0x20000"
EOF

[ -n "${MAGIC_VALUE}" ] || err "could not capture --magic-value from build.ninja; build may be incomplete"

ok "Unsigned artifact bundle -> ${UNSIGNED_DIR}"
log "  $(cd "${UNSIGNED_DIR}" && ls -1 | tr '\n' ' ')"
log "Captured signing parameters in ${MANIFEST_FILE_NAME} (magic=${MAGIC_VALUE})"
log "Transfer ${UNSIGNED_DIR}/ to the secure environment and run sign-release.sh."
