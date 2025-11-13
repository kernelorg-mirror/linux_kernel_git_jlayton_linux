BUILD_IMAGE_X86_64_URI="https://interncache-all.fbcdn.net/manifold/linux_kernel/tree/build_images/D72321848.c9.llvm19.x86_64"
BUILD_IMAGE_X86_64_SHA256="f0529462148f1d71bc92d4292cfe96f727ad7fd88a0646bda05877c05c8250c2"

BUILD_IMAGE_AARCH64_URI="https://interncache-all.fbcdn.net/manifold/linux_kernel/tree/build_images/D68645928.c9.llvm19.aarch64"
BUILD_IMAGE_AARCH64_SHA256="41288b4fcb842e08a196c5c68da13bad0cba644a2d46de1dfe0ac7a0cc76c51c"

KPATCH_BUILD_RPM_URI="http://yum/yum/centos/9/backports/x86_64/RPMS/kpatch-build-0.9.11-0.1.hs.el9.x86_64.rpm"
KPATCH_BUILD_RPM_SHA256="7a17717d3c8213ea848dc2205deaf62889ca7672ddd28e10a34435194e68a19b"

CLANG_TRAIN_DATA_URI="https://interncache-all.fbcdn.net/manifold/linux_kernel/tree/clang_train_data/v613/profdata.6.13.2-0_fbk2_clangtrain_rc4_0_g11312d0b0da1.7200s.yhs.2025-05-20-11-32-59"
CLANG_TRAIN_DATA_SHA256="92361b83018ba3568000bbf3e90bd48849de0a4f2942973056a48fd68b9109a3"

HARDENED_TRAIN_DATA_URI="https://interncache-all.fbcdn.net/manifold/linux_kernel/tree/clang_train_data/v613/profdata.6.13.2-0_fbk2_clangtrain_rc4_0_g11312d0b0da1.7200s.yhs.2025-05-20-11-32-59"
HARDENED_TRAIN_DATA_SHA256="92361b83018ba3568000bbf3e90bd48849de0a4f2942973056a48fd68b9109a3"

AARCH64_TRAIN_DATA_URI="https://interncache-all.fbcdn.net/manifold/linux_kernel/tree/clang_train_data/v613/aarch64/vmlinux.profdata.aarch64.1050"
AARCH64_TRAIN_DATA_SHA256="cfad06ec875e343cbee20dacd121d460de50ae455c39c5f3a6050a6ecae57851"

SelftestsType = enum("none", "all", "bpf")

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
    # "user",
    "x86",
]
