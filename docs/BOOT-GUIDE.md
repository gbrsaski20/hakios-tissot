# HakiOS-x86 — Boot Guide (get it to actually boot)

This is the practical "how do I get HakiOS-x86 to boot on a PC / in QEMU" guide.
It sits on top of `README.md` (architecture, drivers, licenses) and
`README-windows.md` (Windows/WSL tooling). Read this one to actually produce a
USB stick you can boot.

---

## 0. TL;DR — which path do I take?

| Goal | What you need | Path | Result |
|------|---------------|------|--------|
| **I just want a flashable image right now** (proves the boot chain works) | Windows + Python 3 | **Path B** (`make-bootable.bat`) | `hakios-x86.img` with a **placeholder** kernel — loader prints a banner then halts. Bootable, but NOT real XNU yet. |
| **I want the REAL XNU kernel to boot** | A free GitHub account | **Path A** (GitHub Actions) | `hakios-x86.img` built on a macOS runner with the real `mach_kernel`. Flash → boot real XNU. |
| **I have WSL2 + a macOS SDK somehow** | Linux/macOS build host | `make x86-open` | Real kernel built locally (advanced). |

> **Honest status check.** The local build (Path B) produces a valid, Rufus-flashable
> UEFI image, but `mach_kernel` there is a **placeholder** (a halt loop + banner),
> not the real XNU kernel. The real XNU kernel **cannot be built on Windows or
> plain Linux/WSL** — it needs the macOS SDK (clang + `xcrun`). The only
> turnkey way to get a real kernel without owning a Mac is **GitHub Actions**
> (a free macOS-14 runner), which is **Path A** below.

---

## 1. Reality check — what "bootable" means at each stage

The boot chain we have built and verified byte-by-byte:

```
PC firmware (UEFI)
   └─> /EFI/BOOT/BOOTX64.EFI   (xnuloader.efi, a UEFI PE64 app)
          └─> reads /EFI/HAKIOS/mach_kernel
          └─> reads /EFI/HAKIOS/cmdline.txt
          └─> sets up BootArgs and jumps to kernel entry
                 └─> mach_kernel (XNU)  ──> drivers ──> user space
```

- **Loader (`xnuloader.efi`)** — real, working UEFI PE64 application. It prints a
  banner to the GOP/VGA console and (in the full version) loads the kernel. The
  Python-built version prints a banner and halts so you can confirm the UEFI
  hand-off works on your hardware.
- **`mach_kernel`** — **placeholder** in local builds. The GitHub Actions build
  (Path A) replaces it with the real XNU `mach.development.x86_64`.
- **`cmdline.txt`** — `cpus=2 display=1 input=1 disk=1 net=1 serial=1`.

So: with Path B you prove the firmware → loader → (halt) chain. With Path A you
close the loop with the real kernel.

---

## 2. Path A — build the REAL XNU kernel via GitHub Actions (recommended)

This is the path that gets you to a genuine XNU boot without owning a Mac.
It uses the two workflows already in this repo:

- `.github/workflows/xnu.yml` — builds **only** the kernel, uploads it as an artifact.
- `.github/workflows/image.yml` — builds the kernel **and** assembles the full
  `hakios-x86.img` (loader + kernel + cmdline) in one job. **Use this one.**

### Step 0 — Push this repo to GitHub

The repo is already a git repository. Create an empty repo on github.com
(**do not** add a README/LICENSE/.gitignore when creating — we already have them),
then:

```bash
git remote add origin https://github.com/<you>/hakios-x86.git
git branch -M main
git add -A
git commit -m "HakiOS-x86: loader, Python image builder, XNU patch + CI"
git push -u origin main
```

> The workflows live under `.github/workflows/` and are already committed (or
> will be after the commit above). They run on `push` to `main`/`master` **and**
> can be triggered manually from the Actions tab.

### Step 1 — Run the image workflow

1. Open your repo on GitHub → **Actions** tab.
2. Click **"HakiOS-x86 Bootable Image"** (the `image.yml` workflow).
3. Click **Run workflow** → choose kernel config `DEVELOPMENT` (default) → **Run**.
4. Wait ~5–20 minutes. The job:
   - clones Apple's `darwin-xnu` at `xnu-8796.121.2`,
   - applies `xnu/hakios-x86.patch` + copies the `xnu/files/` drivers,
   - builds `ARCH_CONFIGS=X86_64 TARGET_CONFIGS=hakios`,
   - builds `xnuloader.efi` (Python) and assembles `hakios-x86.img`.

If the real kernel fails to build for any reason, the workflow **falls back** to
the placeholder kernel and still produces an image — so you always get a flashable
artifact. (Watch the log: it prints `>>> Real kernel copied` vs `>>> WARNING`.)

### Step 2 — Download the artifact

On the workflow run page, scroll to **Artifacts** →
`hakios-x86-image-DEVELOPMENT` → download and unzip. You get:

```
hakios-x86.img        # 256 MB raw disk image (MBR + FAT32 ESP)
mach.development.x86_64
xnuloader.efi
```

That `hakios-x86.img` is the one you flash.

### Step 3 — Flash with Rufus (DD Image mode)

See **Section 4** for the full Rufus walkthrough. Short version:

1. Download Rufus from https://rufus.ie
2. Plug in a USB stick (≥ 512 MB; 256 MB image + overhead).
3. **SELECT** → choose `hakios-x86.img`.
4. **Partition scheme**: GPT · **Target system**: UEFI (non-CSM).
5. Click **START** → when Rufus asks, choose **DD Image** (NOT ISO).
6. Wait for "READY".

### Step 4 — Boot

Plug the USB into a UEFI PC, pick it from the boot menu (F12 / F11 / Esc — varies
by vendor), and you should see the loader banner, then XNU kernel messages on the
serial console / VGA. See **Section 5–6** for what to expect and how to troubleshoot.

---

## 3. Path B — local Python build (placeholder kernel, no internet build)

If you just want a flashable image immediately and don't mind that the kernel is a
placeholder, this runs entirely on your Windows machine with Python 3.11+.

```bat
make-bootable.bat
```

It runs, in order:

1. `xnuloader/build_efi.py` → `prebuilt/xnuloader.efi` (2 KB, valid PE64).
2. `tools/build_kernel_placeholder.py` → `prebuilt/mach.{development,release,debug}.x86_64` (64 KB each, halt + banner).
3. `tools/make_rufus_img.py` → `prebuilt/hakios-x86.img` (256 MB, MBR + FAT32).

No WSL, no clang, no mtools, no network needed. Use the resulting
`prebuilt/hakios-x86.img` with Rufus exactly as in Section 4. On boot you'll see
the loader banner and a halt — confirming the firmware → loader chain works on
your hardware. To get the real kernel, come back to Path A.

> Equivalent one-liners (PowerShell):
> ```powershell
> python xnuloader/build_efi.py; python tools/build_kernel_placeholder.py; python tools/make_rufus_img.py
> ```

---

## 4. Flashing with Rufus (DD Image mode) — detailed

Rufus has two write modes and **you must pick the right one**:

- **DD Image** — writes the raw `.img` block-for-block (MBR + FAT32 intact). ✅ This is what we need.
- **ISO** — repackages the file as a CD image and can break the GPT/MBR layout. ❌ Avoid.

Steps:

1. **Get Rufus**: https://rufus.ie (portable version is fine).
2. **Insert USB** (everything on it will be erased).
3. **Device**: your USB stick.
4. **Boot selection**: click **SELECT** and choose `hakios-x86.img`.
5. **Partition scheme**: `GPT`.
6. **Target system**: `UEFI (non-CSM)`.
7. Click **START**.
8. A dialog appears — **choose "Write in DD Image mode"** and confirm.
9. Wait until the progress bar says **READY** (green).
10. Safely eject the USB.

If Rufus does **not** ask about DD vs ISO, it already detected a raw image and
will write in DD mode automatically — just let it finish.

> Why GPT + UEFI (non-CSM)? Our image is a real GPT/MBR hybrid with an EFI System
> Partition and a UEFI fallback `BOOTX64.EFI`. CSM/Legacy mode would bypass the
> UEFI loader entirely. Keep the target PC in pure UEFI mode.

---

## 5. Booting on a real UEFI PC

1. Insert the USB.
2. Enter the boot menu (F12/F11/Esc/F10 — depends on vendor) **or** set USB as
   first boot device in BIOS/UEFI setup.
3. Choose the USB entry that says **UEFI** (e.g. `UEFI: Kingston ...`).
4. The loader (`BOOTX64.EFI`) runs:
   - prints the HakiOS banner to the display,
   - reads `mach_kernel` + `cmdline.txt`,
   - transfers control to the kernel.
5. With the **real** kernel (Path A): XNU starts, initializes the hakios x86
   drivers (VGA/serial/HPET/i8042/AHCI/E1000), and prints kernel messages.
   With the **placeholder** kernel (Path B): it prints a banner and halts — by
   design, to prove the chain.

### Serial console (recommended for debugging)

Most of XNU's early output goes to the **serial port (COM1, 16550 UART)**. Connect
a USB-serial adapter / use your PC's COM port at **115200 8N1** and watch with
PuTTY / `screen /dev/ttyUSB0 115200` / `minicom`. This is where you'll see the
real kernel log.

---

## 6. Booting in QEMU first (test before burning a USB)

QEMU with OVMF (UEFI) lets you verify the image boots before you waste a USB write.

**Linux / WSL (OVMF required):**
```bash
qemu-system-x86_64 \
  -machine q35 -m 2048 -accel kvm \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
  -drive file=prebuilt/hakios-x86.img,format=raw,if=ide \
  -serial stdio -display gtk
```

**Windows (no OVMF handy):** use `run-qemu-windows.bat` if you have QEMU +
OVMF installed, or just flash the USB and boot a real PC — QEMU UEFI setup on
Windows is more fiddly than a real PC boot.

Watch the **serial** window for kernel output and the **VGA** window for the
loader banner.

---

## 7. Kernel command line (`cmdline.txt`)

The default `cmdline.txt` written into the image:

```
cpus=2 display=1 input=1 disk=1 net=1 serial=1
```

| Flag | Meaning |
|------|---------|
| `cpus=N` | CPU cores to bring up |
| `display=1` | VGA / bochs display driver |
| `input=1` | i8042 keyboard/mouse |
| `disk=1` | AHCI SATA driver |
| `net=1` | Intel E1000 driver |
| `serial=1` | 16550 UART serial console |
| `audio=1` | Intel HDA (add if you want audio) |
| `var_store=1` | persist `/private/var` |

To change it: edit `tools/make_rufus_img.py` (`cmdline = "..."` near `def main`)
and rebuild, or mount the ESP after flashing and edit `/EFI/HAKIOS/cmdline.txt`.

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Rufus wrote but PC shows "No bootable device" | Wrote in **ISO** mode, or CSM/Legacy boot | Re-flash in **DD Image** mode; set BIOS to pure UEFI (non-CSM) |
| Black screen after selecting USB | Loader ran but no VGA output, or halted | Connect **serial COM1 115200** to see output |
| "Missing BOOTX64.EFI" / Secure Boot error | Secure Boot on | Disable **Secure Boot** in BIOS (our loader isn't signed) |
| Loader banner shows, then nothing | **Placeholder** kernel (Path B) — expected | Use **Path A** (GitHub Actions) for the real kernel |
| GitHub Actions image has placeholder kernel | XNU build failed on runner | Check the workflow log; the patch/drivers may need an XNU version tweak. Open an issue / ping the maintainer |
| USB not listed in boot menu | Fast Boot / wrong USB port | Disable Fast Boot; try a rear USB 2.0 port |
| Kernel panics on `hakios_platform` | Driver/hardware mismatch | Set `disk=0 net=0` to isolate; report the serial log |

---

## 9. FAQ

**Q: Is the kernel I flashed the real XNU?**
Only if you used **Path A** and the workflow log said `>>> Real kernel copied`.
Path B is intentionally a placeholder so the boot chain is verifiable offline.

**Q: Do I need a Mac?**
No. GitHub Actions gives you a free macOS-14 runner that builds XNU with the real
SDK. You only need a GitHub account.

**Q: Will this show the iOS GUI / SpringBoard?**
Not yet. The open path boots XNU + drivers + a minimal shell. The full iOS user
space is a separate, optional step that needs an iOS 16.5 IPSW you supply. That's
tracked in `README.md` ("full mode").

**Q: Is this safe for my PC?**
Yes — nothing is installed; the loader and kernel run from RAM. Reboot returns you
to your normal OS. (Standard research-project caveat: always back up first, and
don't boot unknown images on mission-critical machines.)

**Q: Can I share the image with a friend?**
Yes. `hakios-x86.img` is a self-contained raw image. Share the file; they flash it
with Rufus. The repo itself is also portable (all scripts are path-relative).

---

## 10. What's next (roadmap to a full boot)

1. ✅ UEFI loader → kernel hand-off (works).
2. ✅ Rufus-flashable image (works, local + CI).
3. 🔄 Real XNU kernel booting on x86_64 (CI build in place — verify on hardware).
4. ⏳ Driver hardening on real hardware (AHCI/E1000/i8042 against real chipsets).
5. ⏳ Optional iOS user space via IPSW (full mode).
6. ⏳ Signed/Secure-Boot-friendly loader (future).
