#!/usr/bin/env bash
# =============================================================================
# build-printing-support.sh — cross-build driver for nextbsd-printing-support
# =============================================================================
#
# Builds NextBSD's printing system (E24, nextbsd/nextbsd#574, plan D5 and step
# 10) for ONE architecture: Apple's CUPS 2.3.4 (tag cups-522.4), from its
# pinned tag archive, into the /usr prefix with upstream sonames, plus the
# org.nextbsd.cupsd launchd job. Layout and checks follow the nextbsd-xlibs
# reference (wiki: Source-Repo-Conventions).
#
# For each component, in COMPONENTS order:
#   1. fetch:   download the tarball named in sources.lock, refuse it unless
#               its SHA-256 matches, unpack it under .build/src/;
#   2. patch:   apply patches/<name>/series in order (each patch must state
#               its Origin:);
#   3. build:   the upstream build system as it is: autotools
#               (cross/autotools/<arch>.site, --host=<triple>), installed with
#               DESTDIR into .build/<name>-root-<arch>/. CUPS's makefiles
#               don't support building outside the source tree, so CUPS builds
#               in its freshly unpacked tree;
#   4. stage:   check and tidy that install, then copy it into $SYSROOT (so
#               later components find its headers and libraries) and into
#               $DESTDIR (the published artifact).
#
# Nothing here uses FreeBSD packages, the ports tree or ports tools. CUPS
# links against the NextBSD base (compat: libc, libz, PAM, MIT Kerberos/GSSAPI,
# libusb), nextbsd-userland (liblaunch and mDNSResponder's libdns_sd in
# /usr/lib/system) and nextbsd-gnustep-support (GnuTLS). No D-Bus, no Avahi,
# no systemd.
#
# EXECUTION CONTEXT (set up by CI before this runs)
#   Inside the nextbsd-toolchain container (pinned clang/lld 19.1.7 in
#   $CROSS_BINDIR, pkgconf, autotools), with compat's `continuous` base, then
#   nextbsd-userland's and nextbsd-gnustep-support's `continuous` artifacts,
#   extracted into $SYSROOT. $SYSROOT is scratch: this script installs every
#   component into it as it goes.
#
# USAGE
#   ./build-printing-support.sh            every component, in COMPONENTS order
#   ./build-printing-support.sh cups       named components only
# =============================================================================

set -euo pipefail

# ---- required environment ----------------------------------------------------
: "${T:?set T to the target (amd64 / arm64)}"
: "${TA:?set TA to the target_arch (amd64 / aarch64)}"
: "${SYSROOT:?set SYSROOT to the staged NextBSD base}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the dir holding the cross clang/lld}"
: "${DESTDIR:=/stage}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/.build"
DL="$BUILD/dl"
LOCK="$ROOT/sources.lock"
PATCHES="$ROOT/patches"
PS_CROSS="$ROOT/cross"

# Install prefix: /usr. .pc files, if a component has any, go in FreeBSD
# base's /usr/libdata/pkgconfig whatever the upstream default.
PREFIX=/usr
PCDIR=$PREFIX/libdata/pkgconfig

# The only files this repo installs outside $PREFIX: its launchd jobs, next
# to the userland's in /System/Library/LaunchDaemons. Everything under /etc
# and /var that upstream installs is dropped (see tidy_cups): configuration
# is nextbsd-overlays', and cupsd creates its own /var directories.
LAUNCHD_DIR=/System/Library/LaunchDaemons
OUTSIDE_PREFIX="$LAUNCHD_DIR/org.nextbsd.cupsd.plist"

# Base files this repo replaces. CUPS ships the System V and Berkeley print
# commands at the paths of FreeBSD's LPD suite, which NextBSD drops from the
# base (nextbsd-freebsd-compat scripts/superseded; CUPS replaces lpd, as on
# macOS). Until compat's `continuous` base is rebuilt without them, the stage
# check accepts exactly these paths and says so; any other clash still fails.
BASE_SUPERSEDED="usr/bin/lp usr/bin/lpq usr/bin/lpr usr/bin/lprm usr/sbin/lpc"

case "$T" in
    amd64) CROSS_TRIPLE=x86_64-unknown-freebsd ;;
    arm64) CROSS_TRIPLE=aarch64-unknown-freebsd ;;
    *)     echo "FAIL: unsupported T=$T (amd64 / arm64)" >&2; exit 1 ;;
esac
BUILD_TRIPLE="$(uname -m)-pc-linux-gnu"
JOBS=-j"$(nproc 2>/dev/null || echo 2)"

SYSROOT="$(cd "$SYSROOT" && pwd)"
export SYSROOT DESTDIR CROSS_BINDIR PS_CROSS

# pkgconf only, and only the sysroot's .pc directory: never the build host's.
export PKG_CONFIG=pkgconf
export PKG_CONFIG_LIBDIR="$SYSROOT$PCDIR"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
unset PKG_CONFIG_PATH
# The sysroot's /usr/lib and /usr/include are the compiler's own (clang
# --sysroot), so pkgconf leaves them out of --libs and --cflags: otherwise
# `-L<sysroot>/usr/lib` would end up in what CUPS records for cups-config.
export PKG_CONFIG_SYSTEM_LIBRARY_PATH="$SYSROOT/usr/lib:$SYSROOT/lib"
export PKG_CONFIG_SYSTEM_INCLUDE_PATH="$SYSROOT/usr/include"

READELF="$CROSS_BINDIR/llvm-readelf"

# ---- helpers -----------------------------------------------------------------
comp() { echo; echo "==> [$T/$TA] $*"; }
note() { echo "    - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# lock_field <name> <version|sha256|url>: a component's pin from sources.lock.
lock_field() {
    local name="$1" field="$2" col
    case "$field" in
        version) col=2 ;;
        sha256)  col=3 ;;
        url)     col=4 ;;
        *)       fail "lock_field: unknown field $field" ;;
    esac
    awk -v n="$name" -v c="$col" '$1 == n && $1 !~ /^#/ { print $c; found=1 } END { exit !found }' "$LOCK" \
        || fail "$name is not pinned in sources.lock"
}

# Assert a staged object links a given library (a cross `readelf -d` check; we
# cannot exec target binaries on the runner).
needed_check() {
    local obj="$1" want="$2"
    "$READELF" -d "$obj" 2>/dev/null | grep -q "NEEDED.*\[$want" \
        || fail "$obj missing DT_NEEDED $want"
    note "DT_NEEDED ok: $(basename "$obj") -> $want"
}

# needed_absent <obj> <regex>: the object links no library matching regex.
needed_absent() {
    local obj="$1" re="$2"
    if "$READELF" -d "$obj" | grep -E "NEEDED.*\[($re)"; then
        fail "$(basename "$obj") links a library that must not be there"
    fi
}

# soname_check <lib> <soname>: the staged library (by its development link in
# $DESTDIR/usr/lib) carries the upstream soname, and the soname link exists.
soname_check() {
    local lib="$DESTDIR$PREFIX/lib/$1" want="$2"
    [ -e "$lib" ] || fail "$1 was not staged"
    "$READELF" -d "$lib" 2>/dev/null | grep -q "SONAME.*\[$want\]" \
        || fail "$1 does not have SONAME $want"
    [ -e "$DESTDIR$PREFIX/lib/$want" ] || fail "$want was not staged"
    note "SONAME ok: $want"
}

# fetch <name>: download (cached in .build/dl), verify and unpack the pinned
# tarball, apply the patch series. Sets SRC_DIR and VERSION.
fetch() {
    local name="$1" url sha file got
    VERSION=$(lock_field "$name" version)
    url=$(lock_field "$name" url)
    sha=$(lock_field "$name" sha256)
    file="$DL/$(basename "$url")"
    mkdir -p "$DL"
    if [ ! -f "$file" ]; then
        note "fetch $url"
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    got=$(sha256sum "$file" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || { rm -f "$file"; fail "$name: SHA-256 mismatch for $(basename "$file") (got $got, sources.lock has $sha)"; }
    note "$name $VERSION, sha256 ok"
    SRC_DIR="$BUILD/src/$name-$VERSION"
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    tar -xf "$file" -C "$SRC_DIR" --strip-components=1
    apply_patches "$name"
}

# apply_patches <name>: patches/<name>/series lists the patches in order, one
# per line (# comments allowed). Every *.patch in the directory must be listed,
# and every patch must say where it came from in an `Origin:` header line
# (DEP-3 style: upstream commit or MR, a FreeBSD port file used as a reference,
# or "NextBSD" for our own).
apply_patches() {
    local name="$1" dir="$PATCHES/$1" p n=0
    [ -d "$dir" ] || return 0
    [ -f "$dir/series" ] || fail "patches/$name has no series file"
    for p in "$dir"/*.patch; do
        [ -e "$p" ] || continue
        grep -qx "$(basename "$p")" "$dir/series" || fail "patches/$name/$(basename "$p") is not listed in series"
    done
    while read -r p; do
        case "$p" in ''|'#'*) continue ;; esac
        [ -f "$dir/$p" ] || fail "patches/$name/series lists missing $p"
        grep -q '^Origin:' "$dir/$p" || fail "patches/$name/$p has no Origin: line"
        patch -d "$SRC_DIR" -p1 --forward --batch --quiet < "$dir/$p" || fail "patches/$name/$p does not apply"
        note "patch $p"
        n=$((n + 1))
    done < "$dir/series"
    note "$n patch(es) applied"
}

# Fresh build and install-root directories for a component.
fresh_dirs() {
    local name="$1"
    COMP_BUILD="$BUILD/$name-$T"
    COMP_ROOT="$BUILD/$name-root-$T"
    rm -rf "$COMP_BUILD" "$COMP_ROOT"
    mkdir -p "$COMP_BUILD" "$COMP_ROOT"
}

# The base's own files (compat, plus the userland and gnustep-support
# artifacts CI stages under it), listed while the sysroot doesn't yet hold
# anything from this repo, so stage can refuse a component that would
# overwrite one. A later partial run reuses the list.
base_list() {
    BASE_LIST="$BUILD/base-files-$T.list"
    if [ ! -e "$SYSROOT$PREFIX/include/cups/cups.h" ]; then
        (cd "$SYSROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort) > "$BASE_LIST"
    elif [ ! -f "$BASE_LIST" ]; then
        fail "$SYSROOT already holds this repo's files but $BASE_LIST is missing; start from a fresh base"
    fi
}

# stage <name>: check $COMP_ROOT (already tidied by the component), then copy
# it into $SYSROOT (for the components after this one) and $DESTDIR (the
# artifact).
#   - everything must be under /usr, apart from $OUTSIDE_PREFIX;
#   - libtool .la files and info manuals are dropped (man pages and CUPS's
#     /usr/share/doc/cups, which cupsd serves, are kept; so are the empty
#     directories CUPS installs for drivers and PPDs);
#   - .pc files move to /usr/libdata/pkgconfig;
#   - no .pc file may name /usr/local or a build-host path;
#   - nothing may replace a base file, apart from $BASE_SUPERSEDED.
stage() {
    local name="$1" x="$COMP_ROOT$PREFIX" stray f clash allowed=""
    [ -d "$x" ] || fail "$name installed nothing under $PREFIX"
    for f in $OUTSIDE_PREFIX; do
        allowed="$allowed ! -path .$f"
    done
    # shellcheck disable=SC2086
    stray=$(cd "$COMP_ROOT" && find . -mindepth 1 ! -type d ! -path ".$PREFIX/*" $allowed)
    [ -z "$stray" ] || fail "$name installed outside $PREFIX: $stray"
    find "$x" -name '*.la' -delete
    rm -rf "$x/share/info"
    for f in lib/pkgconfig share/pkgconfig; do
        if [ -d "$x/$f" ]; then
            mkdir -p "$COMP_ROOT$PCDIR"
            mv "$x/$f"/*.pc "$COMP_ROOT$PCDIR/"
            rmdir "$x/$f"
        fi
    done
    for f in "$COMP_ROOT$PCDIR"/*.pc; do
        [ -e "$f" ] || continue
        [ -L "$f" ] && continue
        grep -q "^prefix=$PREFIX\$" "$f" || fail "$(basename "$f"): prefix is not $PREFIX"
        if grep -n -F -e /usr/local -e "$ROOT" -e "$SYSROOT" "$f"; then
            fail "$(basename "$f") names /usr/local or a build-host path"
        fi
    done
    clash=$(cd "$COMP_ROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort | LC_ALL=C comm -12 - "$BASE_LIST")
    for f in $clash; do
        case " $BASE_SUPERSEDED " in
            *" $f "*) note "replaces /$f, which the base still ships (superseded in nextbsd-freebsd-compat; gone once its base is rebuilt)" ;;
            *) fail "$name would replace /$f, a file of the NextBSD base" ;;
        esac
    done
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$SYSROOT" && tar -xf -)
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$DESTDIR" && tar -xf -)
    note "staged $(cd "$COMP_ROOT" && find . ! -type d | wc -l) files"
}

# =============================================================================
# Components, in build order (plan step 10): CUPS. Filters and drivers
# (cups-filters, Ghostscript, Gutenprint) are a later step.
# =============================================================================

# CUPS — Apple's cups-522.4 (CUPS 2.3.4), autotools, in its source tree (cups/
# inside Apple's archive). Configured as on macOS where NextBSD has the same
# mechanism, and with NextBSD's libraries where it doesn't:
#   - launchd on-demand start: cupsd -l collects its socket with
#     launch_activate_socket() from liblaunch (-llaunch, cupsd only; patch
#     0001). The job is launchd/org.nextbsd.cupsd.plist, installed here.
#     No systemd, upstart, SMF, xinetd or rc scripts;
#   - DNS-SD with mDNSResponder (NextBSD's dns_sd.h and libdns_sd from
#     nextbsd-userland, in /usr/lib/system); Avahi off. In CUPS 2.3 this is
#     --disable-avahi --enable-dnssd (CUPS 2.4 spells it
#     --with-dnssd=mdnsresponder); patch 0002 builds ippfind with it;
#   - TLS with GnuTLS (nextbsd-gnustep-support): Apple's CUPS has only
#     SecureTransport and GnuTLS backends;
#   - base MIT Kerberos (GSSAPI), PAM and libusb (the usb backend); no D-Bus;
#   - macOS's accounts and paths where NextBSD keeps them: user and group
#     _lp, SystemGroup "admin _lpadmin" (admin is NextBSD's DirectoryServices
#     administrators group, as on macOS; _lpadmin is the printer operators'),
#     the domain socket /var/run/cupsd and the cache in /var/spool/cups/cache;
#     web interface off by default (`cupsctl WebInterface=yes` turns it on).
# Every configure check that would otherwise look at the build host (its
# /etc/passwd and /etc/group, init and xinetd directories, krb5-config,
# pkg-config) is given its answer here.
build_cups() {
    comp "cups [autotools cross, in tree]"
    fresh_dirs cups
    fetch cups
    local src="$SRC_DIR/cups" sbin lib
    (
        cd "$src"
        # install-sh strips with $STRIPPROG: the cross strip, not the runner's.
        export STRIPPROG="$CROSS_BINDIR/llvm-strip"
        CONFIG_SITE="$PS_CROSS/autotools/$T.site" \
        PKGCONFIG="$(command -v pkgconf)" \
        KRB5CONFIG="$PS_CROSS/autotools/krb5-config" \
        ./configure \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --prefix="$PREFIX" --exec-prefix="$PREFIX" \
            --libdir="$PREFIX/lib" --mandir="$PREFIX/share/man" \
            --sysconfdir=/etc --localstatedir=/var \
            --with-rundir=/var/run/cups --with-logdir=/var/log/cups \
            --with-cachedir=/var/spool/cups/cache \
            --with-domainsocket=/var/run/cupsd \
            --with-cups-user=_lp --with-cups-group=_lp \
            --with-system-groups="admin _lpadmin" \
            --enable-shared --disable-static \
            --enable-launchd --disable-systemd \
            --with-rcdir=no --with-xinetd=no \
            --with-lpdconfig=off --with-smbconfig=off \
            --with-lpdconfigfile=no --with-smbconfigfile=no \
            --enable-ssl --enable-gnutls \
            --disable-avahi --enable-dnssd \
            --with-dnssd-libs="$SYSROOT/usr/lib/system" \
            --enable-gssapi --enable-pam --with-pam-module=unix \
            --enable-libusb --disable-dbus \
            --disable-webif \
            --with-cups-build="cups-$VERSION"
        # The checks configure ran are what NextBSD gets: fail here, not at
        # run time, if one of them didn't find what it should.
        for d in HAVE_LAUNCHD HAVE_ONDEMAND HAVE_LAUNCH_H HAVE_DNSSD HAVE_SSL \
                 HAVE_GNUTLS HAVE_GSSAPI HAVE_LIBUSB HAVE_LIBZ; do
            grep -q "^#define $d 1" config.h || fail "configure did not set $d"
        done
        for d in HAVE_AVAHI HAVE_DBUS HAVE_SYSTEMD HAVE_UPSTART HAVE_CDSASSL; do
            if grep -q "^#define $d " config.h; then fail "configure set $d"; fi
        done
        grep -q '^ONDEMANDLIBS[[:space:]]*=[[:space:]]*-llaunch$' Makedefs || fail "cupsd does not link -llaunch"
        grep -q '^IPPFIND_BIN[[:space:]]*=[[:space:]]*ippfind$' Makedefs || fail "ippfind is not built"
        grep -q '^LAUNCHD_DIR[[:space:]]*=[[:space:]]*$' Makedefs || fail "upstream's org.cups.* launchd plists would be installed"
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
    tidy_cups "$src"
    stage cups

    lib="$DESTDIR$PREFIX/lib/libcups.so.2"
    sbin="$DESTDIR$PREFIX/sbin/cupsd"
    soname_check libcups.so libcups.so.2
    soname_check libcupsimage.so libcupsimage.so.2
    needed_check "$lib" libgnutls.so.30
    needed_check "$lib" libdns_sd.so.1
    needed_check "$lib" libgssapi_krb5.so
    needed_check "$lib" libz.so
    needed_check "$sbin" liblaunch.so.1
    needed_check "$sbin" libpam.so
    needed_check "$sbin" libcups.so.2
    needed_check "$DESTDIR$PREFIX/libexec/cups/backend/usb" libusb.so
    needed_check "$DESTDIR$PREFIX/libexec/cups/backend/dnssd" libcups.so.2
    for f in "$lib" "$sbin" "$DESTDIR$PREFIX/libexec/cups/backend/"*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        "$READELF" -h "$f" >/dev/null 2>&1 || continue
        needed_absent "$f" 'libavahi|libdbus|libsystemd|libssl|libcrypto'
    done
    # Only cupsd talks to launchd.
    if "$READELF" -d "$lib" | grep -q 'NEEDED.*\[liblaunch'; then
        fail "libcups links liblaunch"
    fi
    for f in ippfind lp lpr lpq lprm lpstat cancel lpoptions cups-config; do
        [ -e "$DESTDIR$PREFIX/bin/$f" ] || fail "/usr/bin/$f was not staged"
    done
    for f in cupsd lpc lpadmin lpinfo lpmove cupsctl cupsaccept cupsenable cupsfilter; do
        [ -e "$DESTDIR$PREFIX/sbin/$f" ] || fail "/usr/sbin/$f was not staged"
    done
    # cups-config is what programs on the machine build against: it must
    # describe /usr, with no sysroot or build path in it.
    if grep -n -F -e "$SYSROOT" -e "$ROOT" -e /usr/local "$DESTDIR$PREFIX/bin/cups-config"; then
        fail "cups-config names a build path or /usr/local"
    fi
    note "cups-config: $(grep -E '^(LDFLAGS|LIBS)=' "$DESTDIR$PREFIX/bin/cups-config" | tr '\n' ' ')"
    plutil_check "$DESTDIR$OUTSIDE_PREFIX"
}

# tidy_cups <src>: shape upstream's install into what NextBSD ships.
#   - /etc (cups/*.conf, pam.d/cups) is dropped: configuration belongs to
#     nextbsd-overlays. The files configure generated are printed here so the
#     overlays copies can be checked against them;
#   - /var is dropped: it holds only empty directories, which cupsd creates
#     with the right owners and modes when it starts;
#   - freedesktop menu entries and icons, if any, are dropped;
#   - the org.nextbsd.cupsd launchd job is installed.
tidy_cups() {
    local src="$1" f other
    other=$(cd "$COMP_ROOT" && find . -mindepth 1 -maxdepth 1 ! -name usr ! -name etc ! -name var)
    [ -z "$other" ] || fail "cups installed unexpected top-level paths: $other"
    if [ -d "$COMP_ROOT/etc" ]; then
        other=$(cd "$COMP_ROOT/etc" && find . ! -type d ! -path './cups/*' ! -path './pam.d/cups')
        [ -z "$other" ] || fail "cups installed unexpected files in /etc: $other"
        for f in cups-files.conf cupsd.conf snmp.conf; do
            echo "    --- generated /etc/cups/$f (configuration lives in nextbsd-overlays) ---"
            sed 's/^/    | /' "$src/conf/$f"
        done
        rm -rf "$COMP_ROOT/etc"
    fi
    if [ -d "$COMP_ROOT/var" ]; then
        other=$(cd "$COMP_ROOT/var" && find . ! -type d)
        [ -z "$other" ] || fail "cups installed files in /var: $other"
        rm -rf "$COMP_ROOT/var"
    fi
    rm -rf "$COMP_ROOT$PREFIX/share/applications" "$COMP_ROOT$PREFIX/share/icons"
    install -d -m 0755 "$COMP_ROOT$LAUNCHD_DIR"
    install -m 0644 "$ROOT/launchd/org.nextbsd.cupsd.plist" "$COMP_ROOT$LAUNCHD_DIR/"
}

# plutil_check <plist>: well-formed XML with the label NextBSD expects (no
# plutil on the runner; xmllint if present, else a structural grep).
plutil_check() {
    local p="$1"
    [ -f "$p" ] || fail "$p was not staged"
    if command -v xmllint >/dev/null 2>&1; then
        xmllint --noout "$p" || fail "$p is not well-formed XML"
    fi
    grep -q '<string>org.nextbsd.cupsd</string>' "$p" || fail "$p does not carry the org.nextbsd.cupsd label"
    if grep -E '<string>[^<]*(com\.apple|org\.cups)\.' "$p" || grep -F '<key>PathState</key>' "$p"; then
        fail "$p carries an Apple/CUPS identifier or a PathState key"
    fi
    note "launchd job ok: $(basename "$p")"
}

# =============================================================================
# driver
# =============================================================================
# Add a component: pin it in sources.lock, write build_<name>() above (hyphens
# in the name become underscores in the function), put its patches, if any, in
# patches/<name>/ with a series file, and append <name> here in build order.
COMPONENTS="cups"

if [ $# -gt 0 ]; then
    for c in "$@"; do
        case " $COMPONENTS " in
            *" $c "*) ;;
            *) fail "unknown component '$c' (known: $COMPONENTS)" ;;
        esac
    done
    COMPONENTS="$*"
fi

echo "nextbsd-printing-support: building [$COMPONENTS] for $T/$TA into $DESTDIR"
mkdir -p "$DESTDIR" "$BUILD"
base_list
for c in $COMPONENTS; do
    "build_$(printf '%s' "$c" | tr - _)"
done

echo
echo "==> staged into $DESTDIR:"
( cd "$DESTDIR" && find . ! -type d | sort | sed 's#^\.##' )
