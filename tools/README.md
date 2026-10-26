# HakiOS-x86 Tools

## Available tools

| Script | Purpose |
|--------|---------|
| `make-esp.sh` | Create a FAT32 ESP disk image for QEMU |
| `make-boot-usb.sh` | Create a bootable USB drive for real PC |

## make-esp.sh

```bash
# Create an ESP image for QEMU
make-esp.sh devices/pc-q35/esp.img prebuilt/xnuloader.efi prebuilt/mach.development.x86_64

# With custom command line
make-esp.sh esp.img xnuloader.efi mach_kernel "cpus=4 display=1 disk=1"
```

## make-boot-usb.sh

```bash
# Create a bootable USB drive
# WARNING: DESTROYS all data on the target device!
sudo tools/make-boot-usb.sh /dev/sdb
```

## Other utilities

### Building APFS images

The `userland/build.sh` script handles APFS image creation. It uses:
- `mkfs.apfs` (from apfsprogs or similar)
- `apfs-fuse` for mounting (optional)

### IPSW fetching

The `sysimage/fetch.sh` script downloads the iOS 16.5 IPSW from
Apple's public servers and extracts the needed files.
