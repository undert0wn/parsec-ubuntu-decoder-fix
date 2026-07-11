# Investigating Parsec Error 17 (video decoder failure) on Ubuntu 26.04

## Scope of this writeup

Everything below describes what happened on **one machine, running
Ubuntu 26.04 LTS**, while chasing down Error 17 in Parsec's Linux client.
It is a record of what was tried, ruled out, and what ultimately got it
working there — not a claim that this generalizes to every system or
every Ubuntu release. If you're on a different version (24.04, etc.) and
hit the same symptom, this may still be useful context, but treat it as
a starting point to investigate your own system, not a diagnosis of it.

## Summary

Parsec's Linux client (tested on `release7`, build `150-104a`) failed
every connection with **Error 17** (`decode_frame = -17`,
`DECODE_ERR_NO_SUPPORT`) on this Ubuntu 26.04 machine. Several plausible
suspects — a GPU driver problem, a Wayland/X11 problem, an
NVIDIA-vs-Intel problem — were checked and ruled out one at a time.
What actually resolved it was a missing shared library: vendoring the
old FFmpeg libraries Parsec's client seems to expect into a private
folder and pointing Parsec at them via `LD_LIBRARY_PATH`, without
touching any system package.

## Environment this was diagnosed on

- Ubuntu 26.04 LTS, GNOME on Wayland (with Xwayland running for
  compatibility)
- Hybrid Optimus laptop: Intel UHD 630 iGPU + NVIDIA GTX 1060 (proprietary
  driver 580.159.03)
- Parsec `release7`, build `150-104a`, installed via the official `.deb`

## What seems to be going on

Parsec's own documentation
(["Parsec App for Linux"](https://support.parsec.app/hc/en-us/articles/32381494397332-Parsec-App-for-Linux#other_distros))
lists its Linux client's hard dependencies, including two very specific,
old FFmpeg SONAMEs:

```
libavutil.so.56
libavcodec.so.58
```

These correspond to FFmpeg ~4.4, which is what Ubuntu 22.04 LTS ("jammy")
shipped. Parsec officially only supports Ubuntu 22.04 Desktop.

Ubuntu 26.04 ships FFmpeg 8.0.1, whose libraries are named
`libavcodec.so.62` and `libavutil.so.60`. The old SONAMEs
(`.so.58` / `.so.56`) do not exist anywhere on a modern system, under any
package name — they were dropped from the archive.

Parsec's binary doesn't appear to hard-crash when these libraries are
missing. Instead, it seems to silently fail to load a decoder at all —
the connection itself (STUN, encryption negotiation, audio channels)
succeeded normally in this case, but the very first video frame failed
to decode with Error 17, apparently because there was no decoder loaded,
hardware or software, to decode it with.

On this machine, that meant the standard-looking "hardware decode is
broken" symptom (`decode_frame = -17` on frame 1) was misleading — it
had nothing to do with VAAPI, GPU vendor, or driver availability here.
Those were all checked and ruled out during diagnosis, confirmed by
checking the running process's loaded libraries directly
(`/proc/<pid>/maps` never showed `libavcodec` or `libavutil` loaded at
all, even mid-connection-attempt).

This is also a widely known issue in the community — the Parsec Flatpak
package (`com.parsecgaming.parsec` on Flathub) has hit the exact same
problem multiple times as its base runtime moved past FFmpeg 4.4:
- https://github.com/flathub/com.parsecgaming.parsec/issues/23
- https://github.com/flathub/com.parsecgaming.parsec/issues/26
- https://github.com/flathub/com.parsecgaming.parsec/issues/39

The Flatpak maintainer's fix each time was to pin the Flatpak runtime back
to an older branch that still ships FFmpeg 4.4. On a native `.deb` install
(no Flatpak sandbox), the equivalent fix is to supply the same old FFmpeg
libraries directly, scoped only to the Parsec process.

## Diagnostic steps that ruled out other causes (in order tried)

1. Forced H.264 via `client_decoder_h265=0` — no change, ruled out
   H.265-specific issue.
2. Confirmed Ubuntu 26.04 had **no VAAPI driver at all** for the Intel iGPU
   (no `iHD_drv_video.so` / `i965_drv_video.so` present). Installed
   `intel-media-va-driver-non-free` and verified with `vainfo` that VAAPI
   decode (H.264/HEVC `VAEntrypointVLD`) works correctly on
   `/dev/dri/renderD128`. Error 17 persisted unchanged.
3. Confirmed device permissions were fine — `/dev/dri/renderD128` has a
   `uaccess` ACL granting the logged-in user rw access (standard
   systemd-logind seat behavior), so it was never a permissions issue.
4. Tried `client_decoder_index` = `0` and `1` directly in `config.json`
   (this key is a real, binary-confirmed config key, unlike
   `decoder_software`, which does **not** exist in this build at all and
   gets silently stripped from `config.json` on every restart despite
   being documented at parsec.app/config — likely stale/platform-mismatched
   docs). Both index values produced byte-identical -17 failures.
5. Confirmed via `/proc/<pid>/maps` that the running `parsecd` process
   never loads `libva.so`, `iHD_drv_video.so`, `libavcodec`, or
   `libavutil` at any point — including immediately after receiving and
   failing to decode a real keyframe from the host. This was the key clue
   that pointed at a missing-library problem rather than a
   driver/permissions/config problem.
6. Cross-referenced Parsec's own "Parsec App for Linux" support article,
   which lists `libavcodec.so.58` / `libavutil.so.56` as hard dependencies
   — versions that don't exist on Ubuntu 26.04.

## What fixed it here

### 1. Identify all the libraries actually needed

`libavcodec.so.58` itself has further dependencies (codecs it was built
against) that also no longer exist on a modern system:

```
libavutil.so.56
libswresample.so.3
libvpx.so.7
libdav1d.so.5
libcodec2.so.1.0
libtheoraenc.so.1
libtheoradec.so.1
libx264.so.163
libx265.so.199
libmfx.so.1
```

All of these had to be sourced, not just the two Parsec explicitly
documents — the dynamic linker refuses to load `libavcodec.so.58` unless
every one of its declared dependencies resolves, even ones Parsec's decode
path never actually calls (e.g. the x264/x265 *encoder* libraries, pulled
in because FFmpeg 4.4 was built with broad codec support).

### 2. Download the exact Ubuntu 22.04 ("jammy") package versions

All of these packages are still hosted in Ubuntu's official archive (22.04
is still an active LTS release), at
`http://archive.ubuntu.com/ubuntu/pool/...`. Example for the two primary
ones:

```
http://archive.ubuntu.com/ubuntu/pool/universe/f/ffmpeg/libavcodec58_4.4.2-0ubuntu0.22.04.1_amd64.deb
http://archive.ubuntu.com/ubuntu/pool/universe/f/ffmpeg/libavutil56_4.4.2-0ubuntu0.22.04.1_amd64.deb
```

(the `4.4.2-0ubuntu0.22.04.1` version is the fully-patched final jammy
security-update build — preferred over the original `4.4.1` GA version)

The rest were tracked down via each library's Ubuntu source package name
and pool location (see below for the full list used). Ubuntu's
`Contents-amd64.gz` index for jammy is useful for finding which package
provides a given `.so` file when the package name isn't obvious:

```
curl -s http://archive.ubuntu.com/ubuntu/dists/jammy/Contents-amd64.gz \
  | zgrep "libtheoraenc.so.1"
```

Full package list used (all `amd64`, all from the jammy archive):

| SONAME needed | Package | Version |
|---|---|---|
| `libavcodec.so.58` | `libavcodec58` | `4.4.2-0ubuntu0.22.04.1` |
| `libavutil.so.56` | `libavutil56` | `4.4.2-0ubuntu0.22.04.1` |
| `libswresample.so.3` | `libswresample3` | `4.4.2-0ubuntu0.22.04.1` |
| `libvpx.so.7` | `libvpx7` | `1.11.0-2ubuntu2.5` |
| `libdav1d.so.5` | `libdav1d5` | `0.9.2-1` |
| `libcodec2.so.1.0` | `libcodec2-1.0` | `1.0.1-3` |
| `libtheoraenc.so.1` / `libtheoradec.so.1` | `libtheora0` | `1.1.1+dfsg.1-15ubuntu4` |
| `libx264.so.163` | `libx264-163` | `0.163.3060+git5db6aa6-2build1` |
| `libx265.so.199` | `libx265-199` | `3.5-2build1` |
| `libmfx.so.1` | `libmfx1` | `22.3.0-1` |

### 3. Extract just the shared libraries (do NOT `apt install` these)

Each `.deb` was extracted (not installed) with `dpkg-deb -x <file>.deb
<dest-dir>`, and only the `.so*` files copied out — preserving the SONAME
symlink structure (e.g. `libavcodec.so.58 -> libavcodec.so.58.134.100`).
These were placed in a dedicated folder:

```
~/.parsec/compat-libs/
```

This keeps them completely isolated from the system's real (current)
FFmpeg 8.0.1 libraries used by every other application — nothing under
`/usr/lib` is touched, and no `apt`/`dpkg` state is modified.

### 4. Point Parsec at the compat folder via `LD_LIBRARY_PATH`

Launch Parsec with the compat folder prepended to its library search path,
so only the Parsec process resolves these old libraries — every other
process on the system keeps using the normal system FFmpeg untouched:

```bash
pkill parsecd
LD_LIBRARY_PATH=~/.parsec/compat-libs parsecd &
```

Verified working by checking `/proc/<pid>/maps` after a connection
attempt — `libavcodec.so.58` and friends are now loaded by the process,
and the connection succeeds instead of failing with Error 17.

### 5. Make it work from the desktop icon, not just the terminal

The installed package ships `/usr/share/applications/parsecd.desktop`,
whose `Exec=` line launches `parsecd` with no environment override, so
clicking the icon normally would still hit Error 17. Rather than editing
that file in place (it's owned by the package and would get reset on
Parsec updates, and editing it requires root), a user-level override
desktop file was created at:

```
~/.local/share/applications/parsecd.desktop
```

with the same content, except:

```
Exec=env LD_LIBRARY_PATH=$HOME/.parsec/compat-libs /usr/bin/parsecd %u
```

Note: `.desktop` file `Exec=` lines don't expand `~` or `$HOME` themselves
in all implementations — if `env VAR=$HOME/...` doesn't resolve correctly
on your system, use the literal absolute path to your home directory
instead (e.g. `/home/<your-username>/.parsec/compat-libs`).

XDG desktop file resolution prefers `~/.local/share/applications/` over
`/usr/share/applications/` for a file of the same name, so GNOME's app
grid / dock picks this one up automatically — no system file was modified.
Verified with `gtk-launch parsecd` (which resolves desktop files the same
way a real icon click does) that the resulting process has
`LD_LIBRARY_PATH` set correctly.

### Note on `intel-media-va-driver-non-free`

This package (providing `iHD_drv_video.so`, the modern Intel VAAPI driver)
was installed during diagnosis and is **not required** for this fix to
work — the actual failure was the missing FFmpeg libraries, not missing
VAAPI support. It's a legitimate, low-risk, reversible package to have
installed regardless (proper Intel hardware video acceleration is useful
for other apps too — Firefox, mpv, etc.), but it turned out to be a
red herring for this specific bug. It can be left installed or removed
(`sudo apt remove intel-media-va-driver-non-free`) without affecting this
fix either way.

## Post-fix notes

- Video decode works via hardware acceleration on the NVIDIA GPU
  (confirmed via `log.txt` showing `FFMPEG 4 NVIDIA` / `FFMPEG 4.2.3 hw
  type 2` during a successful connection) — Parsec found and used
  NVIDIA's native NVDEC hwaccel path (built into FFmpeg independently of
  VAAPI), not the Intel iGPU. Installing `intel-media-va-driver-non-free`
  (see note above) was not what actually enabled hardware decode here —
  NVDEC was picked automatically once the missing FFmpeg libraries were
  supplied.
- **Stream quality after the initial fix was very low** (client overlay
  reported only a few Mbps despite the host being configured for a much
  higher bitrate ceiling, and a free-tier Parsec account was briefly
  suspected as the cause). The actual cause turned out to be a **second
  remote-desktop client (Remina) running at the same time**, competing
  for network/system resources and causing Parsec's automatic congestion
  control to clamp bitrate way down. Quitting Remina and reconnecting
  immediately fixed it — quality became clearly usable (not perfectly
  crisp, but no longer the issue). If you hit unexpectedly poor quality
  despite a strong connection and correct host settings, check for other
  remote-desktop/streaming software running at the same time before
  assuming it's a Parsec or decoder problem.

## Packaging

The steps above (sourcing ~10 old library files, setting up
`LD_LIBRARY_PATH`, and making it apply to the desktop launcher too) were
turned into `install.sh` / `uninstall.sh` in the root of this repo, so
they don't need to be done by hand — see the main [README](../README.md)
for usage. As noted there, that script has only been confirmed on the
same Ubuntu 26.04 setup this diagnosis describes.

A support ticket was also filed with Parsec directly, describing this
same investigation. If they end up rebuilding the Linux client against a
modern FFmpeg, this whole workaround becomes unnecessary.
