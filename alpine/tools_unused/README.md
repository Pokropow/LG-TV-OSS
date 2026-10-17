# Retired tools

One-off diagnostics from the audio investigation, kept as a record of what was measured and
how. Audio works (see `PATCHES.md`), so none of these is part of the bring-up or of routine
debugging. Nothing here is referenced by any script in `alpine/tools/`.

**Several of these encode methods that are now known to be wrong.** Read the warnings below
before copying an approach out of one.

## Superseded — the method is flawed, do not reuse

| tool | superseded by | why |
|---|---|---|
| `shared-peek.sh` | `tools/shared-peek2.sh` | Picked each chunk's *densest* 4 KiB block, which selects the `f4e201ff a5ee1bcc 7823f96d 34ba123b` fill pattern on **both** our box and stock — fill is 100% non-zero, real PCM only ~50%. Also read with `bs=4096`, which truncates `bc-speaker` (`0x8304c400`, 1 KiB aligned, **not** 4 KiB aligned) into the neighbouring chunk. |
| `deep-peek.sh`, `pcm-peek.sh` | `tools/shared-peek2.sh` | Scored buffers by non-zero *byte* density, which cannot tell a sine from sparse garbage and produced two wrong conclusions. `pcm-peek.sh` also sampled only the first 2 KiB of a 256 KiB ring. |
| `audio-dump.sh` | `tools/dsp1-deep.sh` | Dumped every instance's `status`/`lstatus` to answer "why does the playback module report `wrong read ptr`" — resolved by patch 0007. |
| `stock-peek.sh`, `stock-audio-probe.sh`, `stock-dsp1-trace.sh` | `tools/audio-snapshot.sh`, `tools/shared-peek2.sh`, `tools/dsp1-deep.sh` (all take `TONE=0` and run on stock) | Dedicated stock-side probes, written before the main tools could run on both boxes. |
| `se-volume.sh` | `tools/audio-up.sh` | Wrote `LGSE Var Fn009` by hand to prove the OSD volume was the bug. The bring-up now sets it as `SE_VOL_GAIN`/`SE_VOL_UI`. |

**The rule those failures point at:** score a buffer by *distinct* 32-bit words, not by non-zero
count, and read HMA chunks in 512-byte units.

## Answered their question

| tool | what it settled |
|---|---|
| `bc-probe.sh` | Stamped `bc-speaker` with `0x01` and watched it be re-zeroed in <0.5 s: `output_speaker` really does own that buffer, and the stamp was audible, proving the DAC and analogue path work. |
| `playback-probe.sh`, `ring-trace.sh`, `ring-trace2.sh`, `wroffset-poke.sh`, `prop-control.sh`, `chunk-test.sh` | The ALSA↔DSP ring protocol, leading to patch 0007. `prop-control.sh` is the one that established the control discipline: always write `log-mask` first to prove a `prop` write lands at all, or a null result means nothing. |

## Dead ends

| tool | verdict |
|---|---|
| `fader-bypass.sh`, `fader-test.sh` | The fader was never the problem; bypassing it changed nothing and `dsp2/fader` was already `running`. |
| `se-mode-test.sh` | Wrong lever. `LGSE SoundEngine Mode` only selects among what `Init` already built, so the `dap` stayed in the pipeline regardless. |

## Not audio

`hidcap.c` — Magic Remote HID report explorer, used to reverse-engineer the MR22N's
undeclared report descriptor. That decoding is finished and lives in
`tools/magicremote.c`.

**Note:** `alpine/build-alpine-rootfs.sh` compiles every `tools/*.c` into the rootfs, so
moving `hidcap.c` here also stops it being shipped on the TV. That is intended — it is a
development tool, not a runtime one. Move it back into `tools/` if you need it on the device
again.
