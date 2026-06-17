#!/usr/bin/env bash
#
# package-app-fota.sh - build dfu_application.zip from a Vault-signed app
#
# Wraps the Vault-signed application .bin into the same FOTA package the NCS
# build would produce (dfu_application.zip), using NCS's own generate_zip.py so
# the manifest matches what nRF Cloud / fota_download expect. App image only.
#
# Required (produced by sign-release.sh):
#   * signed app .bin                ${RELEASE_DIR}/app_signed.bin
#   * manifest.env (load addr/ver)   ${RELEASE_DIR}/manifest.env
#
# Options:
#   --input BIN       Signed app binary.   Default: ${RELEASE_DIR}/app_signed.bin
#   --manifest ENV    Build manifest.      Default: ${RELEASE_DIR}/manifest.env
#   --output ZIP      Output zip.          Default: ${FOTA_DIR}/dfu_application.zip

set -euo pipefail
SCRIPT_NAME="package-app-fota"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

INPUT_BIN="${RELEASE_DIR}/app_signed.bin"
MANIFEST="${RELEASE_DIR}/${MANIFEST_FILE_NAME}"
OUTPUT_ZIP="${FOTA_DIR}/dfu_application.zip"

while [ $# -gt 0 ]; do
    case "$1" in
        --input)    INPUT_BIN="${2:?}"; shift 2 ;;
        --manifest) MANIFEST="${2:?}"; shift 2 ;;
        --output)   OUTPUT_ZIP="${2:?}"; shift 2 ;;
        -h|--help)  sed -n '2,24p' "$0"; exit 0 ;;
        *)          err "unknown argument: $1 (see --help)" ;;
    esac
done

# --- Preconditions -----------------------------------------------------------

require_cmd "${PYTHON}" "set PYTHON=..."
require_file "${GENERATE_ZIP_PY}" "generate_zip.py"
[ -f "${INPUT_BIN}" ] || err \
"signed app binary not found: ${INPUT_BIN}
       Run sign-release.sh first, or pass --input <app_signed.bin>."
[ -f "${MANIFEST}" ] || err \
"manifest not found: ${MANIFEST}
       Expected from build-unsigned.sh/sign-release.sh, or pass --manifest <file>."
# shellcheck disable=SC1090
. "${MANIFEST}"
: "${BOARD_NAME:?manifest missing BOARD_NAME}" "${SOC_NAME:?manifest missing SOC_NAME}"
: "${APP_VERSION:?manifest missing APP_VERSION}" "${APP_LOAD_ADDR:?manifest missing APP_LOAD_ADDR}"

mkdir -p "${FOTA_DIR}"
ZIP_NAME="app.signed.bin"

# --- Build the package -------------------------------------------------------
# generate_zip.py takes "<zipname>key=value" positional meta args (same form the
# NCS build uses for dfu_application.zip).

log "Packaging ${INPUT_BIN} -> ${OUTPUT_ZIP}"
"${PYTHON}" "${GENERATE_ZIP_PY}" \
    --bin-files "${INPUT_BIN}" \
    --zip-names "${ZIP_NAME}" \
    --output "${OUTPUT_ZIP}" \
    --name app \
    --format-version 1 \
    "${ZIP_NAME}load_address=${APP_LOAD_ADDR}" \
    "${ZIP_NAME}image_index=0" \
    "${ZIP_NAME}slot_index_primary=1" \
    "${ZIP_NAME}slot_index_secondary=2" \
    "${ZIP_NAME}version_MCUBOOT=${APP_VERSION}" \
    "type=application" \
    "board=${BOARD_NAME}" \
    "soc=${SOC_NAME}"

ok "FOTA package: ${OUTPUT_ZIP}"
"${PYTHON}" - "$OUTPUT_ZIP" <<'PY' >&2 || true
import sys, zipfile, json
with zipfile.ZipFile(sys.argv[1]) as z:
    print("  contents:", ", ".join(z.namelist()))
    if "manifest.json" in z.namelist():
        print("  manifest:", json.dumps(json.loads(z.read("manifest.json")), indent=2))
PY
