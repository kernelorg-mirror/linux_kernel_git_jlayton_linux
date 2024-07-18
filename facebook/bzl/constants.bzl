BUILD_IMAGE_X86_64_URI="https://interncache-all.fbcdn.net/manifold/linux_kernel/tree/build_images/D54352581.c9.x86_64"
BUILD_IMAGE_X86_64_SHA256="e70627dfeb1f00fe8527b6378c24af34179f5da4deda02a1c90d9482e5c27b25"

BUILD_IMAGE_AARCH64_URI="https://interncache-all.fbcdn.net/manifold/linux_kernel/tree/build_images/D54352581.c9.aarch64"
BUILD_IMAGE_AARCH64_SHA256="0e91aa671d120c160601cea52b32b7e3ecc0b08ca59b4647ac78ac072c98a354"

KPATCH_BUILD_RPM_URI="http://yum/yum/centos/9/backports/x86_64/RPMS/kpatch-build-0.9.8-1.3.hs.el9.x86_64.rpm"
KPATCH_BUILD_RPM_SHA256="b2edfd1d3756794088c320f5cf9adcc0d72afcf0bb646717e99033b98138805f"

CLANG_TRAIN_DATA_URI="https://interncache-all.fbcdn.net/manifold/linux_kernel/tree/clang_train_data/v69/profdata.6.9.0-0_fbk0_clangtrain_rc14_882_g0454ed39ffdd.7200s.yhs.2024-06-23-13-54-38"
CLANG_TRAIN_DATA_SHA256="5f2293c5550094f609045056357d2ef34b6360ced418ba531671a20b99eb34f1"

HARDENED_TRAIN_DATA_URI="https://interncache-all.fbcdn.net/manifold/linux_kernel/tree/clang_train_data/v69/profdata.6.9.0-0_fbk0_clangtrain_rc14_882_g0454ed39ffdd.7200s.yhs.2024-06-23-13-54-38"
HARDENED_TRAIN_DATA_SHA256="5f2293c5550094f609045056357d2ef34b6360ced418ba531671a20b99eb34f1"

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
    "sigaltstack",
    "size",
    "splice",
    "static_keys",
    "sync",
    "sysctl",
    "timers",
    "tmpfs",
    "uevent",
    "user",
    "x86",
]
