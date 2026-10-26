# HakiOS-x86 System Image

## What is this?

The system image scripts download and extract the iOS 16.5 IPSW
from Apple's public servers. The IPSW contains the iOS user space
files needed for the full HakiOS-x86 build.

## Files

| File | Purpose |
|------|---------|
| `fetch.sh` | Download the iOS 16.5 IPSW |

## How it works

1. `fetch.sh` downloads the IPSW from Apple's CDN
2. The IPSW is a ZIP file containing:
   - `kernelcache` — kernel + kexts
   - `Restore.plist` — metadata
   - `Firmware/` — firmware files
   - `*.dmg` — filesystem images
3. The script extracts these files to `sysimage/extracted/`
4. `userland/build.sh` then builds the APFS images

## Important

- **No iOS files are distributed in this repository.**
- You must download the IPSW yourself from Apple's servers.
- The IPSW is not decrypted or modified in any way.
- This is for research purposes only.

## Usage

```bash
# Download the IPSW
sysimage/fetch.sh

# Build the full system
make x86-full
```
