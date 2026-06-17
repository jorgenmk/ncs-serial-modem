#!/usr/bin/env bash
#
# Shared configuration and helpers for the Vault-backed signing workflow.
# Sourced by 01-vault-setup.sh, 02-build-initial.sh, 03-build-mcuboot.sh and
# 04-sign-app.sh. Not meant to be run directly.
#
# Override any of the variables below by exporting them before calling a script.

# --- Paths -------------------------------------------------------------------

SIGN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${APP_DIR:-$(cd "${SIGN_DIR}/../.." && pwd)}"
NCS_DIR="${NCS_DIR:-$(cd "${APP_DIR}/../.." && pwd)}"

BOARD="${BOARD:-nrf9151dk/nrf9151/ns}"

PYTHON="${PYTHON:-/Users/jokv/.defaultpyenv/bin/python3}"
IMGTOOL="${IMGTOOL:-${NCS_DIR}/bootloader/mcuboot/scripts/imgtool.py}"
MERGEHEX="${MERGEHEX:-${NCS_DIR}/zephyr/scripts/build/mergehex.py}"

# NSIB / B0 standalone bootloader scripts (used by the post-build signing flow).
HASH_PY="${HASH_PY:-${NCS_DIR}/nrf/scripts/bootloader/hash.py}"
VALIDATION_DATA_PY="${VALIDATION_DATA_PY:-${NCS_DIR}/nrf/scripts/bootloader/validation_data.py}"
PROVISION_PY="${PROVISION_PY:-${NCS_DIR}/nrf/scripts/bootloader/provision.py}"
GENERATE_ZIP_PY="${GENERATE_ZIP_PY:-${NCS_DIR}/nrf/scripts/bootloader/generate_zip.py}"

# Build directories (kept separate so a bootloader rebuild can't clobber the
# reference initial build).
BUILD_DIR="${BUILD_DIR:-${APP_DIR}/build}"                       # initial full build (script 02)
MCUBOOT_BUILD_DIR="${MCUBOOT_BUILD_DIR:-${APP_DIR}/build-mcuboot}" # bootloader rebuild (script 03)

# Outputs and key material.
KEYS_DIR="${KEYS_DIR:-${APP_DIR}/signing-keys}"   # exported public PEMs
OUT_DIR="${OUT_DIR:-${APP_DIR}/signing-out}"      # bootloader_only.hex, signed apps, merged images

# Build/sign separation directories:
UNSIGNED_DIR="${UNSIGNED_DIR:-${OUT_DIR}/unsigned}"   # build-unsigned.sh output (CI artifact bundle)
RELEASE_DIR="${RELEASE_DIR:-${OUT_DIR}/release}"      # sign-release.sh output (signed images)
FOTA_DIR="${FOTA_DIR:-${OUT_DIR}/fota}"               # package-app-fota.sh output (dfu_application.zip)
MANIFEST_FILE_NAME="manifest.env"                      # signing parameters captured at build time

# --- Signing parameters (must match across build and re-signing) -------------

SLOT_SIZE="${SLOT_SIZE:-0x6f000}"
HEADER_SIZE="${HEADER_SIZE:-0x200}"
ALIGN="${ALIGN:-4}"
APP_VERSION_DEFAULT="${APP_VERSION_DEFAULT:-1.99.0+0}"
MCUBOOT_VERSION_DEFAULT="${MCUBOOT_VERSION_DEFAULT:-0.0.0+0}"

# --- Vault key names ---------------------------------------------------------

VAULT_TRANSIT_MOUNT="${VAULT_TRANSIT_MOUNT:-transit}"
# 4 NSIB / B0 keys (index 0 is the initial signing key; 1..3 are rotation/revocation reserves).
NSIB_KEY_NAMES=(nsib_0 nsib_1 nsib_2 nsib_3)
# 1 MCUboot key (verifies / signs the application image).
MCUBOOT_KEY_NAME="${MCUBOOT_KEY_NAME:-mcuboot}"

# Exported PEM paths derived from a Vault key name.
nsib_priv_pem() { echo "${KEYS_DIR}/$1_priv.pem"; }
nsib_pub_pem()  { echo "${KEYS_DIR}/$1_pub.pem"; }
mcuboot_priv_pem() { echo "${KEYS_DIR}/${MCUBOOT_KEY_NAME}_priv.pem"; }
mcuboot_pub_pem()  { echo "${KEYS_DIR}/${MCUBOOT_KEY_NAME}_pub.pem"; }

# --- Output formatting -------------------------------------------------------

_c_red='\033[31m'; _c_grn='\033[32m'; _c_yel='\033[33m'; _c_cya='\033[36m'; _c_rst='\033[0m'
log()  { printf "${_c_cya}[%s]${_c_rst} %s\n" "${SCRIPT_NAME:-signing}" "$*" >&2; }
ok()   { printf "${_c_grn}[%s] %s${_c_rst}\n" "${SCRIPT_NAME:-signing}" "$*" >&2; }
warn() { printf "${_c_yel}[%s] warning:${_c_rst} %s\n" "${SCRIPT_NAME:-signing}" "$*" >&2; }
err()  { printf "${_c_red}[%s] error:${_c_rst} %s\n" "${SCRIPT_NAME:-signing}" "$*" >&2; exit 1; }

# --- Common precondition checks ---------------------------------------------

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || err "required command '$1' not found in PATH. $2"
}

require_file() {
    [ -f "$1" ] || err "${2:-required file} not found: $1"
}

require_python_imgtool() {
    { [ -x "${PYTHON}" ] || command -v "${PYTHON}" >/dev/null 2>&1; } \
        || err "python interpreter not found: ${PYTHON} (set PYTHON=...)"
    require_file "${IMGTOOL}" "imgtool.py"
}

# Require VAULT_ADDR / VAULT_TOKEN in the environment and confirm the Vault is
# reachable, unsealed, and the token is valid. Used by every script that talks
# to Vault (01, 04, sign-release, vault-sign-nsib).
require_vault_env() {
    require_cmd vault "Install the Vault CLI (or an API-compatible one)."
    require_cmd jq "Install jq."
    [ -n "${VAULT_ADDR:-}" ] || err \
"VAULT_ADDR is not set. Point it at your Vault, e.g.:
       export VAULT_ADDR=\"https://vault.example.com\""
    [ -n "${VAULT_TOKEN:-}" ] || err "VAULT_TOKEN is not set. Export your Vault token."
    export VAULT_ADDR VAULT_TOKEN
    vault status >/dev/null 2>&1 || err "Vault at ${VAULT_ADDR} is not reachable or is sealed."
    vault token lookup >/dev/null 2>&1 || err "VAULT_TOKEN is not valid for ${VAULT_ADDR}."
}

# Verify the PUBLIC key PEMs the build needs are present (private keys are
# optional - only used for the non-secure EXPORT_PRIVATE_KEYS=1 fallback).
require_exported_keys() {
    local missing=()
    for k in "${NSIB_KEY_NAMES[@]}"; do
        [ -f "$(nsib_pub_pem "$k")" ] || missing+=("$(nsib_pub_pem "$k")")
    done
    [ -f "$(mcuboot_pub_pem)" ] || missing+=("$(mcuboot_pub_pem)")
    if [ "${#missing[@]}" -gt 0 ]; then
        err "public key PEMs are missing:
       $(printf '%s\n       ' "${missing[@]}")
       Run 01-vault-setup.sh to (re)create and export the keys."
    fi
}

VAULT_SIGN_NSIB="${VAULT_SIGN_NSIB:-${SIGN_DIR}/vault-sign-nsib.sh}"

# Assemble the signing-key Kconfig -D arguments into the global KCONFIG_ARGS
# array, adapting to what 01-vault-setup.sh exported:
#   * NSIB private key present  -> sign in-build with the PEM (Python signer)
#   * NSIB private key absent    -> sign via Vault (SECURE_BOOT_SIGNING_CUSTOM)
#   * MCUboot private key present-> build signs the app with the PEM
#   * MCUboot private key absent -> bake the public key, build app UNSIGNED
#                                   (it is signed later by 04-sign-app.sh/Vault)
# Arg 1: NSIB signing key index (0..3), default 0.
build_kconfig_args() {
    local sign_idx="${1:-0}"
    local sign_name="${NSIB_KEY_NAMES[${sign_idx}]}"
    KCONFIG_ARGS=()

    # --- NSIB key list (revocation set): all NSIB pubs except the signing key.
    local pub_list=""
    local i
    for i in "${!NSIB_KEY_NAMES[@]}"; do
        [ "$i" -eq "${sign_idx}" ] && continue
        pub_list="${pub_list:+${pub_list},}$(nsib_pub_pem "${NSIB_KEY_NAMES[$i]}")"
    done
    KCONFIG_ARGS+=( "-DSB_CONFIG_SECURE_BOOT_PUBLIC_KEY_FILES=\"${pub_list}\"" )

    # --- NSIB signing: PEM (Python) or Vault (custom command).
    if [ -f "$(nsib_priv_pem "${sign_name}")" ]; then
        KEY_MODE_NSIB="export (PEM: $(nsib_priv_pem "${sign_name}"))"
        KCONFIG_ARGS+=( "-DSB_CONFIG_SECURE_BOOT_SIGNING_KEY_FILE=\"$(nsib_priv_pem "${sign_name}")\"" )
    else
        KEY_MODE_NSIB="vault (transit key: ${sign_name})"
        KCONFIG_ARGS+=(
            "-DSB_CONFIG_SECURE_BOOT_SIGNING_CUSTOM=y"
            "-DSB_CONFIG_SECURE_BOOT_SIGNING_COMMAND=\"${VAULT_SIGN_NSIB} ${sign_name}\""
            "-DSB_CONFIG_SECURE_BOOT_SIGNING_PUBLIC_KEY=\"$(nsib_pub_pem "${sign_name}")\""
        )
    fi

    # --- MCUboot app key: sign in-build (PEM) or bake pubkey + unsigned app.
    if [ -f "$(mcuboot_priv_pem)" ]; then
        KEY_MODE_APP="export (PEM: $(mcuboot_priv_pem))"
        KCONFIG_ARGS+=( "-DSB_CONFIG_BOOT_SIGNATURE_KEY_FILE=\"$(mcuboot_priv_pem)\"" )
    else
        KEY_MODE_APP="vault (pubkey baked, app built unsigned, signed by 04-sign-app.sh)"
        KCONFIG_ARGS+=(
            "-DSB_CONFIG_BOOT_SIGNATURE_KEY_FILE=\"$(mcuboot_pub_pem)\""
            # Build the application image unsigned; Vault signs it afterwards.
            # 'app' is the main application image name (see build/domains.yaml).
            "-Dapp_CONFIG_MCUBOOT_GENERATE_UNSIGNED_IMAGE=y"
        )
    fi
}
