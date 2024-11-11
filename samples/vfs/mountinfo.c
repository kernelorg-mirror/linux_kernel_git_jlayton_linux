#include <stdio.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <linux/pidfd.h>
#include <linux/mount.h>
#include <linux/nsfs.h>
#include <unistd.h>
#include <alloca.h>
#include <getopt.h>
#include <stdlib.h>
#include <stdbool.h>
#include <errno.h>

/* max mounts per listmount call */
#define MAXMOUNTS		1024

/* size of struct statmount (including trailing string buffer) */
#define STATMOUNT_BUFSIZE	4096

/*
 * There are no bindings in glibc for listmount() and statmount() (yet),
 * make our own here.
 */
static int statmount(uint64_t mnt_id, uint64_t mnt_ns_id, uint64_t mask,
			    struct statmount *buf, size_t bufsize,
			    unsigned int flags)
{
	struct mnt_id_req req = {
		.size = MNT_ID_REQ_SIZE_VER0,
		.mnt_id = mnt_id,
		.param = mask,
	};

	if (mnt_ns_id) {
		req.size = MNT_ID_REQ_SIZE_VER1;
		req.mnt_ns_id = mnt_ns_id;
	}

	return syscall(__NR_statmount, &req, buf, bufsize, flags);
}

static ssize_t listmount(uint64_t mnt_id, uint64_t mnt_ns_id,
			 uint64_t last_mnt_id, uint64_t list[], size_t num,
			 unsigned int flags)
{
	struct mnt_id_req req = {
		.size = MNT_ID_REQ_SIZE_VER0,
		.mnt_id = mnt_id,
		.param = last_mnt_id,
	};

	if (mnt_ns_id) {
		req.size = MNT_ID_REQ_SIZE_VER1;
		req.mnt_ns_id = mnt_ns_id;
	}

	return syscall(__NR_listmount, &req, list, num, flags);
}

static void show_mnt_attrs(uint64_t flags)
{
	printf("%s", flags & MOUNT_ATTR_RDONLY ? "ro" : "rw");

	if (flags & MOUNT_ATTR_NOSUID)
		printf(",nosuid");
	if (flags & MOUNT_ATTR_NODEV)
		printf(",nodev");
	if (flags & MOUNT_ATTR_NOEXEC)
		printf(",noexec");
	if (flags & MOUNT_ATTR_NOATIME)
		printf(",noatime");
	if (flags & MOUNT_ATTR_RELATIME)
		printf(",relatime");
	if (flags & MOUNT_ATTR_NOSYMFOLLOW)
		printf(",nosymfollow");
	if (flags & MOUNT_ATTR_IDMAP)
		printf(",idmapped");
}

static void show_propagation(struct statmount *sm)
{
	if (sm->mnt_propagation & MS_SHARED)
		printf(" shared:%llu", sm->mnt_peer_group);
	if (sm->mnt_propagation & MS_SLAVE) {
		printf(" master:%llu", sm->mnt_master);
		if (sm->mnt_master)
			printf(" propagate_from:%llu", sm->propagate_from);
	}
	if (sm->mnt_propagation & MS_UNBINDABLE)
		printf(" unbindable");
}

static void show_sb_flags(uint64_t flags)
{
	printf("%s", flags & MS_RDONLY ? "ro" : "rw");
	if (flags & MS_SYNCHRONOUS)
		printf(",sync");
	if (flags & MS_DIRSYNC)
		printf(",dirsync");
	if (flags & MS_MANDLOCK)
		printf(",mand");
	if (flags & MS_LAZYTIME)
		printf(",lazytime");
}

static int dump_mountinfo(uint64_t mnt_id, uint64_t mnt_ns_id)
{
	int ret;
	struct statmount *buf = alloca(STATMOUNT_BUFSIZE);
	const uint64_t mask = STATMOUNT_SB_BASIC | STATMOUNT_MNT_BASIC |
				STATMOUNT_PROPAGATE_FROM | STATMOUNT_FS_TYPE |
				STATMOUNT_MNT_ROOT | STATMOUNT_MNT_POINT |
				STATMOUNT_MNT_OPTS | STATMOUNT_FS_SUBTYPE |
				STATMOUNT_SB_SOURCE;

	ret = statmount(mnt_id, mnt_ns_id, mask, buf, STATMOUNT_BUFSIZE, 0);
	if (ret < 0) {
		perror("statmount");
		return 1;
	}
	printf("0x%lx 0x%lx %u:%u %s %s ", mnt_id, buf->mnt_parent_id,
				   buf->sb_dev_major, buf->sb_dev_minor,
				   &buf->str[buf->mnt_root],
				   &buf->str[buf->mnt_point]);
	show_mnt_attrs(buf->mnt_attr);
	show_propagation(buf);

	printf(" - %s", &buf->str[buf->fs_type]);
	if (buf->mask & STATMOUNT_FS_SUBTYPE)
		printf(".%s", &buf->str[buf->fs_subtype]);
	if (buf->mask & STATMOUNT_SB_SOURCE)
		printf(" %s", &buf->str[buf->sb_source]);
	else
		printf(":none");

	show_sb_flags(buf->sb_flags);
	printf(",%s\n", &buf->str[buf->mnt_opts]);
	return 0;
}

static int dump_mounts(uint64_t mnt_ns_id)
{
	uint64_t mntid[MAXMOUNTS];
	uint64_t last_mnt_id = 0;
	ssize_t count;
	int i;

	/* Grab a list of mounts in mnt_ns_id */
	do {
		count = listmount(LSMT_ROOT, mnt_ns_id, last_mnt_id, mntid, MAXMOUNTS, 0);
		if (count < 0 || count > MAXMOUNTS) {
			errno = count < 0 ? errno : count;
			perror("listmount");
			return 1;
		}

		for (i = 0; i < count; ++i) {
			int ret = dump_mountinfo(mntid[i], mnt_ns_id);
			if (ret != 0)
				return ret;
		}
		last_mnt_id = mntid[count - 1] + 1;
	} while (count == MAXMOUNTS);
	return 0;
}

int main(int argc, char * const *argv)
{
	struct mnt_ns_info mni = { .size = MNT_NS_INFO_SIZE_VER0 };
	int pidfd, mntns, ret, opt;
	pid_t pid = getpid();
	bool recursive = false;

	while ((opt = getopt(argc, argv, "p:r")) != -1) {
		switch (opt) {
		case 'p':
			pid = atoi(optarg);
			break;
		case 'r':
			recursive = true;
			break;
		}
	}

	/* Get a pidfd for pid */
	pidfd = syscall(SYS_pidfd_open, pid, 0);
	if (pidfd < 0) {
		perror("pidfd_open");
		return 1;
	}

	/* Get the mnt namespace for pidfd */
	mntns = ioctl(pidfd, PIDFD_GET_MNT_NAMESPACE, NULL);
	if (mntns < 0) {
		perror("PIDFD_GET_MNT_NAMESPACE");
		return 1;
	}
	close(pidfd);

	/* get info about mntns. In particular, the mnt_ns_id */
	ret = ioctl(mntns, NS_MNT_GET_INFO, &mni);
	if (ret < 0) {
		perror("NS_MNT_GET_INFO");
		return 1;
	}

	do {
		int ret;

		ret = dump_mounts(mni.mnt_ns_id);
		if (ret)
			return ret;

		if (!recursive)
			break;

		/* get the next mntns (and overwrite the old mount ns info) */
		ret = ioctl(mntns, NS_MNT_GET_NEXT, &mni);
		close(mntns);
		mntns = ret;
	} while (mntns >= 0);

	return 0;
}
