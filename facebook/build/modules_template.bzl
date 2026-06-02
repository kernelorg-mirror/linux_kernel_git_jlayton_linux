load("//facebook/build:container.bzl", "container_genrule")

# This file is concated with the modules coming from configerator
# before being used

def standalone_module():
    kernel_version = native.read_config("kernel", "version")
    arch = native.read_config("kernel", "arch", "x86_64")
    name = native.read_config("kernel", "module")
    module_srpm = native.read_config("kernel", "module_srpm", None)
    kernel_devel = native.read_config("kernel", "devel_rpm", None)


    if kernel_devel:
        native.genrule(
            name = "kernel-devel",
            cmd = "mkdir -p $OUT && cp {} $OUT/kernel-devel.rpm".format(kernel_devel),
            out = "kernel-devel",
            labels = ["linux_kernel"],
        )
    else:
        native.genrule(
            name = "kernel-devel",
            cmd = "mkdir -p $OUT && kerctl download --devel --arch {} --out-dir $OUT {} && mv $OUT/*.rpm $OUT/kernel-devel.rpm".format(arch, kernel_version),
            out = "kernel-devel",
            labels = ["linux_kernel"],
        )

    for mod in modules:
        if mod.name != name:
            continue
        deps = []
        d = 0
        for dep in mod.depends:
            d += 1
            native.genrule(
                name = "dependency-{}".format(dep),
                cmd = "mkdir -p $OUT ; kerctl download --arch {} --module {} --out-dir $OUT {}".format(arch, dep, kernel_version),
                out = "dependency-{}".format(dep),
                labels = ["linux_kernel"],
            )
            tpl = (
                "$(location :dependency-{})".format(dep),
                "/tmp/dependency-{}-{}".format(d, dep)
            )
            deps.append(tpl)
        module(
            name = "{}-{}".format(name, kernel_version),
            arch = arch,
            module = mod,
            kernel_devel = "$(location :kernel-devel)/kernel-devel.rpm",
            dependencies = deps,
            local_srpm=module_srpm,
        )
        native.genrule(
            name = "standalone_module",
            cmd = "mkdir -p $OUT && cp -a $(location :{}-{})/*.rpm $OUT".format(name, kernel_version),
            out = "rpmdir",
            labels = ["linux_kernel"],
        )

        break


def module(name, arch, module, kernel_devel, uname=None, dependencies=None, local_srpm=None):
    if not module.url.startswith("http") and not local_srpm:
        local_srpm = module.url

    if not local_srpm:
        native.genrule(
            name="{}.src.rpm".format(name),
            cmd="curl {} -o $OUT".format(module.url),
            out="{}.src.rpm".format(name),
            labels=[
                "linux_kernel",
                "module",
            ],
        )
    else:
        native.genrule(
            name="{}.src.rpm".format(name),
            cmd="cp {} $OUT".format(local_srpm),
            out="{}.src.rpm".format(name),
            labels = ["linux_kernel"],
        )

    if uname:
        native.genrule(
            name = "uname-{}".format(name),
            cmd = "echo {} > $OUT".format(uname),
            out = "uname",
            labels = ["linux_kernel"],
        )
    else:
        # determine uname from rpm -ql of kernel-devel
        native.genrule(
            name = "uname-{}".format(name),
            cmd = "rpm -qp --queryformat '%{version}-%{release}' " + "{} > $OUT".format(kernel_devel),
            out = "uname",
            labels = ["linux_kernel"],
        )

    native.genrule(
        name = name + "-shared-build-dir",
        cmd = """
            OUT=`realpath $OUT`
            sudo rm -rf $OUT
            mkdir -p $OUT
        """,
        out = ".",
        labels = ["linux_kernel"],
    )

    bind_ro = [
        (":{}.src.rpm".format(name), "/tmp/module.src.rpm"),
        (kernel_devel, "/tmp/kernel-devel.rpm"),
        ("$(location :uname-{})".format(name), "/tmp/uname")
    ]

    if dependencies:
        for dep in dependencies:
            bind_ro.append(dep)

    # Build an rpmmacro config that uses a do-signature semaphore file inside
    # the container to trigger autograph outside the container.
    # Yay escaping backslashes all the way down.
    native.genrule(
        name = name + "-rpmmacros",
        cmd = """
                cat > "$OUT" <<EOF
%__spec_install_post\\\\
%{?__debug_package:%{__debug_install_post}}\\\\
%{__arch_install_post}\\\\
%{__os_install_post}\\\\
touch /rw/BUILDROOT/do-signature\\\\
while [ -e /rw/BUILDROOT/do-signature ]; do sleep 10; done\\\\
%{nil}
EOF
""",
        out = "rpmmacros",
        labels = ["linux_kernel"],
    )

    sign = native.read_config('kernel', 'sign_mod', 'false')
    sign_key = native.read_config('kernel', 'sign_mod_key', 'hsm-test-key')

    if sign != "false":
        native.genrule(
            name = name + "-sign-wrapper",
            cmd = """
                cat > "$OUT" <<EOF
#!/bin/sh

# Start the signature waiter in a background subshell
(
    while [ ! -e "$(location :{name}-shared-build-dir)/do-signature" -a \
            ! -e "$(location :{name}-shared-build-dir)/abort-signature" -a \
            -e "$(location :{name}-shared-build-dir)" ]; do
        sleep 10
    done
    # If the build dir doesn't exist any more then assume we're cleaning up.
    # If the abort touch file is set then just exit the subshell.
    if [ -e "$(location :{name}-shared-build-dir)/abort-signature" -o \
         ! -e "$(location :{name}-shared-build-dir)" ]; then
        exit
    fi
    # /failed-signature is a signal file to the build process to signify that
    # the signature failed.  If it exists then the build process will fail.
    sudo autograph_client.par kmod --sign-key {sign_key} \
        --kernel-tree "$(location :{name}-shared-build-dir)" || \
        touch "$(location :{name}-shared-build-dir)/failed-signature"

    rm "$(location :{name}-shared-build-dir)/do-signature"
) &
EOF
                chmod +x "$OUT"
""".format(name = name, sign_key = sign_key),
            out = "signature-wrapper.sh",
            labels = ["linux_kernel"],
        )

        bind_ro.append((":{}-rpmmacros".format(name), "/tmp/rpmmacros"))
    else:
        native.genrule(
            name = name + "-sign-wrapper",
            cmd = "ln -s /bin/true \"$OUT\"",
            out = "signature-wrapper.sh",
            labels = ["linux_kernel"],
        )

    build_prep = """
        rm -rf /root/rpmbuild/BUILDROOT
        mkdir -p /root/rpmbuild/
        ln -s /rw/BUILDROOT /root/rpmbuild/BUILDROOT
        [ -f "/tmp/rpmmacros" ] && cp /tmp/rpmmacros /root/.rpmmacros
        mkdir -p /fbgcc/bin
        [ -f "/fbgcc/bin/gcc" ] || ln -s /usr/bin/gcc /fbgcc/bin/gcc
        [ -f "/fbgcc/bin/cc" ] || ln -s /usr/bin/gcc /fbgcc/bin/cc
        if ls /tmp/dependency*/*.rpm; then
            rpm -ivh --ignorearch /tmp/dependency*/*.rpm
        fi
        rpm -Uvh --ignorearch /tmp/kernel-devel.rpm
    """

    #
    # `--define "using_clang 1"' is the old way to say "use Clang", and is
    # respected by all existing modules. This will continue to work on x86_64.
    #
    # `--with llvm_cross' is the new way to build with Clang, and requires
    # .spec files to be updated. This is required to build for aarch64 and
    # desired to build correctly (i.e. the same way as the kernel) for x86_64.
    #
    # Once all modules are ported to respect `--with llvm_cross' we
    # can delete `--define "using_clang 1"'.
    #
    container_genrule(
        name = name + "-rpmbuild",
        pre_cmd = "$(location :{}-sign-wrapper)".format(name),
        cmd = """
            {build_prep}
            rpmbuild -rb /tmp/module.src.rpm \
            --target {arch} \
            --define "rpm_kernel_version {uname}" \
            --define "kernel_version {uname}" \
            --define "using_clang 1" \
            --with llvm_cross || touch /rw/BUILDROOT/abort-signature
            if [ -f /rw/BUILDROOT/failed-signature ]; then
                echo "Failed to sign module"
                exit 1
            fi
            cp -R /root/rpmbuild/RPMS/{arch}/*.rpm /rw/rpms
        """.format(uname = "\$(cat /tmp/uname)", build_prep = build_prep, arch = arch),
        bind_ro = bind_ro,
        bind_rw = [
            ("$OUT", "/rw/rpms"),
            (":{}-shared-build-dir".format(name), "/rw/BUILDROOT/"),
        ],
        tmpfs = ["/fbgcc"],
    )


    native.genrule(
        name = name,
        out = ".",
        cmd = """
            sudo rm -rf $(location :{name}-shared-build-dir)
            mkdir -p $OUT && cp $(location :{name}-rpmbuild)/*.rpm $OUT
        """.format(name = name),
        type = "module",
        labels = ["linux_kernel"],
    )
