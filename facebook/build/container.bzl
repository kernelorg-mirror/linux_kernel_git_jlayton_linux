load("//facebook/config:flavors.td.bzl", "ARCH_AARCH64", "ARCH_X86_64", "ARCHITECTURES", "ARCH_FLAVORS")
load("constants.bzl", "BUILD_IMAGE_AARCH64_SHA256", "BUILD_IMAGE_AARCH64_URI", "BUILD_IMAGE_X86_64_SHA256", "BUILD_IMAGE_X86_64_URI")

BIND_VAR=1
BIND_LOC=2

_IMAGE_MAP = {
    ARCH_AARCH64: "//facebook/build:build-image-aarch64",
    ARCH_X86_64: "//facebook/build:build-image-x86_64",
}

def target_container_image(arch):
    if arch not in (ARCH_AARCH64, ARCH_X86_64,):
        fail("unsupported image arch")
    return _IMAGE_MAP[arch]

def default_container_image():
    if native.host_info().arch.is_aarch64:
        return _IMAGE_MAP[ARCH_AARCH64]
    return _IMAGE_MAP[ARCH_X86_64]

def host_container_image():
    return default_container_image()

def _src_loc(src):
    if "$OUT" in src or "$TMP" in src:
        return BIND_VAR, src
    if "$(location" in src:
        return BIND_LOC, src
    return BIND_LOC, "$(location {})".format(src)


def _add_src(attr, src, dst, binds, args):
    argname = attr.replace("_rw", "").replace("_", "-")
    if attr.startswith("overlay"):
        sources = []
        for src_ in src:
            t, s = _src_loc(src_)
            if t == BIND_VAR:
                sources.append(s)
            else:
                bn = "BINDSRC{}".format(len(binds))
                binds.append("{}=\"`realpath {}`\"".format(bn, s))
                sources.append("${}".format(bn))
        args.append("--{}={}:{}".format(argname, ":".join(sources), dst))
        return sources
    t, s = _src_loc(src)
    if t == BIND_VAR:
        args.append("--{}={}:{}".format(argname, s, dst))
    elif t == BIND_LOC:
        bn = "BINDSRC{}".format(len(binds))
        binds.append("{}=\"`realpath {}`\"".format(bn, s))
        args.append("--{}=${}:{}".format(argname, bn, dst))
    else:
        fail("Bad source type for {} ({})".format(src, s), attr=attr)
    return [s]


def container_genrule(name, cmd, pre_cmd = None, bind_ro = None, bind_rw = None, overlay_ro = None, overlay_rw = None, tmpfs = None, cacheable = False, image_override=None):
    """Runs the specified shell command in the build container

    This rule runs commands within a systemd-nspawn container based on the
    image built from fbcode/kernel/build.
    It makes it easy to handle mounts without messing with shell arguments to
    systemd-nspawn

    Args:
      name: a unique name for this rule
      bind_ro: list of (source, dest) tuples where 'source' on the host system
               is read-only bind-mounted into the container at 'dest'
               source must be a buck target (it will be used in a location macro)
      bind_rw: see bind_ro
      overlay_ro: list of (source, ..., sourceN, dest) tuples where the source
                  directories on the host system are overlayed into the container at dest
                  source must be a buck target (it will be used in a location macro)
      overlay_rw: list of (source, ..., sourceN, dest) tuples where the source
                  directories on the host system are overlayed into the container at dest
                  writes to dest from inside the container will be written to
                  the last source directory in the tuple
                  source must be a buck target (it will be used in a location macro)
      tmpfs: list of paths to mount as tmpfs within the container
      cacheable: True if the result of this genrule should be saved in the buck cache
      image_override: img path
    """
    if not pre_cmd:
        pre_cmd = ""
    if not bind_ro:
        bind_ro = []
    if not bind_rw:
        bind_rw = []
    if not overlay_ro:
        overlay_ro = []
    if not overlay_rw:
        overlay_rw = []
    if not tmpfs:
        tmpfs = []

    # create a script with the command that we can bind into the container so
    # that it is easy to inspect exactly what will be run inside the container,
    # and to run it inside the -container target manually if necessary
    native.genrule(
        name = name + "-cmd",
        cmd = "echo '#!/bin/bash' > $OUT && chmod +x $OUT && echo '{}' >> $OUT".format(cmd),
        out = "cmd.sh",
        labels = ["linux-kernel"],
    )

    args = []
    binds = []
    has_out_output = False
    all_rw = []

    # bind the script into the container
    _add_src("bind_ro", "$(location :{}-cmd)".format(name), "/tmp/cmd.sh", binds, args)

    for src, dst in bind_ro:
        if not dst.startswith("/ro") and not dst.startswith("/tmp"):
            fail("RO mounts not allowed outside of /ro,/tmp (found {})".format(dst), attr = "bind_ro")
        _add_src("bind_ro", src, dst, binds, args)

    for src, dst in bind_rw:
        if not dst.startswith("/rw"):
            fail("RW mounts not allowed outside of /rw (found {})".format(dst), attr = "bind_rw")
        sources = _add_src("bind_rw", src, dst, binds, args)
        if not has_out_output and "$OUT" in sources[0]:
            has_out_output = True
        all_rw.append(sources[0])

    for ovl in overlay_ro:
        srcs = ovl[:-1]
        dst = ovl[-1]
        if not dst.startswith("/ro") and not dst.startswith("/tmp"):
            fail("RO overlays not allowed outside of /ro,/tmp (found {})".format(dst), attr = "overlay_ro")
        _add_src("overlay_ro", srcs, dst, binds, args)

    for ovl in overlay_rw:
        srcs = ovl[:-1]
        dst = ovl[-1]
        if not dst.startswith("/rw"):
            fail("RW overlays not allowed outside of /rw (found {})".format(dst), attr = "overlay_rw")
        sources = _add_src("overlay_rw", srcs, dst, binds, args)
        if not has_out_output and "$OUT" in " ".join(sources):
            has_out_output = True
        all_rw += sources

    for t in tmpfs:
        args.append("--tmpfs={}".format(t))

    # find all the host paths that are writable by the container
    if not has_out_output:
        fail("container_genrule will not output anything: {}".format(" ".join(all_rw)))

    if image_override:
        image = image_override
    else:
        image = "$(location {})".format(host_container_image())

    # before setting up the args with the user's command, generate an executable
    # script that allows a user to drop into a shell in the container, to aid in
    # debugging build changes
    native.genrule(
        name = name + "-container",
        cmd = """echo '#!/usr/bin/env bash
set -e

pwd

OUT="$OUT"
TMP="$TMP"

if [ -z "$OUT" ]; then
  OUT="`mktemp -d`"
fi
if [ -z "$TMP" ]; then
  TMP="`mktemp -d`"
fi

OUT="`realpath $OUT`"
TMP="`realpath $TMP`"

# TODO: debug why systemd-nspawn hangs on Sandcastle when trying to mount an
# image file
# just do it here and pass --directory so that it works
mnt="`mktemp -d`"
sudo mount -o ro "{image}" "$mnt"

function cleanup {{
  sudo umount "$mnt"
  rm -rf "$mnt"
  sudo chown -R "`whoami`" "$OUT"
  find "$OUT" -xtype l -delete
  sudo chown -R "`whoami`" "$TMP"
  find "$TMP" -xtype l -delete
}}
trap cleanup EXIT

{pre_cmd}

{binds}

UNIFIED_CGROUP_HIERARCHY=1 sudo systemd-nspawn \
  --hostname="$HOSTNAME" \\
  --directory="$mnt" \\
  --volatile=overlay \\
  --keep-unit --register=no \\
  --settings=no \\
  --link-journal=no \\
  --private-network \\
  --chdir=/ \\
  {args} \
  $@' > $OUT && chmod 755 $OUT
        """.format(image=image, args=" ".join(args), pre_cmd=pre_cmd, binds="\n".join(binds)),
        cacheable = True,
        executable = True,
        out = "nspawn.sh",
        labels = ["linux_kernel"],
    )

    # reuse the -container executable to run the actual build command
    native.genrule(
        name = name,
        cmd = "mkdir -p $OUT && OUT=$OUT TMP=$TMP $(exe :{}-container) /tmp/cmd.sh".format(name),
        # perhaps unintuitively, defaulting to non-cacheable is actually a performance
        # optimization preventing buck from wasting time computing (in|out)put hashes
        # and compressing potentially thousands of individual files, for example:
        # in the case of running `make` on the kernel, the output hash computing
        # step makes up a significant portion of total rule running time
        cacheable = cacheable,
        out = ".",
        labels = ["linux_kernel"],
    )

    # reuse the -container executable to run the actual build command
    native.genrule(
        name = "{}--with-logs".format(name),
        cmd = "mkdir -p $OUT && OUT=$OUT TMP=$TMP $(exe :{}-container) /tmp/cmd.sh 2>&1 | tee $OUT/compile.log".format(name),
        # perhaps unintuitively, defaulting to non-cacheable is actually a performance
        # optimization preventing buck from wasting time computing (in|out)put hashes
        # and compressing potentially thousands of individual files, for example:
        # in the case of running `make` on the kernel, the output hash computing
        # step makes up a significant portion of total rule running time
        cacheable = cacheable,
        out = ".",
        labels = ["linux_kernel"],
    )

    native.genrule(
        name = name + "-logs",
        cmd = """tr -d '\\r' < $(location :{}--with-logs)/compile.log > $OUT""".format(name),
        cacheable = cacheable,
        out = "compile.log",
        labels = ["linux_kernel"],
    )
