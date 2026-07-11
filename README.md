# parsec-ubuntu-decoder-fix

A workaround that resolved **Error 17** ("video decoder failure",
`decode_frame = -17`) in the [Parsec](https://parsec.app) Linux client
on my own machine, running Ubuntu 26.04 LTS.

> **Confirmed on: Ubuntu 26.04 LTS only.** I have not tested this on
> 24.04, other Ubuntu versions, or other distros. The underlying idea
> (supplying the old FFmpeg libraries Parsec's Linux client expects)
> isn't inherently tied to one specific release, so it may well help on
> other newer-than-22.04 systems hitting the same symptom, but I haven't verified it myself. This is
> a solution that worked for my setup, shared in case it's useful to
> someone else troubleshooting the same error, not a guaranteed or
> official fix. If you try it on a different version, please open an
> issue with the result either way, so this note can get more accurate
> over time.

## The problem

Parsec's Linux client connects fine (STUN, encryption, audio all
negotiate successfully), but every video frame fails to decode
immediately, with `decode_frame = -17` in `~/.parsec/log.txt`. This can
look like a GPU/driver/VAAPI problem, but in my case it wasn't. See
[`docs/DIAGNOSIS.md`](docs/DIAGNOSIS.md) for the full investigation and
everything that was ruled out along the way.

**What seems to be going on:** Parsec's Linux client appears to be
dynamically linked against FFmpeg ~4.4 (`libavcodec.so.58`,
`libavutil.so.56`), which is what Ubuntu 22.04 shipped. Ubuntu 26.04
ships a much newer FFmpeg with different library names, and the old ones
don't exist anywhere on the system. Parsec doesn't crash when this
happens, it appears to silently fail to load any decoder, hardware or
software, and every frame fails as a result.

This is a known, recurring issue for Parsec's Flatpak build too:
[#23](https://github.com/flathub/com.parsecgaming.parsec/issues/23),
[#26](https://github.com/flathub/com.parsecgaming.parsec/issues/26),
[#39](https://github.com/flathub/com.parsecgaming.parsec/issues/39).
Their fix each time was pinning the Flatpak runtime back to an older
FFmpeg-compatible branch, which is the same underlying idea as what this
script does for a native `.deb` install.

## What this script does

It downloads the specific old FFmpeg-family libraries Parsec's Linux
client seems to need (and their own dependencies ~10 packages in
total) directly from Ubuntu's official archive, and installs them into
a dedicated, isolated folder:

```
~/.parsec/compat-libs/
```

Parsec is then launched with `LD_LIBRARY_PATH` pointed at that folder.
**As a safety measure, this scopes the old libraries to the Parsec
process only**: nothing under `/usr/lib` is touched, no `apt`/`dpkg`
state is modified, and no other application on your system will resolve
or load these older libraries. Every other app keeps using your distro's
normal, current FFmpeg exactly as before. This was verified directly by
inspecting which libraries the running Parsec process actually loads.

It also installs a user-level `~/.local/share/applications/parsecd.desktop`
override so that launching Parsec from your desktop's app grid/icon picks
up the fix automatically, no terminal needed after the initial install.

## Usage

```bash
git clone https://github.com/undert0wn/parsec-ubuntu-decoder-fix.git
cd parsec-ubuntu-decoder-fix
chmod +x install.sh
./install.sh
```

The script checks your Ubuntu version and will warn you (and ask for
confirmation) if it isn't the one this has actually been confirmed on.
It's idempotent ( safe to re-run any time), e.g. after a Parsec update.

### Uninstall

```bash
./uninstall.sh
```

Removes `~/.parsec/compat-libs/` and the desktop launcher override. Does
not touch Parsec itself or any system package.

## What this does *not* do

- Does not install any system package or require ongoing root access.
- Does not modify `/usr/share/applications/parsecd.desktop` or any other
  system file.
- Does not affect any other application's FFmpeg libraries. This was a
  deliberate design goal, not just an assumption, and was checked
  directly rather than taken on faith (see
  [`docs/DIAGNOSIS.md`](docs/DIAGNOSIS.md)).

## Requirements

- `curl`, `dpkg-deb` (both present by default on any Debian/Ubuntu
  system)
- Parsec's Linux `.deb` build already installed

## Known limitations

- **Only confirmed on Ubuntu 26.04 LTS.** Not tested on 24.04, other
  Ubuntu releases, or non-Ubuntu distros. Please don't read this repo as
  claiming it's a universal fix... it's one data point.
- The download URLs point at Ubuntu's official archive
  (`archive.ubuntu.com`, falling back to `old-releases.ubuntu.com`).
  These specific package versions should stay available for a long time
  given Ubuntu 22.04's support lifecycle, but if a mirror ever removes
  them, the script will fail its checksum/download step loudly rather
  than silently installing something wrong.
- Assumes `apt`/`dpkg` tooling (Debian/Ubuntu-family systems).
- If Parsec ever ships a build linked against a modern FFmpeg, this
  workaround becomes unnecessary. It's  worth checking Parsec's release notes
  before assuming you need this.

## License

MIT - see [`LICENSE`](LICENSE). This script only downloads *links to*
Ubuntu's own official, already-license-compliant packages; it does not
redistribute any GPL/LGPL-covered binaries itself.
