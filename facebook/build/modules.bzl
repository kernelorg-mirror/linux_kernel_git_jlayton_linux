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
                cat > "$OUT" <<'SIGNEOF'
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

    KERNEL_TREE=$(location :{name}-shared-build-dir)

    # /failed-signature is a signal file to the build process to signify that
    # the signature failed. If it exists then the build process will fail.
    # Sign modules via SandcastleKernelBuildCommand (Autograph-whitelisted)
    SIGN_TMPDIR=\$(mktemp -d)
    SIGN_LOG=$SIGN_TMPDIR/signing.log
    (
        set -xe
        tar -cf $SIGN_TMPDIR/unsigned_modules.tar -C "$KERNEL_TREE" .
        EVERSTORE_HANDLE=\$(clowder put $SIGN_TMPDIR/unsigned_modules.tar --fbtype EVERSTORE_LINUX_KERNEL)
        SCUTIL_OUTPUT=\$(scutil create '{{"command":"SandcastleKernelBuildCommand","args":{{"build_mode":"signing","everstore_handle":"'$EVERSTORE_HANDLE'","sign_modules_key":"{sign_key}"}},"capabilities":{{"type":"lego","vcs":"linux-kernel-git","tenant":"kernel"}},"nonce":"'$SANDCASTLE_NONCE'","alias":"kernel-module-signing","oncall":"kernel_infra","hash":"master"}}' --await --follow-retries -v json 2>&1)
        INSTANCE_ID=\$(echo "$SCUTIL_OUTPUT" | jq -r '.id')
        STEP_LOG_HANDLE=\$(scutil get-log-info $INSTANCE_ID | grep 'handle:' | tail -1 | awk '{{print $2}}')
        SIGNED_HANDLE=\$(clowder get $STEP_LOG_HANDLE | grep -oP 'Signed Everstore handle: \K\S+')
        clowder get $SIGNED_HANDLE > $SIGN_TMPDIR/signed_modules.tar
        tar -xf $SIGN_TMPDIR/signed_modules.tar -C "$KERNEL_TREE"
    ) > "$SIGN_LOG" 2>&1 || touch "$KERNEL_TREE/failed-signature"

    echo "=== Signing log ===" >&2
    cat "$SIGN_LOG" >&2
    echo "=== End signing log ===" >&2
    rm -rf "$SIGN_TMPDIR"

    rm "$KERNEL_TREE/do-signature"
) &
SIGNEOF
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
        arch = arch,
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

modules = [
    struct(
        name = "amdgpu-kmod-2.7-27",
        url = "https://yum/yum/common/SRPMS/amdgpu-kmod-2.7-27.src.rpm",
        sha256 = "04eef1a02fbec0ec596ce7e18f4277fe54a15f00b6ce7d1fd1dafd7014472fcf",
        kernels = ["5.2"],
        flavors = ["zion","8way"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "amdgpu-kmod-3.1-44",
        url = "https://yum/yum/common/SRPMS/amdgpu-kmod-3.1-44.src.rpm",
        sha256 = "8a21ea66bae68d32a95373002823a7cd70513c9a4172e0463df8b80fd91cdf35",
        kernels = ["5.2"],
        flavors = ["zion","8way"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "amdgpu-kmod-4.3-59",
        url = "https://yum/yum/common/SRPMS/amdgpu-kmod-4.3-59.src.rpm",
        sha256 = "090aca67402354ee6593ac82072a606df6e3a77f452378c98d5eee8aedeb0759",
        kernels = ["5.6"],
        flavors = ["zion"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "amdgpu-kmod-5.11.32-1350682",
        url = "https://yum/yum/common/SRPMS/amdgpu-kmod-5.11.32-1350682.src.rpm",
        sha256 = "acfe761edc0e70abd15dbbe51d8ce7c5a037925ff5829042ceb50be7d1b40c75",
        kernels = ["5.6","5.12"],
        flavors = ["zion"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "amdgpu-kmod-5.13.11.21.50-1373477",
        url = "https://yum/yum/common/SRPMS/amdgpu-kmod-5.13.11.21.50-1373477.src.rpm",
        sha256 = "a81f364f40fa39e46abf3183d78dd25fe18f8c16a161a7fc7e13af019ceddd98",
        kernels = ["5.6","5.12"],
        flavors = ["zion"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "amdgpu-kmod-5.16.9.22.20-1438747",
        url = "https://yum/yum/common/SRPMS/amdgpu-kmod-5.16.9.22.20-1438747.src.rpm",
        sha256 = "c3137a11923f9f74903dc6041024faa77967edb4771eeed0590f5f327833802f",
        kernels = ["5.12"],
        flavors = ["zion"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "amifldrv-1.0.0-7",
        url = "https://yum/yum/common/SRPMS/amifldrv-1.0.0-7.src.rpm",
        sha256 = "95caf23e7051dfc678d0db4a7063041620a8e327961ff353d50ca645d9691a1a",
        kernels = ["5.6","5.19","5.2","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "arista_bsp_kmods-0.4.0-1",
        url = "https://yum/yum/common/SRPMS/arista_bsp_kmods-0.4.0-1.src.rpm",
        sha256 = "14b52763dbf4dbb6d85f9f74600169c5adc12edded255963c7fa16e99bcc80ff",
        kernels = ["5.19"],
        flavors = ["insecure"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "arista_bsp_kmods-0.5.0-1",
        url = "https://yum/yum/common/SRPMS/arista_bsp_kmods-0.5.0-1.src.rpm",
        sha256 = "618851d3833dc88b411b28983f1e0171bc3f78c1ff5c578ced54d5db645672d8",
        kernels = ["6.4","5.19"],
        flavors = ["insecure"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "arista_bsp_kmods-0.5.1-1",
        url = "https://yum/yum/common/SRPMS/arista_bsp_kmods-0.5.1-1.src.rpm",
        sha256 = "c8bb02a5a9f9df94bac9e4ef03db734bd769453e67d54df78466d6cc10cf8c20",
        kernels = ["6.4","5.19"],
        flavors = ["insecure"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "arista_darwin_bsp-2.1.0-1",
        url = "https://yum/yum/common/SRPMS/arista_darwin_bsp-2.1.0-1.src.rpm",
        sha256 = "84438c9d7f18316adc62844a1e176a4108f9a7488e3fdedd1de6d6f3cf51c5d8",
        kernels = ["5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "fbnic-1.00.00-1",
        url = "https://yum/yum/common/SRPMS/fbnic-1.00.00-1.src.rpm",
        sha256 = "418d40349e4a3cbbaacd032f633301970656bc5c7a616d5bba016cd7831bff7d",
        kernels = ["6.4","5.19","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "intel-i915-0.6469-1.0",
        url = "https://yum/yum/common/SRPMS/intel-i915-0.6469-1.0.src.rpm",
        sha256 = "b8964577a581952bd5ebccc651780bd7b296c01f5cb17927d93867f85fbe4c5d",
        kernels = ["5.12"],
        flavors = ["hardened","zion"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "intel-i915-0.6469EL9-1.0",
        url = "https://yum/yum/common/SRPMS/intel-i915-0.6469EL9-1.0.src.rpm",
        sha256 = "0ad15c443afb893d35f7b1226625ccf3c59c3bfeddd8b3b78129ef7b6cb6aaec",
        kernels = ["5.19"],
        flavors = ["hardened"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "liquidsec-hsm-kmod-2.08-1",
        url = "https://yum/yum/common/SRPMS/liquidsec-hsm-kmod-2.08-1.src.rpm",
        sha256 = "c9e224f047740bd7eac78c0586d96e4efbb9a60ad796e3531c183cf66b91c4ff",
        kernels = ["5.12"],
        flavors = ["hardened"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "liquidsec-hsm-kmod-2.08.01.06-1",
        url = "https://yum/yum/common/SRPMS/liquidsec-hsm-kmod-2.08.01.06-1.src.rpm",
        sha256 = "f2ecec69165e7592eb9ade431df032cf460d9a6068d37954895267f776aa1fb2",
        kernels = ["5.12"],
        flavors = ["hardened"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nfast-hsm-kmod-12.80.4-1",
        url = "https://yum/yum/common/SRPMS/nfast-hsm-kmod-12.80.4-1.src.rpm",
        sha256 = "868a07e4ec3993cd0f24bcf056d3fb167514edfde92b12e53461cff634585999",
        kernels = ["5.12"],
        flavors = ["hardened"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nfast-hsm-kmod-13.4.4-1",
        url = "https://yum/yum/common/SRPMS/nfast-hsm-kmod-13.4.4-1.src.rpm",
        sha256 = "e38e14cd263eae2d39ada65ea92379013cb4464ce6cf0293ba7faf583caa4355",
        kernels = ["5.12"],
        flavors = ["hardened"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia-grid-kmod-510.60.02-1",
        url = "https://yum/yum/common/SRPMS/nvidia-grid-kmod-510.60.02-1.src.rpm",
        sha256 = "42f9a5cd672c012e308c7818213f2d5fe2c9dee6f1852e96e730b9a3e8dfeebe",
        kernels = ["5.6","5.12"],
        flavors = ["hardened"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia-grid-kmod-525.85.05-2",
        url = "https://yum/yum/common/SRPMS/nvidia-grid-kmod-525.85.05-2.src.rpm",
        sha256 = "b45d14111543f810ffcce8727ee4e60bed540e220699f87bad47281c073cb872",
        kernels = ["5.19","5.12"],
        flavors = ["hardened"],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia-kmod-418.126.02-1",
        url = "https://yum/yum/common/SRPMS/nvidia-kmod-418.126.02-1.src.rpm",
        sha256 = "fb5a68899fa2c08e5c857d013cd1a7fa8445cfcd2b4a21b2fffe64bc5ca7b07e",
        kernels = ["5.2"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia-kmod-440.64.00-1",
        url = "https://yum/yum/common/SRPMS/nvidia-kmod-440.64.00-1.src.rpm",
        sha256 = "2b4788e957d473e3a6bceafa8f562fc47a4a7fe0cb14aa8733c97446964d1cdb",
        kernels = ["5.2"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia-kmod-450.51.05-1",
        url = "https://yum/yum/common/SRPMS/nvidia-kmod-450.51.05-1.src.rpm",
        sha256 = "b239e821ca7c9465b9003bbba59faebc43e18de674adc80383a77e3452b846e0",
        kernels = ["5.6"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia-kmod-450.80.02-1",
        url = "https://yum/yum/common/SRPMS/nvidia-kmod-450.80.02-1.src.rpm",
        sha256 = "98e07de58c78f8a07957ae7b411afd2edbcf6ba48a8631e35d9658fe9b33d683",
        kernels = ["5.6","5.2"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia-kmod-470.103.01-1",
        url = "https://yum/yum/common/SRPMS/nvidia-kmod-470.103.01-1.src.rpm",
        sha256 = "f89b68cd2cc1f160c5c84aaeda334fe81124a57edfdcde424598e396f4a786b4",
        kernels = ["5.6","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia-kmod-470.129.06-1",
        url = "https://yum/yum/common/SRPMS/nvidia-kmod-470.129.06-1.src.rpm",
        sha256 = "5540fafe77b3f6655590092af6208e94034e560730960468f17bbea74ad8722b",
        kernels = ["5.6","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia-kmod-470.57.02-3",
        url = "https://yum/yum/common/SRPMS/nvidia-kmod-470.57.02-3.src.rpm",
        sha256 = "5a198b1995543c35941b1928476f03319bdb6a63555296a6ad113bd6ee304014",
        kernels = ["5.6","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia-kmod-510.47.03-1",
        url = "https://yum/yum/common/SRPMS/nvidia-kmod-510.47.03-1.src.rpm",
        sha256 = "2cf391e9fc7ed1b76de06edc94eea6f2f84f4a55b5d7bb35093f10351ee7c3bc",
        kernels = ["5.6","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia-kmod-525.105.17-8",
        url = "https://yum/yum/common/SRPMS/nvidia-kmod-525.105.17-8.src.rpm",
        sha256 = "57e96b4300f64aa1baf9e61b03459b7474e2a6a4b5ec38b4800481df4a71984f",
        kernels = ["6.4","5.19","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64","aarch64"],
    ),
    struct(
        name = "nvidia-kmod-530.30.02-2",
        url = "https://yum/yum/common/SRPMS/nvidia-kmod-530.30.02-2.src.rpm",
        sha256 = "ebb3b199bb02fb1a8ac1effb5a2d6288f6701860fe5f246328a996c4fef857b8",
        kernels = ["5.19","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64","aarch64"],
    ),
    struct(
        name = "nvidia-open-kmod-535.129.03-2",
        url = "https://yum/yum/common/SRPMS/nvidia-open-kmod-535.129.03-2.src.rpm",
        sha256 = "6bcb2f91857b0ede349a7d33c10f65f64f0c35182fdd28075d461b0a5c646bb5",
        kernels = ["6.4","5.19","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64","aarch64"],
    ),
    struct(
        name = "nvidia-open-kmod-535.154.05-1",
        url = "https://yum/yum/common/SRPMS/nvidia-open-kmod-535.154.05-1.src.rpm",
        sha256 = "7f595453dc7416d0ddf403ce6a0499a42e2fdf538e575d30171180cf4e6e5779",
        kernels = ["6.4","5.19","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64","aarch64"],
    ),
    struct(
        name = "nvidia-open-kmod-535.86.10-2",
        url = "https://yum/yum/common/SRPMS/nvidia-open-kmod-535.86.10-2.src.rpm",
        sha256 = "9e1349760112fe604b2bfc64c12cbea5997ed9656129ede310a86706eefdc71d",
        kernels = ["6.4","5.19","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64","aarch64"],
    ),
    struct(
        name = "nvidia_peer_memory-kmod-450.51.05-1-1.1-1",
        url = "https://yum/yum/common/SRPMS/nvidia_peer_memory-1.1-1.src.rpm",
        sha256 = "aaadc29faedbb2bc9be3a23dc0f2fea8d5fe4bce9321a0006f65f583399345dd",
        kernels = ["5.6"],
        flavors = ["zion"],
        depends = ["nvidia-kmod-450.51.05-1"],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia_peer_memory-kmod-450.80.02-1-1.1-1",
        url = "https://yum/yum/common/SRPMS/nvidia_peer_memory-1.1-1.src.rpm",
        sha256 = "aaadc29faedbb2bc9be3a23dc0f2fea8d5fe4bce9321a0006f65f583399345dd",
        kernels = ["5.6"],
        flavors = ["zion"],
        depends = ["nvidia-kmod-450.80.02-1"],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia_peer_memory-kmod-470.103.01-1-1.1-1",
        url = "https://yum/yum/common/SRPMS/nvidia_peer_memory-1.1-1.src.rpm",
        sha256 = "aaadc29faedbb2bc9be3a23dc0f2fea8d5fe4bce9321a0006f65f583399345dd",
        kernels = ["5.6"],
        flavors = ["zion"],
        depends = ["nvidia-kmod-470.103.01-1"],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia_peer_memory-kmod-470.103.01-1-1.1-1",
        url = "https://yum/yum/common/SRPMS/nvidia_peer_memory-1.1-1.src.rpm",
        sha256 = "aaadc29faedbb2bc9be3a23dc0f2fea8d5fe4bce9321a0006f65f583399345dd",
        kernels = ["5.12"],
        flavors = ["zion"],
        depends = ["nvidia-kmod-470.103.01-1"],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia_peer_memory-kmod-470.57.02-3-1.1-1",
        url = "https://yum/yum/common/SRPMS/nvidia_peer_memory-1.1-1.src.rpm",
        sha256 = "aaadc29faedbb2bc9be3a23dc0f2fea8d5fe4bce9321a0006f65f583399345dd",
        kernels = ["5.6"],
        flavors = ["zion"],
        depends = ["nvidia-kmod-470.57.02-3"],
        archs = ["x86_64"],
    ),
    struct(
        name = "nvidia_peer_memory-kmod-470.57.02-3-1.1-1",
        url = "https://yum/yum/common/SRPMS/nvidia_peer_memory-1.1-1.src.rpm",
        sha256 = "aaadc29faedbb2bc9be3a23dc0f2fea8d5fe4bce9321a0006f65f583399345dd",
        kernels = ["5.12"],
        flavors = ["zion"],
        depends = ["nvidia-kmod-470.57.02-3"],
        archs = ["x86_64"],
    ),
    struct(
        name = "pciswitch-0.1.1-1",
        url = "https://yum/yum/common/SRPMS/pciswitch-0.1.1-1.src.rpm",
        sha256 = "e9d098339b03c4a7b365f8db821a8db9c19c1066993a58773b6b8413ac91dc14",
        kernels = ["5.19","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "tsync-kmod-4.0.1-1",
        url = "https://yum/yum/common/SRPMS/tsync-kmod-4.0.1-1.src.rpm",
        sha256 = "0ff0198f091557a058356851799cfcac8a2eaa9e9e3fb074c30cfa97dd645823",
        kernels = ["5.2"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "tsync-kmod-4.0.1-3",
        url = "https://yum/yum/common/SRPMS/tsync-kmod-4.0.1-3.src.rpm",
        sha256 = "5e99dc7299461fbfa3c0bc635f76e1e43e5c8e88e58cc26f08d97bcf12b90672",
        kernels = ["5.6","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    ),
    struct(
        name = "ufispace_bsp_kmods-1.0.0-1",
        url = "https://yum/yum/common/SRPMS/ufispace_bsp_kmods-1.0.0-1.src.rpm",
        sha256 = "1a5bcbd972a73090dc059848aaf8e04b6d7a8892885c0395b58842c0d66381e5",
        kernels = ["5.19","5.12"],
        flavors = [],
        depends = [],
        archs = ["x86_64"],
    )
]
