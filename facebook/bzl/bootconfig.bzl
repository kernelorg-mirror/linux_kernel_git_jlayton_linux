load(":flavors.td.bzl", "ARCHITECTURE_TO_CONFIG_ARCH", "ARCH_FLAVORS", "ARCHITECTURES")
load(":config.bzl", "validate_flavor")
# Hacked from config.bzl.

def bootconfig_name(arch, flavor = None, replace_arch = True):
    bootconfig_name = "bootconfig-%s" % ARCHITECTURE_TO_CONFIG_ARCH[arch] if replace_arch else arch

    if flavor:
        validate_flavor(arch, flavor)
        bootconfig_name += "-" + flavor

    return bootconfig_name

def _impl(ctx: AnalysisContext) -> list[Provider]:
    prepare_bootconfig_script = ctx.attrs._bootconfig[RunInfo]
    kernel_bootconfig = ctx.actions.declare_output(".bootconfig")

    config_files_dir = ctx.actions.copied_dir(
        "config_dir",
        {s.basename: s for s in ctx.attrs.srcs},
    )

    ctx.actions.run(
        cmd_args(
            "bash",
            "-c",
            cmd_args(
                prepare_bootconfig_script,
                "-a",
                ARCHITECTURE_TO_CONFIG_ARCH[ctx.attrs.arch],
                "-f",
                ctx.attrs.flavor,
                "-p",
                config_files_dir,
                ">",
                kernel_bootconfig.as_output(),
                delimiter = " ",
            )
        ),
        category = "base",
    )

    return [
        DefaultInfo(
            default_output = kernel_bootconfig,
        )
    ]

_attrs = {
    "arch": attrs.enum(ARCHITECTURES),
    # Use attrs.one_of() to enforce that flavor is one of the allowed values.
    "flavor": attrs.string(default="none"),
    "srcs": attrs.list(attrs.source()),
    "_bootconfig": attrs.exec_dep(default = "//facebook/scripts:bootconfig"),
}

kernel_bootconfig_rule = rule(
    impl = _impl,
    attrs = _attrs,
)

def kernel_bootconfig(arch, flavor = None, srcs = []):
    """
    Generate targets that will create the facebook/config/bootconfig file
    used to create the embedded kernel boot parameters at build time.
    Note that (unlike .config) missing per-architecture and per-flavor
    bootconfig files are permitted and are treated as if they were
    empty files.
    """
    rule_name = bootconfig_name(
        arch=arch,
        flavor=flavor,
    )

    kernel_bootconfig_rule(
        name=rule_name,
        arch=arch,
        flavor=flavor,
        srcs=srcs,
    )
