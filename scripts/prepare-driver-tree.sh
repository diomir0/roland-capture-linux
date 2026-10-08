#!/usr/bin/env bash
# Prepare the exact-kernel streaming-only Roland Capture driver source tree
# that install-native-driver.sh builds and installs.
#
# It downloads the Fedora kernel source RPM for the requested kernel version,
# extracts only the sound/usb subtree, applies the two Roland patches from
# patches/, and places the result in the adjacent directory
#   ../linux-roland-fedora-<version>/
# where install-native-driver.sh expects it.
#
# Usage:
#   ./scripts/prepare-driver-tree.sh [kernel-version]
#
# The default version is the running kernel's version (e.g. 7.2.9). The source
# RPM must still be available in Fedora: a just-superseded point kernel may
# have been retired, in which case `dnf upgrade` + reboot into the current
# kernel and rerun. The tree must match the running kernel because the module
# is built against, and loaded on, the running kernel.
set -euo pipefail

kernel_version=${1:-$(uname -r | cut -d- -f1)}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
# install-native-driver.sh looks for a sibling tree named after the version.
tree_dir=$(cd -- "$project_dir/.." && pwd)/linux-roland-fedora-$kernel_version
usb_dir=$tree_dir/sound/usb

for c in dnf rpm2cpio cpio tar git curl; do
    command -v "$c" >/dev/null || { echo "Missing required command: $c" >&2; exit 1; }
done

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# 1. Fetch the matching kernel source RPM, first from the Fedora repos, then
#    (for a just-superseded point kernel) directly from the Koji build archive.
echo "Downloading kernel source RPM for $kernel_version ..."
if ! dnf download --source "kernel-$kernel_version" --destdir "$workdir" >/dev/null 2>&1; then
    kernel_release=$(uname -r)
    running_version=${kernel_release%%-*}
    if [[ "$kernel_version" != "$running_version" ]]; then
        echo "Source for kernel $kernel_version is not in Fedora and it is not" >&2
        echo "the running kernel ($running_version); cannot guess a Koji URL." >&2
        exit 1
    fi
    release=${kernel_release#*-}
    release=${release%.$(uname -m)}
    koji_url="https://kojipkgs.fedoraproject.org/packages/kernel/$kernel_version/$release/src/kernel-$kernel_version-$release.src.rpm"
    echo "  (not in dnf repos; using Koji: $koji_url)"
    curl -fsSL "$koji_url" -o "$workdir/kernel-$kernel_version-$release.src.rpm"
fi
src_rpm=$(find "$workdir" -maxdepth 1 -name 'kernel-*.src.rpm' -print -quit)
[[ -n "$src_rpm" ]] || { echo "No kernel source RPM obtained." >&2; exit 1; }

# 2. Unpack the upstream tarball out of the source RPM.
rpm2cpio "$src_rpm" | (cd "$workdir" && cpio -idm --quiet '*.tar.xz')
tarball=$(find "$workdir" -maxdepth 1 -name 'linux-*.tar.xz' -print -quit)
[[ -n "$tarball" ]] || { echo "No linux tarball in $src_rpm." >&2; exit 1; }

# 3. Extract only sound/usb (the streaming driver and the patches touch nothing
#    else). The build compiles the whole sound/usb subtree as external modules.
tar xf "$tarball" -C "$workdir" "linux-$kernel_version/sound/usb"
rm -rf "$tree_dir/sound"
mkdir -p "$tree_dir"
mv "$workdir/linux-$kernel_version/sound" "$tree_dir/sound"

# 4. Apply the Roland patches (git is guaranteed present in this project).
cd "$tree_dir"
git apply "$project_dir/patches/quirks-c-rate-on-start.patch"
git apply "$project_dir/patches/quirks-table-octa-quad.patch"

# 5. Verify the patches landed (same checks as install-native-driver.sh).
grep -q 'roland_capture_set_rate' "$usb_dir/quirks.c" \
    || { echo "quirks.c lacks Roland rate sync after patching." >&2; exit 1; }
grep -q 'SNDRV_PCM_FMTBIT_S24_3LE' "$usb_dir/quirks-table.h" \
    || { echo "quirks-table.h lacks packed 24-bit correction after patching." >&2; exit 1; }

echo "Prepared Roland Capture driver tree at: $tree_dir"
echo "Next: ./scripts/install-native-driver.sh"
