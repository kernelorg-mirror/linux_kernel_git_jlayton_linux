#!/bin/bash
#
# Download and chroot into the x86_64 build rootfs image
#

set -e

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Download and chroot into the x86_64 build rootfs image.

This script downloads the official build rootfs image (as defined in
facebook/bzl/constants.bzl), mounts it using an overlay filesystem to make
it writable, and enters a chroot environment. Any changes made inside the
chroot are temporary and discarded upon exit.

OPTIONS:
    -h              Show this help message and exit
    -D VERSION      Download kernel devel package for the specified kernel
                    version using kerctl and overlay it onto the rootfs.
                    This makes kernel headers available for building modules.
    -m DIRECTORY    Bind-mount a host directory under /mnt/<dirname> inside
                    the chroot. Can be specified multiple times to mount
                    multiple directories.

EXAMPLES:
    # Basic usage - just enter the rootfs
    $(basename "$0")

    # Enter rootfs with kernel 6.16.1-0_fbk1_rc4_0_gb42e0085b289 headers
    $(basename "$0") -D 6.16.1-0_fbk1_rc4_0_gb42e0085b289

    # Mount the current kernel tree into the chroot
    $(basename "$0") -m /data/users/\$USER/kernel

    # Mount multiple directories and install kernel devel
    $(basename "$0") -D 6.16.1 -m /data/users/\$USER/kernel -m /home/\$USER/scripts

NOTES:
    - The rootfs image is cached in ~/.cache/build-images/
    - The image is mounted read-only with an overlay for writes
    - All changes are discarded when you exit the chroot
    - Use 'exit' to leave the chroot environment
    - Mounted directories are accessible under /mnt/<dirname>
    - Requires sudo for mount operations

EOF
    exit 0
}

# Parse options
KERNEL_VERSION=""
MOUNT_DIRS=()
while getopts "hD:m:" opt; do
    case $opt in
        h)
            usage
            ;;
        D)
            KERNEL_VERSION="$OPTARG"
            ;;
        m)
            MOUNT_DIRS+=("$OPTARG")
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))

# Find the kernel tree root (two directories up from this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONSTANTS_FILE="${KERNEL_ROOT}/facebook/bzl/constants.bzl"

if [ ! -f "$CONSTANTS_FILE" ]; then
    echo "Error: Cannot find $CONSTANTS_FILE"
    echo "Run this script from the kernel tree root or place it there."
    exit 1
fi

# Parse BUILD_IMAGE_X86_64_URI and SHA256 from constants.bzl
BUILD_IMAGE_X86_64_URI=$(grep '^BUILD_IMAGE_X86_64_URI=' "$CONSTANTS_FILE" | cut -d'"' -f2)
BUILD_IMAGE_X86_64_SHA256=$(grep '^BUILD_IMAGE_X86_64_SHA256=' "$CONSTANTS_FILE" | cut -d'"' -f2)

if [ -z "$BUILD_IMAGE_X86_64_URI" ] || [ -z "$BUILD_IMAGE_X86_64_SHA256" ]; then
    echo "Error: Could not parse BUILD_IMAGE_X86_64_URI or SHA256 from $CONSTANTS_FILE"
    exit 1
fi

echo "Using image: $BUILD_IMAGE_X86_64_URI"

IMAGE_DIR="${HOME}/.cache/build-images"
IMAGE_FILE="${IMAGE_DIR}/$(basename ${BUILD_IMAGE_X86_64_URI})"

# Directories to track for cleanup
IMAGE_MOUNT=""
OVERLAY_MOUNT=""
OVERLAY_WORK=""
OVERLAY_UPPER=""
DEVEL_DIR=""
BIND_MOUNTS=()
PROC_MOUNTED=""

cleanup() {
    # Unmount /proc first
    if [ -n "$PROC_MOUNTED" ] && mountpoint -q "${OVERLAY_MOUNT}/proc" 2>/dev/null; then
        echo "Unmounting /proc..."
        sudo umount "${OVERLAY_MOUNT}/proc"
    fi

    # Unmount bind mounts (in reverse order)
    for ((i=${#BIND_MOUNTS[@]}-1; i>=0; i--)); do
        if mountpoint -q "${BIND_MOUNTS[i]}" 2>/dev/null; then
            echo "Unmounting bind mount ${BIND_MOUNTS[i]}..."
            sudo umount "${BIND_MOUNTS[i]}"
        fi
    done

    # Unmount overlay
    if [ -n "$OVERLAY_MOUNT" ] && mountpoint -q "$OVERLAY_MOUNT" 2>/dev/null; then
        echo "Unmounting overlay $OVERLAY_MOUNT..."
        sudo umount "$OVERLAY_MOUNT"
    fi

    # Unmount image
    if [ -n "$IMAGE_MOUNT" ] && mountpoint -q "$IMAGE_MOUNT" 2>/dev/null; then
        echo "Unmounting image $IMAGE_MOUNT..."
        sudo umount "$IMAGE_MOUNT"
    fi

    # Clean up temp directories
    [ -n "$OVERLAY_MOUNT" ] && rmdir "$OVERLAY_MOUNT" 2>/dev/null || true
    [ -n "$OVERLAY_WORK" ] && sudo rm -rf "$OVERLAY_WORK" 2>/dev/null || true
    [ -n "$OVERLAY_UPPER" ] && sudo rm -rf "$OVERLAY_UPPER" 2>/dev/null || true
    [ -n "$IMAGE_MOUNT" ] && rmdir "$IMAGE_MOUNT" 2>/dev/null || true
    [ -n "$DEVEL_DIR" ] && sudo rm -rf "$DEVEL_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Create cache directory
mkdir -p "$IMAGE_DIR"

# Download image if not present or checksum mismatch
download_image() {
    echo "Downloading rootfs image..."
    curl -L -o "$IMAGE_FILE" "$BUILD_IMAGE_X86_64_URI"
}

verify_checksum() {
    echo "Verifying checksum..."
    echo "${BUILD_IMAGE_X86_64_SHA256}  ${IMAGE_FILE}" | sha256sum -c -
}

if [ -f "$IMAGE_FILE" ]; then
    if ! verify_checksum; then
        echo "Checksum mismatch, re-downloading..."
        download_image
        verify_checksum
    fi
else
    download_image
    verify_checksum
fi

# Mount the image read-only
IMAGE_MOUNT=$(mktemp -d)
echo "Mounting image at $IMAGE_MOUNT..."
sudo mount -o ro "$IMAGE_FILE" "$IMAGE_MOUNT"

# Create overlay mount (makes the rootfs writable)
OVERLAY_UPPER=$(mktemp -d)
OVERLAY_WORK=$(mktemp -d)
OVERLAY_MOUNT=$(mktemp -d)

echo "Creating overlay mount at $OVERLAY_MOUNT..."
sudo mount -t overlay overlay \
    -o lowerdir="$IMAGE_MOUNT",upperdir="$OVERLAY_UPPER",workdir="$OVERLAY_WORK" \
    "$OVERLAY_MOUNT"

# Download and install kernel devel package if -H was specified
if [ -n "$KERNEL_VERSION" ]; then
    echo "Downloading kernel devel package for version $KERNEL_VERSION..."
    DEVEL_DIR=$(mktemp -d)

    # Download the devel package using kerctl
    kerctl download -D "$KERNEL_VERSION" -O "$DEVEL_DIR"

    # Find the downloaded RPM and extract it into the overlay
    DEVEL_RPM=$(find "$DEVEL_DIR" -name "kernel-devel-*.rpm" -o -name "kernel-uek-devel-*.rpm" 2>/dev/null | head -1)
    if [ -n "$DEVEL_RPM" ]; then
        echo "Extracting devel package $DEVEL_RPM into overlay..."
        cd "$OVERLAY_MOUNT"
        sudo rpm2cpio "$DEVEL_RPM" | sudo cpio -idmv 2>/dev/null
        cd - >/dev/null
        echo "Kernel devel package installed."
    else
        echo "Warning: No devel RPM found in $DEVEL_DIR"
    fi
fi

# Bind mount any directories specified with -m
for dir in "${MOUNT_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        echo "Warning: $dir is not a directory, skipping"
        continue
    fi

    # Get absolute path
    abs_dir=$(realpath "$dir")
    # Use basename as mount point name
    mount_name=$(basename "$abs_dir")
    mount_target="$OVERLAY_MOUNT/mnt/$mount_name"

    echo "Bind mounting $abs_dir -> /mnt/$mount_name"
    sudo mkdir -p "$mount_target"
    sudo mount --bind "$abs_dir" "$mount_target"
    BIND_MOUNTS+=("$mount_target")
done

# Mount /proc inside the chroot
echo "Mounting /proc..."
sudo mount -t proc proc "${OVERLAY_MOUNT}/proc"
PROC_MOUNTED="1"

echo "Entering chroot (use 'exit' to leave)..."
if [ ${#BIND_MOUNTS[@]} -gt 0 ]; then
    echo "Mounted directories available under /mnt/"
fi
sudo chroot "$OVERLAY_MOUNT" /bin/bash

echo "Done."
