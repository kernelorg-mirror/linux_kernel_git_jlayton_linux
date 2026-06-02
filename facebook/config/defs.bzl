load("//facebook/bzl:flavors.td.bzl", "ARCH_X86_64", "ARCHITECTURE_TO_CONFIG_ARCH", "ARCH_FLAVORS")
load(":debug.td.bzl", "COMMON_DEBUG_OPTS", "DEBUG_OPTIONS_DEF")

# TODO(vmagro): we should probably follow the fs_image and others style of
# exporting a `struct` in each .bzl file that contains just the members we want
# exported
DEBUG_OPTIONS = DEBUG_OPTIONS_DEF

SELFTESTS = [
    # Currently bpf selftests do not build in a way which is meaningful, plus
    # they rely on enabling `CONFIG_PROVE_LOCKING`, which in turn clashes with
    # proprietary modules: https://fburl.com/diff/vdprmlzf
    # "bpf",
    "cachestat",
    "capabilities",
    "cgroup",
    "clone3",
    "core",
    "drivers",
    "exec",
    "filesystems",
    "firmware",
    "fpu",
    "ftrace",
    "futex",
    "hid",
    "iommu",
    "ipc",
    "kcmp",
    "kexec",
    # NOTE: kmod sets CONFIG_BTRFS_FS=m, which prevents us from booting VMs.
    # "kmod",
    "lib",
    "livepatch",
    "locking",
    "membarrier",
    "memfd",
    "mincore",
    "mm",
    "mount",
    "mount_setattr",
    "mqueue",
    "net",
    "openat2",
    "perf_events",
    "pidfd",
    "pid_namespace",
    "prctl",
    "proc",
    "ptp",
    "ptrace",
    # we should run rcutorture, but probably in its own test?
    "rlimits",
    "rseq",
    "sched",
    "seccomp",
    "sgx",
    # 6.13 renamed "sigaltstack" to "signal"
    "signal",
    "size",
    "splice",
    "static_keys",
    "sync",
    "sysctl",
    "timers",
    "tmpfs",
    "uevent",
    # 6.12 removed "user" selftest
    "x86",
]

def config_name(arch, flavor = None, debug = None, selftests = False, replace_arch=True):
    if replace_arch:
        name = ARCHITECTURE_TO_CONFIG_ARCH[arch]
    else:
        name = arch[:]
    if replace_arch and flavor and flavor not in ARCH_FLAVORS[arch] + ["lol2"]:
        fail("{} not an allowed flavor {} for attr {}".format(flavor, ARCH_FLAVORS[arch], "flavor"))
    if replace_arch and debug and debug not in DEBUG_OPTIONS:
        fail("{} not an allowed debug option {} for attr {}".format(debug, DEBUG_OPTIONS, "debug"))
    name += "-" + flavor if flavor else ""
    name += "-" + debug if debug else ""
    name += "-selftests" if selftests else ""
    return name

def gen_config(name = None, arch = ARCH_X86_64, flavor = None, debug = None, selftests = False):
    if name:
        name = "{}-{}".format(arch, name)
        if selftests:
            name += "-selftests"
    else:
        name = config_name(arch, flavor, debug, selftests)

    flavor = "" if not flavor else flavor
    # without debug option
    if not debug:
        selftests_cmd = ""
        if selftests:
            selftests_cmd = "&& $(exe //facebook/scripts:selftestsconfig) -a {} {} >> .config".format(arch, ' '.join(SELFTESTS))
        native.genrule(
            name = name,
            cmd = "mkdir -p facebook/config && cp -R $(location //facebook/config:files)/* facebook/config && " +
                  "$(exe //facebook/scripts:prepareconfig) {} {}".format(ARCHITECTURE_TO_CONFIG_ARCH[arch], flavor) +
                  selftests_cmd + "&& mv .config $OUT",
            out = "config",
            type = "config",
            labels = ["linux_local"],
            visibility = ["PUBLIC"],
        )
    else:
        # the debug opt genrule depends on the config without the debug option
        # (debug opt just adds another line to the config)
        without_debug = name.replace("-" + debug, "")
        selftests_cmd = ""
        if selftests:
          without_debug = without_debug.replace("-selftests", "")
          selftests_cmd = "&& $(exe //facebook/scripts:selftestsconfig) -a {} {} >> $OUT".format(arch, ' '.join(SELFTESTS))
        native.genrule(
            name = name,
            cmd = "cat $(location :{}) <(echo '{}') > $OUT {}".format(
                without_debug,
                DEBUG_OPTIONS[debug] + "\n" + COMMON_DEBUG_OPTS,
                selftests_cmd
            ),
            out = "config",
            type = "config",
            labels = ["linux_kernel"],
            visibility = ["PUBLIC"],
        )

def config(arch, name = None, flavor = None, debug = None):
    """
    Generate targets that will create the .config file used to configure the
    kernel at build time. Two sets of config targts are created:
    - Targets for regular kernel builds. That is, targets for the specified
      name, flavor, and debug options.
    - Targets that specifically enable kernel selftests. These targets provide
      exactly the same configurations as the regular targets, but also include
      whatever configurations are required in order to run selftests.
    """
    for selftests in (False, True,):
        gen_config(
            name=name,
            arch=arch,
            flavor=flavor,
            debug=debug,
            selftests=selftests,
        )
