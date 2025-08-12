#!/bin/sh
set -xe

# Arguments:
#   $1 - path to shared build directory (KERNEL_TREE)
#   $2 - signing key name
#   $3 - path to the sign-sandcastle-spec.json template
KERNEL_TREE="$1"
SIGN_KEY="$2"
SPEC_TEMPLATE="$3"

# Start the signature waiter in a background subshell
(
    while [ ! -e "$KERNEL_TREE/do-signature" -a \
            ! -e "$KERNEL_TREE/abort-signature" -a \
            -e "$KERNEL_TREE" ]; do
        sleep 10
    done
    # If the build dir doesn't exist any more then assume we're cleaning up.
    # If the abort touch file is set then just exit the subshell.
    if [ -e "$KERNEL_TREE/abort-signature" -o \
         ! -e "$KERNEL_TREE" ]; then
        exit
    fi

    # /failed-signature is a signal file to the build process to signify that
    # the signature failed.  If it exists then the build process will fail.
    # Sign modules via SandcastleKernelBuildCommand (Autograph-whitelisted)
    SIGN_TMPDIR=$(mktemp -d)
    SIGN_LOG=$SIGN_TMPDIR/signing.log
    (
        set -xeo pipefail
        tar -cf $SIGN_TMPDIR/unsigned_modules.tar -C "$KERNEL_TREE" .
        EVERSTORE_HANDLE=$(clowder put --fbtype EVERSTORE_LINUX_KERNEL $SIGN_TMPDIR/unsigned_modules.tar)
        KERNEL_COMMIT=$(git rev-parse HEAD)

        # Build the scutil job spec from the JSON template
        export EVERSTORE_HANDLE SIGN_KEY SANDCASTLE_NONCE KERNEL_COMMIT
        SPEC=$(envsubst < "$SPEC_TEMPLATE")

        SCUTIL_OUTPUT=$(scutil create "$SPEC" --await --follow-retries -v json 2>&1)
        INSTANCE_ID=$(echo "$SCUTIL_OUTPUT" | jq -r '.id')
        SIGNED_HANDLE=$(scutil get-log $INSTANCE_ID | awk '/==OUTPUT MARKER 0==/{print $NF}')
        clowder get $SIGNED_HANDLE > $SIGN_TMPDIR/signed_modules.tar
        tar -xf $SIGN_TMPDIR/signed_modules.tar -C "$KERNEL_TREE"
    ) > "$SIGN_LOG" 2>&1 || touch "$KERNEL_TREE/failed-signature"

    echo "=== Signing log ===" >&2
    cat "$SIGN_LOG" >&2
    echo "=== End signing log ===" >&2
    rm -rf "$SIGN_TMPDIR"

    rm "$KERNEL_TREE/do-signature"
) &
