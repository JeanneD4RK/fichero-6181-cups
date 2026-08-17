# Fichero 6181 CUPS driver

This repository contains Fichero's Linux driver archive and one installation
script that makes its CUPS PPDs usable on current Debian-based systems.

## What the installer fixes

The vendor filter and device commands remain unchanged. During installation,
the scripts normalize the supplied PPD files by:

- removing malformed optional translations and duplicate UI records;
- adding canonical A4 (`210 × 297 mm`) and A5 (`148 × 210 mm`) media entries;
- making standard A4 the default instead of the vendor's private size name;
- correcting the custom paper-width ceiling for the printer's A4-class width;
- adding the installed driver version as metadata for safe queue upgrades; and

## Compatibility

| Platform | Status |
| --- | --- |
| Debian/Ubuntu `amd64` (x86-64) | Supported |
| Debian/Ubuntu `arm64` (AArch64) | Supported by the vendor package; hardware feedback welcome |
| 32-bit x86 (`i386`) | Unsupported: no vendor package |
| 32-bit ARM (`armhf`, ARMv7) | Unsupported: no vendor package |

The installer requires CUPS 2.x together with the `libcups.so.2` and
`libcupsimage.so.2` compatibility libraries. It checks the installed CUPS
package, ABI libraries, and `cupstestppd` before selecting or installing a
driver. CUPS 3.x is rejected because it no longer supports this classic
PPD/filter driver interface.

The archive also contains RPM packages and a `mips64el` Debian package, but
the included installer currently supports only Debian-family `amd64` and
`arm64` systems.

## Install into CUPS

Install the required system packages first:

```sh
sudo apt-get update
sudo apt-get install cups cups-client curl libcupsimage2 unzip
```

Then run the installer from this repository:

```sh
sudo ./scripts/install-driver.sh
```

In its default interactive mode, the installer validates the bundled archive,
downloads the current archive from Fichero, and compares their actual Debian
package versions. If the vendor archive is newer, it asks whether to use that
version for this installation. If the website is unavailable, the verified
bundled archive is used.

For unattended provisioning, use:

```sh
sudo ./scripts/install-driver.sh --non-interactive
```

Non-interactive mode does not contact the website when the bundled archive is
present. If it is missing, the script downloads the vendor archive; if that
download is unavailable or invalid, installation fails.

An exact archive can also be selected without discovery:

```sh
sudo ./scripts/install-driver.sh --non-interactive --archive /path/to/Linux.zip
```

After selecting an archive, the same script chooses the package matching the
machine architecture, verifies that the installed CUPS version and ABI are
compatible, validates package metadata, installs the vendor filter, repairs
both Fichero PPDs, checks runtime libraries, and validates the result.

The main PPD is installed at:

```text
/usr/share/cups/model/ShippingPrinter/FICHERO 6181.ppd
```

Restart CUPS after a direct host installation:

```sh
sudo systemctl restart cups
```

The warning `Printer drivers are deprecated` can appear when a queue is created
from this PPD. It is a CUPS compatibility warning, not an installation error.

## Updating the pinned archive

`driver/manifest.env` records the expected bundled package version, official
URL, and SHA-256 checksum. Interactive installation may use a newer remote
version temporarily, but it does not overwrite the tracked archive or manifest.

Maintainers can check and adopt a newer vendor release with:

```sh
./scripts/update-driver.sh
```

The updater validates the ZIP and the metadata of both the `amd64` and `arm64`
Debian packages. It changes `driver/Linux.zip` and the version and SHA-256 in
`driver/manifest.env` only when both packages contain the same version and that
version is newer than the pinned release. A same-version archive with a changed
checksum is rejected for manual review. Review the archive and Git diff before
committing the update, then advance the driver submodule in consuming projects
and rebuild their images.

## Licensing and Fichero notice

The installation and normalization scripts are MIT-licensed. The bundled
Fichero archive is proprietary vendor software and is not covered by the MIT
license. See [NOTICE.md](NOTICE.md) for its exact source and checksum.

This is an independent community project and is not affiliated with or
endorsed by Fichero. If you represent Fichero and want the archive removed,
contact the maintainer through the source repository profile. It will be
removed from future revisions upon request.
