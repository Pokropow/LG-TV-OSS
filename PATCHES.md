# Source patches for booting a custom OS on the LG OLED65C21LA

Every change made to LG's GPL source drops, why it exists, and how to re-apply it to a
freshly extracted tree. Target: LG OLED65C21LA, LG1213 ("o22") SoC, aarch64.

Patches live in `patches/` and are generated against the pristine baseline commit of the
webOS 24 tree (`webos24/` — commit "initial lg kernel for webos 24").

## Trees

| Tree | Path | Kernel | Status |
|---|---|---|---|
| webOS 23 | `SIC_O22_webOS23/` (→ `/mnt/storage/`) | 5.4.96 | first working boot; originals kept as `*.orig` |
| webOS 24 | `webos24/linux-and-kdriver_okapi-3/` | 5.4.268 | current; git-tracked, patches below applied |
| webOS 25 | `soc_GO/linux-and-kdriver_paluma-5/` | 5.4.268 | unused so far |

Each drop contains two separately built components: the kernel (`linux-rockhopper`, or
`kernel/linux-5.4-lg115x` on webOS 23) and LG's display/SoC driver stack (`kdriver`).
Patches 1, 2, 4 and 5 are kernel-side; patches 3, 6 and 7 are kdriver-side.

**Finding every local change in the webOS 23 tree.** It is not under version control, so the
modified files have to be found by timestamp and diffed against `kernel/linux-5.4-lg115x.tgz`.
Filter out build artifacts or the real edits are buried:

```sh
W=/mnt/storage/SIC_O22_webOS23/kernel/linux-5.4-lg115x
find $W -newermt "2026-09-17 14:00" -type f \
     \( -name '*.c' -o -name '*.h' -o -name 'Makefile' -o -name '*defconfig*' \) \
  | grep -vE '/(include/config|include/generated|scripts/|\.tmp_)'
```

## Applying to a fresh tree

```sh
cd webos24                     # the git root
for p in ../patches/*.patch; do git apply "$p"; done
```

To check before applying: `git apply --check ../patches/*.patch`.

`patches/not-working/` is deliberately outside that glob. It holds changes that are real fixes
but did not achieve their goal, kept only as a starting point if someone revisits the problem.
Do not apply them blindly; each carries a header explaining what it does and why it is parked.

### Extract the archive with `tar`, not 7-Zip

7-Zip does not preserve symlinks. It writes each one as a small regular file containing
the link target as text, which breaks the device-tree build with a misleading error:

```
arch/arm64/boot/dts/lg/lg1312.dtsi:8:10: fatal error: dt-bindings/gpio/gpio.h: No such file or directory
```

The cause is `scripts/dtc/include-prefixes/dt-bindings`, which upstream is a symlink to
`include/dt-bindings`. dtc is invoked with `-nostdinc -I$(srctree)/scripts/dtc/include-prefixes`
(`scripts/Makefile.lib`, `DTC_INCLUDE`), so with the symlink flattened there is no include
path to the bindings at all. Check with `ls -la scripts/dtc/include-prefixes/` — the entries
must be `lrwxrwxrwx`, not `-rw-r--r--`. Repair without re-extracting:

```sh
cd scripts/dtc/include-prefixes
for f in *; do [ -L "$f" ] || ln -sf "$(cat "$f")" "$f"; done
```

## The patches

### 0001 — `lg1k`: MICOM watchdog petting

Adds `drivers/soc/lg1k/micom_pet.c` and wires it into `obj-y`.

The MICOM is a separate always-on microcontroller that resets the SoC roughly **22 seconds**
after the main CPU stops talking to it. Stock webOS feeds it from userspace via
`/usr/sbin/micomservice` (killing that process on a stock system reboots the TV 22s later,
which is how this was confirmed). On a kexec'd kernel nothing feeds it, so the machine resets
mid-boot with no panic and nothing in the dump partition — the single hardest bug in this
project, because every symptom pointed at a kernel timer instead.

Userspace is far too late, so petting happens from `early_initcall`. The protocol is
reimplemented from `kdriver/chip/o22/ucom/ucom_o22_func.c`: a 3-byte read of command `0xC0`
through the ARM→MICOM mailbox at `0xF0004000`. Verification of each request is deferred to
the following tick rather than busy-waiting, so it never spins in softirq context.

**Off by default** — petting keeps the machine alive, which is the opposite of what you want
when observing a fault. Opt in on the kernel command line:

| | |
|---|---|
| `micom_pet=on` / `micom_pet` | enable at the default 200 ms interval |
| `micom_pet=<ms>` | enable with an explicit interval |
| `micom_pet=off` | explicitly disabled (also the default) |
| `micom_pet_report=<ms>` | progress-log rate (default 60000; turn up when debugging a reset) |

### 0002 — `btusb`: match LG's rebadged MediaTek Bluetooth

The TV's internal Bluetooth is a MediaTek combo chip behind **LG's own USB vendor ID**
(`043e:3110`), so btusb's existing `0x0e8d` MediaTek match never fires. The interface
descriptor is the standard `e0/01/01` HCI one and the chip self-identifies as `0x7663`/`0x7668`
during setup, so matching LG's vendor ID is all that is needed. Stock webOS instead binds this
device with its out-of-tree `btmtk_usb`.

This is what makes the Magic Remote (MR22N, BLE HID) reachable; it needs `CONFIG_BT_LE` from
patch 0004. LG ships vendor Bluetooth driver sources that cover this chip; they were evaluated
and rejected in favour of this patch — see *Vendor Bluetooth drivers* below.

### 0003 — kdriver: `kdrv_skip=` and `/proc/kdrv_init`

Because `KDRV_GLOBAL_LINK` is defined, LG's subsystem init table in
`kdriver/core/base/base_device.c` is **not** registered as kernel initcalls — `module_init()`
is compiled out and the table is walked directly — so the stock `initcall_blacklist=`
parameter cannot reach any of it. This patch adds the equivalent:

```
kdrv_skip=GPU_Init,PE_Init,DE_Init
```

Names match the kallsyms name of the init function, the same way `initcall_blacklist` does.
`Cfg` is skipped alongside `Init`, so a subsystem that won't be initialised doesn't get
half-configured and have its registers poked anyway.

`GPU_Init` is the important one: skipping it leaves `0xC4250000` unclaimed so **panfrost** can
bind to the `gpu@c4250000` node instead of LG's kbase. Without it both drivers fight over the
same registers. (LG's `libmali` blobs are unusable here regardless — they are 32-bit ARM.)

It also adds `/proc/kdrv_init`: read it to list subsystem names (skipped ones are marked),
write a name to run that subsystem's `Cfg`+`Init` on demand. That is what makes bring-up
debuggable — e.g. `echo DE_Init > /proc/kdrv_init` after boot.

### 0004 — `lg1k_defconfig`: options for a general-purpose userspace

| Option(s) | Why |
|---|---|
| `BLK_DEV_INITRD`, `RD_GZIP` | boot via the kexec initramfs at all |
| `FRAMEBUFFER_CONSOLE`(`_DETECT_PRIMARY`), `FONTS`, `FONT_8x16`, `FONT_TER16x32` | a readable console on a 4K panel |
| `BT_HCIBTUSB`, `BT_HCIBTUSB_MTK` | in-tree Bluetooth for the chip in patch 0002; MTK defaults to n |
| `BT_LE=y` (LG ships it off) | the Magic Remote is BLE HID |
| `BT_BREDR=y`, `BT_HIDP=y` (LG ships BR/EDR off) | classic Bluetooth keyboards/mice — see *Classic keyboards need HIDP* below |
| `DRM_PANFROST` | the open mali-g52 driver — see patch 0003 |
| `LG_BUILTIN_KDRIVER=y` | build kdriver into the image instead of loading modules from an initramfs that proved too large |
| `TMPFS_POSIX_ACL`, `TMPFS_XATTR` | Alpine / systemd-free userspace expectations |

Already set in the webOS 24 defconfig and therefore **not** in the patch, though they were
needed on webOS 23: `INPUT_JOYDEV`, `SQUASHFS_LZ4`, `SQUASHFS_ZSTD`, `UHID`.

#### Classic keyboards need HIDP

Symptom: a classic BR/EDR keyboard pairs, connects, and is immediately dropped, with

```
Bluetooth: hci0: unexpected event for opcode 0x0402
Bluetooth Device /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX disconnected
```

`0x0402` is `HCI_OP_INQUIRY_CANCEL` — a classic command. LG ships
`# CONFIG_BT_BREDR is not set`, and **`CONFIG_BT_HIDP` depends on `BT_BREDR`**, so Kconfig never
offers HIDP and the symbol is absent from the resulting `.config` entirely. There is no HIDP
transport in the kernel.

`CONFIG_BT_BREDR` is a thinner gate than it looks — in `net/bluetooth/Makefile` it controls only
`sco.o`, so core classic HCI and L2CAP are still compiled in. That is why discovery and pairing
succeed: bluetoothd brings the link up, its input plugin then finds no HIDP for the HID channel,
and the link drops. Enabling both options fixes it, and also brings in `sco.o`, a prerequisite
for Bluetooth audio out.

The Magic Remote is unaffected either way — it is HID-over-GATT driven through `UHID`, a separate
path needing neither BR/EDR nor HIDP.

To tell the two transports apart for a given device, `bluetoothctl info <addr>` shows UUID
`0x1124` (*Human Interface Device*) for classic HIDP, or `0x1812` (HoG) for BLE.

Unrelated noise seen alongside this: `advertising data len corrected`
(`net/bluetooth/hci_event.c`) is a ratelimited warning about a nearby LE advertiser sending a
malformed length field.

### 0005 — panfrost: bind to the LG o22 Mali G52

Four independent fixes, all required. Without them panfrost does not come up and Mesa silently
falls back to software rendering, which presents as "the whole system got much slower" rather
than as a GPU error.

1. **`panfrost_drv.c` — compatible strings.** The stock DTB declares `gpu@c4250000` as
   `arm,mali-midgard`, which upstream's `dt_match` does not list, so **panfrost never binds at
   all**. Adds `arm,mali-midgard` and `arm,mali-bifrost`; the real model is read from `GPU_ID` at
   probe, so the compatible only has to match.
2. **`panfrost_device.c` — optional clock.** `gpu@c4250000` declares no clocks (the GPU is
   already clocked by firmware before Linux starts, which is why the vendor kbase platform
   backend for this SoC has empty power callbacks). `devm_clk_get` → `devm_clk_get_optional`, so a
   missing clock means "already running" instead of a probe failure.
3. **`panfrost_device.h` + `_gpu.c` / `_job.c` / `_mmu.c` — IRQ name case.** Panfrost's bindings
   say `job`/`mmu`/`gpu`; vendor DTs written against kbase spell them `JOB`/`MMU`/`GPU`, and
   `platform_get_irq_byname()` is case sensitive — every lookup returns `<= 0` and probe gives
   `-ENODEV`. A `panfrost_get_irq()` helper tries lowercase, then uppercase, then the positional
   lookup (whose order is the same either way).
4. **`panfrost_gpu.c` — power-on.** Upstream polls 1 ms total and ORs four results into one
   `error powering up gpu` message. Each domain is now powered and polled separately with a 100 ms
   timeout and a diagnostic naming the domain and what its READY register actually read back.
   Core stacks are also handled: this is a Bifrost G52 with none, and `GPU_STACK_PRESENT` is
   unimplemented — it reads back the same bitmap as `SHADER_PRESENT`, so the original code waited
   on a domain that does not exist. kbase gates this on a hardware feature bit; panfrost has no
   such gate, so a stack failure is advisory and is latched in `features.stack_unusable` so
   runtime PM does not pay that timeout on every single wake.

Also requires `CONFIG_DRM_PANFROST=y` (patch 0004) and `kdrv_skip=GPU_Init` on the command line
(patch 0003), so LG's kbase leaves `0xC4250000` unclaimed.

### 0006 — aud: fix the signed control minimum for 64-bit userspace

```c
-#define SE_INT_MIN              (0x80000000)     /* core/aud/alsa/alsa_se.c:59      */
-#define ALSA_ADEC_INT_MIN (0x80000000)           /* core/aud/alsa/alsa_decoder.c:61 */
+                                (-2147483647 - 1)
```

`0x80000000` does not fit in `int`, so C types it `unsigned int`. Assigned to
`snd_ctl_elem_info.value.integer.min` (a `long`) it widens to **+2147483648**, which is
*greater than* `max` (`0x7FFFFFFF`). LG's userspace is 32-bit ARM, where `long` truncates it
back to `-2147483648` and the range is valid, so the bug is invisible to the vendor.

On a 64-bit userspace (Alpine aarch64) `amixer` sees `min > max`, clamps every write to `min`,
and the driver rejects the resulting `0x80000000`:

```
alsase ERR _kcontrol_init_put 944: lgse init(2147483648) is LGSE_INIT_LGSE_AISOUND(6).
amixer: Control sysdefault:0 element write error: Invalid argument
```

The macro feeds **12** info callbacks in `alsa_se.c` and **2** in `alsa_decoder.c`, so before
this fix *every* `LGSE *` and `Adec *` control is unwritable. Verified: after the fix the control
reports `min=-2147483648,max=2147483647` and `LGSE SoundEngine Init`/`Mode` accept values.
`core/audio/` holds duplicate copies of both macros but is not in the build (only its
`memcfg.o` is), so they are left alone.

### 0007 — aud: fix the ALSA playback ring protocol

`kdriver/core/aud/alsa/alsa_playback.c`, plus one line in `core/aud/kaimc.c`. Three defects
kept the DSP-side `playback` module and the ALSA ring out of sync, so every stream either
failed with `EPIPE` or delivered nothing. (Merged 2026-10-17 from what were separately 0007
and 0008 — same file, same two functions, and the second always declared a dependency on the
first.)

**1. The module was never started or stopped.** `aplayback_trigger()` only set a local
`is_started` flag and sent the DSP nothing, while the module starts its own output thread the
moment `aimc_module_create()` returns. So:

- it drains the ring while userspace is still prefilling it — by the time ALSA issues
  `trigger: start` (which happens only once the ring is **full**), the hardware pointer has
  already run past the application pointer, and the first write fails `EPIPE` (XRUN);
- it keeps reading the DMA buffer **after** `aplayback_hw_free()` returns it to the HMA pool —
  traced at 100 ms past `hma free done`;
- it logs `playback_output_thread_callback: wrong read ptr 0x00000000` at construction,
  before any `CAPTURE_CMD_SET_BUFFER` can have arrived.

`alsa_capture.c:795` and `lgsic_mc.c:437` drive the *same* `CAPTURE_CMD_SET_BUFFER` /
`CAPTURE_CMD_RESET_BUFFER` protocol and both send `ADEC_CMD_START`/`ADEC_CMD_STOP` from their
trigger. `alsa_playback.c` was the only one that did not.

**2. The write pointer was never announced.** `aplayback_ack()` announced `wrOffset` only
`if (aplayback->is_started)`, but **ALSA prefills the entire buffer before it issues
`TRIGGER_START`**. Every prefill ack was gated off, so nothing was ever sent and the module sat
at `wr == 0`.

**3. A full ring was indistinguishable from an empty one.** At `TRIGGER_START` the open-coded
`appl_ptr % buffer_size` aliases a completely **full** ring onto `0`, the same value that means
**empty**. The module then read `(0 - rdOffset) mod size` as the available count and
burst-drained seven 1024-byte chunks in ~1 ms (log timestamps 150 µs apart) rather than pacing
them over 37 ms, lapping the application pointer → XRUN → `EPIPE`.

Both pointer paths now go through `_aplayback_announce_wroffset()`, which announces on every
ack and holds back one **period** when the ring is exactly full. A period is a whole number of
the module's 1024-byte `process_buf` chunk — the parked patch held back a single **frame**
(4 bytes), which broke that alignment and caused the same runaway by a different route
(observed `wr` values 8188, 1020, 3068: always 4 short of a chunk boundary).

**The `kaimc.c` hunk is a consequence of fix 2.** `aimc_set_property()` allocates with
`GFP_KERNEL`, and announcing from every ack means calling it from **atomic context**: ALSA
invokes `ops->ack()` with the PCM stream lock held and interrupts disabled
(`sound/core/pcm_lib.c:2092`, from `__snd_pcm_lib_xfer`). LG's original code had the same
defect behind the `is_started` gate; removing the gate makes it fire on every ack, so the
allocation becomes `GFP_ATOMIC`. It is small and freed before the function returns.
`aimc_send_command()` (fix 1) allocates nothing and `IMC_SendCommand()` does not sleep, so the
rest of the path was already safe.

How this was found, since every earlier reading was partial: the module's own `prop` and
`log-mask` are writable at runtime (`/proc/aaudio/processors/dsp2/playback/<uid>/prop`), and
raising the mask to 31 makes it print `process_buf: wr 0x... rd 0x... data->size 1024`.
Logging that against the kernel's `aplayback_ack` line on one timeline
(`alpine/tools_unused/ring-trace2.sh`) is what showed the two sides disagreeing.

**Traps that cost time here** — each of these produced a confident wrong conclusion:
- The kernel's `aplayback->rdOffset` lags badly; reading it suggested "the DSP consumes
  nothing". The DSP's own `rd` shows it consuming at exactly real time (1024 B / 5.33 ms =
  192 KB/s for 48 kHz stereo S16).
- The `wrOffset=(int)` in the module's `prop` dump is **stale heap data** — a DSP pointer such
  as `0x6040F368`, constant across a whole stream. `wrOffset` *is* delivered; only
  `process_buf`'s `wr` reports it truthfully.
- `wrOffset(0x%x) == rdOffset(0x%x), buf_full = TRUE` exists in the dsp2 firmware strings but
  belongs to a different path; the read path treats `wr == rd` as empty
  (`no data. wait.. read/write 0x%08x`).
- Writing a property and seeing no change proves nothing on its own — the kernel's `ack`
  overwrites `wrOffset` within milliseconds. Always write `log-mask` first as a control.

The firmware blobs are worth remembering as a source: `audio_a0_dsp2.bin` (in
`firmware.tar.gz`) carries the module's own symbol and format strings —
`playback_set_wrOffset`, `playback_prop_updated`, `"%s: updated %s=%d"`, and the `START` /
`STOP` / `INIT` names next to `mod_capture`.

**Verified (2026-10-17).** `speaker-test` runs with zero `EPIPE` **at the default buffer size**,
`rdOffset` advances at real time, and the audio is provably present from the ALSA ring through
every stage of dsp2 and across into dsp1.

## Audio: working

**WORKING as of 2026-10-17.** `speaker-test` plays audibly through the TV speakers from our
kernel via ALSA. The last blocker was the SE's OSD volume sitting at zero (see "The SE's OSD
volume is zero" below); `alpine/tools/audio-up.sh` now sets it. The full bring-up is:

```sh
NO_RUN=1 AUDFWLOAD=/usr/local/bin/audfwload sh load-audio-fw.sh   # stage only
sh run-lg-bin.sh fwload_audio2                                    # LG's own binary
SKIP_FW=1 sh audio-up.sh                                          # controls, incl. SE volume
speaker-test -D hw:0,0 -c 2 -t sine -l 1
```

**Tool layout.** `alpine/tools/` holds what the bring-up needs plus the four diagnostics still
worth reaching for (`audio-snapshot.sh`, `shared-peek2.sh`, `dsp1-deep.sh`, `chain-trace.sh`).
Everything one-off, superseded or dead-ended moved to `alpine/tools_unused/`, which has a
README recording what each one settled — and warning which of them encode measurement methods
now known to be wrong. Note `build-alpine-rootfs.sh` compiles every `tools/*.c` into the
rootfs, so a `.c` file's location decides whether it ships.

The history below is kept because most of it is still load-bearing — the bring-up sequence, the
measurement traps, and the patches — and because several confident conclusions along the way
were wrong in instructive ways.

**The default ALSA buffer is fine.** `speaker-test -D hw:0,0 -c 2 -t sine -l 1` plays with no
`-b`/`-p` override and no EPIPE. The old `-b 680000 -p 170000` (~680 ms) workaround is
obsolete: it was never the fix — patch 0007 stopped the EPIPEs — and it was sized from
latency measurements that the `ignore_loglevel` console stall had inflated. The diagnostic
scripts in `alpine/tools/` and `alpine/tools_unused/` still hardcode it; harmless, but comments calling it "the size
that stopped the EPIPEs" (`chain-trace.sh`, `playback-probe.sh`) are wrong.

### DSP bring-up: use LG's `fwload_audio2`, not our `FWLOAD_IOCTL_RUN`

This is the correct bring-up and it supersedes the `audfwload`-only sequence:

```sh
mkdir -p /mnt/mmc27 /mnt/mmc28           # run-lg-bin.sh mounts these itself
NO_RUN=1 AUDFWLOAD=/usr/local/bin/audfwload sh load-audio-fw.sh   # stage only
sh run-lg-bin.sh fwload_audio2                                    # LG's own binary
SKIP_FW=1 sh audio-up.sh                                          # controls only
```

`fwload_audio2` lives on **eMMC p28 under `bsp/usr/bin`** (not the p27 rootfs). It is 5.5 KB
and links only `libc.so.6` + `libgcc_s.so.1` — no LG audio library, no IPC — so it runs
standalone on Alpine under `CONFIG_COMPAT` via stock's own loader
(`/mnt/mmc27/lib/ld-linux.so.3`, soft-float ABI, *not* `-armhf`). That is what
`alpine/tools/run-lg-bin.sh` does.

All it does is open `/dev/adebug` and issue **`ADBG_IO_RESET`** (`_IO('G', 6)`,
`core/aud/include/aud_kapi_debug.h:48`), which reaches `aud_dsp_reset()`
(`core/aud/dsp_control.c:624`):

```c
aud_dsp_halt ();
for (i = 0; i < number_of_dsp; i++)
    aimc_set_dsp_dead (i, false);   // now, kaimc can send command...
return _aud_dsp_reset ();
```

and `_aud_dsp_reset()` (`dsp_control.c:544`) does five things our `FWLOAD_IOCTL_RUN` never did:

1. registers a `firmware-init-done` named event on `ADEC_CORE_ARM` and **waits for every DSP
   to report it** (`booting_mask == 0`, `aud_dsp_boot_timeout` ms) — the real boot handshake
2. `aimc_stop(); aimc_start();`
3. `fwload_load_backup_image(name,"rom")` → `fwload_reset(name)` → `fwload_unload_backup_image()`
4. `bm_resume()`
5. sets `dsp_infos[i].state = DSP_STATE_RUN` so the heartbeat monitor adopts the cores

Our `FWLOAD_IOCTL_RUN` is only step 3's middle call. `reset audN done.` in dmesg is just the
halt-release — it is **not** confirmation from the DSP. With `fwload_audio2` all four cores
answer:

```
audio ready. dsp0v20, e376444,... Mon Jul  1 15:02:52 KST 2024
audio ready. dsp1v20 / dsp2v20 / dsp3v20
register_processor: new processor. dsp0..dsp3, proc_id 2..5
bm_resume done
```

Run it with nothing staged and you get `dsp boot timeout. 0xf` plus a register dump — that
is the signature of a missing `NO_RUN=1` stage, not of broken firmware.

`SKIP_FW=1 audio-up.sh` exists so a failed external bring-up stays visible instead of being
papered over by our RUN path.

**Working and reusable**
- `alpine/tools/audfwload.c` + `load-audio-fw.sh` — stages all four images byte-identically
  to stock (`FWLOAD_IOCTL_CONFIG` per image under the name `rom`). Use `NO_RUN=1` and let
  `fwload_audio2` start the cores, per above. `FWLOAD_IOCTL_RUN` works in the narrow sense
  that the cores execute, but it skips the handshake and leaves `dsp_infos[].state` wrong.
- `alpine/tools/run-lg-bin.sh` — runs stock 32-bit ARM binaries via stock's own dynamic
  loader, searching `bsp/` and plain layouts across p27 and p28.
- `alpine/tools/audio-up.sh` — the control sequence (SE init/mode/index, sndout
  MainAudio/Open/Spk/Connect, unmute), with readiness polling on
  `/proc/aaudio/processors/dsp2/mixerbin` etc.
- `alpine/tools_unused/fader-bypass.sh` — bypasses the mixer-input fader, which does change
  behaviour: it woke `output_speaker` on dsp1 for the first time (`speaker underflow`).
- `alpine/tools_unused/audio-dump.sh` — snapshots every live module instance during a stream.

**How far it gets.** The pipeline builds end to end —
`playback → pcmcvt → sola → lipsync → mix_lg(input4) → mixerbin` with all four mixerbin output
ports connected — the SE resolves, the speaker output module runs, and `wrOffset` is now
computed and delivered correctly. But `rdOffset` barely advances: the DSP playback module
consumes a few KB at most and then stops, the fader starves
(`_fader_process_data_fadeout: send zero data`), and the write fails with `EPIPE`.

### Ruled out this session

- **`AUDIO_GetLgbusAddr` / `aud_hal_phys_to_aud_bus`.** `alsa_playback.c:503` carries LG's own
  TODO on the line that hands the DSP the ring address (`//TODO: AUDIO_GetLgbusAddr??`), and the
  previous-generation driver *does* translate (`core/audio/alsa/mc.c:310`), as does the working
  capture path (`core/aud/alsa/lgsic_bc.c:461`). But the translation bottoms out in
  `fwloadwov_wovbus_addr()` (`core/fwload/fwload_wov.c:555`), which is `return address;` —
  identity. Adding the call changes nothing on o22. (It does reveal that `buf_addr_p` is
  `unsigned int` while `dma_addr` is a 64-bit `phys_addr_t`, so a pool above 4 GB would
  truncate — worth checking the printed address, but not a translation bug.)
- **"Do it the way webOS does."** Not available to us. Stock's userspace audio enters through
  an `appsrc` module on an **ARM-side processor** (`processor_7`, alongside `appsink`,
  `dec_pcm_arm`, `filesrc`, `wavsrc`, `beep`) which feeds a `glue` pair into dsp0's
  `input_queue → decoderbin`. That is the graph a stock YouTube session shows. Those module
  implementations are registered by LG's closed audio daemons, not by the kernel — `appsrc`
  appears in the GPL tree exactly once, as a comment in `core/aud/renderer.c:31` listing
  "possible input of renderer". Reproducing it means reimplementing LG's userspace stack.
  So the ALSA `playback` path, dead code though it is in LG's own product, is the only route.

### Where it stands after 0007 + 0008 (2026-10-11)

**The ALSA side is fixed and verified.** `speaker-test` runs with **zero EPIPE**, and the audio
is provably present at every stage on dsp2, read straight out of physical memory via
`/dev/mem` (`CONFIG_STRICT_DEVMEM` is off):

| buffer | ours | stock |
|---|---|---|
| `alsa_playback` ring | 129739 non-zero (clean sine) | — |
| `mixerbin` out0 bufs | ~114000 | ~216000 |
| `mixerbin` out2 (→dsp1) | 28581 | 101537 |
| `bc-speaker` (the DAC's buffer) | **1 (pure zeros)** | **7430 (4ch × 32-bit PCM)** |

So data reaches the dsp2→dsp1 hand-off and dies somewhere in
`gluepr → bypass → dap → se → queue → outctrlbin → output_speaker`.

**Everything configurable already matches stock**, compared property-for-property with
`alpine/tools/audio-snapshot.sh` run on both: the `dap` prop block is **byte-identical**, `se`
shows `bypass_mode=true` on both, `output_speaker` has `output-channels=4` on both (stock
writes L/R into ch0/ch1 and zeroes ch2/ch3), `sndout` reports `[SPK] Open=1 Connect=1 Mute=0`.
The only real differences are `main-audio-port` (0 on stock's ADEC path, 4 on our ALSA path)
and `dmx-mode` (1 vs 0 — LTRT/LORO downmix, only ever set from `alsa_decoder.c`, so not a
silence cause).

The one behavioural difference: our speaker `queue` sits at **`state=wait`** (starved) where
stock's is `state=running`.

**Dead ends, all closed with measurements:** the fader (bypassing both changed nothing, and
`dsp2/fader` was already `running`); the SE (`SE_INIT=1` builds a pipeline with no `dap` at
all — still silent; and forcing `bypass_mode=1` on the SE — still silent); gains (every stage
reads `current-gain=0x800000`); `Mute Input`/`Mute Output`; a missing amplifier driver (the DT
has **no** audio nodes at all — it is all `kdriver` register writes); `output-channels`.

**Traps that produced wrong conclusions here**, worth not repeating:
- **`ignore_loglevel` on the kernel cmdline.** Every printk is clocked out of `ttyAMA0` at
  115200 (~10 ms a line) and the kernel blocks on it, even with nothing attached. Verbose DSP
  logging wedged the box, and *every latency number measured before this was found is
  suspect* — including the "hundreds of ms IPC round trip" that motivated the large ALSA
  buffer. `boot_kernel.sh` now uses `loglevel=4`; `dmesg` still records everything.
- **Sampling 2 KiB of a 256 KiB ring** and concluding the mixer output was silent. Scan whole
  buffers (`deep-peek.sh`).
- **Reading a channel slot out of a ring dump.** The apparent position of the live sample moved
  between word 0, 4 and 6 across runs — it tracks wherever the write pointer happened to be,
  not the channel layout.

### dsp1 is not starved — it moves silence (2026-10-17)

The stock-vs-ours dsp1 diff is done, and it clears the entire dsp1 chain.

**`dap_chain` fires once per `dap_write_pcm`** (69 and 69 over the same window). An earlier
reading that our DAP "never logs `dap_chain`" was an artifact: `dsp1/dap` was absent from
`chain-trace.sh`'s `CHAIN`, so its `log-mask` was never raised. Two further traps in the same
script, both now fixed — the display `grep` had no pattern matching `dap_chain` (only the
counts block saw it), so even once raised the lines did not print.

Our dsp1 runs at stock's cadence with stock's sizes:

- `gluepr_03100003` (the speaker path) advances **+8192 bytes per cycle** — stock's exact
  `dap_chain: input 8192. all 8192`
- `dap_write_pcm: output data 2048 bytes`, the same 4:1 reduction stock does
- `out_chain_bc: data size 00000800` into an 8 KiB ring, and `bc-speaker` in the HMA pool is
  8 KiB at `0x8304c400` — so the module is demonstrably writing into the buffer we peek
- `underflow 0`; `output_speaker` reports **`bc-filled=6656`** against stock's **5632**

Ours feeds the DAC buffer *harder* than stock and `bc-speaker` still reads as 8 KiB of zeros.

**The DAP is not the culprit either**, and this is the decisive pairing: `SE_INIT=1` builds a
pipeline with **no `dap` at all** and is silent, while `SE_INIT=5` builds one **with** the DAP,
fed 8192/cycle at stock's cadence, and is also silent. Removing the module and feeding the
module both yield silence, so dsp1 is transporting silence, not producing it.

Config is not the difference. `dsp1/output_speaker` is byte-identical to stock; `dsp2/mixerbin`
differs only in `main-audio-port` (4 vs 0, inherent to the ALSA-vs-ADEC path) and `dmx-mode`.
Stock does carry one structural extra — a second `queue` (`03180002`) and a third `outctrlbin`
— which fully explains stock's `push data` being 2× its `write_pcm` where ours is 1×. That is
an instance count, not a defect.

**The one unexplained number**, and the next thing to measure. Non-zero density by buffer:

| buffer | ours | stock |
|---|---|---|
| `alsa_playback` | 49% | — |
| `mixerbin` out0 | 21.7% | — |
| `mixerbin` out2 (→dsp1) | **5.5%** | **19.4%** |

On stock, out2 matches its own out0. On ours, out2 is **4× below our own out0** — so the
hand-off buffer into dsp1 looks underfilled relative to the mixer's other outputs on the same
box. But byte-density is precisely the metric that produced two earlier wrong conclusions, so
it is evidence of a question, not of an answer.

### The `f4e201ff` fill pattern, and why non-zero counts cannot find audio (2026-10-17)

`shared-peek.sh` run on both boxes turned up a repeating 16-byte pattern filling large parts of
several chunks, including `bc-speaker`:

```
f4e201ff a5ee1bcc 7823f96d 34ba123b    (repeated to fill the region)
```

**It is present identically on stock, which is producing sound.** It is untouched/fill memory,
not silence and not a failure signature, and its presence or absence proves nothing.

It also breaks every "non-zero" metric used here so far, including `shared-peek.sh`'s own
densest-block selector, which picked a pattern block on *both* machines: the pattern is 100%
non-zero, while real PCM is only ~50% non-zero (half the 32-bit words are a silent channel, and
24-bit samples carry a `00` high byte). **Dense means fill; sparse may mean audio.**

**Use distinct-word count instead.** The pattern has exactly 4 distinct 32-bit words; real PCM
has hundreds. `alpine/tools/shared-peek2.sh` scores every 4 KiB block that way and dumps the
block with the most distinct words, so it can never land on the pattern again.

**What real audio looks like here**, for recognising it by eye:

| buffer | sample |
|---|---|
| `alsa_playback` (ours) | `62b30000 641d0000 65330000 65f20000` — smooth 440 Hz ramp, R channel zero |
| `mixerbin` (ours, `0x86a95000`) | `00000000 41310000 00000000 45a20000` — one channel silent |
| `mixerbin` (stock, `0x86b15000`) | `5cfb0000 5a5a0000 576c0000 54340000` |
| `bc-hp` (stock) | `006170b3 00614cf7 00000000 00000000` — **the DAC layout**: 24-bit L/R in ch0/ch1, ch2/ch3 zeroed, matching `output-channels=4` |

**`bc-speaker` still separates the two boxes**, with the confound removed. Same name, same
address `0x8304c400`, same 8 KiB on both:

| | block 0 | block 1 |
|---|---|---|
| ours | 256/1024 non-zero — *exactly* the 1024-byte fill pattern, nothing else | **0** |
| stock | 640/1024 | dense |

So ours holds the fill pattern and nothing past it, while `output_speaker` reports
`bc-filled=6656`. Stock holds real PCM past the pattern.

**HMA chunks are not 4 KiB aligned.** `bc-speaker` starts at `0x8304c400` — 1 KiB aligned but
not 4 KiB aligned — so `dd bs=4096 skip=addr/4096` truncates to `0x8304c000` and reads
`bc-sai2` plus only the first 3 KiB of `bc-speaker`. That is what made `bc-speaker` appear to
contain the fill pattern on *both* boxes; the pattern was in the neighbouring chunk. **Read HMA
chunks in 512-byte units.** `shared-peek2.sh` now does, and its 512-byte breakdown agrees with
the original `snap-ours` figure, so only the block view was ever affected.

**Stock's `bc-speaker`, correctly aligned — this is the target to reproduce:**

```
OFFSET      NONZERO   DISTINCT       020cb6e6 020cb6e6 00000000 00000000
0x0000           63         57       022cc122 022cc122 00000000 00000000
0x0200           64         33       024b68fa 024b68fa 00000000 00000000
   ... every window 64/128 ...       026a5d82 026a5d82 00000000 00000000
```

Exactly 64 non-zero words of 128 in **every** 512-byte window — the 4-channel layout, L/R
carrying data and ch2/ch3 zeroed, L == R for a mono source. Ours reads 0 non-zero in all
sixteen windows.

**`mixerbin_*` and `alsa_playback` chunks exist only while the DSP modules and the ALSA stream
are live.** A pool with no `mixerbin` chunk means the bring-up did not happen and every buffer
will read as zeros for an uninteresting reason. `shared-peek2.sh` warns about this now.

**Chunk addresses do NOT correspond between the two boxes** — stock has **four**
`mixerbin_04280001` chunks to our three, and `0x86b15000` is a mixerbin buffer on stock but
`alsa_playback` on ours. The note above that `0x86ad5000` is the out2→dsp1 hand-off is true on
our kernel only. Resolve chunks by name, always.

### dsp1 receives correct audio and emits zeros (2026-10-17)

`shared-peek2.sh` on both boxes settles it. Stock's fourth `mixerbin` chunk (`0x86b55000`) and
our third (`0x86ad5000`) have the identical block-map shape `*PPPPPPP::::…` — the same role, the
out2→dsp1 hand-off — and both carry an **8-word (32-byte) frame**:

```
stock 0x86b55000     00000000 00000000 01d40000 01d40000    <- slots 6,7 (L=R, mono source)
ours  0x86ad5000     00000000 00000000 00000000 473c0000    <- slot 7 only
```

We fill slot 7 and not 6 only because `speaker-test` drives one channel at a time. The payload
is a clean descending sine (`473c 42e0 3e4c 3983 3489 2f63`) and the distinct-word count
confirms the layout exactly: 129 = 128 samples + the zero word = 1024/8.

**So dsp1 is handed correct audio, in stock's format, and writes zeros to the DAC.**

The dsp1 graph is topologically identical to stock's:

```
stock:  gluepr_03100004 -> bypass_03160002 -> dap_031e0001 -> se_031d0001 -> queue_03180002 -> outctrlbin_032e0003 -> output_speaker
ours:   gluepr_03100003 -> bypass_03160002 -> dap_031e0002 -> se_031d0002 -> queue_03180001 -> outctrlbin_032e0002 -> output_speaker
```

Stock's extra `queue`/`outctrlbin` pair is just its SPDIF output
(`queue_03180001 -> outctrlbin_032e0002 -> output_spdif`), which we do not wire. **That fully
explains stock's instance counts and its `push data` being 2x its `write_pcm`** — it is not a
defect and is not worth chasing. Our speaker `outctrlbin_032e0002` is `mute-output=false` at
unity gain; the muted `032e0001` correctly feeds `output_hp`. Stock's speaker `outctrlbin` runs
`gain=6245466` (~74%) and `delay=60` where ours is unity/0 — quieter on stock, so not a silence
cause, but that is where real volume lives when it is time to set it.

### `bc-speaker` is the right buffer, and the DAC works (2026-10-17)

`bc-probe.sh` stamped all 8 KiB of `bc-speaker` with `0x01` bytes while a tone played:

| step | result |
|---|---|
| before | 0 / 2048 non-zero words |
| immediately after the stamp | 1792 / 2048 — the first 1024 bytes were **already** re-zeroed |
| +0.5 s | 0 / 2048 |
| +2.5 s | 0 / 2048 |

**`output_speaker` owns that buffer and writes zeros into it**, fast enough to erase a full
8 KiB stamp inside half a second (the DAC consumes ~768 KB/s, so the 8 KiB ring turns over in
~11 ms). The "allocated but never touched" alternative is dead.

**The stamp was audible as a click — so the DAC and the entire analogue path work.** That had
never been confirmed, and it removes the amplifier/codec/routing class of explanation for good.

**The instance-count asymmetry is explained and closed.** Stock's speaker queue is `03180002`,
not `03180001` (`03180001` is its SPDIF) — earlier comparisons risked pairing the wrong
instances. Paired correctly, our `queue_03180001` and stock's `queue_03180002` are identical
except `state=wait` (ours) vs `state=running` (stock), which is the already-known starvation
symptom. `dap` and `se` are byte-identical to stock apart from a profiling counter.

So: correct input, identical topology, identical props, working DAC, zeros out. The difference
must be module **internal state**.

### The SE's OSD volume is zero — THIS WAS THE BUG (2026-10-17)

`dsp1-deep.sh` read each instance's **`lstatus`** — never collected before, since
`audio-snapshot.sh` only ever took `prop`. It reports live sample values and internal state,
and it found the difference.

**The `dap` is working.** Ours:

```
= multch input sample value
= L  :0xb9600000, R :0x       0, ...      <- real input
= 2ch output sample value
= L  :0xcd197b00, R :0xfffd0200,          <- real OUTPUT
```

and the `se` passes the byte count straight through (`inbyte/outbyte 347330560/347330560`).

**The one real difference:**

| | ours | stock |
|---|---|---|
| `OSD Volume Gain` | **`0x00000000`** | `0x00007004` |
| `OSD Volume Index` | **`0x00000000`** | `0x00176d37` |

A volume of zero explains every observation simultaneously: correct audio into dsp1, the dap
producing real output, correct byte counts and cadence through `queue`/`outctrlbin`/
`output_speaker`, zero underflows — and perfectly-sized blocks of **silence** in `bc-speaker`.

**Checked and discarded:** the `se`'s own input/output sample values read `0x0` on **both**
boxes, so those fields are simply not populated in bypass mode. They are not evidence.

**The control.** `core/audio/alsa/alsa_se.c:1089` registers `"LGSE Var Fn009"` at index 0 for
`LX_AUD_MASTER_SE_ID_0` (the speaker), payload `LGSE_VAR_FN009_NUM` = `2 * 4` bytes, and
`alsa_se.c:960` pins the layout down:

```c
noti ("Fn009_Var(OSD Volume): SE_ID=%d, Index=%d, Gain=0x%X, UI Vol=%d",
      se_id, param_index, vol[0], vol[1]);
```

so `vol[0]` = gain, `vol[1]` = UI volume. `alpine/tools_unused/se-volume.sh` writes **stock's own
observed values** — `0x00007004`, `0x00176d37`, little-endian — rather than invented ones, and
prints the driver's `Fn009_Var` log line to prove the put reached `_se_func_put` (a silent
amixer failure would look exactly like the theory being wrong).

This also retires the broader parameter-memory worry: it is not that the whole SE table set is
missing, it is one specific variable that stock's audio daemon writes at startup.

**CONFIRMED — this was the bug.** Writing the control made the TV play:

```
amixer -c 0 cset name='LGSE Var Fn009' 4,112,0,0,55,109,23,0
  : values=0x04,0x70,0x00,0x00,0x37,0x6d,0x17,0x00

bc-speaker non-zero words:  0 / 2048   ->   1019 / 2048
```

1019/2048 is ~50%, exactly stock's density (64/128 per 512-byte window: L/R carrying data,
ch2/ch3 zeroed) — and the tone was audible. `audio-up.sh` now writes it as part of the normal
bring-up, as `SE_VOL_GAIN`/`SE_VOL_UI`.

**Trap for next time:** the driver's `noti("Fn009_Var(OSD Volume): ...")` in `alsa_se.c:960`
does **not** reach `dmesg` at the default log level. Its absence does not mean the write
failed — verify with the amixer readback or the module's `lstatus`, never with that log line.

**Why this hid for so long:** a gain of zero is multiplicatively invisible. Every counter,
every byte count, every cadence measurement and every module property stays exactly correct,
and the only observable is that the samples are zero — which looks identical to "no data is
arriving", which is what sent the investigation upstream again and again. The lesson that
actually generalises: read `lstatus`, not just `prop`.

**Superseded:** `dsp1-deep.sh`, on both boxes. Two sources of internal state had never been read: `status`/`lstatus`, and trace-level logging.


**Superseded:** `bc-probe.sh` tested the assumption that `output_speaker` writes into the chunk
named `bc-speaker`, and answered it.



Chunks must be resolved **by name**, never by address — the pool layout differs between our
kernel and stock, and a hardcoded `0x86ad5000` silently reads the wrong memory on the other box.

**Resolved, kept for the record.** "Why the playback module does not consume" was the open
question here for months. Patch 0007 answered it: `rdOffset` now advances at real
time and `speaker-test` runs with zero EPIPE. The `wrOffset` readback from the instance's
`prop` file is stale heap data and was never a usable signal.

**Parked, not applied:** `patches/not-working/aud-alsa-playback-ring-and-lifecycle.patch.NOT-WORKING`.
Every part of it is now either superseded or ruled out, so it is kept only as a record of what
was tried:

| its change | verdict |
|---|---|
| `trigger(START)` announcing an empty ring when it was exactly full | **superseded** — 0007 fixes this, correctly |
| the full/empty ambiguity, holding back one **frame** (4 bytes) | **wrong** — breaks the module's 1024-byte `process_buf` alignment; 0007 holds back one *period* |
| `ack`/`trigger` sending IPC from atomic context, deferred via a workqueue | **superseded** — 0007 makes the allocation `GFP_ATOMIC` instead, which fixes the same defect without changing announcement timing |
| `_aplayback_updated()` never updating the write pointer | moot; the `prop` readback was always stale heap data |
| moving module creation from `open()` to `prepare()` | ruled out — the thread logs `wrong read ptr 0x00000000` within 0.3 ms of construction, before `SET_BUFFER` can be sent, and the two are necessarily sequential |


**Ruled out — do not spend time here again**
- **The `Adec *` controls cannot play host audio.** `adec_src_port_index_ext_type_t` contains
  only hardware sources (ATP0/1, ADC, AAD, HDMI0-3, DisplayPort0/1, HDMI_DEFAULT) and the
  header says so explicitly. They configure the tuner/HDMI decoders.
- **ALSA decoder devices 8-9 are compiled out.** `USE_DIRECT_CODEC` is defined nowhere in the
  build and `Direct Codec` is absent from `vmlinux`. They would also share the same ring.

**The AAPI route — no longer needed.** `core/aud/aud_cdev` + `core/aud/aapi_media.c`
(`renderer_set_param`, `aren_set_bypass_fader` and friends) is the character device starfish
actually drives, which is why the ALSA PCM path was full of unexercised-code bugs. It was the
fallback plan for years. The ALSA path now works, so this is recorded only as context for why
so many defects were found in it, not as a route to take.

**Traps worth remembering**
- **Outputs are muted by default** — `alsa_sndout.c:7026` sets `param_output[i].mute = 1`
  (inputs default to `mute = 0`, gain `0x800000` = unity).
- **`Master Playback Volume` and `Volume0` are dead stubs** — `vol_put()` in
  `alsa_codec.c:246` is entirely inside `#if 0`. Real volume is `Gain Output[0]`
  (stock: `6245466` ~= 74% of unity). Anything driving volume later must use that.
- **DSP module registration is asynchronous** after each core is released. Touching the mixer
  first gives `no such implementation on N. mixerbin` and leaves half-built blocks that cannot
  be cleared at runtime (`bm_destroy_block` is only reachable via the audio debug chardev).
  Reboot between attempts; `audio-up.sh` refuses to reload firmware into a partial state.
- **`amixer controls` aborts partway.** The SE *parameter* controls are registered against
  indices from `se_get_parameter_list()`'s static pre-list, so their `.info` fails
  (`_kcontrol_param_info: invalid value 0x310158`) and enumeration stops there — before every
  `LGSE *` and `Sndout *` entry. **Address controls by name, never by a numid from that listing.**
- **`stock-amixer.txt` gives target state, not write arguments.** `Sndout Open` takes one
  output per call and its GET accumulates a bitmask (stock reads `3` after two calls; writing
  `3` fails `convert_type`); `LGSE SE Index Matched Output` is written `(output, index)` but
  reads back a per-output vector; `Gain Input`/`Mute Input` are `(index, value)` pairs.
- **`Sndout MainAudio Output` must be `16,0` here, not stock's `1,0`.** Stock's main audio is
  the tuner (`COMMON_INPUT_ADEC`); an ALSA PCM renderer lands on mixer **input4**
  (`COMMON_INPUT_AMIXER` port 0 -> `master_index = port + ALSA_SNDOUT_DEC_NUM`).
- **`ignore_loglevel` is on the kernel command line**, so `echo N > /proc/sys/kernel/printk`
  does nothing. Capture proc files to a file and read them back after the stream stops.
- **Module instance `prop` files take two space-separated tokens** (`bypass 1`, not
  `bypass=1`) and exist only while the instance does.

## Vendor Bluetooth drivers (evaluated, not used)

LG's webOS 24 GPL drop includes three Bluetooth driver sources, in
`~/Downloads/webos24_sources/code/`. None of them is used; patch 0002 is used instead.

| Source | Chip | Verdict |
|---|---|---|
| `rtk_btusb_70.tar.gz` | Realtek (`bluetoothdrv-rtk`) | wrong vendor — a different SKU's module |
| `opensource.mt7921_bt_driver.zip` | MT7961/7921 (`BT_RAM_CODE_MT7961_*`) | wrong chip |
| `opensource.bt_driver.zip` | **btmtk_usb** — MT7662/7663/**7668** | correct chip, but unusable with BlueZ |

`opensource.bt_driver` is the driver stock webOS actually binds, and it matches this exact
device — from `bt_driver/btmtk_config.h`:

```c
{USB_DEVICE_AND_INTERFACE_INFO(0x043e, 0x3110, 0xe0, 0x01, 0x01), .bInterfaceNumber = 0}, /* MT7668U Markone */
```

**Why it is not used: it exposes no HCI device.** It includes `net/bluetooth/hci_core.h` but
never calls `hci_register_dev()` or `hci_alloc_dev()`. Instead it registers char devices
(`/dev/stpbt`, `/dev/stpbtfwlog`, `/dev/stpbt_sco`) at `FIXED_STPBT_MAJOR_DEV_ID 111` — which
matches the stock log line `btmtk_usb_fops_close: major 111 minor 0` captured from this TV.

That is MediaTek's "STP BT" architecture: the kernel module is a dumb pipe and *userspace*
drives HCI over the char device. BlueZ needs an `hciX` interface, so adopting this driver means
losing `bluetoothd`, `bluetoothctl`, `btmon` and the BLE HID notifications that feed the
`magicremote` uhid bridge, unless LG's or MediaTek's userspace BT stack is ported to Alpine
first. Patch 0002 gets the same hardware working through the in-tree stack with one match entry.

Two things from these sources are still worth keeping:

- **Chip identity confirmed as MT7668U**, which is natively handled by in-tree btusb
  (`case 0x7668` in `btusb.c`).
- **Firmware fallback.** In-tree btusb loads `mediatek/mt7668pr2h.bin`, currently resolved from
  stock's `/lib/firmware` via the mounted emmc. The vendor archive ships
  `bt_driver/mcu/bin/mt7668_patch_e2_hdr.bin` and `woble_setting_7668.bin` — a different
  filename and probably a different header wrapper, so not a drop-in rename, but that is where
  a blob would come from if the dependency on mounting the stock partition ever needs removing.

**Version flag:** the kernel build tree bundled inside `opensource.bt_driver` is named
`linux-rockhopper_build_o24_5.4.96-304`, while the `okapi-3` drop's `linux-rockhopper` is
**5.4.268**. Those are not module-compatible. Check what the running kernel reports before
building any out-of-tree module for this TV.

## Deliberately NOT ported from webOS 23

### Root-cgroup PSI null-deref fix — fixed upstream in 5.4.268

On webOS 23 (5.4.96), writing `memory.pressure` in the root cgroup oopsed the kernel: the
root cgroup's `psi_group` is never `group_init()`ed, the show paths substituted `psi_system`
inline, but the write path handed the uninitialised struct to `psi_trigger_create()`, whose
`list_add()` then dereferenced a NULL list head. **elogind does exactly that on startup.**
The webOS 23 fix moved the substitution into the `cgroup_psi()` helper
(`include/linux/cgroup.h`, `kernel/cgroup/cgroup.c`).

5.4.268 already carries an equivalent upstream fix — `cgroup_pressure_write()` does
`psi = cgroup_ino(cgrp) == 1 ? &psi_system : &cgrp->psi`. **Do not re-apply it.**
(This is also why `seatd` was usable as an `elogind` alternative on webOS 23.)

### `pm_o22_governor.c`

An experiment to expose `mp_enable` as a kernel parameter. It was reverted — `mp_enable` is
set from the boot initramfs instead — and `kdriver/chip/o22/pm/pm_o22_governor.c` is
byte-identical between the webOS 23 and webOS 24 drops. Nothing to port.

### `fix_stuck_cpus`

Lives in `custom/fix_stuck_cpus` as an out-of-tree module against the **stock** kernel, not a
source patch. It patches `cpus_are_stuck_in_kernel` to return false so `kexec -l` succeeds
with CPUs parked. Not part of this patch set.

## Related

Runtime command lines, MCU shell commands and register pokes are in `notes.md`; the kexec
invocation is `boot_kernel.sh`.
