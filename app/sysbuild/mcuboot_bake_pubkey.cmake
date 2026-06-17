#
# Copyright (c) 2026 Nordic Semiconductor ASA
#
# SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
#
# Appended to each MCUboot image's IMAGE_CONF_SCRIPT by ../sysbuild.cmake when
# MCUBOOT_BAKE_PUBKEY is set. Runs LAST (after the default config that sets the
# key from SB_CONFIG_BOOT_SIGNATURE_KEY_FILE), so this assignment wins and the
# image's getpub bakes the provided public key. MCUBOOT_BAKE_PUBKEY is a cache
# variable (-D...), visible here at configure time. ZCMAKE_APPLICATION is the
# MCUboot image being configured.
#
set_config_string(${ZCMAKE_APPLICATION} CONFIG_BOOT_SIGNATURE_KEY_FILE "${MCUBOOT_BAKE_PUBKEY}")
