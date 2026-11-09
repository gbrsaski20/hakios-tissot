# Xiaomi Mi A1 (tissot)

A HakiOS device repository: what is true of this device and of no other. The kernel, the loader, the drivers and the tools are
the common repository's; the msm8953 family's facts are in `soc/`, carried with the device. How the three are put together:
[docs/porting/repositories.md](https://github.com/oosexgang/hakios-xnu-kernel/blob/main/docs/porting/repositories.md).

| File | What |
|---|---|
| `metal.args` | what `tools/metal-run.sh` gives this phone: its cores, its panel's rate, the threads that copy frames, the touch poll |
| `device.conf` | what the device is, and how far each part of it works: its page in the documentation is made from it |
| `configs/tissot_defconfig` | the common kernel, the SoC's fragment, this device's: `make tissot_defconfig` |
| `configs/tissot.config` | what is this device's own: the drivers built in, the arguments it needs |
| `soc/` | its SoC family's layer (msm8953): `soc.conf`, `configs/msm8953.config`, the SoC's drivers; carried here so that this one repository is all the device needs |
| `drivers/` | drivers of its own, if it needs any (`drivers/<subsystem>/conf`, as in the common repository) |

Every phone driver of the common repository is left out to begin with: their addresses and pins are the phone they were written
for. Put one back in `configs/tissot.config` when it has been made to work here, and say so in `device.conf`.

Check with `tools/hakios-device.py check tissot`.

## Status: a draft, nothing has run on the phone

### Checked against a device tree from a real phone

`dt/phone.dtb` (sha256 `7c4a74fb...`) is the `/sys/firmware/fdt` of a Mi A1 running LineageOS 22 (Android 15), supplied by the
owner; `dt/phone.dts` is its decompilation. It confirms, for that phone: model "MSM8953 + PMI8950 QRD SKU3", `qcom,msm-id` 0x125 (293),
board-id 0x1000b; eight Cortex-A53 with `reg` 0-3 and 0x100-0x103 and PSCI by `smc`; `qcom,msm-qgic2` with distributor `0xb000000`
and CPU interface `0xb002000`; arch timer interrupts `<1 2> <1 3> <1 4> <1 1>` at 19.2 MHz (virtual timer = PPI 4 = INTID 20);
UARTDM `0x78af000`; eMMC `sdhci@7824900`. All of these agree with the values taken from the Linux DTS. This tree is what the Android
kernel was started with (Android's bootloader and kernel may have changed it), not what HakiOS would receive.

This directory was made with `tools/hakios-device.py new tissot --soc msm8953 ...` and **without the phone's own device tree**
(no phone was connected, no `adb`). Every area in `device.conf` is `missing`. A build of the kernel proves that the source compiles,
not that anything boots on a Mi A1.

What `tissot_defconfig` changes: **only which drivers are built in and which boot arguments the run scripts use.** `xnu-build.sh`
compiles the same machine configuration (`BCM2837`) for every device, so `make kernel` produces the same `hakios-kernel` for tissot
as for any other device.

### Hardware reference (not verified on the phone)

Taken from the Linux DTS of `xiaomi-msm8953-devs/android_kernel_xiaomi_msm8953` (branch `lineage-21`, Linux 4.9.337) and the
`xiaomi-msm8953-devs/android_device_xiaomi_tissot` device tree (branch `lineage-21`). Used as a hardware reference only; no code
from either was copied.

| Item | Value | Source |
|---|---|---|
| SoC id | `qcom,msm-id = <293 0>` (MSM8953) | `msm8953.dtsi:25` |
| Board id | `qcom,board-id = <0x1000b 0>` | `msm8953-qrd-sku3-tissot.dts` |
| CPUs | `arm,cortex-a53`, 8 cores | `msm8953-cpu.dtsi:57` |
| Interrupt controller | `qcom,msm-qgic2`, distributor `0x0b000000`, CPU interface `0x0b002000` | `msm8953.dtsi:250-257` |
| Arch timer | 19.2 MHz | `msm8953.dtsi:286-291` |
| Console UART | `qcom,msm-uartdm-v1.4` at `0x078af000` | `msm8953.dtsi:546-548` |
| RAM size | `/memory` of the phone's tree: `0x10000000`+`0x70000000` and `0x80000000`+`0x80000000` (about 3.75 GiB; the bootloader fills it in, so it is this phone's, not every Mi A1's) | `dt/phone.dts` |

### What stands between this and a boot

- **GICv2 support: written, tested only in QEMU.** `xnu/files/osfmk/arm64/gic_v3_irq.c` now drives a GICv2 when the device tree
  says so (`compatible`), with the virtual-timer interrupt number taken from `virt-timer-intid` (MSM8953: PPI 4 = INTID 20, as in the phone's own tree; the
  interrupt path itself is unverified on hardware). Tested on QEMU `virt` GICv2, 1 to 4 cpus; not on the phone.
- **Cortex-A53 has no PAN.** The default kernel dies on its first `msr pan`; build with `xnu/optional/a53-no-pan.patch`
  (see `xnu/optional/a53-no-pan.md`). That kernel reaches user space on QEMU `-cpu cortex-a53`; not run on the phone.
- **Loader entry is a draft.** `platform_tissot` in `xnuloader/loader.c` is taken from the DTS and now models MSM8953's two-level
  MPIDRs (0-3, 0x100-0x103, `cluster_cores`). It compiles (`LOADER_CFLAGS=-DLOADER_PLATFORM_TISSOT xnuloader/build.sh`); the
  flat-MPIDR default still boots on QEMU. The two-level path has not run anywhere.
- **No UEFI port for tissot.** The loader needs UEFI's framebuffer and file access; `hakios-uefi` has no MSM8953/tissot platform
  (checked in the manifest only: `devices/manifest.conf` names no such port). How the Mi A1's own bootloader could start
  the loader instead has not been investigated.
- **No console UART, timer or SoC-specific bring-up** for MSM8953 in the kernel.
- **Storage is eMMC**, the common storage driver is UFS.
- **GPU is an Adreno 506**; the common GPU driver and `hakios-metal` tables are for the Adreno 642L, and `hakios-metal` refuses
  other chip ids.
- **The phone's own device tree is still to be pulled** (`adb pull /sys/firmware/fdt`, or `tools/hakios-device.py new --adb`),
  then `tools/new-device.py` compares it with the reference phone.
- **Bootloader** must be unlocked; nothing here flashes or writes to the phone.
