#!/usr/bin/env bash
#
# 04 - Sign a new application image with the MCUboot key held in Vault
#
# Signs an (unsigned) application image using Vault's Transit engine - the
# private key is exercised inside Vault, never read from disk. Uses imgtool's
# external-signing flow:
#   1. imgtool --vector-to-sign digest   -> export the image digest
#   2. vault transit sign (prehashed)    -> ECDSA-P256 signature
#   3. imgtool --fix-sig                  -> bake the signature into the image
#   4. imgtool verify                     -> confirm it validates
# Then optionally merges the signed app onto the reusable bootloader_only.hex
# from 02-build-initial.sh to produce a full flashable image - no rebuild.
#
# Required (provided by earlier scripts):
#   * Vault running with the 'mcuboot' key   (01-vault-setup.sh)
#   * an unsigned app image                   (02-build-initial.sh, or --input)
#
# Options:
#   --input HEX|BIN   Unsigned app image.   Default: ${OUT_DIR}/app_unsigned.hex
#   --version X.Y.Z+B App image version.    Default: ${APP_VERSION_DEFAULT}
#   --output HEX      Signed app output.    Default: ${OUT_DIR}/signed-by-vault-app.hex
#   --no-merge        Do not merge onto the bootloader image
#   --bootloader HEX  Bootloader image to merge onto. Default: ${OUT_DIR}/bootloader_only.hex

set -euo pipefail
SCRIPT_NAME="04-sign-app"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

INPUT_IMAGE="${OUT_DIR}/app_unsigned.hex"
APP_VERSION="${APP_VERSION_DEFAULT}"
OUTPUT_IMAGE="${OUT_DIR}/signed-by-vault-app.hex"
BOOTLOADER_HEX="${OUT_DIR}/bootloader_only.hex"
DO_MERGE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --input)      INPUT_IMAGE="${2:?--input needs a value}"; shift 2 ;;
        --version)    APP_VERSION="${2:?--version needs a value}"; shift 2 ;;
        --output)     OUTPUT_IMAGE="${2:?--output needs a value}"; shift 2 ;;
        --bootloader) BOOTLOADER_HEX="${2:?--bootloader needs a value}"; shift 2 ;;
        --no-merge)   DO_MERGE=0; shift ;;
        -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
        *)            err "unknown argument: $1 (see --help)" ;;
    esac
done

# --- Preconditions -----------------------------------------------------------

require_python_imgtool
require_vault_env   # requires VAULT_ADDR/VAULT_TOKEN in the environment

[ -f "${INPUT_IMAGE}" ] || err \
"unsigned app image not found: ${INPUT_IMAGE}
       Build it first with ./02-build-initial.sh, or pass --input <hex|bin>."

mkdir -p "${OUT_DIR}"
WORK_DIR="$(mktemp -d)"; trap 'rm -rf "${WORK_DIR}"' EXIT
DIGEST_BIN="${WORK_DIR}/digest.bin"
PUBKEY_PEM="${WORK_DIR}/mcuboot_pub.pem"
SIG_B64="${WORK_DIR}/sig.b64"

COMMON_ARGS=(
    sign
    --version "${APP_VERSION}"
    --slot-size "${SLOT_SIZE}"
    --header-size "${HEADER_SIZE}"
    --pad-header
    --align "${ALIGN}"
)

# --- 0. Public key for the mcuboot transit key -------------------------------

log "Fetching '${MCUBOOT_KEY_NAME}' public key from Vault"
vault read -format=json "${VAULT_TRANSIT_MOUNT}/keys/${MCUBOOT_KEY_NAME}" \
    | jq -r '.data.keys | to_entries | max_by(.key|tonumber) | .value.public_key' > "${PUBKEY_PEM}"
grep -q "BEGIN PUBLIC KEY" "${PUBKEY_PEM}" || err \
"could not read public key for '${MCUBOOT_KEY_NAME}' from Vault. Did 01-vault-setup.sh run?"

# --- 1. Export the digest ----------------------------------------------------

log "Exporting image digest (imgtool --vector-to-sign digest)"
"${PYTHON}" "${IMGTOOL}" "${COMMON_ARGS[@]}" \
    -k "${PUBKEY_PEM}" --vector-to-sign digest \
    "${INPUT_IMAGE}" "${DIGEST_BIN}"
[ -s "${DIGEST_BIN}" ] || err "imgtool produced an empty digest"

# --- 2. Sign with Vault ------------------------------------------------------

DIGEST_B64="$(base64 < "${DIGEST_BIN}" | tr -d '\n')"
log "Signing digest with Vault Transit (ecdsa-p256, prehashed sha2-256)"
VAULT_SIG="$(vault write -format=json "${VAULT_TRANSIT_MOUNT}/sign/${MCUBOOT_KEY_NAME}" \
        input="${DIGEST_B64}" prehashed=true hash_algorithm=sha2-256 \
        marshaling_algorithm=asn1 | jq -r '.data.signature')"
[ -n "${VAULT_SIG}" ] && [ "${VAULT_SIG}" != "null" ] || err "Vault returned no signature"
printf '%s' "${VAULT_SIG#vault:v*:}" > "${SIG_B64}"

# --- 3. Bake the signature in ------------------------------------------------

log "Embedding Vault signature -> ${OUTPUT_IMAGE}"
"${PYTHON}" "${IMGTOOL}" "${COMMON_ARGS[@]}" \
    --fix-sig "${SIG_B64}" --fix-sig-pubkey "${PUBKEY_PEM}" \
    "${INPUT_IMAGE}" "${OUTPUT_IMAGE}"
[ -s "${OUTPUT_IMAGE}" ] || err "signed image was not produced"

# --- 4. Verify ---------------------------------------------------------------

log "Verifying signature against the Vault public key"
"${PYTHON}" "${IMGTOOL}" verify -k "${PUBKEY_PEM}" "${OUTPUT_IMAGE}" >&2 \
    || err "signature verification FAILED"
ok "Signed app: ${OUTPUT_IMAGE}"

# --- 5. Merge onto the bootloader (optional) ---------------------------------

if [ "${DO_MERGE}" -eq 1 ]; then
    if [ ! -f "${BOOTLOADER_HEX}" ]; then
        warn "bootloader image not found (${BOOTLOADER_HEX}); skipping merge."
        warn "Run ./02-build-initial.sh, or pass --no-merge to silence this."
        exit 0
    fi
    case "${OUTPUT_IMAGE}" in
        *.hex) ;;
        *) warn "merge needs a .hex signed app (got ${OUTPUT_IMAGE}); skipping merge."; exit 0 ;;
    esac
    require_file "${MERGEHEX}" "mergehex.py"
    FULL_HEX="${OUT_DIR}/full-with-vault-app.hex"
    log "Merging bootloader + signed app -> ${FULL_HEX}"
    "${PYTHON}" "${MERGEHEX}" -o "${FULL_HEX}" "${BOOTLOADER_HEX}" "${OUTPUT_IMAGE}"
    ok "Full flashable image: ${FULL_HEX}"
fi
