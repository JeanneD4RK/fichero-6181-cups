#!/bin/sh
set -eu

usage() {
    cat <<EOF
Usage: $0

Download Fichero's current Linux driver archive, validate its amd64 and arm64
Debian packages, and update the bundled archive and manifest when the package
version is newer than the pinned version.
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    '') ;;
    *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

for command in curl unzip dpkg dpkg-deb sha256sum awk find mktemp install; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command is missing: $command" >&2
        exit 1
    fi
done

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
manifest=${FICHERO_DRIVER_MANIFEST:-"$script_dir/../driver/manifest.env"}
if [ ! -f "$manifest" ]; then
    echo "Driver manifest not found: $manifest" >&2
    exit 1
fi

# shellcheck disable=SC1090,SC1091
. "$manifest"
for variable in FICHERO_DRIVER_VERSION FICHERO_DRIVER_URL FICHERO_DRIVER_SHA256 FICHERO_DRIVER_ARCHIVE; do
    eval "value=\${$variable:-}"
    if [ -z "$value" ]; then
        echo "Missing $variable in $manifest" >&2
        exit 1
    fi
done

manifest_dir=$(CDPATH='' cd -- "$(dirname -- "$manifest")" && pwd)
bundled_archive="$manifest_dir/$FICHERO_DRIVER_ARCHIVE"

if [ -f "$bundled_archive" ] && ! printf '%s  %s\n' "$FICHERO_DRIVER_SHA256" "$bundled_archive" | sha256sum -c - >/dev/null; then
    echo "The bundled archive does not match the pinned checksum; refusing to overwrite local changes." >&2
    exit 1
fi

work_dir=$(mktemp -d)
archive_tmp="$manifest_dir/.$FICHERO_DRIVER_ARCHIVE.update.$$"
manifest_tmp="$manifest_dir/.manifest.env.update.$$"
trap 'rm -rf "$work_dir"; rm -f "$archive_tmp" "$manifest_tmp"' EXIT HUP INT TERM

remote_archive="$work_dir/remote.zip"
echo "Downloading Fichero's current Linux driver from $FICHERO_DRIVER_URL..."
curl --fail --location --retry 2 --connect-timeout 10 --max-time 120 \
    --silent --show-error --output "$remote_archive" "$FICHERO_DRIVER_URL"

if ! unzip -tq "$remote_archive" >/dev/null 2>&1; then
    echo "The vendor download is not a valid ZIP archive." >&2
    exit 1
fi
if unzip -Z1 "$remote_archive" | awk '/^\// || /(^|\/)\.\.(\/|$)/ { found=1 } END { exit !found }'; then
    echo "The vendor archive contains an unsafe path." >&2
    exit 1
fi

extract_dir="$work_dir/extracted"
mkdir -p "$extract_dir"
unzip -q "$remote_archive" -d "$extract_dir"

remote_version=
for architecture in amd64 arm64; do
    packages=$(find "$extract_dir" -type f -name "shippingprinter-printer-driver_*_${architecture}.deb")
    package_count=$(printf '%s\n' "$packages" | awk 'NF { count++ } END { print count+0 }')
    if [ "$package_count" -ne 1 ]; then
        echo "Expected exactly one $architecture Debian package, found $package_count." >&2
        exit 1
    fi
    package=$packages
    package_name=$(dpkg-deb --field "$package" Package)
    package_version=$(dpkg-deb --field "$package" Version)
    package_architecture=$(dpkg-deb --field "$package" Architecture)
    if [ "$package_name" != shippingprinter-printer-driver ] || [ "$package_architecture" != "$architecture" ]; then
        echo "Unexpected metadata in the $architecture Debian package." >&2
        exit 1
    fi
    if ! dpkg --validate-version "$package_version" >/dev/null 2>&1; then
        echo "Invalid Debian package version in the vendor archive: $package_version" >&2
        exit 1
    fi
    if [ -z "$remote_version" ]; then
        remote_version=$package_version
    elif [ "$package_version" != "$remote_version" ]; then
        echo "Vendor packages have different versions: $remote_version and $package_version." >&2
        exit 1
    fi
done

remote_sha256=$(sha256sum "$remote_archive" | awk '{ print $1 }')
echo "Pinned version: $FICHERO_DRIVER_VERSION"
echo "Remote version: $remote_version"

if dpkg --compare-versions "$remote_version" lt "$FICHERO_DRIVER_VERSION"; then
    echo "The vendor archive is older than the pinned archive; no files were changed."
    exit 0
fi

if [ "$remote_version" = "$FICHERO_DRIVER_VERSION" ]; then
    if [ "$remote_sha256" != "$FICHERO_DRIVER_SHA256" ]; then
        echo "The vendor republished version $remote_version with a different checksum." >&2
        echo "Review the archive manually; it was not adopted automatically." >&2
        exit 1
    fi
    if [ ! -f "$bundled_archive" ]; then
        install -m 0644 "$remote_archive" "$archive_tmp"
        mv -f "$archive_tmp" "$bundled_archive"
        echo "Restored the missing bundled archive for pinned version $remote_version."
    else
        echo "The bundled driver is already current; no files were changed."
    fi
    exit 0
fi

awk -v version="$remote_version" -v checksum="$remote_sha256" '
    /^FICHERO_DRIVER_VERSION=/ { print "FICHERO_DRIVER_VERSION=" version; version_seen=1; next }
    /^FICHERO_DRIVER_SHA256=/ { print "FICHERO_DRIVER_SHA256=" checksum; checksum_seen=1; next }
    { print }
    END { if (!version_seen || !checksum_seen) exit 1 }
' "$manifest" > "$manifest_tmp"

install -m 0644 "$remote_archive" "$archive_tmp"
mv -f "$archive_tmp" "$bundled_archive"
mv -f "$manifest_tmp" "$manifest"

echo "Updated $FICHERO_DRIVER_ARCHIVE and manifest.env to Fichero driver $remote_version."
echo "SHA-256: $remote_sha256"
echo "Review the archive and repository diff before committing."
