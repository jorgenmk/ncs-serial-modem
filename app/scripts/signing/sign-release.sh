#!/usr/bin/env bash
#
# sign-release.sh - secure signing environment, "sign all"
#
# Consumes the unsigned artifact bundle from build-unsigned.sh and signs every
# layer with keys held in Vault (private keys never on disk):
#   * B0 provisioning  : provision.py with the 4 NSIB PUBLIC keys
#   * MCUboot S0/S1     : hash -> Vault(nsib) -> validation_data  (B0 signs MCUboot)
#   * Application       : imgtool digest -> Vault(mcuboot) -> fix-sig
#
# Emits (under signing-out/release/):
#   bootloader_signed.hex   b0 + provisioning + B0-signed MCUboot S0/S1   <-- REUSABLE
#                           (merge a freshly signed app onto this, no rebuild;
#                            see 04-sign-app.sh --bootloader)
#   app_signed.hex / .bin   Vault-signed application image
#   full.hex                bootloader_signed.hex + app_signed.hex (flashable)
#   manifest.env            copied through for package-app-fota.sh
#
# Required:
#   * Vault running with the 5 keys     (01-vault-setup.sh)
#   * unsigned bundle + manifest.env    (build-unsigned.sh)  in ${UNSIGNED_DIR}
#
# Options:
#   --nsib-sign-index N   NSIB key (0..3) that signs MCUboot. Default 0.
#                         A higher index revokes lower NSIB keys on first boot.
#   --unsigned-dir DIR    Input bundle dir. Default: ${UNSIGNED_DIR}

set -euo pipefail
SCRIPT_NAME="sign-release"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

NSIB_SIGN_INDEX=0
while [ $# -gt 0 ]; do
    case "$1" in
        --nsib-sign-index) NSIB_SIGN_INDEX="${2:?}"; shift 2 ;;
        --unsigned-dir)    UNSIGNED_DIR="${2:?}"; shift 2 ;;
        -h|--help)         sed -n '2,32p' "$0"; exit 0 ;;
        *)                 err "unknown argument: $1 (see --help)" ;;
    esac
done
case "${NSIB_SIGN_INDEX}" in 0|1|2|3) ;; *) err "--nsib-sign-index must be 0..3" ;; esac

# --- Preconditions -----------------------------------------------------------

require_python_imgtool
require_file "${VALIDATION_DATA_PY}" "validation_data.py"
require_file "${HASH_PY}" "hash.py"
require_file "${PROVISION_PY}" "provision.py"
require_file "${MERGEHEX}" "mergehex.py"
require_vault_env
require_exported_keys

MANIFEST="${UNSIGNED_DIR}/${MANIFEST_FILE_NAME}"
[ -f "${MANIFEST}" ] || err \
"unsigned bundle not found: ${MANIFEST}
       Run build-unsigned.sh first, or pass --unsigned-dir <dir>."
# shellcheck disable=SC1090
. "${MANIFEST}"

U_B0="${UNSIGNED_DIR}/b0.hex"
U_S0="${UNSIGNED_DIR}/mcuboot_s0.hex"
U_S1="${UNSIGNED_DIR}/mcuboot_s1.hex"
U_APP="${UNSIGNED_DIR}/app_unsigned.hex"
for f in "${U_B0}" "${U_S0}" "${U_S1}" "${U_APP}"; do require_file "$f" "unsigned artifact"; done

NSIB_NAME="${NSIB_KEY_NAMES[${NSIB_SIGN_INDEX}]}"
NSIB_PUB="$(nsib_pub_pem "${NSIB_NAME}")"
mkdir -p "${RELEASE_DIR}"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

log "Signing release: NSIB=${NSIB_NAME} (idx ${NSIB_SIGN_INDEX}), MCUboot app key=${MCUBOOT_KEY_NAME}"

# --- 1. B0 provisioning data (all 4 NSIB public keys) ------------------------

# provision.py splits --public-key-files on commas (despite the help text).
PROV_PUBS=""
for k in "${NSIB_KEY_NAMES[@]}"; do
    PROV_PUBS="${PROV_PUBS:+${PROV_PUBS},}$(nsib_pub_pem "$k")"
done
PROVISION_HEX="${RELEASE_DIR}/provision.hex"
log "Generating B0 provisioning (provision.py) with ${#NSIB_KEY_NAMES[@]} public keys"
"${PYTHON}" "${PROVISION_PY}" \
    --s0-addr "${PROV_S0_ADDR}" --s1-addr "${PROV_S1_ADDR}" \
    --provision-addr "${PROV_ADDR}" \
    --public-key-files "${PROV_PUBS}" \
    --output "${PROVISION_HEX}" \
    --max-size "${PROV_MAX_SIZE}" \
    --num-counter-slots-version "${PROV_COUNTER_SLOTS}" \
    --otp-write-width "${PROV_OTP_WIDTH}"

# --- 2. B0 signs MCUboot (S0 + S1) via Vault ---------------------------------

sign_mcuboot_slot() {  # <unsigned-hex> <out-name>
    local in_hex="$1" out_name="$2"
    local sha="${WORK}/${out_name}.sha256" sig="${WORK}/${out_name}.signature"
    local out_hex="${RELEASE_DIR}/${out_name}.hex" out_bin="${RELEASE_DIR}/${out_name}.bin"

    log "  ${out_name}: hash -> Vault(${NSIB_NAME}) -> validation_data"
    "${PYTHON}" "${HASH_PY}" --in "${in_hex}" --skip "${VAL_SKIP}" > "${sha}"
    NSIB_SIG_FORMAT=raw PYTHON="${PYTHON}" "${VAULT_SIGN_NSIB}" "${NSIB_NAME}" "${sha}" > "${sig}"
    [ "$(wc -c < "${sig}" | tr -d ' ')" = "64" ] || err "expected 64-byte raw NSIB signature for ${out_name}"
    "${PYTHON}" "${VALIDATION_DATA_PY}" \
        --input "${in_hex}" --skip "${VAL_SKIP}" --offset "${VAL_OFFSET}" \
        --signature "${sig}" --public-key "${NSIB_PUB}" \
        --magic-value "${MAGIC_VALUE}" \
        --output-hex "${out_hex}" --output-bin "${out_bin}"
}
sign_mcuboot_slot "${U_S0}" "signed_by_b0_mcuboot"
sign_mcuboot_slot "${U_S1}" "signed_by_b0_mcuboot_s1_variant"

# --- 3. MCUboot signs the application via Vault ------------------------------

APP_PUB="${WORK}/mcuboot_pub.pem"
vault read -format=json "${VAULT_TRANSIT_MOUNT}/keys/${MCUBOOT_KEY_NAME}" \
    | jq -r '.data.keys | to_entries | max_by(.key|tonumber) | .value.public_key' > "${APP_PUB}"
grep -q "BEGIN PUBLIC KEY" "${APP_PUB}" || err "could not fetch mcuboot public key from Vault"

APP_ARGS=( sign --version "${APP_VERSION}" --slot-size "${APP_SLOT_SIZE}"
           --header-size "${APP_HEADER_SIZE}" --pad-header --align "${APP_ALIGN}" )
APP_DIGEST="${WORK}/app.digest"; APP_SIG="${WORK}/app.sig.b64"
APP_HEX="${RELEASE_DIR}/app_signed.hex"; APP_BIN="${RELEASE_DIR}/app_signed.bin"

log "  app: imgtool digest -> Vault(${MCUBOOT_KEY_NAME}) -> fix-sig"
"${PYTHON}" "${IMGTOOL}" "${APP_ARGS[@]}" -k "${APP_PUB}" --vector-to-sign digest "${U_APP}" "${APP_DIGEST}"
APP_DIGEST_B64="$(base64 < "${APP_DIGEST}" | tr -d '\n')"
APP_VAULT_SIG="$(vault write -format=json "${VAULT_TRANSIT_MOUNT}/sign/${MCUBOOT_KEY_NAME}" \
        input="${APP_DIGEST_B64}" prehashed=true hash_algorithm=sha2-256 \
        marshaling_algorithm=asn1 | jq -r '.data.signature')"
[ -n "${APP_VAULT_SIG}" ] && [ "${APP_VAULT_SIG}" != "null" ] || err "Vault returned no app signature"
printf '%s' "${APP_VAULT_SIG#vault:v*:}" > "${APP_SIG}"
"${PYTHON}" "${IMGTOOL}" "${APP_ARGS[@]}" --fix-sig "${APP_SIG}" --fix-sig-pubkey "${APP_PUB}" "${U_APP}" "${APP_HEX}"
"${PYTHON}" "${IMGTOOL}" "${APP_ARGS[@]}" --fix-sig "${APP_SIG}" --fix-sig-pubkey "${APP_PUB}" "${U_APP}" "${APP_BIN}"
"${PYTHON}" "${IMGTOOL}" verify -k "${APP_PUB}" "${APP_HEX}" >/dev/null || err "app signature verification FAILED"

# --- 4. Merge: reusable bootloader, then full image --------------------------

BOOTLOADER_HEX="${RELEASE_DIR}/bootloader_signed.hex"
FULL_HEX="${RELEASE_DIR}/full.hex"
log "Merging reusable bootloader image -> ${BOOTLOADER_HEX}"
"${PYTHON}" "${MERGEHEX}" -o "${BOOTLOADER_HEX}" \
    "${U_B0}" "${PROVISION_HEX}" \
    "${RELEASE_DIR}/signed_by_b0_mcuboot.hex" \
    "${RELEASE_DIR}/signed_by_b0_mcuboot_s1_variant.hex"
log "Merging full flashable image -> ${FULL_HEX}"
"${PYTHON}" "${MERGEHEX}" -o "${FULL_HEX}" "${BOOTLOADER_HEX}" "${APP_HEX}"

cp "${MANIFEST}" "${RELEASE_DIR}/${MANIFEST_FILE_NAME}"

ok "Release signed."
log "Reusable bootloader : ${BOOTLOADER_HEX}"
log "Signed app          : ${APP_HEX} / ${APP_BIN}"
log "Full flashable image: ${FULL_HEX}"
log "Next app FOTA package: ./package-app-fota.sh"
log "New app reusing bootloader: ./04-sign-app.sh --bootloader ${BOOTLOADER_HEX} --input <new tfm_merged.hex>"
