#
# Copyright (c) 2026 Nordic Semiconductor ASA
#
# SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
#
# Application-level sysbuild hook.
#
# Split build/sign support: when -DMCUBOOT_BAKE_PUBKEY=<file.pem> is passed, the
# MCUboot S0/S1 images bake that PUBLIC key as their application-verification key
# (imgtool getpub accepts a public key), WITHOUT changing SB_CONFIG_BOOT_SIGNATURE_KEY_FILE.
#
# Why this way: SB_CONFIG_BOOT_SIGNATURE_KEY_FILE feeds *every* in-build signing
# step (app image, and the signed_by_mcuboot_and_b0 bootloader-FOTA image); a
# public key there makes all of them fail (can't sign with a public key). By
# overriding only the MCUboot images' bake key, the build keeps signing its
# throwaway artifacts with the default debug PRIVATE key (those are discarded),
# while the harvested MCUboot binaries embed the REAL verification key. The
# unsigned app payload (tfm_merged.hex) and the MCUboot binaries are then signed
# for real, later, in a secure environment (e.g. Vault).
#
# We append our key-override to each MCUboot image's IMAGE_CONF_SCRIPT so it runs
# AFTER the default config (which would otherwise set the key from SB_CONFIG),
# and therefore wins (Kconfig: last assignment wins). Normal builds (flag unset)
# are unaffected.

if(MCUBOOT_BAKE_PUBKEY)
  if(NOT EXISTS "${MCUBOOT_BAKE_PUBKEY}")
    message(FATAL_ERROR "MCUBOOT_BAKE_PUBKEY does not exist: ${MCUBOOT_BAKE_PUBKEY}")
  endif()
  set(_baked 0)
  foreach(img mcuboot mcuboot_s1_variant)
    if(TARGET ${img})
      set_property(TARGET ${img} APPEND PROPERTY IMAGE_CONF_SCRIPT
                   "${CMAKE_CURRENT_LIST_DIR}/sysbuild/mcuboot_bake_pubkey.cmake")
      set(_baked 1)
    endif()
  endforeach()
  if(_baked)
    message(STATUS "sysbuild: MCUBOOT_BAKE_PUBKEY -> MCUboot will bake ${MCUBOOT_BAKE_PUBKEY}")
  else()
    message(WARNING "sysbuild: MCUBOOT_BAKE_PUBKEY set but no mcuboot image targets found")
  endif()
endif()
