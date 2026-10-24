# nextbsd-printing-support

NextBSD's printing system: **Apple's CUPS 2.3.4** (tag `cups-522.4` of
apple-oss-distributions/cups), built from its pinned source into base, with
an `org.nextbsd.cupsd` launchd job. Filters and drivers (cups-filters,
Ghostscript, Gutenprint) are a later step.

Plan: [E24 GNUstep & Gershwin requirements](https://github.com/nextbsd/nextbsd-userland/wiki/E24-GNUstep-Gershwin-Requirements-Direction),
decision D5, step 10; epic nextbsd/nextbsd#574, ticket nextbsd/nextbsd-printing-support#1.

| Repo | What it holds | Package |
|---|---|---|
| `nextbsd-freebsd-compat` | the FreeBSD base: libc, PAM, MIT Kerberos, libusb, zlib | `NextBSD-freebsd-compat` |
| `nextbsd-userland` | Darwin sources: launchd and liblaunch, mDNSResponder and libdns_sd | `NextBSD-userland` |
| `nextbsd-gnustep-support` | the libraries GNUstep needs, including GnuTLS | `NextBSD-gnustep-support` |
| **`nextbsd-printing-support`** | **Apple's CUPS; later filters and drivers** | **`NextBSD-printing-support`** |
| `nextbsd-overlays` | `/etc`: `_lp`/`_lpadmin` accounts, `/etc/cups`, `/etc/pam.d/cups` | (seeded, not packaged) |

## The rules for what goes here

1. **Printing:** the CUPS scheduler, library and commands, and later the
   filters and drivers it runs.
2. **Pinned source only**, each with its URL and SHA-256 in `sources.lock`,
   downloaded at build time: for CUPS, GitHub's archive of Apple's tag. No
   FreeBSD packages, ports or ports tools. NextBSD's changes are a patch series
   in `patches/<name>/`.
3. **Upstream build systems** (CUPS's autotools) driven in cross mode with the
   files in `cross/`; no hand-written replacement makefiles.
4. **Installed into `/usr`**, with upstream sonames. The only file outside
   `/usr` is the launchd job, `/System/Library/LaunchDaemons/org.nextbsd.cupsd.plist`.
   Never `/usr/local`.
5. **Darwin mechanisms first:** launchd socket activation, mDNSResponder for
   DNS-SD, macOS's `_lp` account and `admin` group. **No D-Bus, no Avahi, no
   systemd.** pkgconf, never freedesktop's `pkg-config`.
6. **It ships no `/etc` and no `/var`.** Configuration and accounts come from
   `nextbsd-overlays`; cupsd creates its `/var` directories itself.
7. **Nothing on the console on a normal boot.** cupsd logs to `/var/log/cups/`
   and its stdout/stderr go to `/var/log/cupsd.stderr`.

## CUPS

| | |
|---|---|
| Source | Apple `cups-522.4` (CUPS 2.3.4, Apache-2.0 with the CUPS exceptions) |
| Installs | `libcups.so.2`, `libcupsimage.so.2`, headers, `cups-config`; `cupsd`, `cupsfilter`, `lpadmin`, `lpinfo`, `lpmove`, `lpc`, `cupsctl`, `cupsaccept`/`cupsreject`, `cupsenable`/`cupsdisable` in `/usr/sbin`; `lp`, `lpr`, `lpq`, `lprm`, `lpstat`, `lpoptions`, `cancel`, `ippfind`, `ipptool`, `ippeveprinter` in `/usr/bin`; backends, CGIs, daemons and filters in `/usr/libexec/cups`; data in `/usr/share/cups`; docs in `/usr/share/doc/cups`; man pages |
| TLS | GnuTLS 3.8 from nextbsd-gnustep-support (Apple's CUPS has only SecureTransport and GnuTLS backends) |
| DNS-SD | mDNSResponder: NextBSD's `dns_sd.h` and `libdns_sd` (nextbsd-userland). CUPS 2.3 spells it `--disable-avahi --enable-dnssd`; CUPS 2.4 calls the same choice `--with-dnssd=mdnsresponder` |
| Other | base MIT Kerberos (GSSAPI), PAM (`/etc/pam.d/cups`), libusb (the `usb` backend), zlib |
| Off | Avahi, D-Bus, systemd, upstart, xinetd, rc scripts, the web interface by default (as on macOS; `cupsctl WebInterface=yes`) |

The configure line (`build_cups` in `build-printing-support.sh`):

```
./configure --build=<runner> --host=<arch>-unknown-freebsd \
    --prefix=/usr --exec-prefix=/usr --libdir=/usr/lib --mandir=/usr/share/man \
    --sysconfdir=/etc --localstatedir=/var \
    --with-rundir=/var/run/cups --with-logdir=/var/log/cups \
    --with-cachedir=/var/spool/cups/cache --with-domainsocket=/var/run/cupsd \
    --with-cups-user=_lp --with-cups-group=_lp --with-system-groups="admin _lpadmin" \
    --enable-shared --disable-static \
    --enable-launchd --disable-systemd --with-rcdir=no --with-xinetd=no \
    --with-lpdconfig=off --with-smbconfig=off --with-lpdconfigfile=no --with-smbconfigfile=no \
    --enable-ssl --enable-gnutls \
    --disable-avahi --enable-dnssd --with-dnssd-libs=$SYSROOT/usr/lib/system \
    --enable-gssapi --enable-pam --with-pam-module=unix \
    --enable-libusb --disable-dbus --disable-webif \
    --with-cups-build=cups-522.4
```

with `CONFIG_SITE=cross/autotools/<arch>.site`, `PKGCONFIG=pkgconf` and
`KRB5CONFIG=cross/autotools/krb5-config` (a cross stand-in that answers from
base Kerberos's `.pc` files). Every check that would otherwise look at the
runner (its `/etc/passwd` and `/etc/group`, init and xinetd directories,
`krb5-config`, `pkg-config`) is answered explicitly. After configure the build
asserts what it found (`HAVE_LAUNCHD`, `HAVE_DNSSD`, `HAVE_GNUTLS`,
`HAVE_GSSAPI`, `HAVE_LIBUSB`, ...; no Avahi, D-Bus or systemd).

### Patches

| Patch | Why |
|---|---|
| `0001-launchd-find-launch_activate_socket-in-liblaunch` | On macOS `launch_activate_socket()` is in libSystem; on NextBSD it is in liblaunch. configure now also looks in `-llaunch`, and links it into cupsd only |
| `0002-dnssd-build-ippfind-with-mdnsresponder` | A misplaced comma in `cups-dnssd.m4` dropped `ippfind` whenever mDNSResponder was found outside Darwin |

### launchd: `org.nextbsd.cupsd`

`launchd/org.nextbsd.cupsd.plist` is Apple's `org.cups.cupsd.plist` adapted to
NextBSD:

- **Socket activation, as on macOS.** launchd owns `/var/run/cupsd` (the
  `Listeners` socket, mode `0777`) and starts `/usr/sbin/cupsd -l` when a
  client connects. cupsd collects the socket with `launch_activate_socket()`
  (liblaunch, nextbsd/nextbsd-userland#447; cupsd links `-llaunch`), and exits
  by itself after `IdleExitTimeout` (60 s) once it has no jobs, no shared
  printers and no clients. The next connection starts it again.
- **No `PathState`.** Apple keeps cupsd alive with `KeepAlive`/`PathState` on
  the file cupsd writes while it has work; NextBSD's launchd doesn't act on
  `PathState`. **`RunAtLoad`** takes its place: cupsd starts once when the job
  loads at boot, resumes queued jobs and advertises shared printers, and stays
  only while it has work.
- **No `KeepAlive`.** If cupsd stops, launchd keeps the socket and the next
  client starts it again, so a failing cupsd can't loop.
- **Silent.** cupsd logs to `/var/log/cups/` (`error_log`, `access_log`,
  `page_log`); its stdout/stderr go to `/var/log/cupsd.stderr`. Apple's
  `CUPS_DEBUG_*` environment and the macOS-only keys are dropped.

### Accounts and configuration (nextbsd-overlays)

cupsd needs, from `nextbsd-overlays`:

- the `_lp` user and group (filters and backends run as `_lp`), and the
  `_lpadmin` group (printer operators); `admin` (DirectoryServices) is already
  there;
- `/etc/cups/cupsd.conf`, `/etc/cups/cups-files.conf` and
  `/etc/cups/snmp.conf`, as generated by this configure (the build prints
  them), and `/etc/pam.d/cups`.

### `lp` and `lpr` in the base

CUPS installs `lp`, `lpr`, `lpq`, `lprm` and `lpc` at the paths of FreeBSD's
LPD suite. NextBSD drops that suite from the base, as macOS has no `lpd`
(`nextbsd-freebsd-compat`'s `scripts/superseded`). The build refuses any CUPS
file that would replace a base file, apart from those five, which it accepts
(and reports) until compat's `continuous` base is rebuilt without them.

## Layout

Same layout as nextbsd-xlibs (wiki: Source-Repo-Conventions):

```
build-printing-support.sh    cross-build driver: every component, or some by name
sources.lock                 name, version, SHA-256, URL of every upstream tarball
patches/<name>/series        the patches for <name>, in the order applied
patches/<name>/*.patch       one change each, with an Origin: header
launchd/*.plist              the launchd jobs this repo installs
cross/autotools/<arch>.site  autotools CONFIG_SITE files (cross compiler, pkgconf,
cross/autotools/common.site    cache answers for checks that would run a program)
cross/autotools/krb5-config  cross krb5-config, from base Kerberos's .pc files
cross/meson/<arch>.ini       meson cross files, for meson components (none yet)
.github/workflows/build.yml  CI: build both arches, publish `continuous`
NOTICE.md                    per-component provenance and licence
```

Nothing upstream is committed. `build-printing-support.sh` downloads into
`.build/dl/` and unpacks into `.build/src/`. CUPS's makefiles don't support
building outside the source tree, so CUPS builds inside its freshly unpacked
copy. The build refuses a patch directory without a `series` file, a `*.patch`
not listed in it, and a patch without an `Origin:` line.

## Build model

`build-printing-support.sh` runs inside the `nextbsd-kernel-toolchain`
container (the pinned clang/lld 19.1.7, pkgconf, autotools) with a sysroot
made of, in order: compat's `continuous` base, then the `continuous` artifacts
of nextbsd-userland (liblaunch, `dns_sd`) and nextbsd-gnustep-support (GnuTLS).
It needs:

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | the staged sysroot; scratch, since each component is installed into it |
| `CROSS_BINDIR` | the toolchain's clang, lld and LLVM binutils (set by the container image) |
| `DESTDIR` | where to stage the artifact; default `/stage` |

For each component, in `COMPONENTS` order, it downloads and verifies the
tarball, applies the patches, runs the upstream build and installs it with
`DESTDIR`, tidies the install, and copies it into the sysroot and `DESTDIR`.

**Checks the build enforces:** everything installs under `/usr` apart from the
launchd job; `/etc` and `/var` hold only what CUPS is known to install there
(configuration, empty directories) and are dropped; nothing replaces a file of
the base sysroot (compat, userland, gnustep-support) apart from the five LPD
commands above; no `.la` files; `cups-config` names no build path or
`/usr/local`; `libcups.so.2` and `libcupsimage.so.2` carry their sonames;
libcups links GnuTLS, `libdns_sd`, GSSAPI and zlib, cupsd links liblaunch and
PAM, the usb backend links libusb, and nothing links Avahi, D-Bus, systemd or
OpenSSL (cross `readelf -d`); the launchd job carries the `org.nextbsd.cupsd`
label and no Apple/CUPS identifier or `PathState` key. pkgconf searches only
the sysroot.

```
./build-printing-support.sh            # every component
./build-printing-support.sh cups       # one component
```

## CI, artifact, package

The workflow builds both arches on pull requests, pushes to `main` and manual
runs. A push to `main`, or a manual run from `main`, also publishes
`nextbsd-printing-support-<arch>.tar.gz` to the `continuous` release, rooted
at `/`: the whole install, headers, `cups-config` and man pages included, and
the launchd job. Pull requests never publish.

Builds run by hand, in order, after the repos they depend on (the rebuild
policy): there is no `repository_dispatch` trigger, and this repo dispatches
nothing to any other repo. `nextbsd-pkg` repackages the tarball as
`NextBSD-printing-support` when it is run by hand (nextbsd/nextbsd-pkg#27).

## Adding a component

1. A line in `sources.lock`: name, version, the tarball's SHA-256, its URL.
2. `build_<name>()` in `build-printing-support.sh` (hyphens become
   underscores), registered in `COMPONENTS` in build order. End it with
   `stage` and `soname_check`/`needed_check` for what it installs.
3. Patches, if any, in `patches/<name>/`, listed in `patches/<name>/series`,
   each with an `Origin:` header (upstream commit or MR, a FreeBSD port file
   used as a reference, or `NextBSD`).
4. A row in `NOTICE.md` and a section above.
5. Turn off every D-Bus, Avahi or systemd option the component has, and say
   so in the function's comment.
