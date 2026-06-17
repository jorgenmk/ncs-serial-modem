#!/usr/bin/env bash
#
# 01 - Provision signing keys on a Vault instance
#
# Creates the signing keys our build/sign scripts expect on the Vault pointed to
# by the VAULT_ADDR / VAULT_TOKEN environment variables (any reachable Vault -
# local, remote, or a CI secret), and exports their PUBLIC keys to signing-keys/:
#
#   nsib_0 .. nsib_3   ECDSA-P256, B0/NSIB keys (nsib_0 is the active signer,
#                      nsib_1..3 are rotation/revocation reserves)
#   mcuboot            ECDSA-P256, signs/verifies the application image
#
# The names here MUST match common.sh (NSIB_KEY_NAMES / MCUBOOT_KEY_NAME), which
# the build and signing scripts use. Idempotent: existing keys are left as-is and
# only their public keys are (re-)exported.
#
# Keys are NON-exportable by default (private key never leaves Vault). Set
# EXPORT_PRIVATE_KEYS=1 to also export private PEMs (less secure; only for the
# in-build PEM-signing fallback).
#
# Requires: VAULT_ADDR and VAULT_TOKEN exported in the environment.
#   export VAULT_ADDR="https://vault.example.com"
#   export VAULT_TOKEN="<token>"

set -euo pipefail
SCRIPT_NAME="01-vault-setup"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- Preconditions -----------------------------------------------------------

require_vault_env   # checks vault/jq, VAULT_ADDR/VAULT_TOKEN, reachability
mkdir -p "${KEYS_DIR}"

EXPORT_PRIVATE_KEYS="${EXPORT_PRIVATE_KEYS:-0}"
KEY_EXPORTABLE_ARG=""
[ "${EXPORT_PRIVATE_KEYS}" = "1" ] && KEY_EXPORTABLE_ARG="exportable=true"

# Enable the Transit engine at the configured mount if it is not already there.
if ! vault secrets list -format=json 2>/dev/null \
        | jq -e --arg m "${VAULT_TRANSIT_MOUNT}/" '.[$m]' >/dev/null 2>&1; then
    log "Enabling Transit secrets engine at '${VAULT_TRANSIT_MOUNT}/'"
    vault secrets enable -path="${VAULT_TRANSIT_MOUNT}" transit >/dev/null
fi

# --- Create (if absent) and export public key --------------------------------

create_and_export() {
    local name="$1" priv_pem="$2" pub_pem="$3"

    if vault read "${VAULT_TRANSIT_MOUNT}/keys/${name}" >/dev/null 2>&1; then
        log "Key '${name}' already exists - reusing"
    else
        log "Creating ECDSA-P256 key '${name}'$([ -n "${KEY_EXPORTABLE_ARG}" ] && echo ' (exportable)')"
        vault write -f "${VAULT_TRANSIT_MOUNT}/keys/${name}" \
            type=ecdsa-p256 ${KEY_EXPORTABLE_ARG} >/dev/null
    fi

    # Public key (always exported - it is public).
    vault read -format=json "${VAULT_TRANSIT_MOUNT}/keys/${name}" \
        | jq -r '.data.keys | to_entries | max_by(.key|tonumber) | .value.public_key' > "${pub_pem}"
    grep -q "BEGIN PUBLIC KEY" "${pub_pem}" || err "failed to export public key for ${name}"

    # Private key PEM only in the explicit (non-secure) fallback mode.
    if [ "${EXPORT_PRIVATE_KEYS}" = "1" ] && [ -n "${priv_pem}" ]; then
        vault read -format=json "${VAULT_TRANSIT_MOUNT}/export/signing-key/${name}" \
            | jq -r '.data.keys | to_entries | max_by(.key|tonumber) | .value' > "${priv_pem}"
        grep -q "BEGIN EC PRIVATE KEY" "${priv_pem}" || err "failed to export private key for ${name} (is it exportable?)"
        chmod 600 "${priv_pem}"
    else
        rm -f "${priv_pem}"   # ensure no stale private key lingers
    fi
}

for k in "${NSIB_KEY_NAMES[@]}"; do
    create_and_export "$k" "$(nsib_priv_pem "$k")" "$(nsib_pub_pem "$k")"
done
create_and_export "${MCUBOOT_KEY_NAME}" "$(mcuboot_priv_pem)" "$(mcuboot_pub_pem)"

# --- Summary -----------------------------------------------------------------

ok "Keys provisioned on ${VAULT_ADDR}"
log "Transit keys: ${NSIB_KEY_NAMES[*]} ${MCUBOOT_KEY_NAME}"
if [ "${EXPORT_PRIVATE_KEYS}" = "1" ]; then
    warn "EXPORT_PRIVATE_KEYS=1: private keys exported to ${KEYS_DIR} (less secure)"
else
    log "Private keys are NON-exportable (stay in Vault)."
fi
log "Exported public PEMs -> ${KEYS_DIR}"
log "Next: ./build-unsigned.sh  (CI/build)  then  ./sign-release.sh  (secure env)"
