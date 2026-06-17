# MCUboot application signing: build/sign decoupling gap (NCS / Zephyr)

Assessment of why `app/sysbuild.cmake` + `app/sysbuild/mcuboot_bake_pubkey.cmake`
had to be added for the Vault-backed split build/sign workflow, and whether that
reflects a bug or a missing feature upstream.

## TL;DR

**Missing feature, not a bug.** Every component behaves as designed. What's
absent is a first-class way to **bake the MCUboot verification (public) key into
the bootloader while building the application *unsigned*** (to be signed later by
an HSM / Vault / offline key). MCUboot/imgtool already has all the primitives;
the gap is in the **sysbuild build integration**. Notably, NCS already solved the
equivalent problem for the NSIB/B0 signer but not for the MCUboot app signer.

## What we wanted

Split build/sign so private keys never touch the build host (e.g. public CI):

- the **build** stage produces unsigned b0 / MCUboot / app images, with MCUboot
  baking the *public* app-verification key (so it can verify the app at boot);
- a separate **secure** stage signs the app (and B0-signs MCUboot) via Vault.

The build stage therefore needs: *bake public key into MCUboot, but do not sign
the app in-build.*

## Why it isn't directly possible

A single sysbuild option drives **both** the key baked into MCUboot **and** the
key the app self-signs with, and the only "unsigned app" path also disables
verification:

- `zephyr/share/sysbuild/image_configurations/MAIN_image_default.cmake`
  ```cmake
  set_config_string(${ZCMAKE_APPLICATION} CONFIG_MCUBOOT_SIGNATURE_KEY_FILE
                    "${SB_CONFIG_BOOT_SIGNATURE_KEY_FILE}")
  if("${SB_CONFIG_SIGNATURE_TYPE}" STREQUAL "NONE")
    set_config_bool(${ZCMAKE_APPLICATION} CONFIG_MCUBOOT_GENERATE_UNSIGNED_IMAGE y)
  else()
    set_config_bool(${ZCMAKE_APPLICATION} CONFIG_MCUBOOT_GENERATE_UNSIGNED_IMAGE n)
  endif()
  ```
- `bootloader/mcuboot/boot/zephyr/CMakeLists.txt` bakes the public key by running
  `imgtool getpub -k ${CONFIG_BOOT_SIGNATURE_KEY_FILE}` (same key, propagated from
  the same `SB_CONFIG_BOOT_SIGNATURE_KEY_FILE`).
- `nrf/cmake/sysbuild/image_signing.cmake` signs the app whenever the key is
  non-empty (`-k <keyfile>`); `CONFIG_MCUBOOT_GENERATE_UNSIGNED_IMAGE` only
  suppresses the "no key" warning — it does **not** skip signing when a key is set.

Net result — the only supported states are:

| Path | App build | MCUboot gets pub key | External signing |
|------|-----------|----------------------|------------------|
| Signed (default) | signed with private key at build | yes (same key) | no |
| Unsigned (`SIGNATURE_TYPE=NONE`) | unsigned | **no** | manual, but no verification |
| **bake pubkey + unsigned app** | — | — | **not supported** |

## The asymmetry (the evidence)

NSIB/B0 has exactly the hook the MCUboot app path lacks
(`nrf/sysbuild/Kconfig.secureboot`, `nrf/cmake/sysbuild/sign.cmake`):

| Capability | NSIB (B0) | MCUboot app |
|------------|-----------|-------------|
| External/HSM signing command | `SB_CONFIG_SECURE_BOOT_SIGNING_CUSTOM` + `..._SIGNING_COMMAND` | none |
| Provide only a public key | `SB_CONFIG_SECURE_BOOT_SIGNING_PUBLIC_KEY` | none |

The same vendor built "sign externally, here's just the public key" for one
bootloader signer and not the other. That's the strongest indication this is an
unaddressed gap rather than a deliberate omission.

## Ownership

- **MCUboot / imgtool — not the gap.** `getpub`, `--vector-to-sign`, `--fix-sig`
  already provide everything needed for external/deferred signing.
- **Gap is in the sysbuild integration:** the key↔config coupling in Zephyr's
  `MAIN_image_default.cmake`, and the lack of a custom/public-key-only path in
  NCS's `nrf/cmake/sysbuild/image_signing.cmake`.
- Best fixed in **NCS** (it owns the app `image_signing.cmake` and already has the
  NSIB precedent to mirror); a fully general fix could also land upstream in
  Zephyr sysbuild.

## Minor rough edge (borderline bug)

`CONFIG_MCUBOOT_GENERATE_UNSIGNED_IMAGE` does not, by itself, make the image
unsigned — with a non-empty key it still signs; the image is unsigned only when
the key is *also* empty. Naming/behavior mismatch; a documentation/ergonomics
wart, not a functional defect.

## Our workaround

`app/sysbuild.cmake` (gated on `-DMCUBOOT_BAKE_PUBKEY=<pem>`) appends
`app/sysbuild/mcuboot_bake_pubkey.cmake` to each MCUboot image's
`IMAGE_CONF_SCRIPT`, so it runs **after** `MAIN_image_default.cmake` and overrides
`CONFIG_BOOT_SIGNATURE_KEY_FILE` to the public key for `getpub` only. The default
key stays a private debug key so the throwaway in-build signing still succeeds
(those outputs are discarded); the app payload (`tfm_merged.hex`) is harvested
unsigned and signed later by Vault. This is effectively a hand-rolled
`MCUBOOT_SIGNING_CUSTOM`.

## Proposed clean fix (if pursued upstream/in NCS)

Mirror the NSIB pattern for the MCUboot app image — either:
1. an option to supply the MCUboot verification **public key independently** of
   the signing key (decouple bake from sign), or
2. a `MCUBOOT_SIGNING_CUSTOM` + signing-command + public-key trio analogous to
   `SB_CONFIG_SECURE_BOOT_SIGNING_*`.

Either removes the need for the `IMAGE_CONF_SCRIPT` hook.

## References

- `zephyr/share/sysbuild/image_configurations/MAIN_image_default.cmake`
- `bootloader/mcuboot/boot/zephyr/CMakeLists.txt` (getpub / `autogen-pubkey.c`)
- `bootloader/mcuboot/boot/zephyr/Kconfig` (`CONFIG_BOOT_SIGNATURE_KEY_FILE`)
- `nrf/cmake/sysbuild/image_signing.cmake` (app signing)
- `nrf/sysbuild/Kconfig.secureboot` + `nrf/cmake/sysbuild/sign.cmake` (NSIB custom signing)
- workaround: `app/sysbuild.cmake`, `app/sysbuild/mcuboot_bake_pubkey.cmake`
