#!/bin/sh
set -eu

usage() {
    cat <<EOF
Usage: $0 [--non-interactive] [--archive PATH]

Without --non-interactive, a bundled archive is compared with the current
vendor download and you are prompted before using a newer remote version.

With --non-interactive, the bundled archive is used when present. The vendor
archive is downloaded only when no local archive exists.
EOF
}

non_interactive=false
explicit_archive=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -n|--non-interactive)
            non_interactive=true
            ;;
        --archive)
            [ "$#" -ge 2 ] || { echo "--archive requires a path." >&2; exit 2; }
            explicit_archive=$2
            shift
            ;;
        --archive=*)
            explicit_archive=${1#*=}
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$explicit_archive" ]; then
                echo "Only one archive path can be selected." >&2
                exit 2
            fi
            # Preserve compatibility with the previous positional archive.
            explicit_archive=$1
            ;;
    esac
    shift
done

if [ "$#" -gt 0 ]; then
    echo "Unexpected argument: $1" >&2
    exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this installer as root (for example with sudo)." >&2
    exit 1
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
manifest=${FICHERO_DRIVER_MANIFEST:-"$script_dir/../driver/manifest.env"}
if [ ! -f "$manifest" ]; then
    echo "Driver manifest not found: $manifest" >&2
    exit 1
fi
# shellcheck disable=SC1090,SC1091
. "$manifest"
manifest_dir=$(CDPATH='' cd -- "$(dirname -- "$manifest")" && pwd)
local_archive="$manifest_dir/$FICHERO_DRIVER_ARCHIVE"

architecture=$(dpkg --print-architecture)
case "$architecture" in
    amd64|arm64) ;;
    i386)
        echo "Unsupported architecture: i386 (32-bit x86)." >&2
        echo "Fichero publishes an amd64 driver, but no i386 driver." >&2
        exit 1
        ;;
    armhf|armel)
        echo "Unsupported architecture: $architecture (32-bit ARM)." >&2
        echo "Fichero publishes an arm64 driver, but no ARMv7/32-bit ARM driver." >&2
        exit 1
        ;;
    *)
        echo "Unsupported architecture: $architecture." >&2
        echo "This installer supports amd64 (x86-64) and arm64 (AArch64)." >&2
        exit 1
        ;;
esac

check_cups_compatibility() {
    cups_package=
    cups_version=
    for candidate in cups cups-daemon; do
        candidate_status=$(dpkg-query -W -f='${Status}' "$candidate" 2>/dev/null || true)
        if [ "$candidate_status" = "install ok installed" ]; then
            cups_package=$candidate
            cups_version=$(dpkg-query -W -f='${Version}' "$candidate")
            break
        fi
    done

    if [ -z "$cups_version" ]; then
        echo "CUPS is not installed. Install the cups package before this driver." >&2
        return 1
    fi

    cups_upstream=${cups_version#*:}
    cups_upstream=${cups_upstream%%-*}
    cups_major=${cups_upstream%%.*}
    case "$cups_major" in
        2) ;;
        3)
            echo "Incompatible CUPS version: $cups_version." >&2
            echo "This driver uses the classic PPD/filter interface removed from CUPS 3.x." >&2
            return 1
            ;;
        *)
            echo "Unsupported CUPS version: $cups_version. This driver requires CUPS 2.x." >&2
            return 1
            ;;
    esac

    if ! command -v cupstestppd >/dev/null 2>&1; then
        echo "cupstestppd is missing. Install the cups-client package." >&2
        return 1
    fi
    if ! command -v ldconfig >/dev/null 2>&1; then
        echo "Cannot inspect the system's CUPS compatibility libraries: ldconfig is missing." >&2
        return 1
    fi
    for required_abi in libcups.so.2 libcupsimage.so.2; do
        if ! ldconfig -p 2>/dev/null | grep -Fq "$required_abi"; then
            echo "Missing required CUPS 2 compatibility library: $required_abi" >&2
            return 1
        fi
    done

    echo "Compatible CUPS $cups_version detected ($cups_package, CUPS 2 ABI)."
}

check_cups_compatibility

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

download_remote() {
    destination=$1
    echo "Checking Fichero's current Linux driver at $FICHERO_DRIVER_URL..."
    curl --fail --location --retry 2 --connect-timeout 10 --max-time 120 \
        --silent --show-error --output "$destination" "$FICHERO_DRIVER_URL"
}

inspect_archive() {
    inspected_archive=$1
    inspect_dir=$2

    if ! unzip -tq "$inspected_archive" >/dev/null 2>&1; then
        echo "Not a valid ZIP archive: $inspected_archive" >&2
        return 1
    fi

    mkdir -p "$inspect_dir"
    if ! unzip -q "$inspected_archive" -d "$inspect_dir"; then
        echo "Could not extract driver archive: $inspected_archive" >&2
        return 1
    fi

    inspected_package=$(find "$inspect_dir" -type f -name "shippingprinter-printer-driver_*_${architecture}.deb" -print -quit)
    package_count=$(find "$inspect_dir" -type f -name "shippingprinter-printer-driver_*_${architecture}.deb" | wc -l)
    if [ -z "$inspected_package" ] || [ "$package_count" -ne 1 ]; then
        echo "Expected exactly one $architecture Fichero Debian package, found $package_count." >&2
        return 1
    fi

    if ! inspected_name=$(dpkg-deb --field "$inspected_package" Package) || ! inspected_version=$(dpkg-deb --field "$inspected_package" Version) || ! inspected_architecture=$(dpkg-deb --field "$inspected_package" Architecture); then
        echo "Could not read driver package metadata." >&2
        return 1
    fi
    if [ "$inspected_name" != shippingprinter-printer-driver ] || [ "$inspected_architecture" != "$architecture" ]; then
        echo "Unexpected package metadata in driver archive." >&2
        return 1
    fi

    if [ "$inspected_version" = "$FICHERO_DRIVER_VERSION" ]; then
        if ! printf '%s  %s\n' "$FICHERO_DRIVER_SHA256" "$inspected_archive" | sha256sum -c - >/dev/null; then
            echo "The pinned driver archive checksum does not match." >&2
            return 1
        fi
    fi
}

selected_archive=
selected_source=
remote_archive="$work_dir/remote.zip"

if [ -n "$explicit_archive" ]; then
    if [ ! -f "$explicit_archive" ]; then
        echo "Selected driver archive does not exist: $explicit_archive" >&2
        exit 1
    fi
    selected_archive=$explicit_archive
    selected_source="explicit archive"
elif [ "$non_interactive" = true ]; then
    if [ -f "$local_archive" ]; then
        echo "Using bundled driver archive without a remote check: $local_archive"
        selected_archive=$local_archive
        selected_source="bundled archive"
    else
        echo "No bundled driver archive found."
        if ! download_remote "$remote_archive"; then
            echo "No local driver is available and the vendor download failed." >&2
            exit 1
        fi
        selected_archive=$remote_archive
        selected_source="vendor download"
    fi
elif [ -f "$local_archive" ]; then
    if ! inspect_archive "$local_archive" "$work_dir/local-inspect"; then
        echo "The bundled driver archive is invalid; refusing to install it." >&2
        exit 1
    fi
    local_version=$inspected_version
    selected_archive=$local_archive
    selected_source="bundled archive"

    if download_remote "$remote_archive"; then
        if inspect_archive "$remote_archive" "$work_dir/remote-inspect"; then
            remote_version=$inspected_version
            if dpkg --compare-versions "$remote_version" gt "$local_version"; then
                printf 'A newer Fichero driver is available (%s -> %s). Use it for this installation? [y/N] ' "$local_version" "$remote_version"
                answer=
                IFS= read -r answer || true
                case "$answer" in
                    y|Y|yes|YES|Yes)
                        selected_archive=$remote_archive
                        selected_source="newer vendor download"
                        ;;
                    *)
                        echo "Keeping bundled driver $local_version."
                        ;;
                esac
            else
                echo "Bundled driver $local_version is current; vendor archive contains $remote_version."
            fi
        else
            echo "Warning: the vendor download failed validation; using bundled driver $local_version." >&2
        fi
    else
        echo "Warning: the vendor could not be reached; using bundled driver $local_version." >&2
    fi
else
    echo "No bundled driver archive found."
    if ! download_remote "$remote_archive"; then
        echo "No local driver is available and the vendor download failed." >&2
        exit 1
    fi
    selected_archive=$remote_archive
    selected_source="vendor download"
fi

if ! inspect_archive "$selected_archive" "$work_dir/selected"; then
    echo "Selected driver archive failed validation." >&2
    exit 1
fi
package=$inspected_package
package_version=$inspected_version

echo "Installing Fichero $package_version from $selected_source..."
dpkg --install "$package"

filter=/usr/lib/cups/filter/shippingprinter_printer_filter
ppd='/usr/share/cups/model/ShippingPrinter/FICHERO 6181.ppd'
test -x "$filter"
test -f "$ppd"
if ldd "$filter" | grep -q 'not found'; then
    echo "The Fichero filter has unresolved runtime libraries:" >&2
    ldd "$filter" >&2
    exit 1
fi

normalize_ppd() {
    input=$1
    output=$2
    driver_version=$3

    awk -v driver_version="$driver_version" '
        NR == 1 {
            print
            print "*% FicheroDriverVersion: " driver_version
            next
        }
        /^\*cupsLanguages:/ { next }
        /^\*[a-z][a-z](_[A-Z][A-Z])?\./ { next }
        /^\*DefaultPageSize:/ {
            print "*DefaultPageSize: A4"
            next
        }
        /^\*CloseUI: \*PageSize$/ {
            print "*PageSize A4/A4 [210 x 297 mm]: \"<</PageSize[595 842]/ImagingBBox null>>setpagedevice\""
            print "*PageSize A5/A5 [148 x 210 mm]: \"<</PageSize[420 595]/ImagingBBox null>>setpagedevice\""
        }
        /^\*DefaultPageRegion:/ {
            print "*DefaultPageRegion: A4"
            next
        }
        /^\*CloseUI: \*PageRegion$/ {
            if (page_region_closed++) next
            print "*PageRegion A4/A4 [210 x 297 mm]: \"<</PageSize[595 842]/ImagingBBox null>>setpagedevice\""
            print "*PageRegion A5/A5 [148 x 210 mm]: \"<</PageSize[420 595]/ImagingBBox null>>setpagedevice\""
        }
        /^\*DefaultImageableArea:/ {
            print "*DefaultImageableArea: A4"
            next
        }
        /^\*DefaultPaperDimension:/ {
            print "*ImageableArea A4/A4 [210 x 297 mm]: \"0 0 595 842\""
            print "*ImageableArea A5/A5 [148 x 210 mm]: \"0 0 420 595\""
            print "*DefaultPaperDimension: A4"
            next
        }
        /^\*MaxMediaWidth:/ {
            print "*PaperDimension A4/A4 [210 x 297 mm]: \"595 842\""
            print "*PaperDimension A5/A5 [148 x 210 mm]: \"420 595\""
            print "*MaxMediaWidth: \"598\""
            next
        }
        /^\*ParamCustomPageSize Width:/ {
            print "*ParamCustomPageSize Width: 1 points 36 598"
            next
        }
        { print }
    ' "$input" > "$output"
}

# The vendor PPDs contain duplicate CloseUI records and malformed optional
# translations. Preserve device commands and print options while replacing the
# invalid metadata and adding canonical A4/A5 media definitions.
for fichero_ppd in \
    '/usr/share/cups/model/ShippingPrinter/FICHERO 6181.ppd' \
    '/usr/share/cups/model/ShippingPrinter/FICHERO A4Printer.ppd'
do
    normalized="$work_dir/$(basename "$fichero_ppd")"
    normalize_ppd "$fichero_ppd" "$normalized" "$package_version"
    install -m 0644 "$normalized" "$fichero_ppd"
    cupstestppd -W none "$fichero_ppd" >/dev/null
done

echo "Installed and normalized Fichero $package_version for $architecture."
