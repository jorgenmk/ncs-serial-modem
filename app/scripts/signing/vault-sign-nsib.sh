#!/usr/bin/env bash
#
# NSIB external signing command (for SB_CONFIG_SECURE_BOOT_SIGNING_COMMAND).
#
# The NCS build invokes the configured command as:
#     <command> <hash_file> > <signature_file>
# i.e. it hands us the firmware hash and expects an ECDSA signature on stdout.
# We sign with the named Vault Transit key - the private key never leaves Vault.
#
# Configured as:  SB_CONFIG_SECURE_BOOT_SIGNING_COMMAND="/abs/vault-sign-nsib.sh nsib_0"
# so this script is called as:  vault-sign-nsib.sh nsib_0 <hash_file> [> <sig_file>]
#
# do_sign.py (the built-in signer this replaces) computes
#   ECDSA_P256( SHA256( <hash_file contents> ) )
# so we sign the hash-file contents with prehashed=false (Vault does the SHA256).
#
# NOTE: the exact signature encoding the build expects (DER vs raw r||s) should
# be confirmed against your NCS revision. This emits DER (per the Kconfig help);
# set NSIB_SIG_FORMAT=raw to emit raw 64-byte r||s instead.

set -euo pipefail

KEY_NAME="${1:?vault-sign-nsib: key name required as first arg}"
HASH_FILE="${2:?vault-sign-nsib: hash file required as second arg}"

# The build appends "> <file>"; CMake may pass '>' and the path as literal args.
OUT_FILE=""
[ "${3:-}" = ">" ] && OUT_FILE="${4:-}"

[ -n "${VAULT_ADDR:-}" ] && [ -n "${VAULT_TOKEN:-}" ] || {
    echo "vault-sign-nsib: VAULT_ADDR and VAULT_TOKEN must be set in the environment" >&2
    exit 1
}
export VAULT_ADDR VAULT_TOKEN

# Vault always signs as DER (asn1). For the NSIB validation-data path we then
# convert DER -> raw 64-byte r||s, matching do_sign.py (the built-in signer).
SIG_FORMAT="${NSIB_SIG_FORMAT:-raw}"

B64_IN="$(base64 < "${HASH_FILE}" | tr -d '\n')"
SIG="$(vault write -field=signature \
        "${VAULT_TRANSIT_MOUNT:-transit}/sign/${KEY_NAME}" \
        input="${B64_IN}" \
        hash_algorithm=sha2-256 \
        marshaling_algorithm=asn1)"

PY="${PYTHON:-python3}"
emit() {
    local der_b64="${SIG#vault:v*:}"
    if [ "${SIG_FORMAT}" = "der" ]; then
        printf '%s' "${der_b64}" | base64 -d
    else
        # DER -> raw r||s (two 32-byte big-endian integers), as do_sign.py does.
        printf '%s' "${der_b64}" | base64 -d | "${PY}" -c '
import sys
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
r, s = decode_dss_signature(sys.stdin.buffer.read())
sys.stdout.buffer.write(r.to_bytes(32, "big") + s.to_bytes(32, "big"))'
    fi
}
if [ -n "${OUT_FILE}" ]; then emit > "${OUT_FILE}"; else emit; fi
