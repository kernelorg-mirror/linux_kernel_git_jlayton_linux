# FS_MGTIME Conversion Plan

This document describes the plan for opting additional local filesystems
into multigrain timestamps via the `FS_MGTIME` flag.

For background on the multigrain timestamp mechanism itself, see
`Documentation/filesystems/multigrain-ts.rst`.

## Background

The kernel exposes three related identifiers:

- `FS_MGTIME` — a `file_system_type::fs_flags` bit (`include/linux/fs.h:2281`).
  Set by the filesystem author to opt every inode of that FS type into
  multigrain timestamps.
- `IOP_MGTIME` — a per-inode `i_opflags` bit (`include/linux/fs.h:632`).
  Set in `inode_init_always()` (`fs/inode.c:246-247`) for every inode whose
  filesystem has `FS_MGTIME`.
- `I_CTIME_QUERIED` — `BIT(31)` of the in-memory `i_ctime_nsec` field
  (`include/linux/fs.h:1681`). Set by `fill_mg_cmtime()` to indicate that
  someone has observed the ctime since the last update; cleared by the
  next ctime update.

When the QUERIED bit is set and a subsequent modification arrives whose
truncated coarse timestamp is not strictly later than the stored ctime,
`inode_set_ctime_current()` (`fs/inode.c:2831`) acquires a fine-grained
timestamp via `ktime_get_real_ts64_mg()` and stores that instead. This
ensures the next observation will see a distinct value — required for
NFS cache coherency in particular.

## Requirements for adding FS_MGTIME

A filesystem can adopt mgtime by setting the flag if all four of the
following hold:

1. **`inode_set_ctime_current()` is used for ctime updates.** This is
   the entry point that consults the QUERIED bit and possibly switches
   to a fine-grained timestamp.

2. **The `.getattr` operation calls `generic_fillattr()`** (or uses the
   VFS default, which calls it directly). `generic_fillattr()` at
   `fs/stat.c:98` invokes `fill_mg_cmtime()` for mgtime inodes; this is
   what sets the QUERIED bit.

3. **The `.setattr` operation calls `setattr_copy()`** (or uses the VFS
   default). `setattr_copy()` at `fs/attr.c:357` dispatches to
   `setattr_copy_mgtime()` for mgtime inodes.

4. **`s_time_gran` is fine enough that mgtime can produce a visible
   change.** The fine-grained timestamp is run through
   `timestamp_truncate()` and stored. If `s_time_gran` is coarser than
   the elapsed time between the coarse and fine-grained acquisitions
   (~hundreds of nanoseconds), the fine-grained value is truncated back
   to the same on-disk value as the coarse one, defeating the purpose.

The first three are correctness/structural requirements — without them
the QUERIED bit machinery does not run. The fourth is a benefit
requirement — without it the machinery runs but produces no observable
change.

### Practical s_time_gran threshold

| s_time_gran | Effective benefit |
|-------------|-------------------|
| 1 ns        | ~100% — almost every fine-grained acquisition lands in a different bucket |
| 100 ns      | ~50–90% — comparable to the cost of `ktime_get_real_ts64_mg()` itself |
| 1 µs        | ~10–50% — depends on system speed |
| 1 ms        | <0.1% — would need a 1 ms gap between the two reads |
| 10 ms       | ~0% |
| 1 s         | 0% |

The practical cutoff is `s_time_gran <= 1 µs`. Filesystems with coarser
granularity should not opt in: mgtime adds overhead (an extra
`ktime_get_real_ts64_mg()` call per modification when QUERIED is set,
plus contention on the global `mg_floor` atomic) but cannot produce a
visible ctime change.

## Current state

Four filesystems already set `FS_MGTIME`:

| FS    | File                       | Line |
|-------|----------------------------|------|
| ext4  | `fs/ext4/super.c`          | 7504 |
| xfs   | `fs/xfs/xfs_super.c`       | 2294 |
| btrfs | `fs/btrfs/super.c`         | 2208 |
| tmpfs | `mm/shmem.c`               | 5357 |

## i_ctime_nsec audit results

A tree-wide audit of every conversion candidate confirmed that no
filesystem reads `inode->i_ctime_nsec` directly outside the mgtime
machinery itself (`fs/inode.c` and `fs/stat.c:fill_mg_cmtime()`).

Every on-disk encode path uses `inode_get_ctime_nsec()`,
`inode_get_ctime_sec()`, or `inode_get_ctime()`, all of which mask the
QUERIED bit. Several filesystems happen to have an on-disk struct
member also named `i_ctime_nsec` (e.g. `struct nilfs_inode`,
`struct f2fs_inode`, `struct ocfs2_dinode`, `struct gfs2_dinode`); these
are different fields and cannot leak the QUERIED bit to disk.

No preparatory cleanup patches are required.

## Conversion tiers

### Tier A — Real benefit, one-line patch

Each of these passes all four requirements. The patch consists of
adding `| FS_MGTIME` to the `fs_flags` field in the FS type registration.

| FS          | s_time_gran | Patch site                       |
|-------------|-------------|----------------------------------|
| jfs         | 1 ns        | `fs/jfs/super.c:931`             |
| nilfs2      | 1 ns        | `fs/nilfs2/super.c:1310`         |
| ntfs3       | 100 ns      | `fs/ntfs3/super.c:1925`          |
| ntfs (old)  | 100 ns      | `fs/ntfs/super.c:2646`           |
| udf         | 1 µs        | `fs/udf/super.c:142`             |
| ufs (ufs2)  | 1 ns        | `fs/ufs/super.c:1467`            |
| ramfs       | 1 ns        | `fs/ramfs/inode.c:322`           |
| hugetlbfs   | 1 ns        | `fs/hugetlbfs/inode.c:1493`      |

ufs1 mounts use `s_time_gran = NSEC_PER_SEC` and will not benefit; the
`FS_MGTIME` bit is set on the shared `ufs_fs_type` so this opts in both
formats. If desired, ufs1 mounts can be excluded by gating the
`IOP_MGTIME` set in the fill_super based on the ufs flavour.

### Tier B — Real benefit, code fix needed first

#### f2fs

Patch site: `fs/f2fs/super.c:5565`. Has `s_time_gran = 1`.

When `CONFIG_F2FS_FS_POSIX_ACL` is enabled, the local `__setattr_copy()`
at `fs/f2fs/file.c:1048-1068` bypasses the generic `setattr_copy()` and
sets ctime directly via `inode_set_ctime_to_ts(inode, attr->ia_ctime)`.
This skips the `setattr_copy_mgtime()` dispatch.

Fix required before opt-in: either teach the local `__setattr_copy()`
to call `setattr_copy_mgtime()` when `is_mgtime(inode)`, or refactor to
always go through the generic helper.

### Tier C — Cluster filesystems, needs analysis

#### gfs2 and ocfs2

Patch sites: `fs/gfs2/ops_fstype.c:1802`, `fs/ocfs2/super.c:1226`.
Both have `s_time_gran = 1`.

Both filesystems satisfy all four structural requirements. The concern
is ocfs2's Lock Value Block (LVB) mechanism, which caches inode
timestamps across cluster nodes:

- When a node releases an inode lock, current timestamps are written
  into the LVB.
- When another node acquires the lock, it restores timestamps from the
  LVB into the VFS inode via `inode_set_ctime_to_ts()`
  (`fs/ocfs2/dlmglue.c:2245`).

`inode_set_ctime_to_ts()` writes the nsec value verbatim. After an LVB
restore, the in-memory `i_ctime_nsec` reflects the value that was
current on the *other* node and does not encode the QUERIED state of
queries that happened locally. This is not necessarily a defect — the
QUERIED bit is conceptually local to a node — but the cross-node
semantics need explicit confirmation that mgtime's distinctness
guarantee still holds against the LVB cache.

A similar review is needed for gfs2's DLM-based timestamp coherency.

These conversions should be deferred until the LVB/DLM interactions are
verified.

### Skip list — s_time_gran too coarse

The following filesystems satisfy the structural requirements but cannot
benefit from mgtime; opting in would add overhead without producing
visible ctime changes.

| FS         | s_time_gran |
|------------|-------------|
| ext2       | 1 s         |
| exfat      | 10 ms       |
| omfs       | 1 ms        |
| affs       | 1 s         |
| bfs        | 1 s         |
| hfs        | 1 s         |
| hfsplus    | 1 s         |
| minix      | 1 s         |
| ufs (ufs1) | 1 s         |

If any of these filesystems gains finer-grained on-disk timestamps in
the future, they become Tier A candidates.

## Excluded categories

The following classes of filesystem are out of scope for mgtime:

- **Network filesystems** — timestamps come from a server, not the
  local clock: nfs, smb/cifs, ceph, 9p, afs, coda, orangefs.
- **Pseudo filesystems** — no persistent storage or no meaningful
  timestamps: proc, sysfs, debugfs, tracefs, configfs, devpts, pidfs,
  nsfs, anon_inodes, etc.
- **Read-only filesystems** — timestamps never change at runtime:
  squashfs, erofs, isofs, cramfs, romfs.
- **Stackable filesystems** — timestamps come from the lower
  filesystem: overlayfs, ecryptfs.
- **Userspace filesystems** — timestamps are externally controlled:
  fuse, virtio_fs.
- **Filesystems needing significant work** beyond a flag change: fat
  (ctime/mtime share an on-disk field; 2 s granularity), hpfs, jffs2,
  ubifs (uses `do_attr_changes()` instead of `setattr_copy()`), zonefs,
  hostfs, vboxsf.

## Per-patch changelog checklist

For each Tier A patch, the changelog should record:

1. The filesystem's `s_time_gran` value and where it is set.
2. That `.getattr` calls `generic_fillattr()` (or uses the VFS default).
3. That `.setattr` calls `setattr_copy()` (or uses the VFS default).
4. That `inode_set_ctime_current()` is used for ctime updates.
5. That on-disk encode paths use `inode_get_ctime_nsec()` /
   `inode_get_ctime()` / `inode_get_ctime_sec()`.

## Known mgtime implementation concerns

These are not blockers for Tier A/B conversions but should be tracked:

1. **Per-FS-type flag granularity.** `FS_MGTIME` is on
   `file_system_type` and translated into `IOP_MGTIME` unconditionally
   in `inode_init_always()`. There is no per-mount opt-out (e.g. a
   `nomgtime` mount option) and no way to mark individual inodes as
   exempt.

2. **Stackable filesystem handling.** overlayfs and ecryptfs do not
   propagate or care about `IOP_MGTIME` on copy-up paths. The semantics
   when an mgtime FS is used as the upper layer of an overlay are not
   defined.

3. **Global `mg_floor` contention.** `kernel/time/timekeeping.c:184`
   defines `mg_floor` as a single system-wide atomic. Every
   fine-grained acquisition does an `atomic64_try_cmpxchg()` against
   it. As more filesystems opt in, contention on this cacheline grows.
   There is no per-superblock or per-NUMA sharding.

4. **Cost paid by non-mgtime filesystems.** `inode_set_ctime_current()`
   and `current_time()` always call `ktime_get_coarse_real_ts64_mg()`,
   which reads `mg_floor` even for non-mgtime inodes.

5. **`inode_set_ctime_deleg()` race.** The retry path only handles the
   case where another task set the QUERIED bit; a concurrent writer
   that stamps a real timestamp will cause the delegation update to be
   silently dropped.

6. **`mg_floor` and realtime backward jumps.** `mg_floor` is monotonic,
   but the conversion to realtime in `ktime_get_coarse_real_ts64_mg()`
   uses the current `offs_real`. After a backward step of the realtime
   clock, on-disk ctimes can be in the future relative to the new
   `f_real`, forcing the fine-grained path on every modification.
