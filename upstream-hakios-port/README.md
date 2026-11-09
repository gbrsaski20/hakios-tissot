# Mi A1 (tissot) work against upstream HakiOS (oosexgang/hakios-xnu-kernel)

Not part of the xnu-8020 patch series in this repository: this is a separate port against upstream HakiOS's
xnu-8796 tree, kept here as a bundle of changed files. Paths below `xnu/`, `xnuloader/`, `qemu/` mirror upstream;
`devices-tissot/` is upstream's git-ignored `devices/tissot/`.

- GICv2 support in the kernel's interrupt driver, Cortex-A53 no-PAN option, draft tissot loader platform (two-level MPIDRs).
- `devices-tissot/dt/phone.dtb`: the /sys/firmware/fdt of a Mi A1 on LineageOS 22.
- Tested only on QEMU `virt` (Cortex-A53, GICv2): reaches user space. Never run on the phone. No iOS boot is claimed.

Apply: copy over an upstream checkout (commit f2e2751's parent is upstream `main`), then see `devices-tissot/README.md`.
