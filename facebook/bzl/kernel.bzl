load(":flavors.td.bzl", "ARCHITECTURE_TO_KERNEL_ARCH", "ARCH_X86_64", "ARCH_AARCH64", "ARCHITECTURE_TO_RPMBUILD_TARGET")
load(":config.bzl", "config_name")
load(":bootconfig.bzl", "bootconfig_name")
load(":constants.bzl", "SELFTESTS", "SelftestsType")
load(":container.bzl", "container_genrule")
load(":modules.bzl", "module")
load(":modules_list.bzl", MODULES="modules")

def is_hex(s: str) -> bool:
    for i in range(len(s)):
        if s[i] not in "0123456789abcdefABCDEF":
            return False
    return True

# Returns tuple (fbk_version, rc_version, hostfix, extraver)
def parse_fbk_tag(fbk_tag):
    # parse the rc version and fbk name out of the tag (eg v5.2-fbk1-rc1)
    fbk_pieces = fbk_tag.split("-")
    if is_hex(fbk_pieces[-1]):
        fbk_pieces=fbk_pieces[:-1]
    fbk_version = fbk_pieces[1]

    if len(fbk_pieces) == 2:
        return (fbk_version, None, None, None)

    if len(fbk_pieces) == 3:
        if "hotfix" in fbk_pieces[-1]:
            return (fbk_version, None, fbk_pieces[-1], None)

        if "rc" in fbk_pieces[-1]:
            return (fbk_version, fbk_pieces[-1], None, None)

        if "upstream" in fbk_pieces[-1]:
            return (fbk_version, None, None, "upstream")

        fail("fbk_tag supposed to have rc, hotfix or upstream suffix, it is: %s" % fbk_tag)

    if len(fbk_pieces) == 4:
        if "hotfix" in fbk_pieces[-1]:
            return (fbk_version, fbk_pieces[-2], fbk_pieces[-1], None)

        fail("fbk_tag have to look like v5.2-fbk1[-rc1|-rc1-hotfix1|-hotfix1], got: %s" % fbk_tag)

    fail("expected either 2 to 4 pieces in fbk_tag: '{}', found {}".format(fbk_tag, fbk_pieces))

def buildinfo():
    # read runtime build info from buckconfig, this allows the wrapper to insert
    # information about git state that is not accessible to buck (the same way eg
    # fbpkg builds work)
    # if invoked as just `buck` (not via the wrapper) these values will be faked
    # with the values in .buckconfig, which allows for faster iteration on local
    # builds for testing purposes
    fbk_tag = native.read_config("build_info", "fbk_tag")

    # eg: 5.2.9
    kernelversion = native.read_config("build_info", "kernelversion")
    # eg: 5.2
    major = ".".join(kernelversion.split(".")[:2])
    fbk_version, rc_version, hotfix, extraver = parse_fbk_tag(fbk_tag)

    return struct(
        major = major,
        kernelversion = kernelversion,
        # eg: 1920_gd7e71ef6c6bd
        gittish = native.read_config("build_info", "gittish"),
        # eg: fbk1
        fbk = fbk_version,
        # eg: rc1
        rc_version = rc_version,
        hotfix = hotfix,
        extraver = extraver,
        # custom_tag allows a user to inject an arbitrary string into the
        # EXTRAVERSION, for example to indicate -debug
        custom_tag = native.read_config("build_info", "custom_tag", ""),
    )

def gen_extra_version(info, flavor):
    # Historically the rpm_number was a monotonically increasing integer.
    # Starting with 5.6 this is constantly set to 0, because it is not
    # required anymore.
    rpm_number = "0"

    segments = [
        rpm_number,
        info.fbk,
        flavor,
        info.rc_version,
        info.custom_tag,
        info.extraver,
        info.gittish,
    ]

    return "_".join([str(seg) for seg in segments if seg])

def gen_kernel(
    arch,
    flavor = None,
    headers_rpm = True,
    devel_rpm = True,
    build_modules = True,
    selftests: SelftestsType = SelftestsType("none"),
    extra_srcs = None,
    labels = None,
):
    name = config_name(
        arch = arch,
        flavor = flavor,
        selftests = selftests,
        replace_arch = False,
    )

    config_target = "//facebook/config:" + config_name(
        arch = arch,
        flavor = flavor,
        selftests = selftests,
    )
    bootconfig_target = "//facebook/config:" + bootconfig_name(
        arch = arch,
        flavor = flavor,
    )
    if not labels:
        labels = []
    if not "linux_kernel" in labels:
        labels.append("linux_kernel")

    info = buildinfo()
    extra_version = gen_extra_version(info, flavor)
    uname = info.kernelversion + "-" + extra_version

    if not extra_srcs:
        extra_srcs = []

    # In the clang world we always cross-compile
    kern_arch = "ARCH={}".format(ARCHITECTURE_TO_KERNEL_ARCH[arch])

    if flavor and "train" in flavor:
        llvm_macro = "LLVM=1 CFLAGS_PGO_CLANG=-fprofile-generate"
    elif flavor and "debug" in flavor:
        llvm_macro = "LLVM=1"
    else:
        # both x86_64 and arm64 have clang PGO
        if arch == ARCH_X86_64:
            # default clang pgo kernel
            if flavor and "hardened" in flavor:
                extra_srcs += [("$(location //facebook/build:hardened-train-data)", "/tmp/vmlinux.profdata")]
            else:
                extra_srcs += [("$(location //facebook/build:clang-train-data)", "/tmp/vmlinux.profdata")]
            llvm_macro = "LLVM=1 CFLAGS_PGO_CLANG=-fprofile-use=/tmp/vmlinux.profdata"
        elif arch == ARCH_AARCH64:
            extra_srcs += [("$(location //facebook/build:aarch64-train-data)", "/tmp/vmlinux.profdata")]
            llvm_macro = "LLVM=1 CFLAGS_PGO_CLANG=-fprofile-use=/tmp/vmlinux.profdata"
        else:
            llvm_macro = "LLVM=1"

    fb_makeflags = "{} {}".format(kern_arch, llvm_macro)

    # convenience rule to inspect uname
    native.genrule(
        name = name + "-uname",
        cmd = "echo -n {} > $OUT".format(uname),
        out = "uname",
        labels = ["linux_kernel"],
    )

    native.genrule(
        name = name + "-rpmspec",
        cmd = """cp $(location //facebook/build:fb-kernel.spec.template) $OUT""",
        out = "{}-rpmspec.spec".format(name),
        labels = ["linux_kernel"],
    )

    native.genrule(
        name = name + "-config-overlay",
        cmd = "mkdir -p $OUT && cp $(location {}) $OUT/.config".format(config_target),
        out = ".",
        labels = ["linux_kernel"],
    )

    sign = native.read_config('kernel', 'sign_mod', 'false')
    sign_key = native.read_config('kernel', 'sign_mod_key', 'autograph-test')

    # run make directly before rpmbuild so that outputs may be consumed without
    # first building an rpm, and to better leverage caching and error reporting
    container_genrule(
        name = name + "-compile",
        arch = arch,
        cmd = """cd /rw/compile
        # there needs to be a writable .config
        cp /tmp/config /rw/compile/.config
        cp /tmp/bootconfig /rw/compile/.bootconfig
        cp -r /ro/source/. .
        make EXTRAVERSION=-{extra_version} {fb_makeflags} olddefconfig
        make EXTRAVERSION=-{extra_version} {fb_makeflags} -s -j`nproc`
        """.format(
            extra_version = extra_version,
            fb_makeflags = fb_makeflags,
        ),
        bind_ro = [
            ("//:sources", "/ro/source"),
            (config_target, "/tmp/config"),
            (bootconfig_target, "/tmp/bootconfig"),
            # copy in the uname target to enforce that necessary pieces get
            # re-built when the release name changes
            (":{}-uname".format(name), "/tmp/uname"),
        ] + extra_srcs,
        bind_rw = [("$OUT", "/rw/compile")],
    )
    if sign != "false":
        native.genrule(
            name = name + "-sign",
            cmd = """
            chmod +x $(location //facebook:sign-kernel-build-sh)
            $(location //facebook:sign-kernel-build-sh) \
                $(location :{name}-compile) \
                {sign_key} \
                $(location //facebook:sign-sandcastle-spec) \
                $OUT
            """.format(name = name, sign_key = sign_key),
            out = ".",
            labels = ["linux_kernel"],
        )
    else:
        native.genrule(
            name = name + "-sign",
            cmd = "mkdir -p $OUT",
            out = ".",
            labels = ["linux_kernel"],
        )
    # the vmlinuz target can be useful to be consumed directly, such as in
    # fbcode/tupperware/vmtest to launch a qemu vm from a vmlinuz extracted from
    # an rpm generated by the same release build process
    container_genrule(
        name = name + "-vmlinuz",
        arch = arch,
        cmd = "cd /rw/compile && cp `make -s image_name` /rw/out/vmlinuz",
        bind_ro = [
            # this needs to be bound to the original location as well as in the
            # overlay, since there will be some hardcoded paths in Makefiles in
            # the output directory (which we need for `make -s image_name`)
            ("//:sources", "/ro/source"),
        ],
        overlay_rw = [
            (":{}-compile".format(name), "//:sources", "$TMP", "/rw/compile"),
        ],
        bind_rw = [("$OUT", "/rw/out")],
    )

    # build the kernel in a systemd container based on the container image built
    # with tupperware's image build infra in fbcode
    #
    rpmbuild_args = []
    if flavor == "kdump":
        rpmbuild_args += ["--define", "\"_kdump 1\""]
    else:
        rpmbuild_args += ["--undefine", "_kdump"]
    if headers_rpm:
        rpmbuild_args += ["--define", "\"_headers_rpm 1\""]
    else:
        rpmbuild_args += ["--undefine", "_headers_rpm"]
    if devel_rpm:
        rpmbuild_args += ["--define", "\"_devel_rpm 1\""]
    else:
        rpmbuild_args += ["--undefine", "_devel_rpm"]
    if build_modules:
        rpmbuild_args += ["--define", "\"_modules 1\""]
    else:
        rpmbuild_args += ["--undefine", "_modules"]
    rpmbuild_args += ["--define", "\"_version {}\"".format(info.kernelversion)]
    rpmbuild_args += ["--define", "\"_release {}\"".format(extra_version)]
    rpmbuild_args += ["--define", "\"_uname {}\"".format(uname)]
    rpmbuild_args += ["--define", "\"_fb_makeopts {}\"".format(fb_makeflags)]
    if selftests in [SelftestsType("all"), SelftestsType("bpf")]:
        rpmbuild_args += ["--define", "\"_selftests 1\""]
    else:
        rpmbuild_args += ["--undefine", "_selftests"]
    if selftests == SelftestsType("all"):
        rpmbuild_args += ["--define", "\"_selftest_suites {}\"".format(" ".join(SELFTESTS))]
    if selftests == SelftestsType("bpf"):
        rpmbuild_args += ["--define", "\"_selftest_suites bpf\""]

    container_genrule(
        name = name + "-rpmbuild",
        arch = arch,
        cmd = """
            # Apply signed modules if signing was performed
            if [ -n "$$(find /tmp/signed-modules -name '*.ko' -print -quit 2>/dev/null)" ]; then
                echo "Applying signed kernel modules..."
                cp -a /tmp/signed-modules/. /rw/kernel/
            fi
            rpmbuild \\
            --target={target} \\
            --noclean \\
            {args} \\
            -bb /ro/kernel.spec
            cp -R /root/rpmbuild/RPMS/{arch}/*.rpm /rw/rpms
        """.format(
              name=name,
              arch=arch,
              target=ARCHITECTURE_TO_RPMBUILD_TARGET[arch],
              args=" ".join(rpmbuild_args),
        ),
        bind_ro = extra_srcs + [
            (":{}-rpmspec".format(name), "/ro/kernel.spec"),
            (":{}-sign".format(name), "/tmp/signed-modules"),
        ],
        overlay_rw = [
            (":{}-compile".format(name), "//:sources", "$TMP", "/rw/kernel"),
        ],
        bind_rw = [
            ("$OUT", "/rw/rpms"),
        ],
    )

    # # make additional targets for each of the rpms - this makes them easier to
    # # consume without knowing what the full name will be a-priori
    native.genrule(
        name = name + ".rpm",
        cmd = "cp $(location :{}-rpmbuild)/kernel-{}.{}.rpm $OUT".format(name, uname, arch),
        out = "kernel.rpm",
        labels = ["linux_kernel"],
        visibility = ["PUBLIC"],
    )
    native.genrule(
        name = name + "-devel.rpm",
        cmd = "cp $(location :{}-rpmbuild)/kernel-devel-*.rpm $OUT".format(name),
        out = "kernel-devel.rpm",
        labels = ["linux_kernel"],
        visibility = ["PUBLIC"],
    )
    native.genrule(
        name = name + "-headers.rpm",
        cmd = "cp $(location :{}-rpmbuild)/kernel-headers-*.rpm $OUT".format(name),
        out = "kernel-headers.rpm",
        labels = ["linux_kernel"],
        visibility = ["PUBLIC"],
    )
    if selftests == SelftestsType("all"):
            native.genrule(
                name = name + "-selftests.rpm",
                cmd = "cp $(location :{}-rpmbuild)/kernel-selftests-*.rpm $OUT".format(name),
                out = "kernel-selftests.rpm",
                labels = ["linux_kernel"],
                visibility = ["PUBLIC"],
            )
    elif selftests == SelftestsType("bpf"):
            native.genrule(
                name = name + "-bpf-selftests.rpm",
                cmd = "cp $(location :{}-rpmbuild)/kernel-bpf-selftests-*.rpm $OUT".format(name),
                out = "kernel-bpf-selftests.rpm",
                labels = ["linux_kernel"],
                visibility = ["PUBLIC"],
            )

    # allow an escape hatch to not build modules, even if they exist in the config
    kmods = [m for m in MODULES if info.major in m.kernels]
    # if a module is set to build on only certain flavors, filter it out
    if not flavor:
        # non-flavored flavor is insecure for kernel-external kmods
        flavor = "insecure"
    kmods = [m for m in kmods if flavor in m.flavors or not m.flavors]
    # Remove the modules that do not match the architecture
    kmods = [m for m in kmods if arch in m.archs]

    disable_kmod = native.read_config("build_info", "disable_kmod")

    if build_modules and kmods and disable_kmod != "True" and flavor != "debug":
        cmd_str_list = []

        for mod in kmods:
            deps = []
            d = 0
            for dep in mod.depends:
                d += 1
                tpl = (
                    "$(location :{}-module_{}-rpmbuild)".format(name, dep),
                    "/tmp/dependency-{}-{}".format(d, dep)
                )
                deps.append(tpl)
            module(
                name = "{}-module_{}".format(name, mod.name),
                arch = arch,
                module = mod,
                kernel_devel = "$(location :{}-devel.rpm)".format(name),
                uname = uname,
                dependencies = deps,
            )
            cmd_str_list.append("$(location :{}-module_{})/*.rpm".format(name, mod.name))

        native.genrule(
            name = name + "-modules",
            out = ".",
            cmd = "mkdir -p $OUT && cp {} $OUT/".format(" ".join(cmd_str_list)),
            labels = ["linux_kernel"],
        )
        module_rpms = "$(location :{}-modules)/*.rpm".format(name)
    else:
        module_rpms = " "

    # the named output should be a directory of all RPMs for the kernel,
    # including modules if any
    native.genrule(
        name = name,
        type = "kernel",
        out = ".",
        cmd = "mkdir -p $OUT && cp $(location :{}-rpmbuild)/*.rpm {} $OUT/".format(name, module_rpms),
        labels = labels,
    )

    native.genrule(
        name = name + "-bundle",
        out = ".",
        cmd = """
            cp $(location :{target})/* $OUT && \
            cp $(location :{target}-uname) $OUT
        """.format(target=name),
        labels = ["linux_kernel"],
    )

    # Provide a target that will create a tarball of the RPMs created by the
    # top-level kernel target, that kernelctl can install.
    native.genrule(
        name = name + "-tar-pkg",
        out = ".",
        cmd = "tar -C $(location :{}-bundle) -czf $OUT/blobby.tgz .".format(name),
        labels = ["linux_kernel"],
    )


def kernel(
    arch,
    flavor = None,
    headers_rpm = True,
    devel_rpm = True,
    build_modules = True,
    extra_srcs = None,
    labels = None,
):
    """
    Generate two sets of kernel targets:
      - A regular kernel target that includes all of the aforementioned
        specified configurations, such as flavor, debug options, etc.
      - A kernel specifically designed to run Linux kernel selftests. That is, a
        kernel that includes all of the configurations required for the flavor,
        debug options, etc, and also the config options required to be compiled
        by the selftests in order to run.
    """

    for selftests in SelftestsType.values():
        gen_kernel(
            arch=arch,
            flavor=flavor,
            headers_rpm=headers_rpm,
            devel_rpm=devel_rpm,
            build_modules=build_modules,
            selftests=SelftestsType(selftests),
            extra_srcs=extra_srcs,
            labels=labels,
        )

def validate_config():
    if read_config("build_info", "provided") != "True":
        warn_msg = "CAUTION!!! You're running buck without a config script, you probably want to run `buck2 <COMMAND> $(facebook/build/buck-config) <TARGET> <ARGS>`"
        warning("#" * len(warn_msg))
        warning(warn_msg)
        warning("#" * len(warn_msg))
