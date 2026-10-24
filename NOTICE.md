# Upstream sources & licences

`nextbsd-printing-support` builds third-party software from pinned upstream
release tarballs or tag archives (`sources.lock`), each **under its own
upstream licence**. The licence files inside each tarball are authoritative;
this table records provenance and does not relicense anything. NextBSD's
changes are in `patches/<name>/` and are under the licence of the component
they change.

The top-level **`LICENSE` (BSD 2-Clause)** covers only what this repo authors:
`build-printing-support.sh`, `sources.lock`, `cross/`, `launchd/`,
`.github/workflows/`, this `NOTICE.md` and `README.md`.

## Shipped in `NextBSD-printing-support`

| Component | Upstream | Version | Licence (file in the tarball) |
|---|---|---|---|
| CUPS | Apple, github.com/apple-oss-distributions/cups (tag `cups-522.4`) | CUPS 2.3.4 | **Apache-2.0 with the CUPS exceptions** for GPL-2.0/LGPL-2 linking (`cups/LICENSE`, `cups/NOTICE`); the Kerberos support code is under its own permissive licence, quoted in `cups/NOTICE`. "CUPS" and the CUPS logo are Apple trademarks (`cups/NOTICE`) |

The CUPS exceptions let software under GPL-2.0 or LGPL-2 link against libcups
(Apache-2.0 is otherwise incompatible with GPL-2.0).

## Linked from other NextBSD repos (not shipped here)

| Library | Repo | Licence |
|---|---|---|
| GnuTLS (`libgnutls.so.30`) | nextbsd-gnustep-support | LGPL-2.1-or-later |
| `liblaunch` (launchd) | nextbsd-userland | Apache-2.0 (Apple) |
| `libdns_sd` (mDNSResponder client library) | nextbsd-userland | BSD 3-Clause (Apple, `dns_sd.h`) |
| PAM, MIT Kerberos, libusb, zlib | nextbsd-freebsd-compat (base) | BSD-style / MIT |
