# Cortex-A53 (ARMv8.0): a kernel without PAN

The `BCM2837` machine configuration of this repository turns on PAN (`__ARM_PAN_AVAILABLE__` in
`pexpert/pexpert/arm64/BCM2837.h`, and `-Xclang -target-feature -Xclang +pan` in `makedefs/MakeInc.def`). PAN is ARMv8.1.
A Cortex-A53, such as the Snapdragon 625 of the Xiaomi Mi A1, is ARMv8.0: the first `msr pan, #1` of `arm_init()` is an undefined
instruction there, and the kernel stops before it prints anything.

What was run (QEMU `virt`, `-cpu cortex-a53`, UEFI at EL1, this repository's loader and `hello`):

| kernel | result |
|---|---|
| default build (PAN on) | silent after the loader's "jumping to ..."; `-d int` shows an Undefined Instruction at `arm_init+0x478`, `msr pan, #1` |
| `-DHAKIOS_NO_PAN` build | boots: loader, kernel banner, then `hello` prints "Hello from user space on Darwin!" (1 and 4 cpus, GICv2 and GICv3) |

A scan of all 2,094,768 instruction words of the default kernel's text found no other ARMv8.1+ instruction a Cortex-A53 lacks
(no LSE atomics, no MTE, no `sb`, no dot product ...); `msr pan` is the only one, at 24 places.

## Result

On QEMU `virt` with `-cpu cortex-a53` the no-PAN kernel reaches the same point as the PAN kernel on `cortex-a76`: it starts
`hello` as process 1, which prints its line. The panic "initproc failed to start" that follows is `hello` exiting (the demo
user space is one static program, not a launchd). This is an emulator result only. Nothing here was run on a Mi A1.

## Build

    cd xnu-src/xnu-8796.121.2 && patch -p1 < ../../xnu/optional/a53-no-pan.patch
    tools/make-kernel.sh -j8 MACHINE_FLAGS_ARM64_BCM2837="-DARM64_BOARD_CONFIG_BCM2837 -DHAKIOS_NO_PAN"

The second line replaces the machine flags, which also drops `+pan`. Move `BUILD/` away first (or clean it): XNU's build does
not notice that the compiler flags changed, so objects of an earlier build would be kept.

## What it costs

Without PAN the hardware no longer stops the kernel from reading or writing user memory by mistake; the kernel is then in the
position XNU is in on the iPhones before the A10. This is a weaker kernel, built so that it can start on this CPU at all.
`xnu/optional/a53-no-pan.patch` is not applied by `xnu/apply.sh`.
