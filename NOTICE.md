# Third-party driver notice

This repository includes Fichero's official Linux printer driver archive so it
can be installed reproducibly and used as a source dependency.

- Product: ShippingPrinter/Fichero Linux printer driver
- Source page: <https://fichero.eu/drivers/>
- Bundled file: `driver/Linux.zip`
- Pinned package version, archive URL, and SHA-256: `driver/manifest.env`

The scripts validate the package metadata inside the archive instead of
relying on the version label shown on the download page.

The archive contains proprietary Debian filters for `amd64`, `arm64`, and
`mips64el`, plus RPM packages. The included installer supports the `amd64` and
`arm64` Debian packages. No 32-bit x86 or ARM package is present.

The supported filters are native 64-bit executables linked to the CUPS 2 ABI,
including `libcups.so.2` and `libcupsimage.so.2`. The target system must provide
those compatibility libraries and a CUPS 2.x server. The installer rejects
CUPS 3.x because its PPD/filter driver interface is not compatible.

Fichero's archive is included unchanged. After package installation,
`scripts/install-driver.sh` repairs invalid PPD metadata, adds standard A4 and
A5 media definitions, corrects the custom-width ceiling, and records the
installed package version. It does not modify the proprietary filter binary or
reimplement the printer protocol.

The archive and installed vendor files remain the property of Fichero and are
not covered by this repository's MIT license.

This is an independent community project and is not affiliated with or
endorsed by Fichero. A Fichero representative who wants the archive removed
can contact the maintainer through the source repository profile. It will be
removed from future revisions upon request.
