# Legal

## What is distributed

- Source code: my patches to XNU (`xnu/hakios-x86.patch`, APSL 2.0), my driver files (`xnu/files/`), my boot loader (`xnuloader/`), my user space programs (`userland/src/`), build scripts, and tools.
- Prebuilt: the kernel, loader, and libraries built from this repository.

## What is NOT distributed

- **No iOS files**: no binary, image, cache, font, picture, screenshot, or any other file of iOS. You build the system image on your machine from the iOS 16.5 IPSW, which `sysimage/fetch.sh` downloads from Apple's public servers, without decrypting or circumventing anything.
- **No firmware**: the PC's firmware (BIOS/UEFI, GPU, Wi-Fi, audio, NIC) is the vendor's. For QEMU, firmware (OVMF) comes from your distribution.
- **No keys, certificates, activation**: nothing that would make the PC pass as an iPhone to Apple's services. Signing in to an Apple account is impossible here and not a goal.

## Licenses

- XNU patch: Apple Public Source License 2.0 (APSL 2.0). Apple publishes XNU under it. The terms are met: changes are published as source, notices are kept.
- My code (drivers, loader, userland, tools): see file headers. Default: APSL 2.0 (for kernel files that are derivatives of XNU) or MIT/BSD (for standalone code).
- Third-party components: see `THIRD_PARTY_LICENSES.md`.

## Trademarks

"iOS", "iPhone", "XNU", "Apple", and any other trademarks mentioned are the property of their respective owners. They are named only to describe what the code works with. HakiOS-x86 is not affiliated with or endorsed by Apple.

## Not legal advice

The information in this file, `COMPLIANCE.md`, `THIRD_PARTY_LICENSES.md`, and `NOTICE` is provided for informational purposes only and is not legal advice.
