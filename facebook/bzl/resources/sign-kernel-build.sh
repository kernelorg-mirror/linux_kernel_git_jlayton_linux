#!/bin/bash
# sign-kernel-build.sh
# Signs kernel modules (.ko files) via SandcastleKernelSignCommand.
# Used by kernel.bzl during kernel builds with kernel.sign_mod=true.
#
# This script follows the same signing flow as sign-hook-wrapper.sh (used for
# standalone module signing), but runs synchronously instead of using the
# semaphore-based approach needed for mid-build signing.
#
# Arguments:
#   $1 - path to compiled kernel tree (contains .ko files)
#   $2 - signing key name (e.g., fbinfra-kmod-hsm)
#   $3 - path to sign-sandcastle-spec.json template
#   $4 - output directory for signed .ko files

set -xeo pipefail

KERNEL_TREE="$1"
SIGN_KEY="$2"
SPEC_TEMPLATE="$3"
OUT_DIR="$4"

# Buck's genrule context strips PATH. Ensure common tool locations are present.
export PATH="/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH"

# Check if there are any .ko files to sign
if [ -z "$(find "$KERNEL_TREE" -name '*.ko' -print -quit)" ]; then
    echo "No .ko files found in kernel tree, nothing to sign"
    exit 0
fi

SIGN_TMPDIR=$(mktemp -d)
trap "rm -rf $SIGN_TMPDIR" EXIT

echo "=== Creating tar of unsigned .ko files ==="
# Tar only .ko files, preserving directory structure.
# autograph_client.par only needs .ko files, not the full tree.
(cd "$KERNEL_TREE" && find . -name '*.ko' -print0 | tar -cf "$SIGN_TMPDIR/unsigned.tar" --null -T -)

echo "=== Uploading unsigned tar to Everstore ==="
EVERSTORE_HANDLE=$(clowder put --fbtype EVERSTORE_LINUX_KERNEL "$SIGN_TMPDIR/unsigned.tar")
echo "Everstore handle: $EVERSTORE_HANDLE"

KERNEL_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "0000000000000000000000000000000000000000")

echo "=== Building scutil job spec ==="
# Build the scutil job spec from the JSON template (same as sign-hook-wrapper.sh)
SPEC=$(sed -e "s|\$EVERSTORE_HANDLE|$EVERSTORE_HANDLE|g" \
           -e "s|\$SIGN_KEY|$SIGN_KEY|g" \
           -e "s|\$SANDCASTLE_NONCE|${SANDCASTLE_NONCE}|g" \
           -e "s|\$KERNEL_COMMIT|$KERNEL_COMMIT|g" \
           "$SPEC_TEMPLATE")

# Remove nonce field entirely if empty (sandcastle rejects non-numeric nonces)
if [ -z "$SANDCASTLE_NONCE" ]; then
    SPEC=$(echo "$SPEC" | jq 'del(.nonce)')
fi
echo "Spec: $SPEC"

echo "=== Invoking SandcastleKernelSignCommand via scutil ==="
SCUTIL_OUTPUT=$(scutil create "$SPEC" --await --follow-retries -v json)
echo "scutil output: $SCUTIL_OUTPUT"

INSTANCE_ID=$(echo "$SCUTIL_OUTPUT" | jq -r '.id')
echo "Instance ID: $INSTANCE_ID"

SIGNED_HANDLE=$(scutil get-log "$INSTANCE_ID" | awk '/==OUTPUT MARKER 0==/{print $NF}')
echo "Signed handle: $SIGNED_HANDLE"

if [ -z "$SIGNED_HANDLE" ]; then
    echo "ERROR: Could not find signed Everstore handle in scutil output"
    echo "Check sandcastle job: $INSTANCE_ID"
    exit 1
fi

echo "=== Downloading signed tar from Everstore ==="
clowder get "$SIGNED_HANDLE" "$SIGN_TMPDIR/signed.tar"

echo "=== Extracting signed modules to output ==="
mkdir -p "$OUT_DIR"
tar -xf "$SIGN_TMPDIR/signed.tar" -C "$OUT_DIR"

echo "=== Kernel module signing complete ==="
