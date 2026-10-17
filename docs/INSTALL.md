# Installing Alpine + Plasma Bigscreen on an LG OLED65C21LA

Boots a custom 5.4 kernel by `kexec` from the running stock webOS 24, with the root
filesystem on a USB stick. Stock webOS is left untouched on eMMC — power-cycle the TV and it
comes back normally.

**Target:** LG OLED65C21LA, LG1213 ("o22") SoC, aarch64. Other models will need at minimum a
different kernel command line (see [Step 7](#7-copy-to-the-tv)).

**Prerequisite:** root access on the TV (this project assumes an already-rooted set, with
`/home/root` writable and SSH or a serial console available). Rooting the TV is out of scope.

---

## A note on `tv.dtb`

**No device tree file is needed.** `boot_kernel.sh` has its `--dtb=` line commented out, so
`kexec` falls back to the device tree the stock kernel is already running with, and `boot.sh`
does not deploy one. There is no `tv.dtb` in this repo and nothing needs one.

Older notes said this file was required. If you ever want to go back to supplying one
explicitly, uncomment the `--dtb` line, add the file to the `files` list in `boot.sh`, and
produce it with:

```sh
# on the TV, booted into stock webOS
dtc -I fs -O dtb /proc/device-tree > tv.dtb
```

That is an educated reconstruction, not a verified procedure.

---

## What gets built

| artifact | built by | ends up |
|---|---|---|
| `Image` | `webos24/linux-and-kdriver_okapi-3/build.sh` | TV, `/home/root/os_loader/` (by `boot.sh`) |
| `boot-initramfs.cpio.gz` | `alpine/build-boot-initramfs.sh` | TV, `/home/root/os_loader/` (by `boot.sh`) |
| `fix_stuck_cpus.ko` | `custom/fix_stuck_cpus/Makefile` → `build/modules/` | TV, `/home/root/os_loader/` (by `boot.sh`) |
| `kexec` | `kexec-tools/` | TV, `/home/root/os_loader/` (by `boot.sh`) |
| Alpine rootfs | `alpine/build-alpine-rootfs.sh` | USB stick |

The TV holds only the kernel, a ~1 MB boot initramfs, and the kexec helper. Everything else
lives on the stick, so rebuilding userspace never touches the TV.

---

## 1. Host prerequisites

- A Linux host.
- `aarch64-linux-gnu-` cross toolchain, for the kernel and the stock-kernel module.
- A **recent** `qemu-user-static` with its binfmt rules registered on the host — on Arch,
  `qemu-user-static` + `qemu-user-static-binfmt`, which `systemd-binfmt` registers
  persistently. Everything aarch64 that is not the kernel is compiled under this. Check it
  with `qemu-aarch64-static --version`; the stale emulator problem described in step 5 is
  worth avoiding.
- Docker with `binfmt`/qemu-user-static registered, for the rootfs build. The rootfs is built
  **inside an aarch64 container** because `apk` has to run natively and the C tools in
  `alpine/tools/` must be aarch64 + musl.
- Root on the host, for partitioning and writing the USB stick.

---

## 2. Apply the patches to the kernel tree

`webos24/` is an extracted LG GPL drop under git, with the patches already applied in this
working copy. For a *fresh* tree:

```sh
cd webos24
git apply --check ../patches/*.patch     # dry run first
for p in ../patches/*.patch; do git apply "$p"; done
```

Extract a fresh drop with `tar`, **not** 7-Zip — see `PATCHES.md` for why (it mangles
symlinks). `PATCHES.md` documents what each patch does and why; read it before changing any
of them.

---

## 3. Build the kernel

```sh
cd webos24/linux-and-kdriver_okapi-3
./build.sh
```

`CHIP_NAME` already defaults to `o22` in this tree (patched from LG's `o24`). The build
produces both the kernel and LG's `kdriver` stack. The kernel lands at

```
webos24/linux-and-kdriver_okapi-3/linux-rockhopper/arch/arm64/boot/Image
```

Copy that to the project root as `Image`.

---

## 4. Build `fix_stuck_cpus.ko`

This one is **built against the stock kernel, not ours.** It patches
`cpus_are_stuck_in_kernel()` to return false so `kexec -l` will accept the load with CPUs
parked.

```sh
cd custom/fix_stuck_cpus
# KDIR in the Makefile points at a kernel tree configured with ../../config
make
```

Both modules land in `build/modules/`. Kbuild still compiles them in the source directory —
5.4 has no output-directory option for external modules, `KBUILD_EXTMOD_OUTPUT` is 6.x — so
the `.o` and `.mod*` litter stays in `custom/fix_stuck_cpus/` and only the `.ko` files are
copied out. `make clean` removes both copies. Override with `make OUTDIR=/somewhere`.

### How strictly `vermagic` has to match

Less strictly than you would expect, and it is worth knowing which part matters. The running
stock kernel is `5.4.268-320` (see the header of the extracted `config`), but `KDIR` points at
the webOS 23 tree, which is **5.4.96** — and the resulting module loads anyway.

That is because the stock kernel sets `CONFIG_MODULE_IGNORE_SUBVER=y`, an LG option
(`init/Kconfig`, `default y if WEBOS`). `same_magic()` at `kernel/module.c:1399` then compares
only VERSION and PATCHLEVEL, skips to the first space, and compares the remainder:

```
5.4.96 SMP preempt mod_unload aarch64        ->  "5" "4" + " SMP preempt mod_unload aarch64"
5.4.268-320 SMP preempt mod_unload aarch64   ->  "5" "4" + " SMP preempt mod_unload aarch64"
```

So **only `5.4` and the flag tail have to agree**; the sublevel and the `-320` suffix are
skipped entirely. `CONFIG_MODVERSIONS` and module signing are both off, so nothing else is
checked.

The catch is that this removes the guard rather than satisfying it. A module built against
5.4.96 headers will load on 5.4.268 even if a struct it touches changed in between — it fails
at runtime instead of at `insmod`. A tree at the matching 5.4.268 exists at
`/mnt/storage/soc_GO/linux-and-kdriver_paluma-5/linux-rockhopper` and builds these two modules
cleanly, so pointing `KDIR` there is the safer option if you ever see unexplained behaviour
from them.

---

## 5. Build `kexec` and the boot initramfs

All three pieces are built by one script, from the **project root**:

```sh
sh alpine/build.sh
```

It starts the aarch64 `alpine-builder` container, builds whatever is missing, and stops the
container again:

| step | source | output | skipped if |
|---|---|---|---|
| `alpine/build_kexec.sh` | kexec-tools 2.0.32 tarball | `build/kexec/sbin/kexec` | the binary exists |
| `alpine/build_busybox.sh` | busybox 1.38.0 tarball | `build/busybox/busybox` | the binary exists |
| `alpine/build-boot-initramfs.sh` | `build/busybox/busybox` + `alpine/boot-initramfs-init.sh` | `build/boot-initramfs.cpio.gz` | never — it is cheap |

Both downloads are pinned to a version and checked against a SHA-256 before anything is
built. The two compiles run inside the container, so nothing needs a cross toolchain on the
host; only the last step is a host script, and it just assembles files.

If you have not built the container image yet:

```sh
cd alpine && sh build_arm_docker_image.sh
```

### ⚠ Do not re-register binfmt from the multiarch container

`binfmt` must come from the host's `qemu-user-static-binfmt` package (see prerequisites),
**not** from `docker run --rm --privileged multiarch/qemu-user-static --reset -p yes`. That
line used to be the first thing `build_arm_docker_image.sh` did, and it has been removed.

Running it replaces the host registration with whatever qemu is baked into that image. A
three-year-old copy of it emulated gcc badly enough to segfault the compiler at random
while building busybox — four runs, four *different* translation units
(`util-linux/volume_id/sysv.c`, `libbb/hash_md5_sha.c`, `coreutils/nl.c`,
`archival/libarchive/init_handle.c`), at `-j32`, `-j4` and `-j1` alike. It is not a
parallelism or memory problem and it does not reproduce in any one place, so it reads as a
broken build rather than a broken emulator. With qemu 11.1.2 the same build is clean in
about 75 seconds. kexec never showed it because it is a handful of files and the crash rate
is per-compilation.

### busybox, and why it is static

`busybox` is the entire userspace of the boot initramfs, and `/init` is PID 1 there — at a
point where no dynamic loader and no `/lib` exist yet. A dynamically linked busybox dies
before it can print anything, which on the TV is indistinguishable from the kernel failing
to boot. `build_busybox.sh` therefore sets `CONFIG_STATIC=y` and then **verifies** the result
with `file`, failing the build rather than shipping a binary that cannot run.

It also passes `-no-pie`. Alpine's gcc defaults to PIE, and `CONFIG_STATIC` then yields a
*static-pie* (`ET_DYN`) binary, which self-relocates and needs no loader either — but every
busybox known to have booted this TV has been plain `ET_EXEC`, and PID 1 failing to start
is debugged over a serial cable. Not a good place for an untested difference.

It also turns on `CONFIG_FINDFS` and `CONFIG_BLKID`, which busybox's `defconfig` leaves off.
`/init` resolves `root=LABEL=alpineroot` with `findfs`; without it the only symptom is
`no root device matching LABEL=alpineroot after 15s`, fifteen seconds into a boot, with
nothing pointing at the real cause. `build_busybox.sh` asserts both config symbols survived
`oldconfig`, and `build-boot-initramfs.sh` separately reads the applet name table out of the
finished binary and refuses to build an image containing a symlink to an applet that is not
there — a dead link nothing notices until `/init` needs it.

`BUSYBOX=/path/to/busybox` overrides the binary if you already have one you trust.

### The init script

`/init` lives in `alpine/boot-initramfs-init.sh` and is copied verbatim into the image —
it is not generated or rewritten, so that file is exactly what runs as PID 1. If you add a
command to it, add the matching applet to `APPLETS` in `build-boot-initramfs.sh`; the
symlinks are created at build time because `/init` runs before anything could call
`busybox --install`, and the applet check above will stop you if the name is not in the
binary.

---

## 6. Build and write the Alpine rootfs

```sh
./alpine/run_build_alpine_rootfs_docker.sh      # builds into alpine/alpine-rootfs
sudo ./alpine/write-alpine-usb.sh /dev/sdX      # DESTROYS /dev/sdX
```

Give `write-alpine-usb.sh` the **whole device**, not a partition. It refuses non-removable
disks unless you pass `FORCE=1`. It creates a GPT root partition labelled `alpineroot` (ext4)
plus swap labelled `alpineswap`.

Settings live in `alpine/config.sh` — Alpine branch (`edge`, because Plasma Bigscreen is only
in edge/community), filesystem labels, swap size, hostname. **Changing `LABEL` means changing
`root=LABEL=` in the kexec command line too.**

What goes into the rootfs:

- `alpine/packages.txt` — the apk package list
- `alpine/overlay/` — literal files copied over the rootfs; hand-maintained, nothing generates
  it. Three files are templated at build time *in the rootfs copy only*: `etc/fstab`
  (`@LABEL@`, `@SWAPLABEL@`), `etc/apk/repositories` (`@BRANCH@`), and `etc/hostname` (written
  fresh from `TV_HOSTNAME`). Keep the `@...@` tokens when editing the overlay.
- `alpine/tools/*.c` — compiled to `/usr/local/bin/` **inside the container**. A `.c` file's
  presence in `tools/` is what decides whether it ships.
- `ucom` and `fbtest` from the project root, if present, to `/usr/bin/`.

`alpine/overlay/sbin/rc-local` is the boot script: it disables LG's CPU hotplug governor,
brings up the network, starts an **unauthenticated telnet root shell on port 23**, starts
udev/seatd/D-Bus/bluetooth, and creates the unprivileged `tv` session user.

> **The telnet shell has no password at all.** It exists because the project needs access
> without rotating keys on every rootfs rebuild. Fine on an isolated lab network; do not put
> this TV on a shared one.

---

## 7. Copy to the TV

First record your set's own values. The kernel command line needs about twenty fields that
belong to one physical television — MAC address, serial number, `sbkey`, AVS silicon
calibration, model and region options. These are **not** in the repo; they live in
`tv-env.sh`, which is gitignored:

```sh
cp tv-env.example.sh tv-env.sh
$EDITOR tv-env.sh
```

Read each value off the TV while it is booted into stock webOS:

```sh
cat /proc/cmdline | tr ' ' '\n'
```

`tv-env.example.sh` names the command-line field each variable maps to. `boot_kernel.sh`
refuses to run if any of them is unset, rather than booting with an empty `ethaddr=` or
`serialNum=` — the LG drivers accept those and then misbehave in ways that look like kernel
bugs.

Copying the payload across is handled by `boot.sh`, in Step 8 — it is the same step as
booting. **`tv-env.sh` is deliberately never copied**; see Step 8 for why.

**Moving to another TV means editing `tv-env.sh` and nothing else.** Everything
`boot_kernel.sh` adds itself is generic to the o22 SoC:

| addition | why |
|---|---|
| `micom_pet=on` | pets the MICOM watchdog, which otherwise resets the TV ~22 s after kexec |
| `kdrv_skip=GPU_Init` | leaves the GPU registers unclaimed so panfrost can bind instead of LG's kbase |
| `initcall_blacklist=wdt_detect_init` | keeps the SoC watchdog driver out of the way |
| `root=LABEL=alpineroot` | must match `LABEL` in `alpine/config.sh` |
| `loglevel=4` | **not** `ignore_loglevel` — see the warning below |
| `dispopts=skipfw`, `osd.disp.*` | display bring-up without reloading firmware |

> **Never use `ignore_loglevel`.** Every printk is then clocked out of `ttyAMA0` at 115200
> (~10 ms a line) and the kernel blocks on it *even with nothing attached to the port*. It
> wedges the box under verbose logging and silently inflates every latency measurement you
> take. `dmesg` still records everything at `loglevel=4`.

---

## 8. Boot

One command from the project root, with the TV's address:

```sh
sh boot.sh 192.168.1.60
```

`boot.sh` syncs the payload and then boots, so it is both the deploy step and the boot step.
It needs `bash` (it uses arrays and `[[ ]]`), which `sh` is on most distributions but not on
Debian or Ubuntu, where `sh` is dash — run it as `bash boot.sh <ip>` there.

What it does:

1. `mkdir -p os_loader` on the TV — paths are relative to root's home, so
   `/home/root/os_loader`.
2. For each of `kexec`, `Image`, `boot-initramfs.cpio.gz` and `fix_stuck_cpus.ko`: compares
   the local `sha1sum` under `build/` against the copy on the TV and `scp`s it **only if they
   differ**. A re-boot after rebuilding just the initramfs copies ~800 KB rather than 38 MB.
   Missing local files abort with a message instead of booting something stale.
3. Pipes `cat tv-env.sh boot_kernel.sh` into `ssh … "bash -s"`.

That last step is the reason `tv-env.sh` is never copied. It is concatenated *ahead* of
`boot_kernel.sh`, so the variables are already set by the time the script runs, and the serial
number and MAC address never touch the television's filesystem. Neither file is deployed.

Everything `boot.sh` sends comes from `build/`, so the TV only ever receives artefacts the
build actually produced.

### Running the pieces by hand

The boot half alone, against a TV that is already in sync:

```sh
cat tv-env.sh boot_kernel.sh | ssh root@<tv> "bash -s"
```

Or keep `tv-env.sh` on the TV in `/home/root/os_loader/` and run the script there — it falls
back to reading the file when the variables are not already in the environment:

```sh
sh /home/root/os_loader/boot_kernel.sh
```

Either way the payload directory is `/home/root/os_loader`; set `MY_STUFF=` to override.
Piping `boot_kernel.sh` **alone** is the one thing that will not work — it exits with an error
naming both options rather than booting with empty values.

`boot_kernel.sh` retries `kexec -l` until it succeeds, unbinds the watchdog detector, loads
`fix_stuck_cpus.ko`, disables LG's CPU hotplug governor, offlines CPUs 1–3, and calls
`kexec -e`.

Afterwards the TV prints its address on screen and you can reach it with:

```sh
telnet <tv-ip>          # no password
```

There is also a fixed fallback address, `10.213.0.1/24`, for when DHCP fails — put your
machine on that subnet to use it.

---

## 9. Bring up audio

Audio is **not** automatic; it needs three steps after boot. The DSP firmware comes from the
stock eMMC partitions, which the scripts mount read-only themselves.

Copy the tools to the TV (`/usr/local/bin/`) and run:

```sh
NO_RUN=1 AUDFWLOAD=/usr/local/bin/audfwload sh load-audio-fw.sh   # stage firmware only
sh run-lg-bin.sh fwload_audio2                                    # LG's own binary starts the DSPs
dmesg | grep -a 'audio ready'                                     # expect FOUR lines before continuing
SKIP_FW=1 sh audio-up.sh                                          # ALSA controls, incl. the SE volume
speaker-test -D hw:0,0 -c 2 -t sine -l 1
```

`audio_start` in the project root is this sequence as a script.

Notes that save a lot of time:

- **Order matters and it is one-shot.** DSP module registration happens asynchronously after
  each core is released. Touching the mixer early leaves a half-built state that cannot be
  cleared at runtime. If `fwload_audio2` fails with `ioctl(ADBG_IO_RESET) ... Input/output
  error`, check `dmesg` for `dsp boot timeout. 0xN` — the mask says which cores never answered
  — then **reboot** and start over. Retrying without a reboot does not recover, because the
  driver marks every core `DSP_STATE_RUN` even after the timeout.
- `fwload_audio2` is LG's own 32-bit binary from eMMC p28 (`bsp/usr/bin`), run under
  `CONFIG_COMPAT` through stock's own loader. `run-lg-bin.sh` handles the mounting and the
  library paths.
- `audio-up.sh` sets the SE's OSD volume (`LGSE Var Fn009`). Nothing in the kernel initialises
  it and it defaults to **zero**, which produces a perfectly healthy-looking pipeline that
  outputs pure silence. See `PATCHES.md`.
- Volume is `Gain Output[0]`, not `Master Playback Volume` (a dead stub). `audio-up.sh` sets
  unity; stock runs ~74% (`6245466`).

---

## Known-broken / not yet working

- **On-screen keyboard.** kwin reports the Maliit input method `available: false`.
- **Occasional kernel panic around `udevd` during boot.**

## Where to read next

- `PATCHES.md` — every kernel/kdriver change, why it exists, and the measurement traps that
  produced wrong conclusions along the way. Read this before touching the audio path.
- `docs/REPO.md` — what each file and directory in this repo is for, and what can be deleted.
- `notes.md` — kernel command-line fragments, MCU shell commands, runtime register pokes.
