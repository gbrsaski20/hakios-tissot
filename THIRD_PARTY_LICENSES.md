# Third-Party Licenses

## XNU Kernel
- **Origin**: Apple Inc. (https://github.com/apple/darwin-xnu)
- **License**: Apple Public Source License 2.0 (APSL 2.0)
- **Used in**: xnu/ (patch and driver files are derivatives)
- **Version**: xnu-8796.121.2

## OVMF / EDK2 (UEFI firmware)
- **Origin**: Tianocore (https://www.tianocore.org)
- **License**: BSD-2-Clause-Patent + other licenses (see EDK2 license.txt)
- **Used in**: QEMU UEFI firmware (not distributed, provided by your distribution)
- **Used by**: xnuloader (our code targets UEFI, but does not include OVMF)

## Clang / LLVM
- **Origin**: LLVM Project (https://llvm.org)
- **License**: Apache 2.0 with LLVM exceptions
- **Used in**: Building the kernel and loader

## 7-Zip
- **Origin**: Igor Pavlov (https://www.7-zip.org)
- **License**: LGPL 2.1 + unRAR restriction
- **Used in**: Unpacking IPSW files

## QEMU
- **Origin**: QEMU Project (https://www.qemu.org)
- **License**: GPL 2.0
- **Used in**: Running the system in emulation

## lz4
- **Origin**: Cyan (https://github.com/lz4/lz4)
- **License**: BSD-2-Clause
- **Used in**: Decompression during IPSW processing
