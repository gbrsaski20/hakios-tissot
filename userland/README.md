# HakiOS-x86 User Space

## What is this?

The user space is the set of programs and libraries that run on top
of the XNU kernel. HakiOS-x86 provides two modes:

### Open mode (`make x86-open`)

A minimal user space with no iOS files:
- `launchd` — simplified init process
- `sh` — minimal interactive shell
- `init` — fallback init
- `libSystem.dylib` — stub system library

This is the "Apple-free" path. It boots XNU, prints kernel messages,
and drops to a shell.

### Full mode (`make x86-full`)

The full iOS user space, built from the iOS 16.5 IPSW:
- Apple's launchd
- backboardd (display server)
- SpringBoard (home screen)
- Stock apps
- Full iOS libraries

This requires the IPSW from Apple's servers.

## Building

```bash
# Open mode
userland/build.sh --open

# Full mode (needs IPSW)
userland/build.sh
```

## Files

| File | Purpose |
|------|---------|
| `src/sh.c` | Minimal shell |
| `src/launchd.c` | Simplified launchd |
| `src/init.c` | Fallback init |
| `src/lib/libSystem.c` | Stub libSystem |
| `build.sh` | Build script |

## APFS Images

The build script produces:
- `root.apfs` — Root filesystem (/, /bin, /sbin, /etc, etc.)
- `system.apfs` — System filesystem (/System, /usr, etc.)

These are mounted by XNU at boot time.
